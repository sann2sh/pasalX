import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../core/database/app_database.dart';
import '../../../core/providers/foundation_providers.dart';
import '../data/supplier_repository.dart';

final supplierRepositoryProvider = Provider<SupplierRepository?>((ref) {
  final db = ref.watch(activeDatabaseProvider);
  if (db == null) return null;
  return SupplierRepository(db);
});

final supplierSearchQueryProvider = StateProvider<String>((ref) => '');

final suppliersListProvider = StreamProvider<List<SupplierRow>>((ref) {
  final repo = ref.watch(supplierRepositoryProvider);
  final query = ref.watch(supplierSearchQueryProvider);
  if (repo == null) return Stream.value(const <SupplierRow>[]);
  return repo.watchSuppliers(search: query);
});

