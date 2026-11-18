import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:pasalx_mobile/app.dart';
import 'package:pasalx_mobile/core/database/app_database.dart';
import 'package:pasalx_mobile/core/providers/foundation_providers.dart';
import 'package:pasalx_mobile/core/router/app_router.dart';
import 'package:pasalx_mobile/core/security/ram_key_holder.dart';
import 'package:pasalx_mobile/features/home/data/home_repository.dart';

ActiveLeaseSession _fakeSession(String role) {
  final now = DateTime.now().toUtc();
  return ActiveLeaseSession(
    userId: 'user-1',
    username: role == 'OWNER' ? 'ramesh' : 'sunita',
    role: role,
    deviceId: 'dev-1',
    deviceCode: 'TERM-01',
    leaseId: 'lease-1',
    issuedAt: now,
    expiresAt: now.add(const Duration(hours: 12)),
  );
}

Future<void> _seedPhase3Data(AppDatabase db) async {
  final now = DateTime.now().toUtc();
  final soonExpiry = DateFormat('yyyy-MM-dd')
      .format(DateTime.now().add(const Duration(days: 15)));
  final freshExpiry = DateFormat('yyyy-MM-dd')
      .format(DateTime.now().add(const Duration(days: 240)));

  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: 'user-1',
          name: 'Ramesh Shrestha',
          username: 'ramesh',
          role: 'OWNER',
        ),
      );

  await db.into(db.registerShifts).insert(
        RegisterShiftsCompanion.insert(
          id: 'shift-1',
          openedByUserId: 'user-1',
          openingFloat: 500000, // Rs. 5,000
          cashSales: const Value(135000),
          expectedCash: 635000, // Rs. 6,350
          status: const Value('OPEN'),
        ),
      );

  await db.into(db.customers).insert(
        CustomersCompanion.insert(
          id: 'cust-1',
          name: 'Sita Sharma',
          phone: '9841234567',
          currentBalanceDue: const Value(340000), // Rs. 3,400
        ),
      );

  await db.into(db.suppliers).insert(
        SuppliersCompanion.insert(
          id: 'sup-1',
          name: 'Nepal Beauty Distributors Ltd.',
          phone: const Value('9851099887'),
          panVat: const Value('302918291'),
          totalPurchased: const Value(8500000),
          balanceDue: const Value(8500000), // Rs. 85,000
        ),
      );

  await db.into(db.products).insert(
        ProductsCompanion.insert(
          id: 'prod-1',
          name: 'Fit Me Matte Foundation',
          brand: 'Maybelline',
          category: 'Face',
        ),
      );
  await db.into(db.products).insert(
        ProductsCompanion.insert(
          id: 'prod-2',
          name: 'Retro Matte Lipstick',
          brand: 'MAC',
          category: 'Lips',
        ),
      );

  await db.into(db.productVariants).insert(
        ProductVariantsCompanion.insert(
          id: 'var-1',
          productId: 'prod-1',
          variantName: '#128 Warm Nude',
          sizeVolume: const Value('30ml'),
          colorHex: const Value('#E6BE9A'),
        ),
      );
  await db.into(db.productVariants).insert(
        ProductVariantsCompanion.insert(
          id: 'var-2',
          productId: 'prod-2',
          variantName: 'Ruby Woo',
          sizeVolume: const Value('3g'),
          colorHex: const Value('#A32B38'),
        ),
      );

  await db.into(db.batches).insert(
        BatchesCompanion.insert(
          id: 'batch-1',
          variantId: 'var-1',
          supplierId: const Value('sup-1'),
          batchCode: 'LOT-FM-01',
          stickerBarcode: '890123450001',
          costPrice: const Value(85000), // Rs. 850
          sellingPrice: 135000, // Rs. 1,350
          stockQuantity: const Value(12),
          expiryDate: soonExpiry, // Near expiry (< 30 days)
        ),
      );
  await db.into(db.batches).insert(
        BatchesCompanion.insert(
          id: 'batch-2',
          variantId: 'var-2',
          supplierId: const Value('sup-1'),
          batchCode: 'LOT-MAC-01',
          stickerBarcode: '890123450002',
          costPrice: const Value(190000), // Rs. 1,900
          sellingPrice: 285000, // Rs. 2,850
          stockQuantity: const Value(8),
          expiryDate: freshExpiry,
        ),
      );

  // Purchase Invoice
  await db.into(db.purchaseInvoices).insert(
        PurchaseInvoicesCompanion.insert(
          id: 'pinv-1',
          supplierId: 'sup-1',
          invoiceNo: 'PINV-8821',
          invoiceDate: '2026-11-10',
          totalAmount: 8500000,
          dueAmount: 8500000,
          status: const Value('UNPAID'),
          createdByUserId: const Value('user-1'),
        ),
      );
  await db.into(db.purchaseInvoiceItems).insert(
        PurchaseInvoiceItemsCompanion.insert(
          id: 'pitem-1',
          purchaseInvoiceId: 'pinv-1',
          variantId: 'var-1',
          batchId: const Value('batch-1'),
          productName: 'Fit Me Matte Foundation',
          variantName: '#128 Warm Nude',
          quantityReceived: 20,
          unitCostPrice: const Value(85000),
          unitSellingPrice: 135000,
          totalCost: const Value(1700000),
          batchCode: const Value('LOT-FM-01'),
          expiryDate: soonExpiry,
        ),
      );

  // Today's Sale 1: Cash + QR (Rs. 4,200 total -> 1x Foundation + 1x Lipstick)
  await db.into(db.saleOrders).insert(
        SaleOrdersCompanion.insert(
          id: 'sale-1',
          billNo: 'BL-2026-0891',
          customerId: const Value('cust-1'),
          customerName: const Value('Sita Sharma'),
          customerPhone: const Value('9841234567'),
          cashierUserId: 'user-1',
          cashierName: 'Sunita Shrestha',
          shiftId: const Value('shift-1'),
          subtotal: 420000,
          totalAmount: 420000,
          paymentMode: 'FONEPAY_QR',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
  await db.into(db.saleItems).insert(
        SaleItemsCompanion.insert(
          id: 'sitem-1',
          saleOrderId: 'sale-1',
          batchId: 'batch-1',
          productName: 'Fit Me Matte Foundation',
          variantName: '#128 Warm Nude',
          quantity: 1,
          sellingPrice: 135000,
          totalPrice: 135000,
        ),
      );
  await db.into(db.saleItems).insert(
        SaleItemsCompanion.insert(
          id: 'sitem-2',
          saleOrderId: 'sale-1',
          batchId: 'batch-2',
          productName: 'Retro Matte Lipstick',
          variantName: 'Ruby Woo',
          quantity: 1,
          sellingPrice: 285000,
          totalPrice: 285000,
        ),
      );
  await db.into(db.salePayments).insert(
        SalePaymentsCompanion.insert(
          id: 'spay-1',
          saleOrderId: 'sale-1',
          method: 'FONEPAY_QR',
          amount: 420000,
        ),
      );

  // Today's Sale 2: Cash (Rs. 1,350 -> 1x Foundation)
  await db.into(db.saleOrders).insert(
        SaleOrdersCompanion.insert(
          id: 'sale-2',
          billNo: 'BL-2026-0890',
          cashierUserId: 'user-1',
          cashierName: 'Sunita Shrestha',
          shiftId: const Value('shift-1'),
          subtotal: 135000,
          totalAmount: 135000,
          paymentMode: 'CASH',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
  await db.into(db.saleItems).insert(
        SaleItemsCompanion.insert(
          id: 'sitem-3',
          saleOrderId: 'sale-2',
          batchId: 'batch-1',
          productName: 'Fit Me Matte Foundation',
          variantName: '#128 Warm Nude',
          quantity: 1,
          sellingPrice: 135000,
          totalPrice: 135000,
        ),
      );
  await db.into(db.salePayments).insert(
        SalePaymentsCompanion.insert(
          id: 'spay-2',
          saleOrderId: 'sale-2',
          method: 'CASH',
          amount: 135000,
        ),
      );

  // Today's Petty Expense
  await db.into(db.expenses).insert(
        ExpensesCompanion.insert(
          id: 'exp-1',
          category: 'Staff Refreshments',
          title: 'Staff Tea & Snacks',
          amount: 25000, // Rs. 250
          paymentMethod: 'CASH',
          shiftId: const Value('shift-1'),
          createdByUserId: 'user-1',
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
}

void main() {
  group('Phase 3 Home & History', () {
    late AppDatabase db;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      await _seedPhase3Data(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('HomeRepository aggregates fixed-point paisa KPIs, expiry count & top sellers',
        () async {
      final repo = HomeRepository(db);
      final snap = await repo.loadTodaySnapshot();

      expect(snap.totalSalesPaisa, 555000); // Rs. 5,550
      expect(snap.billCount, 2);
      expect(snap.avgBillPaisa, 277500); // Rs. 2,775
      expect(snap.itemsSoldCount, 3);
      expect(snap.cashSalesPaisa, 135000);
      expect(snap.qrSalesPaisa, 420000);
      expect(snap.khataSalesPaisa, 0);
      expect(snap.khataDueTotalPaisa, 340000);
      expect(snap.khataDueCustomersCount, 1);
      expect(snap.unpaidSuppliersCount, 1);
      expect(snap.unpaidSuppliersTotalPaisa, 8500000);
      expect(snap.nearExpiryBatchCount, 1);
      expect(snap.drawerCashPaisa, 635000);
      expect(snap.topSellingToday.length, 2);
      expect(snap.topSellingToday.first.productName, 'Fit Me Matte Foundation');
      expect(snap.topSellingToday.first.quantitySold, 2);
    });

    testWidgets('HomeScreen shows Owner KPIs & warning popup, and hides Owner tiles for Staff',
        (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final router = createAppRouter(initialLocation: AppRoutes.home);
      addTearDown(router.dispose);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final holder = container.read(ramKeyHolderProvider);
      holder.unlock(
        dekBytes: Uint8List.fromList(List<int>.filled(32, 3)),
        session: _fakeSession('OWNER'),
      );
      container.read(activeDatabaseProvider.notifier).setDatabase(db);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: PasalXApp(routerOverride: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Namaste, Ramesh'), findsOneWidget);
      expect(find.text('Rs. 5,550'), findsOneWidget);
      expect(find.text('Stock Inward'), findsOneWidget);
      expect(find.text('Suppliers & Bills'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('Fit Me Matte Foundation'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Fit Me Matte Foundation'), findsOneWidget);

      // Scroll back up to tap yellow expiry warning pill
      await tester.scrollUntilVisible(
        find.byIcon(Icons.warning_amber_rounded),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byIcon(Icons.warning_amber_rounded));
      await tester.pumpAndSettle();
      expect(
        find.text('1 batch expires within 30 days. Sell oldest stock first.'),
        findsOneWidget,
      );
      expect(find.text('View'), findsOneWidget);

      // Switch to STAFF -> hides Owner-only quick actions
      holder.unlock(
        dekBytes: Uint8List.fromList(List<int>.filled(32, 3)),
        session: _fakeSession('STAFF'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Stock Inward'), findsNothing);
      expect(find.text('Suppliers & Bills'), findsNothing);
      expect(find.text('Customer Khata'), findsOneWidget);
    });

    testWidgets('HistoryScreen filters Sales/Expenses, opens SaleDetailScreen & enforces Staff Purchases privacy',
        (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final router = createAppRouter(initialLocation: AppRoutes.history);
      addTearDown(router.dispose);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final holder = container.read(ramKeyHolderProvider);
      holder.unlock(
        dekBytes: Uint8List.fromList(List<int>.filled(32, 4)),
        session: _fakeSession('OWNER'),
      );
      container.read(activeDatabaseProvider.notifier).setDatabase(db);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: PasalXApp(routerOverride: router),
        ),
      );
      await tester.pumpAndSettle();

      // Owner sees all 3 tabs
      expect(find.text('Sales (2)'), findsOneWidget);
      expect(find.text('Purchases (1)'), findsOneWidget);
      expect(find.text('Expenses (1)'), findsOneWidget);

      // Search filters bills
      await tester.enterText(find.byType(TextField), '0891');
      await tester.pumpAndSettle();
      expect(find.text('#BL-2026-0891'), findsOneWidget);
      expect(find.text('#BL-2026-0890'), findsNothing);

      // Tap sale row -> SaleDetailScreen
      await tester.tap(find.text('#BL-2026-0891'));
      await tester.pumpAndSettle();
      expect(find.text('Sale Receipt'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Share Bill'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Store PAN Bill • No VAT'), findsOneWidget);
      expect(find.text('Share Bill'), findsOneWidget);
      expect(find.text('Reprint Slip'), findsOneWidget);

      // Tap Share Bill -> copies summary and shows success alert
      await tester.ensureVisible(find.text('Share Bill'));
      await tester.tap(find.text('Share Bill'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.text('Bill summary copied to share on WhatsApp/SMS'),
        findsOneWidget,
      );

      // Navigate back to History -> clear search -> Purchases -> PurchaseDetailScreen
      await tester.pageBack();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Purchases (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nepal Beauty Distributors Ltd.'));
      await tester.pumpAndSettle();

      expect(find.text('Purchase Bill'), findsOneWidget);
      expect(find.text('+37% Margin'), findsOneWidget);
      expect(find.text('Pay Supplier'), findsOneWidget);

      // Navigate back and switch to STAFF -> Purchases tab & KPI hidden
      await tester.pageBack();
      await tester.pumpAndSettle();
      holder.unlock(
        dekBytes: Uint8List.fromList(List<int>.filled(32, 4)),
        session: _fakeSession('STAFF'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Purchases (1)'), findsNothing);
      expect(find.text('Expenses (1)'), findsOneWidget);
    });
  });
}
