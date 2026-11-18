import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../suppliers/application/supplier_providers.dart';
import '../data/register_repository.dart';
import '../domain/register_models.dart';

final registerRepositoryProvider = Provider<RegisterRepository?>((ref) {
  final db = ref.watch(activeDatabaseProvider);
  if (db == null) return null;
  return RegisterRepository(db);
});

final activeRegisterShiftProvider = StreamProvider<RegisterShiftRow?>((ref) {
  final repo = ref.watch(registerRepositoryProvider);
  if (repo == null) return Stream.value(null);
  return repo.watchActiveShift();
});

final lastClosedShiftProvider = StreamProvider<RegisterShiftRow?>((ref) {
  final repo = ref.watch(registerRepositoryProvider);
  if (repo == null) return Stream.value(null);
  return repo.watchLastClosedShift();
});

final shiftStaffSessionsProvider =
    StreamProvider.family<List<StaffSessionWithUser>, String>((ref, shiftId) {
  final repo = ref.watch(registerRepositoryProvider);
  if (repo == null) return Stream.value(const <StaffSessionWithUser>[]);
  return repo.watchStaffSessionsForShift(shiftId);
});

final shiftExpensesProvider =
    StreamProvider.family<List<ExpenseRow>, String?>((ref, shiftId) {
  final repo = ref.watch(supplierRepositoryProvider);
  if (repo == null) return Stream.value(const <ExpenseRow>[]);
  return repo.watchExpenses(shiftId: shiftId);
});

