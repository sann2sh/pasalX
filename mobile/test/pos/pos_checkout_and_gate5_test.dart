import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pasalx_mobile/core/database/app_database.dart';
import 'package:pasalx_mobile/core/printer/printer.dart';
import 'package:pasalx_mobile/core/providers/foundation_providers.dart';
import 'package:pasalx_mobile/core/security/ram_key_holder.dart';
import 'package:pasalx_mobile/core/theme/app_theme.dart';
import 'package:pasalx_mobile/features/pos/data/pos_repository.dart';
import 'package:pasalx_mobile/features/pos/domain/pos_models.dart';
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

class _CapturingReceiptDriver extends Xlab365tDriver {
  _CapturingReceiptDriver({this.failWith});

  final PrinterException? failWith;
  final List<ReceiptPrintData> printedReceipts = <ReceiptPrintData>[];
  final List<Uint8List> printedBytes = <Uint8List>[];

  @override
  Future<Uint8List> printReceipt(
    ReceiptPrintData receipt, {
    bool? autoSwitch,
  }) async {
    final bytes = EscPosReceiptBuilder().build(receipt);
    if (failWith != null) {
      throw failWith!;
    }
    printedReceipts.add(receipt);
    printedBytes.add(bytes);
    return bytes;
  }
}

Future<void> _seedPosTestCatalog(AppDatabase db) async {
  final now = DateTime.utc(2026, 11, 16, 10, 0);

  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: '11111111-1111-1111-1111-111111111111',
          name: 'Sunita Staff',
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
          openingFloat: 500000, // Rs. 5,000
          expectedCash: 500000,
          status: const Value('OPEN'),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );

  // Product 1: Fit Me Matte Foundation -> Shade #128 Warm Nude
  // Has 3 batches: EXPIRED, OLDER FEFO, NEWER
  await db.into(db.products).insert(
        ProductsCompanion.insert(
          id: 'prod-fitme',
          name: 'Fit Me Matte Foundation',
          brand: 'Maybelline',
          category: 'Makeup - Face',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
  await db.into(db.productVariants).insert(
        ProductVariantsCompanion.insert(
          id: 'var-128',
          productId: 'prod-fitme',
          variantName: '#128 Warm Nude',
          colorHex: const Value('#E0B083'),
          sizeVolume: const Value('30ml'),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
  // Expired batch
  await db.into(db.batches).insert(
        BatchesCompanion.insert(
          id: 'batch-expired',
          variantId: 'var-128',
          batchCode: 'LOT-EXP',
          stickerBarcode: '01100001',
          costPrice: const Value(80000),
          sellingPrice: 135000, // Rs. 1,350
          stockQuantity: const Value(3),
          expiryDate: '2025-05-01',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
  // Older FEFO batch
  await db.into(db.batches).insert(
        BatchesCompanion.insert(
          id: 'batch-older',
          variantId: 'var-128',
          batchCode: 'LOT-OLD',
          stickerBarcode: '01100002',
          costPrice: const Value(80000),
          sellingPrice: 135000, // Rs. 1,350
          stockQuantity: const Value(4),
          expiryDate: '2027-03-01',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
  // Newer batch
  await db.into(db.batches).insert(
        BatchesCompanion.insert(
          id: 'batch-newer',
          variantId: 'var-128',
          batchCode: 'LOT-NEW',
          stickerBarcode: '01100003',
          costPrice: const Value(85000),
          sellingPrice: 135000, // Rs. 1,350
          stockQuantity: const Value(10),
          expiryDate: '2028-06-01',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );

  // Generic Quick-Pad Item: Hair Rubbers
  await db.into(db.products).insert(
        ProductsCompanion.insert(
          id: 'prod-rubbers',
          name: 'Silk Hair Rubbers',
          brand: 'Generic',
          category: 'Generic',
          isGeneric: const Value(true),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
  await db.into(db.productVariants).insert(
        ProductVariantsCompanion.insert(
          id: 'var-rubbers',
          productId: 'prod-rubbers',
          variantName: 'Pack',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
  await db.into(db.batches).insert(
        BatchesCompanion.insert(
          id: 'batch-rubbers',
          variantId: 'var-rubbers',
          batchCode: 'GEN-01',
          stickerBarcode: '01900001',
          costPrice: const Value(2000),
          sellingPrice: 5000, // Rs. 50
          stockQuantity: const Value(100),
          expiryDate: '2099-12-31',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );

  // Customer + Shade Profile
  await db.into(db.customers).insert(
        CustomersCompanion.insert(
          id: 'cust-sita',
          name: 'Sita Sharma',
          phone: '9841000001',
          creditLimit: const Value(500000), // Rs. 5,000
          currentBalanceDue: const Value(100000), // Rs. 1,000 due
          favoriteShadeNotes: const Value('Fit Me #128'),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
  await db.into(db.customerShadeProfiles).insert(
        CustomerShadeProfilesCompanion.insert(
          id: 'shade-sita-1',
          customerId: 'cust-sita',
          productName: 'Fit Me Matte Foundation',
          brand: 'Maybelline',
          shadeVariant: '#128 Warm Nude',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
}

Widget _buildPosHarness({
  required AppDatabase db,
  required RamKeyHolder holder,
  required Xlab365tDriver driver,
  Size viewport = const Size(390, 844),
}) {
  return ProviderScope(
    overrides: [
      activeDatabaseProvider.overrideWith(() => _FixedDbNotifier(db)),
      ramKeyHolderProvider.overrideWith((ref) => holder),
      xlabPrinterDriverProvider.overrideWithValue(driver),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(size: viewport),
        child: const Scaffold(body: PosScreen()),
      ),
    ),
  );
}

class _FixedDbNotifier extends ActiveDatabaseNotifier {
  _FixedDbNotifier(this._db);
  final AppDatabase _db;
  @override
  AppDatabase? build() => _db;
}

Future<void> _unmountWidgetTree(WidgetTester tester, AppDatabase db) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await db.close();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('Review Gate 5: POS Counter, FEFO/Expired, Quick-Pad, Checkout & Khata',
      () {
    late AppDatabase db;
    late RamKeyHolder holder;
    late _CapturingReceiptDriver driver;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      await _seedPosTestCatalog(db);
      holder = RamKeyHolder();
      holder.unlock(
        dekBytes: Uint8List.fromList(List<int>.filled(32, 7)),
        session: _fakeSession('STAFF'),
      );
      driver = _CapturingReceiptDriver();
    });

    tearDown(() async {
      await db.close();
    });

    testWidgets(
      'Gate 5 E2E: Expired block -> FEFO older-batch switch -> 3x3 Quick-Pad -> 10% Negotiation -> Cash Checkout & 80mm PAN-only receipt',
      (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          _buildPosHarness(
            db: db,
            holder: holder,
            driver: driver,
            viewport: const Size(360, 780),
          ),
        );
        await tester.pumpAndSettle();

        // 1. Scan EXPIRED batch via Search/Enter -> Hard-Blocked!
        await tester.enterText(
          find.byType(TextField).first,
          '01100001',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        expect(find.text('EXPIRED BATCH BLOCKED'), findsOneWidget);
        await tester.tap(find.text('Acknowledge'));
        await tester.pumpAndSettle();
        expect(find.text('Cart is Empty'), findsOneWidget);

        // 2. Scan NEWER batch (01100003) -> FEFO soft warning shown -> Switch to Older!
        await tester.enterText(
          find.byType(TextField).first,
          '01100003',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        expect(find.text('FEFO: Older Batch Available'), findsOneWidget);
        expect(find.textContaining('LOT-OLD'), findsOneWidget);
        await tester.tap(find.text('Switch to Older'));
        await tester.pumpAndSettle();

        expect(find.text('Fit Me Matte Foundation'), findsOneWidget);
        expect(find.text('Rs. 1,350'), findsWidgets);

        // 3. Tap Quick-Pad (bottom-right thumb stack) -> Tap Silk Hair Rubbers -> Enter Rs. 75 x 2 -> Add to Bill
        await tester.tap(find.text('Quick-Pad'));
        await tester.pumpAndSettle();

        expect(find.text('Accessories Quick-Pad'), findsOneWidget);
        expect(find.text('Silk Hair Rubbers'), findsOneWidget);
        await tester.tap(find.text('Silk Hair Rubbers'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('CLR'));
        await tester.pump();
        await tester.tap(find.text('7'));
        await tester.pump();
        await tester.tap(find.text('5'));
        await tester.pump();
        await tester.tap(find.byIcon(Icons.add_rounded).last); // qty -> 2
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add to Bill (Rs. 150)'));
        await tester.pumpAndSettle();

        // Subtotal = 1350 + 150 = Rs. 1,500
        expect(find.text('Rs. 1,500'), findsWidgets);

        // 4. Open 4-tier Negotiation Sheet -> Apply 10% OFF (-Rs. 150 -> Net Rs. 1,350)
        await tester.tap(find.text('Discount'));
        await tester.pumpAndSettle();

        expect(find.text('Negotiation & Discount'), findsOneWidget);
        await tester.tap(find.text('10% OFF'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Apply Discount'));
        await tester.tap(find.text('Apply Discount'));
        await tester.pumpAndSettle();

        expect(find.text('Rs. 1,350'), findsWidgets);

        // 5. Open Checkout Sheet via Cash -> Tap +Rs. 500 -> Complete Sale & Print Receipt
        await tester.tap(find.text('Cash'));
        await tester.pumpAndSettle();

        expect(find.text('Counter Checkout'), findsOneWidget);
        await tester.ensureVisible(find.text('+Rs. 500'));
        await tester.tap(find.text('+Rs. 500'));
        await tester.pumpAndSettle();
        expect(find.text('CHANGE DUE'), findsOneWidget);
        expect(find.text('Rs. 500'), findsOneWidget);

        await tester.ensureVisible(find.text('Complete Sale & Print Receipt'));
        await tester.tap(find.text('Complete Sale & Print Receipt'));
        await tester.pumpAndSettle();

        // Verify ESC/POS receipt dispatched with PAN-only (no VAT) & cut command
        expect(driver.printedReceipts.length, 1);
        final receipt = driver.printedReceipts.single;
        expect(receipt.billNo, '01-0001');
        expect(receipt.subtotalPaisa, 150000);
        expect(receipt.discountPaisa, 15000);
        expect(receipt.totalPaisa, 135000);
        expect(receipt.changeDuePaisa, 50000);

        final rawAscii = ascii.decode(driver.printedBytes.single, allowInvalid: true);
        expect(rawAscii.contains('RETAIL BILL'), isTrue);
        expect(rawAscii.contains('VAT'), isFalse);
        expect(
          driver.printedBytes.single.sublist(driver.printedBytes.single.length - 4),
          equals(const [0x1D, 0x56, 0x41, 0x00]),
        );

        // Verify SQLite atomic state: stock decremented, sale_orders + outbox queued
        final olderBatch = await (db.select(db.batches)
              ..where((b) => b.id.equals('batch-older')))
            .getSingle();
        expect(olderBatch.stockQuantity, 3); // 4 -> 3

        final outbox = await db.fetchPendingOutbox();
        expect(outbox.length, 1);
        expect(outbox.single.targetTable, 'sale_orders');
        final payload =
            jsonDecode(outbox.single.payloadJson) as Map<String, dynamic>;
        // STAFF role must not emit cost_total / net_profit / cost_price
        expect(payload.containsKey('cost_total'), isFalse);
        expect(payload.containsKey('net_profit'), isFalse);
        expect(payload['subtotal'], '1500.00');
        expect(payload['discount_amount'], '150.00');
        expect(payload['total_amount'], '1350.00');

        await _unmountWidgetTree(tester, db);
      },
    );

    testWidgets(
      'HID Bluetooth Laser Scanner rapid keystrokes + Enter adds batch directly',
      (tester) async {
        await tester.pumpWidget(
          _buildPosHarness(db: db, holder: holder, driver: driver),
        );
        await tester.pumpAndSettle();

        // Simulate HID gun typing "01100002" + Enter while no text field is focused
        for (final key in const [
          LogicalKeyboardKey.digit0,
          LogicalKeyboardKey.digit1,
          LogicalKeyboardKey.digit1,
          LogicalKeyboardKey.digit0,
          LogicalKeyboardKey.digit0,
          LogicalKeyboardKey.digit0,
          LogicalKeyboardKey.digit0,
          LogicalKeyboardKey.digit2,
        ]) {
          await tester.sendKeyEvent(key);
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pumpAndSettle();

        expect(find.text('Fit Me Matte Foundation'), findsOneWidget);
        expect(find.text('Rs. 1,350'), findsWidgets);

        await _unmountWidgetTree(tester, db);
      },
    );

    test('Khata Credit Limit enforcement, DEBIT_PURCHASE & CREDIT_REPAYMENT',
        () async {
      addTearDown(holder.dispose);
      final repo = PosRepository(
        db: db,
        clock: () => DateTime.utc(2026, 11, 16, 12, 0),
      );

      final bundle = await repo.loadCustomerBundle('cust-sita');
      expect(bundle, isNotNull);
      expect(bundle!.shades.length, 1);

      // Add previous shade via repository
      final matched = await repo.findBestBatchForShadeProfile(
        bundle.shades.single,
        role: 'STAFF',
      );
      expect(matched, isNotNull);
      expect(matched!.batchId, 'batch-older'); // FEFO picks older batch!

      // Attempt Khata sale exceeding credit limit (Limit 5000, Due 1000, Sale 4500 -> 5500 > 5000)
      await expectLater(
        () => repo.completeCheckout(
          items: [
            PosCartItem(
              lineKey: matched.batchId,
              batchId: matched.batchId,
              productId: matched.productId,
              variantId: matched.variantId,
              productName: matched.productName,
              variantName: matched.variantName,
              batchCode: matched.batchCode,
              stickerBarcode: matched.stickerBarcode,
              isGeneric: false,
              unitPricePaisa: 450000,
              quantity: 1,
              availableStock: 4,
              expiryDate: matched.expiryDate,
            ),
          ],
          discount: const PosDiscount.none(),
          payments: const [
            PosPaymentLeg(method: 'KHATA_CREDIT', amountPaisa: 450000),
          ],
          paymentMode: 'KHATA_CREDIT',
          cashierUserId: '11111111-1111-1111-1111-111111111111',
          cashierName: 'Sunita Staff',
          role: 'STAFF',
          deviceCode: '01',
          shiftId: 'shift-01',
          customer: bundle.customer,
        ),
        throwsA(isA<PosValidationException>()),
      );

      // Valid Khata purchase (Rs. 1,350 -> Due becomes Rs. 2,350)
      final commit = await repo.completeCheckout(
        items: [
          PosCartItem(
            lineKey: matched.batchId,
            batchId: matched.batchId,
            productId: matched.productId,
            variantId: matched.variantId,
            productName: matched.productName,
            variantName: matched.variantName,
            batchCode: matched.batchCode,
            stickerBarcode: matched.stickerBarcode,
            isGeneric: false,
            unitPricePaisa: 135000,
            quantity: 1,
            availableStock: 4,
            expiryDate: matched.expiryDate,
          ),
        ],
        discount: const PosDiscount.none(),
        payments: const [
          PosPaymentLeg(method: 'KHATA_CREDIT', amountPaisa: 135000),
        ],
        paymentMode: 'KHATA_CREDIT',
        cashierUserId: '11111111-1111-1111-1111-111111111111',
        cashierName: 'Sunita Staff',
        role: 'STAFF',
        deviceCode: '01',
        shiftId: 'shift-01',
        customer: bundle.customer,
      );
      expect(commit.khataBalanceAfterPaisa, 235000);

      // Verify DEBIT_PURCHASE outbox payload omits payment_method (Go sync only allows CASH|FONEPAY_QR|BANK_TRANSFER)
      final pending = await db.fetchPendingOutbox();
      final debitRow = pending.firstWhere(
        (r) => r.targetTable == 'customer_transactions',
      );
      final debitJson = jsonDecode(debitRow.payloadJson) as Map<String, dynamic>;
      expect(debitJson.containsKey('payment_method'), isFalse);

      // Record Cash Khata Repayment of Rs. 500 -> Due becomes Rs. 1,850, Shift expectedCash += 500
      await repo.recordKhataRepayment(
        customerId: 'cust-sita',
        amountPaisa: 50000,
        paymentMethod: 'CASH',
        userId: '11111111-1111-1111-1111-111111111111',
        shiftId: 'shift-01',
      );

      final updatedCust = await (db.select(db.customers)
            ..where((c) => c.id.equals('cust-sita')))
          .getSingle();
      expect(updatedCust.currentBalanceDue, 185000);

      final updatedShift = await (db.select(db.registerShifts)
            ..where((s) => s.id.equals('shift-01')))
          .getSingle();
      expect(updatedShift.khataCashRepayments, 50000);
      expect(updatedShift.expectedCash, 550000); // 5000 + 500
    });

    testWidgets(
      'Printer offline during Complete & Print still saves bill & shows Retry Print',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final offlineDriver = _CapturingReceiptDriver(
          failWith: const PrinterConnectionException('TCP timeout'),
        );
        await tester.pumpWidget(
          _buildPosHarness(db: db, holder: holder, driver: offlineDriver),
        );
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField).first, '01100002');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        await tester.tap(find.text('Cash'));
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.text('Complete Sale & Print Receipt'));
        await tester.tap(find.text('Complete Sale & Print Receipt'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pumpAndSettle();

        // Bill saved once and Retry Print banner visible
        expect(find.text('Retry Print'), findsOneWidget);
        final orders = await db.select(db.saleOrders).get();
        expect(orders.length, 1);

        await _unmountWidgetTree(tester, db);
      },
    );

    testWidgets(
      'Static Fonepay QR requires confirmation & prints GS ( k QR on 80mm receipt',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          _buildPosHarness(db: db, holder: holder, driver: driver),
        );
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField).first, '01100002');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        await tester.tap(find.text('QR Pay'));
        await tester.pumpAndSettle();

        // Attempting to complete without Confirm QR Received shows error
        await tester.ensureVisible(find.text('Complete Sale & Print Receipt'));
        await tester.tap(find.text('Complete Sale & Print Receipt'));
        await tester.pumpAndSettle();
        expect(
          find.text('Please confirm Fonepay QR payment was received.'),
          findsOneWidget,
        );

        // Toggle Confirm QR Received -> Complete Sale & Print Receipt
        await tester.ensureVisible(find.text('Confirm QR Received'));
        await tester.tap(find.text('Confirm QR Received'));
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.text('Complete Sale & Print Receipt'));
        await tester.tap(find.text('Complete Sale & Print Receipt'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pumpAndSettle();

        expect(driver.printedReceipts.length, 1);
        expect(driver.printedReceipts.single.paymentMode, 'FONEPAY_QR');
        expect(
          driver.printedReceipts.single.staticQrPayload,
          'FONEPAY:PASALCOSMETICS:NP',
        );
        // Verify ESC/POS GS ( k (0x1D 0x28 0x6B) QR command is present
        final bytes = driver.printedBytes.single;
        var hasQrCmd = false;
        for (var i = 0; i < bytes.length - 2; i++) {
          if (bytes[i] == 0x1D && bytes[i + 1] == 0x28 && bytes[i + 2] == 0x6B) {
            hasQrCmd = true;
            break;
          }
        }
        expect(hasQrCmd, isTrue);

        // Verify shift digital_sales incremented by Rs. 1,350
        final shift = await (db.select(db.registerShifts)
              ..where((s) => s.id.equals('shift-01')))
            .getSingle();
        expect(shift.digitalSales, 135000);
        expect(shift.cashSales, 0);

        await _unmountWidgetTree(tester, db);
      },
    );

    testWidgets(
      'Khata & Shades UI: search customer by phone, Add Previous Shade, and Attach to Bill',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          _buildPosHarness(db: db, holder: holder, driver: driver),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Tap to attach Khata / Shades'));
        await tester.pumpAndSettle();

        expect(find.text('Khata & Shade Lookup'), findsOneWidget);
        expect(find.text('Sita Sharma'), findsOneWidget);

        await tester.tap(find.text('Sita Sharma'));
        await tester.pumpAndSettle();

        expect(find.text('Add Previous Shade'), findsOneWidget);
        await tester.tap(find.text('Add Previous Shade'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Attach to Bill'));
        await tester.pumpAndSettle();

        // Cart now has Fit Me Matte Foundation (from shade profile) & Sita Sharma attached
        expect(find.text('Fit Me Matte Foundation'), findsOneWidget);
        expect(find.text('Sita Sharma'), findsOneWidget);

        await _unmountWidgetTree(tester, db);
      },
    );

    test('Split tender (Cash + Fonepay) & OWNER cost/profit calculation',
        () async {
      addTearDown(holder.dispose);
      final repo = PosRepository(
        db: db,
        clock: () => DateTime.utc(2026, 11, 16, 12, 0),
      );

      final lookup = await repo.lookupByBarcode('01100002', role: 'OWNER');
      expect(lookup.status, PosBatchScanStatus.ok);
      final batch = lookup.scannedBatch!;
      expect(batch.costPricePaisa, 80000);

      final commit = await repo.completeCheckout(
        items: [
          PosCartItem(
            lineKey: batch.batchId,
            batchId: batch.batchId,
            productId: batch.productId,
            variantId: batch.variantId,
            productName: batch.productName,
            variantName: batch.variantName,
            batchCode: batch.batchCode,
            stickerBarcode: batch.stickerBarcode,
            isGeneric: false,
            unitPricePaisa: batch.sellingPricePaisa,
            costPricePaisa: batch.costPricePaisa,
            quantity: 1,
            availableStock: 4,
            expiryDate: batch.expiryDate,
          ),
        ],
        discount: const PosDiscount.none(),
        payments: const [
          PosPaymentLeg(method: 'CASH', amountPaisa: 100000),
          PosPaymentLeg(method: 'FONEPAY_QR', amountPaisa: 35000),
        ],
        paymentMode: 'SPLIT',
        cashierUserId: '11111111-1111-1111-1111-111111111111',
        cashierName: 'Owner',
        role: 'OWNER',
        deviceCode: '01',
        shiftId: 'shift-01',
      );

      final order = await (db.select(db.saleOrders)
            ..where((o) => o.id.equals(commit.saleOrderId)))
          .getSingle();
      expect(order.costTotal, 80000);
      expect(order.netProfit, 55000); // 1350 - 800

      final shift = await (db.select(db.registerShifts)
            ..where((s) => s.id.equals('shift-01')))
          .getSingle();
      expect(shift.cashSales, 100000);
      expect(shift.digitalSales, 35000);
      expect(shift.expectedCash, 600000); // 5000 + 1000
    });

    testWidgets(
      'Phase 4: Full-screen BarcodeScannerScreen & Item Negotiation Sheet (zero cost/margin even for OWNER)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final ownerHolder = RamKeyHolder()
          ..unlock(
            dekBytes: Uint8List.fromList(List<int>.filled(32, 7)),
            session: _fakeSession('OWNER'),
          );

        await tester.pumpWidget(
          _buildPosHarness(db: db, holder: ownerHolder, driver: driver),
        );
        await tester.pumpAndSettle();

        // 1. Open Full-Screen Barcode Scanner from bottom-right Scan button
        await tester.tap(find.text('Scan'));
        await tester.pumpAndSettle();

        expect(find.text('Barcode Scanner'), findsOneWidget);
        expect(find.text('Continuous Scan Active'), findsOneWidget);

        // Manual barcode add on scanner screen
        await tester.enterText(
          find.widgetWithText(
            TextField,
            'Type barcode manually (e.g. 01100024)',
          ),
          '01100002',
        );
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();

        expect(find.text('1 item'), findsOneWidget);
        await tester.tap(find.text('Done Scanning • Back to Cart'));
        await tester.pumpAndSettle();

        // Back on POS with item in cart
        expect(find.text('Fit Me Matte Foundation'), findsOneWidget);

        // 2. Tap cart item to open Item Negotiation Sheet (Screen 9)
        await tester.tap(find.text('Fit Me Matte Foundation'));
        await tester.pumpAndSettle();

        expect(find.text('Edit Cart Item'), findsOneWidget);
        // Privacy check: Cost & Margin MUST NEVER appear on POS, even for OWNER
        expect(find.textContaining('Cost'), findsNothing);
        expect(find.textContaining('Margin'), findsNothing);
        expect(find.text('Rs. 800'), findsNothing);

        // Apply 10% Off item discount (1350 -> 1215)
        await tester.ensureVisible(find.text('10% Off'));
        await tester.tap(find.text('10% Off'));
        await tester.pumpAndSettle();
        expect(find.text('Rs. 1,215'), findsOneWidget);

        await tester.ensureVisible(find.text('Done & Update Cart'));
        await tester.tap(find.text('Done & Update Cart'));
        await tester.pumpAndSettle();

        // Cart Net Payable updated to Rs. 1,215
        expect(find.text('Rs. 1,215'), findsWidgets);

        await _unmountWidgetTree(tester, db);
      },
    );
  });
}
