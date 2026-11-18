import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../../core/database/app_database.dart';
import '../../inventory/domain/catalog_models.dart';

/// Top-selling product variant summary for today's Home Dashboard.
@immutable
class TopSellingItemSnapshot {
  const TopSellingItemSnapshot({
    required this.productId,
    required this.productName,
    required this.variantName,
    required this.quantitySold,
    required this.unitPricePaisa,
    this.sizeVolume,
    this.colorHex,
  });

  final String productId;
  final String productName;
  final String variantName;
  final int quantitySold;
  final int unitPricePaisa;
  final String? sizeVolume;
  final String? colorHex;
}

/// Aggregated live snapshot for the Home Dashboard (Screen 3).
@immutable
class HomeDashboardSnapshot {
  const HomeDashboardSnapshot({
    required this.totalSalesPaisa,
    required this.dailyTargetPaisa,
    required this.billCount,
    required this.avgBillPaisa,
    required this.itemsSoldCount,
    required this.cashSalesPaisa,
    required this.qrSalesPaisa,
    required this.khataSalesPaisa,
    required this.khataDueTotalPaisa,
    required this.khataDueCustomersCount,
    required this.unpaidSuppliersCount,
    required this.unpaidSuppliersTotalPaisa,
    required this.nearExpiryBatchCount,
    required this.drawerCashPaisa,
    required this.activeShiftId,
    required this.topSellingToday,
  });

  static const int defaultDailyTargetPaisa = 5500000; // Rs. 55,000

  final int totalSalesPaisa;
  final int dailyTargetPaisa;
  final int billCount;
  final int avgBillPaisa;
  final int itemsSoldCount;
  final int cashSalesPaisa;
  final int qrSalesPaisa;
  final int khataSalesPaisa;
  final int khataDueTotalPaisa;
  final int khataDueCustomersCount;
  final int unpaidSuppliersCount;
  final int unpaidSuppliersTotalPaisa;
  final int nearExpiryBatchCount;
  final int drawerCashPaisa;
  final String? activeShiftId;
  final List<TopSellingItemSnapshot> topSellingToday;

  int get targetPercent {
    if (dailyTargetPaisa <= 0) return 0;
    return ((totalSalesPaisa * 100) / dailyTargetPaisa).round().clamp(0, 999);
  }
}

/// Repository aggregating today's sales, payment split, Khata dues,
/// near-expiry batch alerts, and top sellers from encrypted SQLite.
class HomeRepository {
  HomeRepository(this._db);

  final AppDatabase _db;

  /// Reactive stream refreshing whenever sales, stock, customers,
  /// suppliers, or register shifts change.
  Stream<HomeDashboardSnapshot> watchTodaySnapshot({DateTime? now}) async* {
    yield await loadTodaySnapshot(now: now);
    final updates = _db.tableUpdates(
      TableUpdateQuery.onAllTables({
        _db.saleOrders,
        _db.saleItems,
        _db.salePayments,
        _db.customers,
        _db.suppliers,
        _db.batches,
        _db.productVariants,
        _db.products,
        _db.registerShifts,
        _db.expenses,
        _db.syncMetadata,
      }),
    );
    await for (final _ in updates) {
      yield await loadTodaySnapshot(now: now);
    }
  }

  /// Computes today's Home Dashboard KPIs in fixed-point paisa.
  Future<HomeDashboardSnapshot> loadTodaySnapshot({DateTime? now}) async {
    final current = now ?? DateTime.now();
    final startLocal = DateTime(current.year, current.month, current.day);
    final endLocal = startLocal.add(const Duration(days: 1));
    final startUtc = startLocal.toUtc();
    final endUtc = endLocal.toUtc();

    final targetRaw = await _db.getMetadata('daily_sales_target_paisa');
    final dailyTargetPaisa = int.tryParse(targetRaw ?? '') ??
        HomeDashboardSnapshot.defaultDailyTargetPaisa;

    // 1. Today's sale orders + items + payments
    final orders = await (_db.select(_db.saleOrders)
          ..where(
            (t) =>
                t.createdAt.isBiggerOrEqualValue(startUtc) &
                t.createdAt.isSmallerThanValue(endUtc),
          ))
        .get();

    var totalSalesPaisa = 0;
    final orderIds = <String>[];
    for (final order in orders) {
      totalSalesPaisa += order.totalAmount;
      orderIds.add(order.id);
    }
    final billCount = orders.length;
    final avgBillPaisa = billCount == 0 ? 0 : totalSalesPaisa ~/ billCount;

    var itemsSoldCount = 0;
    var cashSalesPaisa = 0;
    var qrSalesPaisa = 0;
    var khataSalesPaisa = 0;
    final topSellingToday = <TopSellingItemSnapshot>[];

    if (orderIds.isNotEmpty) {
      final payments = await (_db.select(_db.salePayments)
            ..where((t) => t.saleOrderId.isIn(orderIds)))
          .get();
      for (final p in payments) {
        switch (p.method.toUpperCase()) {
          case 'CASH':
            cashSalesPaisa += p.amount;
          case 'FONEPAY_QR':
          case 'QR':
          case 'CARD':
            qrSalesPaisa += p.amount;
          case 'KHATA_CREDIT':
          case 'KHATA':
            khataSalesPaisa += p.amount;
        }
      }

      final items = await (_db.select(_db.saleItems)
            ..where((t) => t.saleOrderId.isIn(orderIds)))
          .get();
      for (final item in items) {
        itemsSoldCount += item.quantity;
      }

      topSellingToday.addAll(await _aggregateTopSelling(items));
    }

    // 2. Customer Khata dues
    final dueCustomers = await (_db.select(_db.customers)
          ..where(
            (t) =>
                t.deletedAt.isNull() & t.currentBalanceDue.isBiggerThanValue(0),
          ))
        .get();
    var khataDueTotalPaisa = 0;
    for (final c in dueCustomers) {
      khataDueTotalPaisa += c.currentBalanceDue;
    }

    // 3. Unpaid Suppliers (empty when scrubbed for STAFF)
    final unpaidSuppliers = await (_db.select(_db.suppliers)
          ..where((t) => t.deletedAt.isNull() & t.balanceDue.isBiggerThanValue(0)))
        .get();
    var unpaidSuppliersTotalPaisa = 0;
    for (final s in unpaidSuppliers) {
      unpaidSuppliersTotalPaisa += s.balanceDue;
    }

    // 4. Near-expiry or expired in-stock batches (< 30 days)
    final activeBatches = await (_db.select(_db.batches)
          ..where((t) => t.deletedAt.isNull() & t.stockQuantity.isBiggerThanValue(0)))
        .get();
    var nearExpiryBatchCount = 0;
    for (final b in activeBatches) {
      final status = InventoryDateUtils.classifyExpiry(
        b.expiryDate,
        now: current,
      );
      if (status == BatchExpiryStatus.expired ||
          status == BatchExpiryStatus.expiringSoon) {
        nearExpiryBatchCount++;
      }
    }

    // 5. Active register shift drawer cash
    final activeShift = await (_db.select(_db.registerShifts)
          ..where((t) => t.status.equals('OPEN'))
          ..orderBy([(t) => OrderingTerm.desc(t.openedAt)])
          ..limit(1))
        .getSingleOrNull();

    return HomeDashboardSnapshot(
      totalSalesPaisa: totalSalesPaisa,
      dailyTargetPaisa: dailyTargetPaisa,
      billCount: billCount,
      avgBillPaisa: avgBillPaisa,
      itemsSoldCount: itemsSoldCount,
      cashSalesPaisa: cashSalesPaisa,
      qrSalesPaisa: qrSalesPaisa,
      khataSalesPaisa: khataSalesPaisa,
      khataDueTotalPaisa: khataDueTotalPaisa,
      khataDueCustomersCount: dueCustomers.length,
      unpaidSuppliersCount: unpaidSuppliers.length,
      unpaidSuppliersTotalPaisa: unpaidSuppliersTotalPaisa,
      nearExpiryBatchCount: nearExpiryBatchCount,
      drawerCashPaisa: activeShift?.expectedCash ?? 0,
      activeShiftId: activeShift?.id,
      topSellingToday: topSellingToday,
    );
  }

  Future<List<TopSellingItemSnapshot>> _aggregateTopSelling(
    List<SaleItemRow> items,
  ) async {
    if (items.isEmpty) return const <TopSellingItemSnapshot>[];
    final batchIds = items.map((i) => i.batchId).toSet().toList(growable: false);
    final batchRows = await (_db.select(_db.batches)
          ..where((t) => t.id.isIn(batchIds)))
        .get();
    final batchById = {for (final b in batchRows) b.id: b};

    final variantIds =
        batchRows.map((b) => b.variantId).toSet().toList(growable: false);
    final variantRows = variantIds.isEmpty
        ? const <ProductVariantRow>[]
        : await (_db.select(_db.productVariants)
              ..where((t) => t.id.isIn(variantIds)))
            .get();
    final variantById = {for (final v in variantRows) v.id: v};

    final grouped = <String, _TopAgg>{};
    for (final item in items) {
      final batch = batchById[item.batchId];
      final variant = batch == null ? null : variantById[batch.variantId];
      final productId = variant?.productId ?? item.batchId;
      final key = variant?.id ?? '${item.productName}|${item.variantName}';
      final existing = grouped[key];
      if (existing == null) {
        grouped[key] = _TopAgg(
          productId: productId,
          productName: item.productName,
          variantName: item.variantName,
          sizeVolume: variant?.sizeVolume,
          colorHex: variant?.colorHex,
          quantitySold: item.quantity,
          revenuePaisa: item.totalPrice,
          unitPricePaisa: item.sellingPrice,
        );
      } else {
        existing.quantitySold += item.quantity;
        existing.revenuePaisa += item.totalPrice;
      }
    }

    final list = grouped.values.toList()
      ..sort((a, b) {
        final qtyCmp = b.quantitySold.compareTo(a.quantitySold);
        if (qtyCmp != 0) return qtyCmp;
        return b.revenuePaisa.compareTo(a.revenuePaisa);
      });

    return list
        .take(3)
        .map(
          (e) => TopSellingItemSnapshot(
            productId: e.productId,
            productName: e.productName,
            variantName: e.variantName,
            quantitySold: e.quantitySold,
            unitPricePaisa: e.unitPricePaisa,
            sizeVolume: e.sizeVolume,
            colorHex: e.colorHex,
          ),
        )
        .toList(growable: false);
  }
}

class _TopAgg {
  _TopAgg({
    required this.productId,
    required this.productName,
    required this.variantName,
    required this.quantitySold,
    required this.revenuePaisa,
    required this.unitPricePaisa,
    this.sizeVolume,
    this.colorHex,
  });

  final String productId;
  final String productName;
  final String variantName;
  final String? sizeVolume;
  final String? colorHex;
  int quantitySold;
  int revenuePaisa;
  final int unitPricePaisa;
}
