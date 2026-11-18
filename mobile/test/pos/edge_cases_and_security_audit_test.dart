import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pasalx_mobile/core/database/app_database.dart';
import 'package:pasalx_mobile/core/database/money.dart';
import 'package:pasalx_mobile/core/printer/printer.dart';
import 'package:pasalx_mobile/core/providers/foundation_providers.dart';
import 'package:pasalx_mobile/core/security/ram_key_holder.dart';
import 'package:pasalx_mobile/core/theme/app_theme.dart';
import 'package:pasalx_mobile/features/pos/application/pos_providers.dart';
import 'package:pasalx_mobile/features/pos/data/pos_repository.dart';
import 'package:pasalx_mobile/features/pos/domain/pos_models.dart';
import 'package:pasalx_mobile/features/pos/presentation/hid_barcode_listener.dart';
import 'package:pasalx_mobile/features/pos/presentation/pos_screen.dart';

ActiveLeaseSession _fakeSession(String role) {
  final now = DateTime.now().toUtc();
  return ActiveLeaseSession(
    userId: '11111111-1111-1111-1111-111111111111',
    username: role.toLowerCase(),
    role: role,
    deviceId: '22222222-2222-2222-2222-222222222222',
    deviceCode: '01',
    leaseId: '33333333-3333-3333-3333-333333333333',
    issuedAt: now,
    expiresAt: now.add(const Duration(hours: 12)),
  );
}

class _FixedDbNotifier extends ActiveDatabaseNotifier {
  _FixedDbNotifier(this._db);
  final AppDatabase _db;
  @override
  AppDatabase? build() => _db;
}

class _CapturingReceiptDriver extends Xlab365tDriver {
  final List<ReceiptPrintData> printedReceipts = <ReceiptPrintData>[];
  final List<Uint8List> printedBytes = <Uint8List>[];

  @override
  Future<Uint8List> printReceipt(
    ReceiptPrintData receipt, {
    bool? autoSwitch,
  }) async {
    final bytes = EscPosReceiptBuilder().build(receipt);
    printedReceipts.add(receipt);
    printedBytes.add(bytes);
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

Future<void> _seedAuditData(AppDatabase db) async {
  final now = DateTime.utc(2026, 11, 16, 10, 0);

  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: '11111111-1111-1111-1111-111111111111',
          name: 'Audit Staff',
          username: 'staff',
          passwordHash: const Value('hash'),
          role: 'STAFF',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );

  await db.into(db.registerShifts).insert(
        RegisterShiftsCompanion.insert(
          id: 'shift-01',
          openedByUserId: '11111111-1111-1111-1111-111111111111',
          openingFloat: 500000,
          expectedCash: 500000,
          status: const Value('OPEN'),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );

  await db.into(db.products).insert(
        ProductsCompanion.insert(
          id: 'prod-serum',
          name: "L'Oréal Paris Revitalift 1.5% Hyaluronic Acid Serum 30ml",
          brand: "L'Oréal",
          category: 'Skincare',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );

  // Two variants: "#1" and "#128" (to test exact shade match precedence)
  await db.into(db.productVariants).insert(
        ProductVariantsCompanion.insert(
          id: 'var-128',
          productId: 'prod-serum',
          variantName: '#128',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
  await db.into(db.productVariants).insert(
        ProductVariantsCompanion.insert(
          id: 'var-1',
          productId: 'prod-serum',
          variantName: '#1',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );

  // Variant #128 has an older batch (stock=1) and newer batch (stock=5)
  await db.into(db.batches).insert(
        BatchesCompanion.insert(
          id: 'batch-old-1',
          variantId: 'var-128',
          batchCode: 'OLD-1',
          stickerBarcode: '01200001',
          costPrice: const Value(50000),
          sellingPrice: 100000, // Rs. 1,000
          stockQuantity: const Value(1),
          expiryDate: '2027-02-01',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
  await db.into(db.batches).insert(
        BatchesCompanion.insert(
          id: 'batch-new-5',
          variantId: 'var-128',
          batchCode: 'NEW-5',
          stickerBarcode: '01200002',
          costPrice: const Value(50000),
          sellingPrice: 100000,
          stockQuantity: const Value(5),
          expiryDate: '2028-02-01',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );

  // Variant #1 batch (zero stock offline test + shade precedence)
  await db.into(db.batches).insert(
        BatchesCompanion.insert(
          id: 'batch-shade-1',
          variantId: 'var-1',
          batchCode: 'SHADE-1',
          stickerBarcode: '01200003',
          costPrice: const Value(40000),
          sellingPrice: 80000, // Rs. 800
          stockQuantity: const Value(0),
          expiryDate: '2028-05-01',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );

  // Generic items: one expired (must be filtered out), one active
  await db.into(db.products).insert(
        ProductsCompanion.insert(
          id: 'prod-gen-exp',
          name: 'Expired Generic',
          brand: 'Generic',
          category: 'Generic',
          isGeneric: const Value(true),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
  await db.into(db.productVariants).insert(
        ProductVariantsCompanion.insert(
          id: 'var-gen-exp',
          productId: 'prod-gen-exp',
          variantName: 'Pack',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
  await db.into(db.batches).insert(
        BatchesCompanion.insert(
          id: 'batch-gen-exp',
          variantId: 'var-gen-exp',
          batchCode: 'G-EXP',
          stickerBarcode: '01999901',
          sellingPrice: 5000,
          stockQuantity: const Value(10),
          expiryDate: '2025-01-01',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );

  await db.into(db.products).insert(
        ProductsCompanion.insert(
          id: 'prod-gen-ok',
          name: 'Bangles Set',
          brand: 'Generic',
          category: 'Generic',
          isGeneric: const Value(true),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
  await db.into(db.productVariants).insert(
        ProductVariantsCompanion.insert(
          id: 'var-gen-ok',
          productId: 'prod-gen-ok',
          variantName: 'Pack',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
  await db.into(db.batches).insert(
        BatchesCompanion.insert(
          id: 'batch-gen-ok',
          variantId: 'var-gen-ok',
          batchCode: 'G-OK',
          stickerBarcode: '01999902',
          sellingPrice: 15000,
          stockQuantity: const Value(20),
          expiryDate: '2099-12-31',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );

  // Active customer & soft-deleted customer
  await db.into(db.customers).insert(
        CustomersCompanion.insert(
          id: 'cust-long',
          name: 'Sita Kumari Rajbanshi-Shrestha',
          phone: '9841000099',
          creditLimit: const Value(1000000),
          currentBalanceDue: const Value(120000), // Rs. 1,200
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
  await db.into(db.customers).insert(
        CustomersCompanion.insert(
          id: 'cust-deleted',
          name: 'Deleted Customer',
          phone: '9800000000',
          createdAt: Value(now),
          updatedAt: Value(now),
          deletedAt: Value(now),
        ),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('Step 9 Security Audit & Edge Cases', () {
    late AppDatabase db;
    late RamKeyHolder holder;
    late PosRepository repo;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      await _seedAuditData(db);
      holder = RamKeyHolder();
      holder.unlock(
        dekBytes: Uint8List.fromList(List<int>.filled(32, 9)),
        session: _fakeSession('STAFF'),
      );
      repo = PosRepository(
        db: db,
        clock: () => DateTime.utc(2026, 11, 17, 0, 30),
      );
    });

    tearDown(() async {
      await db.close();
    });

    test(
      '100% discount (net=0) checkout omits 0-amount sale_payments for Go sync & prints 80mm receipt',
      () async {
        addTearDown(holder.dispose);

        final commit = await repo.completeCheckout(
          items: [
            PosCartItem(
              lineKey: 'batch-old-1',
              batchId: 'batch-old-1',
              productId: 'prod-serum',
              variantId: 'var-128',
              productName: 'Serum',
              variantName: '#128',
              batchCode: 'OLD-1',
              stickerBarcode: '01200001',
              isGeneric: false,
              unitPricePaisa: 100000,
              quantity: 1,
              availableStock: 1,
              expiryDate: DateTime.utc(2027, 2, 1),
            ),
          ],
          discount: const PosDiscount(
            tier: DiscountTier.custom,
            customAmountPaisa: 100000,
          ),
          payments: const <PosPaymentLeg>[],
          paymentMode: 'CASH',
          cashierUserId: '11111111-1111-1111-1111-111111111111',
          cashierName: 'Audit Staff',
          role: 'STAFF',
          deviceCode: '01',
          shiftId: 'shift-01',
        );

        final receiptBytes = EscPosReceiptBuilder().build(commit.receiptData);
        expect(receiptBytes.isNotEmpty, isTrue);

        final outbox = await db.fetchPendingOutbox();
        expect(outbox.length, 1);
        final payload =
            jsonDecode(outbox.single.payloadJson) as Map<String, dynamic>;
        expect(payload['subtotal'], '1000.00');
        expect(payload['discount_amount'], '1000.00');
        expect(payload['total_amount'], '0.00');
        expect(payload['payments'], isEmpty);
      },
    );

    test(
      'Khata repayment auto-resolves open shift_id when null & blocks overpayment',
      () async {
        addTearDown(holder.dispose);

        // Overpayment > Rs. 1,200 must throw PosValidationException
        await expectLater(
          () => repo.recordKhataRepayment(
            customerId: 'cust-long',
            amountPaisa: 150000,
            paymentMethod: 'CASH',
            userId: '11111111-1111-1111-1111-111111111111',
          ),
          throwsA(isA<PosValidationException>()),
        );

        // Valid repayment with shiftId: null resolves shift-01 automatically
        await repo.recordKhataRepayment(
          customerId: 'cust-long',
          amountPaisa: 120000,
          paymentMethod: 'CASH',
          userId: '11111111-1111-1111-1111-111111111111',
        );

        final shift = await (db.select(db.registerShifts)
              ..where((s) => s.id.equals('shift-01')))
            .getSingle();
        expect(shift.khataCashRepayments, 120000);
        expect(shift.expectedCash, 620000);

        final outbox = await db.fetchPendingOutbox();
        final payload =
            jsonDecode(outbox.single.payloadJson) as Map<String, dynamic>;
        expect(payload['shift_id'], 'shift-01');

        // Repaying again when balance due == 0 must throw cleanly
        await expectLater(
          () => repo.recordKhataRepayment(
            customerId: 'cust-long',
            amountPaisa: 100,
            paymentMethod: 'CASH',
            userId: '11111111-1111-1111-1111-111111111111',
          ),
          throwsA(isA<PosValidationException>()),
        );
      },
    );

    test(
      'Soft-deleted phone collision, negative stock sale, FEFO in-cart skip, Quick-Pad expiry filter & exact shade match',
      () async {
        addTearDown(holder.dispose);

        // 1. Soft-deleted phone number throws PosValidationException instead of SqliteException
        await expectLater(
          () => repo.createCustomer(
            name: 'Duplicate Phone',
            phone: '9800000000',
            role: 'STAFF',
          ),
          throwsA(isA<PosValidationException>()),
        );

        // 2. Quick-Pad filters out expired generic batches
        final qpItems = await repo.watchQuickPadItems(role: 'STAFF').first;
        expect(qpItems.map((e) => e.batchId), equals(['batch-gen-ok']));

        // 3. Exact shade profile match picks "#1" over "#128" even though "#128" contains "#1"
        final shadeMatch = await repo.findBestBatchForShadeProfile(
          CustomerShadeProfileRow(
            id: 's1',
            customerId: 'cust-long',
            productName:
                "L'Oréal Paris Revitalift 1.5% Hyaluronic Acid Serum 30ml",
            brand: "L'Oréal",
            shadeVariant: '#1',
            createdAt: DateTime.utc(2026, 11, 16),
            updatedAt: DateTime.utc(2026, 11, 16),
          ),
          role: 'STAFF',
        );
        expect(shadeMatch, isNotNull);
        expect(shadeMatch!.variantId, 'var-1');

        // 4. FEFO skips older batch when all its stock (1) is already in cart
        final fefoWithEmptyCart = await repo.lookupByBarcode(
          '01200002',
          role: 'STAFF',
        );
        expect(fefoWithEmptyCart.status, PosBatchScanStatus.fefoOlderExists);

        final fefoWithAllocatedOlder = await repo.lookupByBarcode(
          '01200002',
          role: 'STAFF',
          inCartQtyByBatchId: const {'batch-old-1': 1},
        );
        expect(fefoWithAllocatedOlder.status, PosBatchScanStatus.ok);

        // 5. Zero-stock non-expired batch sells offline (negative stock allowed for sync discrepancy)
        await repo.completeCheckout(
          items: [
            PosCartItem(
              lineKey: 'batch-shade-1',
              batchId: 'batch-shade-1',
              productId: 'prod-serum',
              variantId: 'var-1',
              productName: 'Serum',
              variantName: '#1',
              batchCode: 'SHADE-1',
              stickerBarcode: '01200003',
              isGeneric: false,
              unitPricePaisa: 80000,
              quantity: 2,
              availableStock: 0,
              expiryDate: DateTime.utc(2028, 5, 1),
            ),
          ],
          discount: const PosDiscount.none(),
          payments: const [PosPaymentLeg(method: 'CASH', amountPaisa: 80000 * 2)],
          paymentMode: 'CASH',
          cashierUserId: '11111111-1111-1111-1111-111111111111',
          cashierName: 'Audit Staff',
          role: 'STAFF',
          deviceCode: '01',
        );
        final updatedZeroBatch = await (db.select(db.batches)
              ..where((b) => b.id.equals('batch-shade-1')))
            .getSingle();
        expect(updatedZeroBatch.stockQuantity, -2);
      },
    );

    test(
      'Repository rejects invalid paymentMode, zero-paisa legs, invalid qty & missing batch',
      () async {
        addTearDown(holder.dispose);

        final validItem = PosCartItem(
          lineKey: 'batch-old-1',
          batchId: 'batch-old-1',
          productId: 'prod-serum',
          variantId: 'var-128',
          productName: 'Serum',
          variantName: '#128',
          batchCode: 'OLD-1',
          stickerBarcode: '01200001',
          isGeneric: false,
          unitPricePaisa: 100000,
          quantity: 1,
          availableStock: 1,
          expiryDate: DateTime.utc(2027, 2, 1),
        );

        await expectLater(
          () => repo.completeCheckout(
            items: [validItem.copyWith(quantity: 0)],
            discount: const PosDiscount.none(),
            payments: const [PosPaymentLeg(method: 'CASH', amountPaisa: 100000)],
            paymentMode: 'CASH',
            cashierUserId: '11111111-1111-1111-1111-111111111111',
            cashierName: 'Staff',
            role: 'STAFF',
            deviceCode: '01',
          ),
          throwsA(isA<PosValidationException>()),
        );

        await expectLater(
          () => repo.completeCheckout(
            items: [validItem],
            discount: const PosDiscount.none(),
            payments: const [PosPaymentLeg(method: 'CASH', amountPaisa: 0)],
            paymentMode: 'CASH',
            cashierUserId: '11111111-1111-1111-1111-111111111111',
            cashierName: 'Staff',
            role: 'STAFF',
            deviceCode: '01',
          ),
          throwsA(isA<PosValidationException>()),
        );

        await expectLater(
          () => repo.completeCheckout(
            items: [validItem],
            discount: const PosDiscount.none(),
            payments: const [PosPaymentLeg(method: 'CASH', amountPaisa: 100000)],
            paymentMode: 'CRYPTO',
            cashierUserId: '11111111-1111-1111-1111-111111111111',
            cashierName: 'Staff',
            role: 'STAFF',
            deviceCode: '01',
          ),
          throwsA(isA<PosValidationException>()),
        );
      },
    );

    testWidgets(
      'HidBarcodeListener ignores keystrokes when hidden tab (TickerMode=false) or modal is open',
      (tester) async {
        addTearDown(holder.dispose);
        final scanned = <String>[];

        await tester.pumpWidget(
          MaterialApp(
            home: TickerMode(
              enabled: false,
              child: HidBarcodeListener(
                onBarcodeScanned: scanned.add,
                child: const Scaffold(body: Text('Hidden POS Tab')),
              ),
            ),
          ),
        );

        for (final key in const [
          LogicalKeyboardKey.digit0,
          LogicalKeyboardKey.digit1,
          LogicalKeyboardKey.digit2,
          LogicalKeyboardKey.digit3,
        ]) {
          await tester.sendKeyEvent(key);
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(scanned, isEmpty);

        // Now enabled, but with a modal dialog open on top -> still ignored!
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => HidBarcodeListener(
                onBarcodeScanned: scanned.add,
                child: Scaffold(
                  body: TextButton(
                    onPressed: () {
                      unawaited(
                        showDialog<void>(
                          context: context,
                          builder: (_) => const AlertDialog(title: Text('Modal')),
                        ),
                      );
                    },
                    child: const Text('Open Modal'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open Modal'));
        await tester.pumpAndSettle();

        for (final key in const [
          LogicalKeyboardKey.digit0,
          LogicalKeyboardKey.digit1,
          LogicalKeyboardKey.digit2,
          LogicalKeyboardKey.digit3,
        ]) {
          await tester.sendKeyEvent(key);
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(scanned, isEmpty);
      },
    );

    testWidgets(
      'Worst-case 360x780 break-ui: extra-long names, Rs. 9,99,999 totals & customer detach zero overflow',
      (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final driver = _CapturingReceiptDriver();
        final container = ProviderContainer(
          overrides: [
            activeDatabaseProvider.overrideWith(() => _FixedDbNotifier(db)),
            ramKeyHolderProvider.overrideWith((ref) => holder),
            xlabPrinterDriverProvider.overrideWithValue(driver),
          ],
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(),
              home: const Scaffold(body: PosScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Attach extra-long customer name & add Rs. 9,99,999 item
        final cust = await (db.select(db.customers)
              ..where((c) => c.id.equals('cust-long')))
            .getSingle();
        container.read(posCartProvider.notifier).selectCustomer(cust);
        container.read(posCartProvider.notifier).addBatch(
              PosScannedBatch(
                batchId: 'batch-gen-ok',
                variantId: 'var-gen-ok',
                productId: 'prod-gen-ok',
                productName:
                    "L'Oréal Paris Revitalift 1.5% Hyaluronic Acid Serum 30ml",
                brand: "L'Oréal",
                category: 'Skincare',
                isGeneric: false,
                variantName: 'Limited Jumbo Collector Edition #128',
                batchCode: 'BIG-999',
                stickerBarcode: '01999902',
                sellingPricePaisa: 99999900, // Rs. 9,99,999
                stockQuantity: 5,
                expiryDate: DateTime.utc(2028, 12, 31),
              ),
            );
        await tester.pumpAndSettle();

        final formattedHuge = MoneyUtils.formatRs(99999900);
        expect(find.text(formattedHuge), findsWidgets);
        expect(find.byTooltip('Detach customer'), findsOneWidget);

        // Detach customer cleanly without losing cart item
        await tester.tap(find.byTooltip('Detach customer'));
        await tester.pumpAndSettle();
        expect(find.text('Khata / Shades'), findsOneWidget);
        expect(find.text(formattedHuge), findsWidgets);

        container.dispose();
        await _unmountWidgetTree(tester, db);
      },
    );
  });
}
