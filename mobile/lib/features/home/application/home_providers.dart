import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/foundation_providers.dart';
import '../data/home_repository.dart';

final homeRepositoryProvider = Provider<HomeRepository?>((ref) {
  final db = ref.watch(activeDatabaseProvider);
  if (db == null) return null;
  return HomeRepository(db);
});

final homeDashboardProvider = StreamProvider<HomeDashboardSnapshot?>((ref) {
  final repo = ref.watch(homeRepositoryProvider);
  if (repo == null) return Stream.value(null);
  return repo.watchTodaySnapshot();
});

