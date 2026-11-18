import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/money.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../application/inventory_providers.dart';
import '../domain/catalog_models.dart';
import 'barcode_scanner_sheet.dart';
import 'inventory_action_sheets.dart';

/// Screen 6: Stock Catalog (`Product -> Variant -> Batch`) with compact cards,
/// Role-protected Stock Value KPI, quick Label & Adjust buttons, and tap-to-open
/// Product & Batch Details (`/inventory/product/:id`).
class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});

  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _openScanner() async {
    final scanned = await showBarcodeScannerSheet(
      context,
      title: 'Scan Catalog Barcode',
      hintText: 'Barcode or batch code...',
    );
    if (scanned != null && mounted) {
      _searchController.text = scanned;
      ref.read(catalogFilterProvider.notifier).setQuery(scanned);
    }
  }

  void _openSmartIntake({String? productId, String? variantId}) {
    final canManage = ref.read(canManageInventoryProvider);
    if (!canManage) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Stock intake is restricted to Manager or Store Owner accounts.',
          ),
        ),
      );
      return;
    }

    final params = <String, String>{
      if (productId != null) 'productId': productId,
      if (variantId != null) 'variantId': variantId,
    };
    final uri = Uri(
      path: '/inventory/intake',
      queryParameters: params.isEmpty ? null : params,
    );
    context.push(uri.toString());
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final stats = ref.watch(catalogSummaryStatsProvider);
    final filter = ref.watch(catalogFilterProvider);
    final filteredNodes = ref.watch(filteredCatalogNodesProvider);
    final canManage = ref.watch(canManageInventoryProvider);
    final canViewCost = ref.watch(canViewCostPriceProvider);
    final stockValuePaisa = ref.watch(ownerStockValuePaisaProvider);
    final asyncNodes = ref.watch(catalogNodesProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutterMobile,
        AppSpacing.sm,
        AppSpacing.gutterMobile,
        AppSpacing.xl,
      ),
      children: [
        // Search / Scan Bar + Inward CTA
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('catalog-search-input'),
                controller: _searchController,
                onChanged: (val) =>
                    ref.read(catalogFilterProvider.notifier).setQuery(val),
                decoration: InputDecoration(
                  hintText: 'Search product, brand, shade...',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  isDense: true,
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (filter.query.isNotEmpty)
                        IconButton(
                          tooltip: 'Clear search',
                          onPressed: () {
                            _searchController.clear();
                            ref
                                .read(catalogFilterProvider.notifier)
                                .setQuery('');
                          },
                          icon: const Icon(Icons.close_rounded, size: 18),
                        ),
                      IconButton(
                        key: const ValueKey('catalog-barcode-scan-btn'),
                        tooltip: 'Scan barcode',
                        onPressed: _openScanner,
                        icon: Icon(
                          Icons.qr_code_scanner_rounded,
                          size: 20,
                          color: c.primaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            SizedBox(
              height: 46,
              child: FilledButton.tonalIcon(
                key: const ValueKey('catalog-inward-btn'),
                onPressed: () => _openSmartIntake(),
                icon: Icon(
                  canManage
                      ? Icons.add_circle_outline_rounded
                      : Icons.lock_outline_rounded,
                  size: 18,
                ),
                label: Text(canManage ? '+ Inward' : 'Locked'),
                style: FilledButton.styleFrom(
                  backgroundColor: canManage
                      ? c.secondaryContainer
                      : c.surfaceContainerHigh,
                  foregroundColor: canManage
                      ? c.onSecondaryContainer
                      : c.onSurfaceVariant,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),

        // Category Filter Pills
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  key: const ValueKey('filter-cat-all'),
                  selected: filter.selectedCategory == null &&
                      !filter.expiringOnly &&
                      !filter.lowOrExpiringOnly &&
                      !filter.lowReserveOnly,
                  label: Text('All (${stats.activeProductCount})'),
                  onSelected: (_) {
                    _searchController.clear();
                    ref.read(catalogFilterProvider.notifier).clearAll();
                  },
                ),
              ),
              ...SmartIntakeCategory.values.map(
                (cat) => Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    key: ValueKey('filter-cat-${cat.name}'),
                    selected: filter.selectedCategory == cat,
                    label: Text(cat.shortLabel),
                    onSelected: (_) => ref
                        .read(catalogFilterProvider.notifier)
                        .selectCategory(
                          filter.selectedCategory == cat ? null : cat,
                        ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  key: const ValueKey('filter-cat-low-expiring'),
                  selected: filter.lowOrExpiringOnly || filter.expiringOnly,
                  label: const Text('Low / Expiring'),
                  selectedColor: c.errorContainer,
                  onSelected: (_) => ref
                      .read(catalogFilterProvider.notifier)
                      .toggleLowOrExpiringOnly(),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),

        // Top KPI Glance Cards (Stock Value hidden for Staff/Manager)
        Row(
          children: [
            Expanded(
              child: PasalPressable(
                onTap: () =>
                    ref.read(catalogFilterProvider.notifier).clearAll(),
                child: PasalCard(
                  color: c.surfaceContainerLow,
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ACTIVE SKUS',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.labelSmall?.copyWith(fontSize: 10),
                      ),
                      const SizedBox(height: 2),
                      PasalTabularText(
                        '${stats.activeProductCount} SKUs',
                        style: t.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${stats.totalUnits} units',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall?.copyWith(
                          color: c.primary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: PasalPressable(
                onTap: () => ref
                    .read(catalogFilterProvider.notifier)
                    .toggleLowReserveOnly(),
                child: PasalCard(
                  color: filter.lowReserveOnly
                      ? c.errorContainer
                      : (stats.lowReserveCount > 0
                          ? c.errorContainer.withValues(alpha: 0.45)
                          : c.surfaceContainerLow),
                  borderColor:
                      stats.lowReserveCount > 0 || filter.lowReserveOnly
                          ? c.error.withValues(alpha: 0.3)
                          : null,
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'LOW STOCK',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.labelSmall?.copyWith(
                          fontSize: 10,
                          color: stats.lowReserveCount > 0
                              ? c.error
                              : c.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      PasalTabularText(
                        '${stats.lowReserveCount} Alerts',
                        style: t.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: stats.lowReserveCount > 0
                              ? c.onErrorContainer
                              : c.onSurface,
                        ),
                      ),
                      Text(
                        '${stats.expiringCount} expiring soon',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall?.copyWith(
                          fontSize: 11,
                          color: stats.expiringCount > 0
                              ? c.error
                              : c.secondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (canViewCost && stockValuePaisa != null) ...[
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: PasalCard(
                  key: const ValueKey('catalog-stock-value-kpi'),
                  color: c.surfaceContainerLow,
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'STOCK VALUE',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.labelSmall?.copyWith(fontSize: 10),
                      ),
                      const SizedBox(height: 2),
                      PasalTabularText(
                        MoneyUtils.formatRs(stockValuePaisa),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'Wholesale cost',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall?.copyWith(
                          color: c.outline,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.md),

        // Loading / Empty / Compact Product Cards
        if (asyncNodes.isLoading && filteredNodes.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (filteredNodes.isEmpty)
          _EmptyCatalogCard(
            hasActiveFilters: filter.query.isNotEmpty ||
                filter.selectedCategory != null ||
                filter.lowReserveOnly ||
                filter.expiringOnly ||
                filter.lowOrExpiringOnly,
            canManage: canManage,
            onClearFilters: () {
              _searchController.clear();
              ref.read(catalogFilterProvider.notifier).clearAll();
            },
            onOpenIntake: () => _openSmartIntake(),
          )
        else
          ...filteredNodes.map(
            (node) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ProductCompactCard(
                node: node,
                canManage: canManage,
                canViewCost: canViewCost,
                onTapCard: () =>
                    context.push('/inventory/product/${node.product.id}'),
              ),
            ),
          ),
      ],
    );
  }
}

class _ProductCompactCard extends StatelessWidget {
  const _ProductCompactCard({
    required this.node,
    required this.canManage,
    required this.canViewCost,
    required this.onTapCard,
  });

  final ProductCatalogNode node;
  final bool canManage;
  final bool canViewCost;
  final VoidCallback onTapCard;

  ({VariantCatalogNode variant, BatchCatalogItem batch})? _primaryBatch() {
    for (final v in node.variants) {
      if (v.batches.isNotEmpty) {
        return (variant: v, batch: v.batches.first);
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final p = node.product;
    final primary = _primaryBatch();
    final primaryBatch = primary?.batch;
    final primaryVariant = primary?.variant;

    final isAlert = node.hasLowStock || node.hasExpiringOrExpired;
    final cardBg = node.hasLowStock
        ? c.errorContainer.withValues(alpha: 0.22)
        : c.surfaceContainerLowest;
    final borderColor = node.hasLowStock
        ? c.error.withValues(alpha: 0.35)
        : c.hairline;

    return PasalPressable(
      onTap: onTapCard,
      child: PasalCard(
        key: ValueKey('product-card-${p.id}'),
        color: cardBg,
        borderColor: borderColor,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top Row: Brand/Product/Swatches + Price/(Owner Cost)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.brand.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.labelSmall?.copyWith(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.7,
                          color: node.hasLowStock ? c.error : c.secondary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        p.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: t.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (node.variants.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            ...node.variants.take(2).map(
                                  (v) => Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: c.surfaceContainerLow,
                                      borderRadius:
                                          BorderRadius.circular(AppRadii.sm),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (v.swatchColor != null) ...[
                                          Container(
                                            width: 9,
                                            height: 9,
                                            decoration: BoxDecoration(
                                              color: v.swatchColor,
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: Colors.black
                                                    .withValues(alpha: 0.15),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 5),
                                        ],
                                        Flexible(
                                          child: Text(
                                            v.variant.variantName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: t.bodySmall?.copyWith(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            if (node.variants.length > 2)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: c.surfaceContainer,
                                  borderRadius:
                                      BorderRadius.circular(AppRadii.sm),
                                ),
                                child: Text(
                                  '+${node.variants.length - 2} more',
                                  style: t.bodySmall?.copyWith(
                                    fontSize: 11,
                                    color: c.outline,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    PasalTabularText(
                      node.formattedPriceRange,
                      style: t.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (canViewCost &&
                        primaryBatch?.batch.costPrice != null) ...[
                      const SizedBox(height: 2),
                      PasalTabularText(
                        'Cost: ${MoneyUtils.formatRs(primaryBatch!.batch.costPrice!)}',
                        style: t.bodySmall?.copyWith(
                          fontSize: 10,
                          color: c.outline,
                        ),
                      ),
                    ] else if (!canViewCost &&
                        canManage &&
                        primaryBatch != null) ...[
                      const SizedBox(height: 2),
                      Container(
                        key: ValueKey(
                          'cost-locked-badge-${primaryBatch.batch.id}',
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: c.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.lock_outline_rounded,
                              size: 11,
                              color: c.outline,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              'Owner Cost',
                              style: t.labelSmall?.copyWith(
                                fontSize: 9,
                                color: c.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),

            const SizedBox(height: 10),
            Divider(
              height: 1,
              color: (node.hasLowStock ? c.error : c.hairline)
                  .withValues(alpha: 0.35),
            ),
            const SizedBox(height: 8),

            // Footer Row: Stock + Expiry + Quick Label/Adjust
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: node.hasLowStock
                              ? c.errorContainer
                              : c.secondaryContainer,
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                        ),
                        child: PasalTabularText(
                          node.hasLowStock
                              ? '${node.totalStock} pcs • Low'
                              : '${node.totalStock} pcs',
                          style: t.labelSmall?.copyWith(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: node.hasLowStock
                                ? c.onErrorContainer
                                : c.onSecondaryContainer,
                          ),
                        ),
                      ),
                      if (primaryBatch != null)
                        Text(
                          'Exp: ${primaryBatch.displayExpiry}',
                          style: t.bodySmall?.copyWith(
                            fontSize: 11,
                            color: isAlert ? c.error : c.outline,
                            fontWeight:
                                isAlert ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                    ],
                  ),
                ),
                if (canManage && primaryBatch != null && primaryVariant != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      OutlinedButton.icon(
                        key: ValueKey('batch-print-btn-${primaryBatch.batch.id}'),
                        onPressed: () => showPrintLabelsSheet(
                          context,
                          product: p,
                          variant: primaryVariant.variant,
                          batch: primaryBatch.batch,
                        ),
                        icon: Icon(
                          Icons.qr_code_2_rounded,
                          size: 14,
                          color: c.primary,
                        ),
                        label: const Text('Label'),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          textStyle: t.labelSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      OutlinedButton(
                        key: ValueKey(
                          'batch-adjust-btn-${primaryBatch.batch.id}',
                        ),
                        onPressed: () => showStockAdjustmentSheet(
                          context,
                          product: p,
                          variant: primaryVariant.variant,
                          batch: primaryBatch.batch,
                        ),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          textStyle: t.labelSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        child: const Text('Adjust'),
                      ),
                    ],
                  )
                else if (!canManage)
                  PasalStatusBadge(
                    label: 'STAFF READ-ONLY',
                    icon: Icons.visibility_outlined,
                    backgroundColor: c.surfaceContainer,
                    foregroundColor: c.onSurfaceVariant,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyCatalogCard extends StatelessWidget {
  const _EmptyCatalogCard({
    required this.hasActiveFilters,
    required this.canManage,
    required this.onClearFilters,
    required this.onOpenIntake,
  });

  final bool hasActiveFilters;
  final bool canManage;
  final VoidCallback onClearFilters;
  final VoidCallback onOpenIntake;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return PasalCard(
      color: c.surfaceContainerLow,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        children: [
          Icon(Icons.inventory_2_outlined, size: 40, color: c.secondary),
          const SizedBox(height: AppSpacing.sm),
          Text(
            hasActiveFilters
                ? 'No matching batches or shades'
                : 'No products in vault yet',
            style: t.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            hasActiveFilters
                ? 'Try clearing category or search filters.'
                : 'Add your first cosmetic batch using 1-Screen Smart Intake.',
            style: t.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.md),
          if (hasActiveFilters)
            OutlinedButton(
              onPressed: onClearFilters,
              child: const Text('Clear Filters'),
            )
          else if (canManage)
            ElevatedButton.icon(
              onPressed: onOpenIntake,
              icon: const Icon(Icons.add_circle_outline_rounded),
              label: const Text('Open Smart Intake'),
            ),
        ],
      ),
    );
  }
}
