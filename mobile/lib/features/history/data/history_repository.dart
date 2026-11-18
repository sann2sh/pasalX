import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';

/// Repository powering Screen 4 (`HistoryScreen`), Screen 14 (`SaleDetailScreen`),
/// and Screen 15 (`PurchaseDetailScreen`).
class HistoryRepository {
  HistoryRepository(this._db);

  final AppDatabase _db;

  Stream<List<SaleOrderBundle>> watchSales({
    bool todayOnly = true,
    DateTime? now,
  }) {
    if (!todayOnly) {
      return _db.watchSaleOrderBundles();
    }
    final current = now ?? DateTime.now();
    final startLocal = DateTime(current.year, current.month, current.day);
    final endLocal = startLocal.add(const Duration(days: 1));
    return _db.watchSaleOrderBundles(from: startLocal, to: endLocal);
  }

  Stream<List<PurchaseInvoiceBundle>> watchPurchases() {
    return _db.watchPurchaseInvoiceBundles();
  }

  Stream<List<ExpenseRow>> watchExpenses({
    bool todayOnly = true,
    DateTime? now,
  }) {
    final query = _db.select(_db.expenses)
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
    if (todayOnly) {
      final current = now ?? DateTime.now();
      final startLocal = DateTime(current.year, current.month, current.day);
      final endLocal = startLocal.add(const Duration(days: 1));
      query.where(
        (t) =>
            t.createdAt.isBiggerOrEqualValue(startLocal.toUtc()) &
            t.createdAt.isSmallerThanValue(endLocal.toUtc()),
      );
    }
    return query.watch();
  }

  Stream<SaleDetailBundle?> watchSaleDetail(String saleOrderId) {
    return _db.watchSaleDetailBundle(saleOrderId);
  }

  Stream<PurchaseDetailBundle?> watchPurchaseDetail(String purchaseInvoiceId) {
    return _db.watchPurchaseDetailBundle(purchaseInvoiceId);
  }
}

