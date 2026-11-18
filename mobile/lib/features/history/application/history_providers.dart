import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/providers/foundation_providers.dart';
import '../data/history_repository.dart';

final historyRepositoryProvider = Provider<HistoryRepository?>((ref) {
  final db = ref.watch(activeDatabaseProvider);
  if (db == null) return null;
  return HistoryRepository(db);
});

final historySalesProvider =
    StreamProvider.family<List<SaleOrderBundle>, bool>((ref, todayOnly) {
  final repo = ref.watch(historyRepositoryProvider);
  if (repo == null) return Stream.value(const <SaleOrderBundle>[]);
  return repo.watchSales(todayOnly: todayOnly);
});

final historyPurchasesProvider =
    StreamProvider<List<PurchaseInvoiceBundle>>((ref) {
  final repo = ref.watch(historyRepositoryProvider);
  if (repo == null) return Stream.value(const <PurchaseInvoiceBundle>[]);
  return repo.watchPurchases();
});

final historyExpensesProvider =
    StreamProvider.family<List<ExpenseRow>, bool>((ref, todayOnly) {
  final repo = ref.watch(historyRepositoryProvider);
  if (repo == null) return Stream.value(const <ExpenseRow>[]);
  return repo.watchExpenses(todayOnly: todayOnly);
});

final saleDetailProvider =
    StreamProvider.family<SaleDetailBundle?, String>((ref, saleId) {
  final repo = ref.watch(historyRepositoryProvider);
  if (repo == null) return Stream.value(null);
  return repo.watchSaleDetail(saleId);
});

final purchaseDetailProvider =
    StreamProvider.family<PurchaseDetailBundle?, String>((ref, purchaseId) {
  final repo = ref.watch(historyRepositoryProvider);
  if (repo == null) return Stream.value(null);
  return repo.watchPurchaseDetail(purchaseId);
});

