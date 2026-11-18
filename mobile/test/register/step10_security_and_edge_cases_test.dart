import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' hide Column, isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pasalx_mobile/core/database/app_database.dart';
import 'package:pasalx_mobile/core/database/money.dart';
import 'package:pasalx_mobile/core/printer/printer.dart';
import 'package:pasalx_mobile/core/providers/foundation_providers.dart';
import 'package:pasalx_mobile/core/security/keystore_dek_manager.dart';
import 'package:pasalx_mobile/core/security/ram_key_holder.dart';
import 'package:pasalx_mobile/core/theme/app_theme.dart';
import 'package:pasalx_mobile/features/pos/data/pos_repository.dart';
import 'package:pasalx_mobile/features/pos/domain/pos_models.dart';
import 'package:pasalx_mobile/features/register/data/register_repository.dart';
import 'package:pasalx_mobile/features/register/presentation/petty_expense_sheet.dart';
import 'package:pasalx_mobile/features/register/presentation/register_screen.dart';
import 'package:pasalx_mobile/features/settings/presentation/settings_screen.dart';
import 'package:pasalx_mobile/features/suppliers/data/supplier_repository.dart';
import 'package:pasalx_mobile/features/suppliers/presentation/supplier_sheets.dart';
import 'package:pasalx_mobile/features/suppliers/presentation/suppliers_screen.dart';
import 'package:uuid/uuid.dart';

class _InMemoryStore implements SecureKeyValueStore {
  final Map<String, String> _data = <String, String>{};
  @override
  Future<void> delete(String key) async => _data.remove(key);
  @override
  Future<String?> read(String key) async => _data[key];
  @override
  Future<void> write(String key, String value) async => _data[key] = value;
}

class _FixedDbNotifier extends ActiveDatabaseNotifier {
  _FixedDbNotifier(this._db);
  final AppDatabase _db;
  @override
  AppDatabase? build() => _db;
}

Future<void> _unmount(WidgetTester tester, AppDatabase db) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await db.close();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const uuid = Uuid();

  late AppDatabase db;
  late SupplierRepository supplierRepo;
  late RegisterRepository registerRepo;
  late PosRepository posRepo;
  final ownerId = uuid.v4();
  final staffId = uuid.v4();

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    supplierRepo = SupplierRepository(db);
    registerRepo = RegisterRepository(db);
    posRepo = PosRepository(db: db);

    await db.upsertAuthenticatedUser(
      id: ownerId,
      name: 'Sita Owner',
      username: 'owner',
      role: 'OWNER',
    );
    await db.upsertAuthenticatedUser(
      id: staffId,
      name: 'Ram Staff',
      username: 'ram',
      role: 'STAFF',
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('Security: STAFF role rejected at repository layer for Suppliers & Z-Report/ForceClose',
      () async {
    final sup = await supplierRepo.saveSupplier(
      role: 'OWNER',
      name: 'Test Distributor',
    );
    await (db.update(db.suppliers)..where((t) => t.id.equals(sup.id))).write(
      const SuppliersCompanion(
        totalPurchased: Value(10000),
        balanceDue: Value(10000),
      ),
    );
    final opened = await db.openRegisterShiftAndPunchIn(
      userId: ownerId,
      deviceCode: '01',
      openingFloatPaisa: 100000,
    );
    final staffSess = await db.punchInToExistingShift(
      registerShiftId: opened.shift.id,
      userId: staffId,
      deviceCode: '02',
    );

    await expectLater(
      supplierRepo.saveSupplier(role: 'STAFF', name: 'Blocked Co'),
      throwsStateError,
    );
    await expectLater(
      supplierRepo.recordSupplierPayment(
        role: 'STAFF',
        supplierId: sup.id,
        amountPaisa: 5000,
        paymentMethod: 'CASH',
        createdByUserId: staffId,
      ),
      throwsStateError,
    );
    await expectLater(
      registerRepo.forceCloseStaffSession(
        sessionId: staffSess.id,
        managerUserId: staffId,
        managerRole: 'STAFF',
      ),
      throwsStateError,
    );
    await expectLater(
      registerRepo.closeShiftAndGenerateZReport(
        shiftId: opened.shift.id,
        closedByUserId: staffId,
        closedByRole: 'STAFF',
        actualCashCountedPaisa: 100000,
        cashWithdrawnDepositPaisa: 0,
        retainedNextDayFloatPaisa: 100000,
      ),
      throwsStateError,
    );
  });

  test('Z-Report Edge Cases: Negative expected cash, discrepancy overflow guard & duplicate active sessions cleanup',
      () async {
    final opened = await db.openRegisterShiftAndPunchIn(
      userId: ownerId,
      deviceCode: '01',
      openingFloatPaisa: 100000, // Rs. 1,000
    );

    // Spend Rs. 2,500 CASH -> expectedCash becomes -150000 (-Rs. 1,500)
    await supplierRepo.recordPettyExpense(
      category: 'Courier / Delivery',
      title: 'Emergency COD Delivery',
      amountPaisa: 250000,
      paymentMethod: 'CASH',
      shiftId: opened.shift.id,
      createdByUserId: ownerId,
    );
    final mid = await db.fetchOpenRegisterShift();
    expect(mid!.expectedCash, -150000);

    // Insert a duplicate ACTIVE session row for same user/device to test cleanup
    await db.into(db.staffShiftSessions).insert(
          StaffShiftSessionsCompanion.insert(
            id: uuid.v4(),
            registerShiftId: opened.shift.id,
            userId: ownerId,
            deviceCode: '01',
            status: const Value('ACTIVE'),
          ),
        );

    await registerRepo.punchOutCurrentStaff(
      shiftId: opened.shift.id,
      userId: ownerId,
      deviceCode: '01',
    );

    // Zero active sessions should remain
    final activeLeft = await (db.select(db.staffShiftSessions)
          ..where(
            (t) =>
                t.registerShiftId.equals(opened.shift.id) &
                t.status.equals('ACTIVE'),
          ))
        .get();
    expect(activeLeft, isEmpty);

    // Mismatched deposit + float rejected
    await expectLater(
      registerRepo.closeShiftAndGenerateZReport(
        shiftId: opened.shift.id,
        closedByUserId: ownerId,
        closedByRole: 'OWNER',
        actualCashCountedPaisa: 50000,
        cashWithdrawnDepositPaisa: 10000,
        retainedNextDayFloatPaisa: 10000,
      ),
      throwsArgumentError,
    );

    // Discrepancy DECIMAL(10,2) overflow rejected cleanly
    await expectLater(
      registerRepo.closeShiftAndGenerateZReport(
        shiftId: opened.shift.id,
        closedByUserId: ownerId,
        closedByRole: 'OWNER',
        actualCashCountedPaisa: MoneyUtils.maxDecimal10_2Paisa,
        cashWithdrawnDepositPaisa: MoneyUtils.maxDecimal10_2Paisa,
        retainedNextDayFloatPaisa: 0,
      ),
      throwsArgumentError,
    );

    // Valid settlement on negative expectedCash: actual=50000, expected=-150000 -> discrepancy=+200000
    final closed = await registerRepo.closeShiftAndGenerateZReport(
      shiftId: opened.shift.id,
      closedByUserId: ownerId,
      closedByRole: 'OWNER',
      actualCashCountedPaisa: 50000,
      cashWithdrawnDepositPaisa: 0,
      retainedNextDayFloatPaisa: 50000,
    );
    expect(closed.discrepancy, 200000);
    expect(closed.status, 'CLOSED');
  });

  test('Post-Z-Report Integrity: POS checkout & Khata repayment ignore stale CLOSED shiftId',
      () async {
    final prodId = uuid.v4();
    final varId = uuid.v4();
    final batchId = uuid.v4();
    final custId = uuid.v4();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: prodId,
            name: 'Lip Balm',
            brand: 'Nivea',
            category: 'Lipstick',
          ),
        );
    await db.into(db.productVariants).insert(
          ProductVariantsCompanion.insert(
            id: varId,
            productId: prodId,
            variantName: 'Original',
          ),
        );
    await db.into(db.batches).insert(
          BatchesCompanion.insert(
            id: batchId,
            variantId: varId,
            batchCode: 'B01',
            stickerBarcode: '01000099',
            sellingPrice: 30000,
            stockQuantity: const Value(5),
            expiryDate: '2029-01-01',
          ),
        );
    await db.into(db.customers).insert(
          CustomersCompanion.insert(
            id: custId,
            name: 'Maya',
            phone: '9800001111',
            currentBalanceDue: const Value(50000),
          ),
        );

    final opened = await db.openRegisterShiftAndPunchIn(
      userId: ownerId,
      deviceCode: '01',
      openingFloatPaisa: 100000,
    );
    await registerRepo.punchOutCurrentStaff(
      shiftId: opened.shift.id,
      userId: ownerId,
      deviceCode: '01',
    );
    await registerRepo.closeShiftAndGenerateZReport(
      shiftId: opened.shift.id,
      closedByUserId: ownerId,
      closedByRole: 'OWNER',
      actualCashCountedPaisa: 100000,
      cashWithdrawnDepositPaisa: 0,
      retainedNextDayFloatPaisa: 100000,
    );

    // Late sale & Khata repayment passing stale closed shift.id must NOT mutate closed shift
    final commit = await posRepo.completeCheckout(
      cashierUserId: ownerId,
      cashierName: 'Sita Owner',
      role: 'OWNER',
      deviceCode: '01',
      shiftId: opened.shift.id,
      items: [
        PosCartItem(
          lineKey: batchId,
          batchId: batchId,
          productId: prodId,
          variantId: varId,
          productName: 'Lip Balm',
          variantName: 'Original',
          batchCode: 'B01',
          stickerBarcode: '01000099',
          isGeneric: false,
          unitPricePaisa: 30000,
          quantity: 1,
          availableStock: 5,
          expiryDate: DateTime.utc(2029, 1, 1),
        ),
      ],
      discount: const PosDiscount.none(),
      payments: const [PosPaymentLeg(method: 'CASH', amountPaisa: 30000)],
      paymentMode: 'CASH',
    );
    await posRepo.recordKhataRepayment(
      customerId: custId,
      amountPaisa: 20000,
      paymentMethod: 'CASH',
      userId: ownerId,
      shiftId: opened.shift.id,
    );

    final saleRow = await (db.select(db.saleOrders)
          ..where((t) => t.id.equals(commit.saleOrderId)))
        .getSingle();
    expect(saleRow.shiftId, isNull);

    final closedShift = await (db.select(db.registerShifts)
          ..where((t) => t.id.equals(opened.shift.id)))
        .getSingle();
    expect(closedShift.cashSales, 0);
    expect(closedShift.khataCashRepayments, 0);
    expect(closedShift.expectedCash, 100000);
  });

  test('PrinterConfigNotifier persists Xlab 365T IP, Store Name & PAN inside encrypted SQLite sync_metadata',
      () async {
    final container1 = ProviderContainer(
      overrides: [
        activeDatabaseProvider.overrideWith(() => _FixedDbNotifier(db)),
      ],
    );
    addTearDown(container1.dispose);

    container1.read(printerConfigProvider.notifier).updateConfig(
          const PrinterConfig(
            host: '192.168.1.222',
            port: 9101,
            storeName: 'Pasal Botanicals',
            storePan: '605551234',
            autoSwitchMode: false,
          ),
        );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // New ProviderContainer simulates app restart reopening same DB
    final container2 = ProviderContainer(
      overrides: [
        activeDatabaseProvider.overrideWith(() => _FixedDbNotifier(db)),
      ],
    );
    addTearDown(container2.dispose);

    container2.read(printerConfigProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final reloaded = container2.read(printerConfigProvider);
    expect(reloaded.host, '192.168.1.222');
    expect(reloaded.port, 9101);
    expect(reloaded.storeName, 'Pasal Botanicals');
    expect(reloaded.storePan, '605551234');
    expect(reloaded.autoSwitchMode, isFalse);
  });

  testWidgets('Security: Locked state (session == null) fails closed across Suppliers, Register & Settings',
      (tester) async {
    final keyHolder = RamKeyHolder(); // locked (session == null)
    final mockClient = MockClient(
      (req) async => http.Response(jsonEncode({'devices': []}), 200),
    );

    // SuppliersScreen locked -> Access Required
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeDatabaseProvider.overrideWith(() => _FixedDbNotifier(db)),
          ramKeyHolderProvider.overrideWith((ref) => keyHolder),
          secureKeyValueStoreProvider.overrideWithValue(_InMemoryStore()),
          connectivityStreamProvider
              .overrideWithValue(Stream.value([ConnectivityResult.wifi])),
          connectivityCheckProvider
              .overrideWithValue(() async => [ConnectivityResult.wifi]),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const SuppliersScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Manager / Owner Access Required'), findsOneWidget);
    expect(find.text('Supplier'), findsNothing);

    await _unmount(tester, db);

    // New DB for SettingsScreen locked check
    final db2 = AppDatabase(NativeDatabase.memory());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeDatabaseProvider.overrideWith(() => _FixedDbNotifier(db2)),
          ramKeyHolderProvider.overrideWith((ref) => RamKeyHolder()),
          secureKeyValueStoreProvider.overrideWithValue(_InMemoryStore()),
          httpClientFactoryProvider.overrideWithValue(() => mockClient),
          connectivityStreamProvider
              .overrideWithValue(Stream.value([ConnectivityResult.wifi])),
          connectivityCheckProvider
              .overrideWithValue(() async => [ConnectivityResult.wifi]),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: SettingsScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Suppliers & Purchase Bills'), findsNothing);
    expect(find.text('STAFF ACCESS & REMOTE KILL-SWITCH'), findsNothing);

    await _unmount(tester, db2);
  });

  testWidgets('320x780 Narrow Screen Interactive Flow: Petty Expense Sheet + Pay Supplier Sheet + Open Next Shift CTA',
      (tester) async {
    tester.view.physicalSize = const Size(320, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final opened = await db.openRegisterShiftAndPunchIn(
      userId: ownerId,
      deviceCode: '01',
      openingFloatPaisa: 500000,
    );
    final sup = await supplierRepo.saveSupplier(
      role: 'OWNER',
      name: 'Everest Beauty Trade',
    );
    await (db.update(db.suppliers)..where((t) => t.id.equals(sup.id))).write(
      const SuppliersCompanion(
        totalPurchased: Value(250000),
        balanceDue: Value(250000),
      ),
    );

    final nowUtc = DateTime.now().toUtc();
    final keyHolder = RamKeyHolder()
      ..unlock(
        dekBytes: Uint8List(32),
        session: ActiveLeaseSession(
          leaseId: uuid.v4(),
          userId: ownerId,
          username: 'owner',
          role: 'OWNER',
          deviceId: uuid.v4(),
          deviceCode: '01',
          issuedAt: nowUtc,
          expiresAt: nowUtc.add(const Duration(hours: 12)),
        ),
      );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeDatabaseProvider.overrideWith(() => _FixedDbNotifier(db)),
          ramKeyHolderProvider.overrideWith((ref) => keyHolder),
          secureKeyValueStoreProvider.overrideWithValue(_InMemoryStore()),
          connectivityStreamProvider
              .overrideWithValue(Stream.value([ConnectivityResult.wifi])),
          connectivityCheckProvider
              .overrideWithValue(() async => [ConnectivityResult.wifi]),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Column(
                children: [
                  Expanded(child: const RegisterScreen()),
                  TextButton(
                    onPressed: () => showPettyExpenseSheet(
                      context,
                      ref,
                      shiftId: opened.shift.id,
                    ),
                    child: const Text('TEST_PETTY'),
                  ),
                  TextButton(
                    onPressed: () => showPaySupplierSheet(
                      context,
                      ref,
                      supplier: sup.copyWith(balanceDue: 250000),
                    ),
                    child: const Text('TEST_PAY_SUP'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    // 1. Open Petty Expense Sheet & record Rs. 150.50 CASH
    await tester.tap(find.text('TEST_PETTY'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Expense Title / Note *'),
      'Staff Tea',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Amount (Rs.) *'),
      '150.50',
    );
    await tester.ensureVisible(find.text('Save Expense'));
    await tester.tap(find.text('Save Expense'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    final shiftAfterExpense = await db.fetchOpenRegisterShift();
    expect(shiftAfterExpense!.expectedCash, 484950); // 5000 - 150.50

    // 2. Open Pay Supplier Sheet & pay Rs. 1,000
    await tester.tap(find.text('TEST_PAY_SUP'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Payment Amount (Rs.) *'),
      '1000',
    );
    await tester.ensureVisible(find.text('Confirm Payment'));
    await tester.tap(find.text('Confirm Payment'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    final supDetail = await supplierRepo.loadSupplierDetail(sup.id);
    expect(supDetail!.supplier.balanceDue, 150000);

    // 3. Punch out & close shift -> RegisterScreen shows 'Open Next Shift' CTA
    await registerRepo.punchOutCurrentStaff(
      shiftId: opened.shift.id,
      userId: ownerId,
      deviceCode: '01',
    );
    await registerRepo.closeShiftAndGenerateZReport(
      shiftId: opened.shift.id,
      closedByUserId: ownerId,
      closedByRole: 'OWNER',
      actualCashCountedPaisa: 484950,
      cashWithdrawnDepositPaisa: 184950,
      retainedNextDayFloatPaisa: 300000,
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(find.text('Open Next Shift'), findsOneWidget);
    expect(find.text('LAST CLOSED Z-REPORT'), findsOneWidget);

    await _unmount(tester, db);
  });
}
