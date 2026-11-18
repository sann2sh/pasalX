import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/providers/foundation_providers.dart';
import '../data/inventory_repository.dart';
import '../domain/catalog_models.dart';

/// Active [InventoryRepository] bound to the unlocked encrypted SQLCipher vault.
final inventoryRepositoryProvider = Provider<InventoryRepository?>((ref) {
  final db = ref.watch(activeDatabaseProvider);
  if (db == null) return null;
  return InventoryRepository(
    db: db,
    onMutationCommitted: () {
      ref.read(syncOutboxWorkerProvider).scheduleImmediateSync();
    },
  );
});

/// Role check matching `TECHNICAL_SPEC.md` §7.5: only `OWNER` / `MANAGER`
/// may perform stock intake, adjustments, or sticker printing.
final canManageInventoryProvider = Provider<bool>((ref) {
  final role = ref.watch(ramKeyHolderProvider).session?.role;
  return InventoryRepository.canManageInventory(role);
});

/// Role check matching `TECHNICAL_SPEC.md` §7.5 & Task 8.3: strictly `OWNER`
/// may view or edit wholesale `cost_price` and margin values.
final canViewCostPriceProvider = Provider<bool>((ref) {
  final role = ref.watch(ramKeyHolderProvider).session?.role;
  return InventoryRepository.canViewCostPrice(role);
});

/// Reactive 3-tier `Product -> Variant -> Batch` catalog stream from SQLite.
final catalogNodesProvider = StreamProvider<List<ProductCatalogNode>>((ref) {
  final repo = ref.watch(inventoryRepositoryProvider);
  if (repo == null) {
    return Stream<List<ProductCatalogNode>>.value(const <ProductCatalogNode>[]);
  }
  return repo.watchCatalogHierarchy();
});

/// Role-filtered suppliers stream (`OWNER` & `MANAGER` only; empty for `STAFF`).
final inventorySuppliersProvider = StreamProvider<List<SupplierRow>>((ref) {
  final repo = ref.watch(inventoryRepositoryProvider);
  final role = ref.watch(ramKeyHolderProvider).session?.role;
  if (repo == null) {
    return Stream<List<SupplierRow>>.value(const <SupplierRow>[]);
  }
  return repo.watchSuppliersForRole(role);
});

class CatalogFilterNotifier extends Notifier<CatalogFilterState> {
  @override
  CatalogFilterState build() => const CatalogFilterState();

  void setQuery(String value) {
    state = state.copyWith(query: value);
  }

  void selectCategory(SmartIntakeCategory? category) {
    if (category == null) {
      state = state.copyWith(clearCategory: true);
    } else {
      state = state.copyWith(selectedCategory: category);
    }
  }

  void toggleLowReserveOnly() {
    state = state.copyWith(lowReserveOnly: !state.lowReserveOnly);
  }

  void toggleExpiringOnly() {
    state = state.copyWith(expiringOnly: !state.expiringOnly);
  }

  void toggleLowOrExpiringOnly() {
    state = state.copyWith(lowOrExpiringOnly: !state.lowOrExpiringOnly);
  }

  void clearAll() {
    state = const CatalogFilterState();
  }
}

final catalogFilterProvider =
    NotifierProvider<CatalogFilterNotifier, CatalogFilterState>(
  CatalogFilterNotifier.new,
);

/// Aggregated KPI metrics computed across the full unfiltered catalog.
final catalogSummaryStatsProvider = Provider<CatalogSummaryStats>((ref) {
  final nodes = ref.watch(catalogNodesProvider).asData?.value ??
      const <ProductCatalogNode>[];
  final categories = <String>{};
  var lowCount = 0;
  var expCount = 0;
  var totalUnits = 0;

  for (final n in nodes) {
    categories.add(n.categoryKind.dbValue);
    if (n.hasLowStock) lowCount++;
    if (n.hasExpiringOrExpired) expCount++;
    totalUnits += n.totalStock;
  }

  return CatalogSummaryStats(
    activeProductCount: nodes.length,
    categoryCount: categories.length,
    lowReserveCount: lowCount,
    expiringCount: expCount,
    totalUnits: totalUnits,
  );
});

/// Filtered 3-tier catalog nodes reacting immediately to search / category pills.
final filteredCatalogNodesProvider = Provider<List<ProductCatalogNode>>((ref) {
  final all = ref.watch(catalogNodesProvider).asData?.value ??
      const <ProductCatalogNode>[];
  final filter = ref.watch(catalogFilterProvider);
  final q = filter.query.trim().toLowerCase();

  return all.where((node) {
    if (filter.selectedCategory != null &&
        node.categoryKind != filter.selectedCategory) {
      return false;
    }
    if (filter.lowReserveOnly && !node.hasLowStock) {
      return false;
    }
    if (filter.expiringOnly && !node.hasExpiringOrExpired) {
      return false;
    }
    if (filter.lowOrExpiringOnly &&
        !node.hasLowStock &&
        !node.hasExpiringOrExpired) {
      return false;
    }
    if (q.isEmpty) {
      return true;
    }

    if (node.product.name.toLowerCase().contains(q) ||
        node.product.brand.toLowerCase().contains(q) ||
        node.product.category.toLowerCase().contains(q)) {
      return true;
    }

    for (final v in node.variants) {
      if (v.variant.variantName.toLowerCase().contains(q) ||
          (v.variant.sizeVolume?.toLowerCase().contains(q) ?? false)) {
        return true;
      }
      for (final b in v.batches) {
        if (b.batch.batchCode.toLowerCase().contains(q) ||
            b.batch.stickerBarcode.toLowerCase().contains(q)) {
          return true;
        }
      }
    }
    return false;
  }).toList(growable: false);
});

/// Total wholesale stock value in paisa — strictly `OWNER` only (null otherwise).
final ownerStockValuePaisaProvider = Provider<int?>((ref) {
  final canViewCost = ref.watch(canViewCostPriceProvider);
  if (!canViewCost) return null;

  final nodes = ref.watch(catalogNodesProvider).asData?.value ??
      const <ProductCatalogNode>[];
  var totalPaisa = 0;
  for (final n in nodes) {
    for (final v in n.variants) {
      for (final b in v.batches) {
        final cost = b.batch.costPrice ?? 0;
        if (b.batch.stockQuantity > 0 && cost > 0) {
          totalPaisa += b.batch.stockQuantity * cost;
        }
      }
    }
  }
  return totalPaisa;
});

/// Single [ProductCatalogNode] lookup by `productId` for [ProductDetailScreen].
final productNodeByIdProvider =
    Provider.family<ProductCatalogNode?, String>((ref, productId) {
  final nodes = ref.watch(catalogNodesProvider).asData?.value ??
      const <ProductCatalogNode>[];
  for (final n in nodes) {
    if (n.product.id == productId) return n;
  }
  return null;
});

/// Chronological stock movements across all batches of a product.
final productMovementsProvider =
    StreamProvider.family<List<StockMovementRow>, String>((ref, productId) {
  final db = ref.watch(activeDatabaseProvider);
  if (db == null) {
    return Stream<List<StockMovementRow>>.value(const <StockMovementRow>[]);
  }
  return db.watchProductMovements(productId);
});

/// Latest sourcing purchase invoice for a product (strictly `OWNER` only).
final productLatestPurchaseProvider =
    StreamProvider.family<PurchaseDetailBundle?, String>((ref, productId) {
  final canViewCost = ref.watch(canViewCostPriceProvider);
  final db = ref.watch(activeDatabaseProvider);
  final node = ref.watch(productNodeByIdProvider(productId));
  if (!canViewCost || db == null || node == null) {
    return Stream<PurchaseDetailBundle?>.value(null);
  }

  BatchRow? latestWithInvoice;
  for (final v in node.variants) {
    for (final b in v.batches) {
      if (b.batch.purchaseInvoiceId != null &&
          b.batch.purchaseInvoiceId!.isNotEmpty) {
        if (latestWithInvoice == null ||
            b.batch.createdAt.isAfter(latestWithInvoice.createdAt)) {
          latestWithInvoice = b.batch;
        }
      }
    }
  }

  if (latestWithInvoice == null) {
    return Stream<PurchaseDetailBundle?>.value(null);
  }
  return db.watchPurchaseDetailBundle(latestWithInvoice.purchaseInvoiceId!);
});


