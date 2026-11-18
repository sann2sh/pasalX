import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pasalx_mobile/core/database/app_database.dart';
import 'package:pasalx_mobile/core/printer/printer.dart';
import 'package:pasalx_mobile/core/providers/foundation_providers.dart';
import 'package:pasalx_mobile/core/security/keystore_dek_manager.dart';
import 'package:pasalx_mobile/core/security/ram_key_holder.dart';
import 'package:pasalx_mobile/core/theme/app_theme.dart';
import 'package:pasalx_mobile/features/pos/data/pos_repository.dart';
import 'package:pasalx_mobile/features/pos/domain/pos_models.dart';
import 'package:pasalx_mobile/features/register/data/register_repository.dart';
import 'package:pasalx_mobile/features/register/presentation/register_screen.dart';
import 'package:pasalx_mobile/features/settings/presentation/settings_screen.dart';
import 'package:pasalx_mobile/features/suppliers/data/supplier_repository.dart';
import 'package:pasalx_mobile/features/suppliers/presentation/suppliers_screen.dart';
import 'package:uuid/uuid.dart';

class _InMemoryKeyValueStore implements SecureKeyValueStore {
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

class _CapturingZReportDriver extends Xlab365tDriver {
  final List<ZReportPrintData> printedZReports = <ZReportPrintData>[];

  @override
  Future<Uint8List> printZReport(
    ZReportPrintData data, {
    bool? autoSwitch,
  }) async {
    final bytes = EscPosReceiptBuilder().buildZReport(data);
    printedZReports.add(data);
    return bytes;
  }
}

Future<void> _unmountWidgetTree(WidgetTester tester, AppDatabase db) async {
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

  test('Task 10.1: Supplier ledger, partial/full invoice payment & overpayment guard',
      () async {
    final supplier = await supplierRepo.saveSupplier(
      role: 'OWNER',
      name: 'Himalayan Cosmetics Distributors Pvt. Ltd.',
      phone: '9801122334',
      panVat: '601234567',
      address: 'New Road, Kathmandu',
    );
    expect(supplier.balanceDue, 0);

    final invId = uuid.v4();
    await db.into(db.purchaseInvoices).insert(
          PurchaseInvoicesCompanion.insert(
            id: invId,
            supplierId: supplier.id,
            invoiceNo: 'INV-2083-01',
            invoiceDate: '2026-11-17',
            totalAmount: 500000, // Rs. 5,000
            paidAmount: const Value(0),
            dueAmount: 500000,
            status: const Value('UNPAID'),
            createdByUserId: Value(ownerId),
          ),
        );
    await (db.update(db.suppliers)..where((t) => t.id.equals(supplier.id)))
        .write(
      const SuppliersCompanion(
        totalPurchased: Value(500000),
        balanceDue: Value(500000),
      ),
    );

    // Overpayment guard
    await expectLater(
      supplierRepo.recordSupplierPayment(
        role: 'OWNER',
        supplierId: supplier.id,
        purchaseInvoiceId: invId,
        amountPaisa: 600000,
        paymentMethod: 'BANK_TRANSFER',
        createdByUserId: ownerId,
      ),
      throwsStateError,
    );

    // Partial payment Rs. 2,000
    await supplierRepo.recordSupplierPayment(
      role: 'OWNER',
      supplierId: supplier.id,
      purchaseInvoiceId: invId,
      amountPaisa: 200000,
      paymentMethod: 'BANK_TRANSFER',
      referenceNo: 'NIC-8821',
      createdByUserId: ownerId,
    );

    var detail = await supplierRepo.loadSupplierDetail(supplier.id);
    expect(detail!.supplier.totalPaid, 200000);
    expect(detail.supplier.balanceDue, 300000);
    expect(detail.invoices.single.status, 'PARTIAL');
    expect(detail.invoices.single.dueAmount, 300000);

    // Final payment Rs. 3,000
    await supplierRepo.recordSupplierPayment(
      role: 'OWNER',
      supplierId: supplier.id,
      purchaseInvoiceId: invId,
      amountPaisa: 300000,
      paymentMethod: 'CASH',
      createdByUserId: ownerId,
    );

    detail = await supplierRepo.loadSupplierDetail(supplier.id);
    expect(detail!.supplier.balanceDue, 0);
    expect(detail.invoices.single.status, 'PAID');

    final outbox = await db.fetchPendingOutbox();
    final tables = outbox.map((e) => e.targetTable).toList();
    expect(tables, containsAll(<String>['suppliers', 'supplier_payments']));
  });

  test('Task 10.1: Petty cash expenses deduct CASH from Single-Galla, leave FONEPAY untouched',
      () async {
    final opened = await db.openRegisterShiftAndPunchIn(
      userId: ownerId,
      deviceCode: '01',
      openingFloatPaisa: 500000, // Rs. 5,000
    );

    await supplierRepo.recordPettyExpense(
      category: 'Tea & Snacks',
      title: 'Staff Chiya & Biscuit',
      amountPaisa: 25000, // Rs. 250
      paymentMethod: 'CASH',
      paidTo: 'Didi Chiya Pasal',
      shiftId: opened.shift.id,
      createdByUserId: ownerId,
    );

    await supplierRepo.recordPettyExpense(
      category: 'Courier / Delivery',
      title: 'Pathao Parcel',
      amountPaisa: 100000, // Rs. 1,000
      paymentMethod: 'FONEPAY',
      shiftId: opened.shift.id,
      createdByUserId: ownerId,
    );

    final updatedShift = await db.fetchOpenRegisterShift();
    expect(updatedShift!.cashExpenses, 25000);
    expect(updatedShift.expectedCash, 475000); // 5000 - 250
  });

  test(
      'Review Gate 6: 2-Phone Simulation (01 & 02) -> Force Close -> Z-Report Bank Drop & Next-Day Float Rollover + 80mm ESC/POS',
      () async {
    // Seed 1 sellable batch
    final prodId = uuid.v4();
    final varId = uuid.v4();
    final batchId = uuid.v4();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: prodId,
            name: 'Maybelline Superstay Matte Ink',
            brand: 'Maybelline',
            category: 'Lipstick',
          ),
        );
    await db.into(db.productVariants).insert(
          ProductVariantsCompanion.insert(
            id: varId,
            productId: prodId,
            variantName: '65 Seductress',
          ),
        );
    await db.into(db.batches).insert(
          BatchesCompanion.insert(
            id: batchId,
            variantId: varId,
            batchCode: 'B2601',
            stickerBarcode: '26010001',
            costPrice: const Value(80000),
            sellingPrice: 150000, // Rs. 1,500
            stockQuantity: const Value(10),
            expiryDate: '2028-12-31',
          ),
        );

    // 1. Phone 01 opens Single-Galla shift with Rs. 5,000
    final phone01 = await db.openRegisterShiftAndPunchIn(
      userId: ownerId,
      deviceCode: '01',
      openingFloatPaisa: 500000,
    );
    // 2. Phone 02 punches into same shift
    final phone02Session = await db.punchInToExistingShift(
      registerShiftId: phone01.shift.id,
      userId: staffId,
      deviceCode: '02',
    );

    // 3. Phone 01 makes Cash sale Rs. 1,500
    await posRepo.completeCheckout(
      cashierUserId: ownerId,
      cashierName: 'Sita Owner',
      role: 'OWNER',
      deviceCode: '01',
      shiftId: phone01.shift.id,
      items: [
        PosCartItem(
          lineKey: batchId,
          batchId: batchId,
          variantId: varId,
          productId: prodId,
          productName: 'Maybelline Superstay Matte Ink',
          variantName: '65 Seductress',
          batchCode: 'B2601',
          stickerBarcode: '26010001',
          isGeneric: false,
          expiryDate: DateTime.utc(2028, 12, 31),
          unitPricePaisa: 150000,
          costPricePaisa: 80000,
          availableStock: 10,
          quantity: 1,
        ),
      ],
      discount: const PosDiscount.none(),
      paymentMode: 'CASH',
      payments: const [PosPaymentLeg(method: 'CASH', amountPaisa: 150000)],
      cashTenderedPaisa: 150000,
      changeDuePaisa: 0,
    );

    // 4. Phone 02 makes Fonepay QR sale Rs. 1,500
    await posRepo.completeCheckout(
      cashierUserId: staffId,
      cashierName: 'Ram Staff',
      role: 'STAFF',
      deviceCode: '02',
      shiftId: phone01.shift.id,
      items: [
        PosCartItem(
          lineKey: batchId,
          batchId: batchId,
          variantId: varId,
          productId: prodId,
          productName: 'Maybelline Superstay Matte Ink',
          variantName: '65 Seductress',
          batchCode: 'B2601',
          stickerBarcode: '26010001',
          isGeneric: false,
          expiryDate: DateTime.utc(2028, 12, 31),
          unitPricePaisa: 150000,
          costPricePaisa: 80000,
          availableStock: 9,
          quantity: 1,
        ),
      ],
      discount: const PosDiscount.none(),
      paymentMode: 'FONEPAY_QR',
      payments: const [
        PosPaymentLeg(
          method: 'FONEPAY_QR',
          amountPaisa: 150000,
          transactionRef: 'FP-991',
        ),
      ],
    );

    // 5. Phone 01 logs Cash petty expense Rs. 200
    await supplierRepo.recordPettyExpense(
      category: 'Packaging & Bags',
      title: 'Paper Carry Bags',
      amountPaisa: 20000,
      paymentMethod: 'CASH',
      shiftId: phone01.shift.id,
      createdByUserId: ownerId,
    );

    // Expected drawer cash: 5000 + 1500 - 200 = Rs. 6,300 (630000 paisa)
    final midShift = await db.fetchOpenRegisterShift();
    expect(midShift!.expectedCash, 630000);
    expect(midShift.digitalSales, 150000);

    // 6. Z-Report pre-flight gate MUST block while Phone 01 & 02 are ACTIVE
    await expectLater(
      registerRepo.closeShiftAndGenerateZReport(
        shiftId: phone01.shift.id,
        closedByUserId: ownerId,
        closedByRole: 'OWNER',
        actualCashCountedPaisa: 625000,
        cashWithdrawnDepositPaisa: 325000,
        retainedNextDayFloatPaisa: 300000,
      ),
      throwsStateError,
    );

    // 7. Phone 02 battery died -> Owner triggers Force Punch-Out
    final forced = await registerRepo.forceCloseStaffSession(
      sessionId: phone02Session.id,
      managerUserId: ownerId,
      managerRole: 'OWNER',
    );
    expect(forced.status, 'FORCE_CLOSED');
    expect(forced.forceClosedByUserId, ownerId);

    // 8. Phone 01 normal Punch-Out
    final punched = await registerRepo.punchOutCurrentStaff(
      shiftId: phone01.shift.id,
      userId: ownerId,
      deviceCode: '01',
    );
    expect(punched.status, 'PUNCHED_OUT');

    // 9. Owner settles Z-Report with Rs. 6,250 counted (Rs. 50 short), Rs. 3,000 float
    final closed = await registerRepo.closeShiftAndGenerateZReport(
      shiftId: phone01.shift.id,
      closedByUserId: ownerId,
      closedByRole: 'OWNER',
      actualCashCountedPaisa: 625000,
      cashWithdrawnDepositPaisa: 325000,
      retainedNextDayFloatPaisa: 300000,
      notes: 'Rs. 50 coin rounding short',
    );
    expect(closed.status, 'CLOSED');
    expect(closed.discrepancy, -5000);
    expect(closed.cashWithdrawnDeposit, 325000);
    expect(closed.retainedNextDayFloat, 300000);

    // 10. 80mm ESC/POS Z-Report bytes check
    final zBytes = const EscPosReceiptBuilder().buildZReport(
      ZReportPrintData(
        shiftId: closed.id,
        openedAt: closed.openedAt,
        closedAt: closed.closedAt!,
        closedByName: 'Sita Owner',
        openingFloatPaisa: closed.openingFloat,
        cashSalesPaisa: closed.cashSales,
        digitalSalesPaisa: closed.digitalSales,
        khataCashRepaymentsPaisa: closed.khataCashRepayments,
        cashExpensesPaisa: closed.cashExpenses,
        expectedCashPaisa: closed.expectedCash,
        actualCashCountedPaisa: closed.actualCashCounted!,
        discrepancyPaisa: closed.discrepancy!,
        cashWithdrawnDepositPaisa: closed.cashWithdrawnDeposit,
        retainedNextDayFloatPaisa: closed.retainedNextDayFloat,
        notes: closed.notes,
      ),
    );
    final zText = ascii.decode(zBytes, allowInvalid: true);
    expect(zText, contains('END-OF-DAY Z-REPORT'));
    expect(zText, contains('NEXT-DAY FLOAT'));
    expect(zText, contains('Bank Drop / Deposit'));
    expect(zBytes.sublist(zBytes.length - 4), [0x1D, 0x56, 0x41, 0x00]);

    // 11. Next-day float rollover check
    final lastClosed = await registerRepo.fetchLastClosedShift();
    expect(lastClosed!.retainedNextDayFloat, 300000);
  });

  testWidgets(
      'break-ui Stress Test (360x780): RegisterScreen renders Rs. 9,99,999.00 & long expense without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final opened = await db.openRegisterShiftAndPunchIn(
      userId: ownerId,
      deviceCode: '01',
      openingFloatPaisa: 99999900, // Rs. 9,99,999.00
    );
    await supplierRepo.recordPettyExpense(
      category: 'Tea & Snacks',
      title: 'Extra-long Nepali festival staff refreshment & courier order',
      amountPaisa: 12550,
      paymentMethod: 'CASH',
      shiftId: opened.shift.id,
      createdByUserId: ownerId,
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

    final mockClient = MockClient(
      (req) async => http.Response(jsonEncode({'devices': []}), 200),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeDatabaseProvider.overrideWith(() => _FixedDbNotifier(db)),
          ramKeyHolderProvider.overrideWith((ref) => keyHolder),
          secureKeyValueStoreProvider.overrideWithValue(_InMemoryKeyValueStore()),
          httpClientFactoryProvider.overrideWithValue(() => mockClient),
          connectivityStreamProvider
              .overrideWithValue(Stream.value([ConnectivityResult.wifi])),
          connectivityCheckProvider
              .overrideWithValue(() async => [ConnectivityResult.wifi]),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: RegisterScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Register & Shift'), findsOneWidget);
    expect(find.textContaining('9,99'), findsWidgets);

    await _unmountWidgetTree(tester, db);
  });

  testWidgets(
      'break-ui Stress Test (360x780): SuppliersScreen long Nepali distributor name + STAFF RBAC gate',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await supplierRepo.saveSupplier(
      role: 'OWNER',
      name:
          'Himalayan Botanicals & International Cosmetics Distributors Kathmandu Pvt. Ltd.',
      phone: '9801234567',
      panVat: '609876543',
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

    final zDriver = _CapturingZReportDriver();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeDatabaseProvider.overrideWith(() => _FixedDbNotifier(db)),
          ramKeyHolderProvider.overrideWith((ref) => keyHolder),
          secureKeyValueStoreProvider.overrideWithValue(_InMemoryKeyValueStore()),
          xlabPrinterDriverProvider.overrideWithValue(zDriver),
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
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Suppliers & Bills'), findsOneWidget);
    expect(
      find.textContaining('Himalayan Botanicals & International'),
      findsOneWidget,
    );

    // STAFF role is blocked from SuppliersScreen
    keyHolder.unlock(
      dekBytes: Uint8List(32),
      session: ActiveLeaseSession(
        leaseId: uuid.v4(),
        userId: staffId,
        username: 'ram',
        role: 'STAFF',
        deviceId: uuid.v4(),
        deviceCode: '02',
        issuedAt: nowUtc,
        expiresAt: nowUtc.add(const Duration(hours: 12)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Manager / Owner Access Required'), findsOneWidget);

    await _unmountWidgetTree(tester, db);
  });

  testWidgets(
      'break-ui Stress Test (360x780): SettingsScreen Printer Config & Owner-Only Kill-Switch',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

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

    final mockClient = MockClient(
      (req) async => http.Response(jsonEncode({'devices': []}), 200),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeDatabaseProvider.overrideWith(() => _FixedDbNotifier(db)),
          ramKeyHolderProvider.overrideWith((ref) => keyHolder),
          secureKeyValueStoreProvider.overrideWithValue(_InMemoryKeyValueStore()),
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
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Printer Settings'), findsOneWidget);
    expect(find.text('Backup & Sync'), findsOneWidget);
    expect(find.textContaining('AES'), findsNothing);
    expect(find.textContaining('DEK'), findsNothing);
    expect(find.textContaining('SQLCipher'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('STAFF PHONE ACCESS'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('STAFF PHONE ACCESS'), findsOneWidget);

    // STAFF cannot see Owner Staff Phone Access
    keyHolder.unlock(
      dekBytes: Uint8List(32),
      session: ActiveLeaseSession(
        leaseId: uuid.v4(),
        userId: staffId,
        username: 'ram',
        role: 'STAFF',
        deviceId: uuid.v4(),
        deviceCode: '02',
        issuedAt: nowUtc,
        expiresAt: nowUtc.add(const Duration(hours: 12)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('STAFF PHONE ACCESS'), findsNothing);

    await _unmountWidgetTree(tester, db);
  });

  testWidgets(
      'Review Gate 6 UI Flow: Z-Report modal blocks active staff -> Force Punch-Out -> Finalize Z-Report',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final phone01 = await db.openRegisterShiftAndPunchIn(
      userId: ownerId,
      deviceCode: '01',
      openingFloatPaisa: 500000,
    );
    await db.punchInToExistingShift(
      registerShiftId: phone01.shift.id,
      userId: staffId,
      deviceCode: '02',
    );
    await registerRepo.punchOutCurrentStaff(
      shiftId: phone01.shift.id,
      userId: ownerId,
      deviceCode: '01',
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

    final zDriver = _CapturingZReportDriver();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeDatabaseProvider.overrideWith(() => _FixedDbNotifier(db)),
          ramKeyHolderProvider.overrideWith((ref) => keyHolder),
          secureKeyValueStoreProvider.overrideWithValue(_InMemoryKeyValueStore()),
          xlabPrinterDriverProvider.overrideWithValue(zDriver),
          connectivityStreamProvider
              .overrideWithValue(Stream.value([ConnectivityResult.wifi])),
          connectivityCheckProvider
              .overrideWithValue(() async => [ConnectivityResult.wifi]),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: RegisterScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.scrollUntilVisible(
      find.text('Count Cash & Close Shift (Z-Report)'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Count Cash & Close Shift (Z-Report)'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('STAFF PUNCH-OUT CHECKLIST'),
      ),
      findsOneWidget,
    );
    expect(find.text('1 ACTIVE'), findsOneWidget);

    // Finalize button is disabled while 1 staff is still ACTIVE
    final finalizeBtn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Finalize Z-Report & Close Shift'),
    );
    expect(finalizeBtn.onPressed, isNull);

    // Trigger Force Punch-Out inside Z-Report modal
    await tester.tap(find.text('Force Punch-Out').first);
    await tester.pumpAndSettle();
    expect(find.text('Force Punch-Out Staff?'), findsOneWidget);
    await tester.tap(
      find.widgetWithText(FilledButton, 'Force Punch-Out'),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(find.text('ALL CLEAR'), findsOneWidget);

    await tester.ensureVisible(
      find.text('Finalize Z-Report & Close Shift'),
    );
    await tester.tap(find.text('Finalize Z-Report & Close Shift'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    final closedShift = await registerRepo.fetchLastClosedShift();
    expect(closedShift, isNotNull);
    expect(closedShift!.status, 'CLOSED');
    expect(closedShift.retainedNextDayFloat, 500000);
    expect(zDriver.printedZReports.length, 1);
    expect(zDriver.printedZReports.single.retainedNextDayFloatPaisa, 500000);

    await _unmountWidgetTree(tester, db);
  });
}
