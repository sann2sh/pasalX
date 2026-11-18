import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/money.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../application/inventory_providers.dart';
import '../domain/catalog_models.dart';
import 'inventory_action_sheets.dart';

/// Screen 12: 3-Tier Product & Batch Details (`/inventory/product/:id`).
///
/// Displays variant specs, Owner-only cost & margin economics, FEFO priority
/// banner, physical batch cards with Print/Adjust actions, Owner-only sourcing
/// purchase invoice link, and chronological movement audit log.
class ProductDetailScreen extends ConsumerStatefulWidget {
  const ProductDetailScreen({
    super.key,
    required this.productId,
  });

  final String productId;

  @override
  ConsumerState<ProductDetailScreen> createState() =>
      _ProductDetailScreenState();
}

class _ProductDetailScreenState extends ConsumerState<ProductDetailScreen> {
  String? _selectedVariantId;

  void _openAddBatch(String productId, {String? variantId}) {
    final params = <String, String>{
      'productId': productId,
      if (variantId != null) 'variantId': variantId,
    };
    context.push(
      Uri(path: '/inventory/intake', queryParameters: params).toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final asyncNodes = ref.watch(catalogNodesProvider);
    final node = ref.watch(productNodeByIdProvider(widget.productId));
    final canManage = ref.watch(canManageInventoryProvider);
    final canViewCost = ref.watch(canViewCostPriceProvider);

    return Scaffold(
      backgroundColor: c.surface,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Product Details', style: t.titleLarge),
            Text(
              'Stock & Batches',
              style: t.bodySmall?.copyWith(color: c.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          if (canManage && node != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.tonalIcon(
                onPressed: () => _openAddBatch(
                  node.product.id,
                  variantId: _resolveSelectedVariant(node)?.variant.id,
                ),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add Lot'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  backgroundColor: c.secondaryContainer,
                  foregroundColor: c.onSecondaryContainer,
                ),
              ),
            ),
        ],
      ),
      body: _buildBody(context, asyncNodes, node, canManage, canViewCost),
    );
  }

  VariantCatalogNode? _resolveSelectedVariant(ProductCatalogNode node) {
    if (node.variants.isEmpty) return null;
    if (_selectedVariantId != null) {
      for (final v in node.variants) {
        if (v.variant.id == _selectedVariantId) return v;
      }
    }
    return node.variants.first;
  }

  Widget _buildBody(
    BuildContext context,
    AsyncValue<List<ProductCatalogNode>> asyncNodes,
    ProductCatalogNode? node,
    bool canManage,
    bool canViewCost,
  ) {
    final c = context.pasalColors;
    final t = context.textTheme;

    if (asyncNodes.isLoading && node == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (node == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: PasalCard(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.inventory_2_outlined, size: 42, color: c.outline),
                const SizedBox(height: AppSpacing.sm),
                Text('Product not found', style: t.titleMedium),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'This product may have been archived or removed.',
                  textAlign: TextAlign.center,
                  style: t.bodySmall?.copyWith(color: c.onSurfaceVariant),
                ),
                const SizedBox(height: AppSpacing.md),
                FilledButton(
                  onPressed: () => context.pop(),
                  child: const Text('Back to Catalog'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final selectedVariant = _resolveSelectedVariant(node);
    final sortedBatches = List<BatchCatalogItem>.from(
      selectedVariant?.batches ?? const <BatchCatalogItem>[],
    )..sort((a, b) => a.expiryDateTime.compareTo(b.expiryDateTime));

    BatchCatalogItem? fefoBatch;
    for (final b in sortedBatches) {
      if (b.batch.stockQuantity > 0 &&
          b.expiryStatus != BatchExpiryStatus.expired) {
        fefoBatch = b;
        break;
      }
    }
    fefoBatch ??= sortedBatches.cast<BatchCatalogItem?>().firstWhere(
          (b) => b != null && b.batch.stockQuantity > 0,
          orElse: () => null,
        );

    final primaryBatch =
        fefoBatch ?? (sortedBatches.isNotEmpty ? sortedBatches.first : null);
    final movementsAsync = ref.watch(productMovementsProvider(node.product.id));
    final purchaseAsync = canViewCost
        ? ref.watch(productLatestPurchaseProvider(node.product.id))
        : const AsyncValue<PurchaseDetailBundle?>.data(null);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutterMobile,
        AppSpacing.sm,
        AppSpacing.gutterMobile,
        AppSpacing.xl,
      ),
      children: [
        // 1. Product & Variant Overview + Economics Card
        PasalCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                node.product.brand.toUpperCase(),
                style: t.labelSmall?.copyWith(
                  color: c.secondary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                node.product.name,
                style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(
                '${node.categoryKind.displayLabel} • ${node.variants.length} Variant(s)',
                style: t.bodySmall?.copyWith(color: c.outline),
              ),

              if (node.variants.length > 1) ...[
                const SizedBox(height: 12),
                SizedBox(
                  height: 36,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: node.variants.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 6),
                    itemBuilder: (context, index) {
                      final v = node.variants[index];
                      final isSelected =
                          v.variant.id == selectedVariant?.variant.id;
                      return ChoiceChip(
                        selected: isSelected,
                        onSelected: (_) =>
                            setState(() => _selectedVariantId = v.variant.id),
                        avatar: v.swatchColor != null
                            ? CircleAvatar(
                                backgroundColor: v.swatchColor,
                                radius: 7,
                              )
                            : null,
                        label: Text(v.variant.variantName),
                      );
                    },
                  ),
                ),
              ],

              if (selectedVariant != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: c.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(AppRadii.md),
                  ),
                  child: Row(
                    children: [
                      if (selectedVariant.swatchColor != null) ...[
                        Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            color: selectedVariant.swatchColor,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.black.withValues(alpha: 0.15),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              selectedVariant.variant.variantName,
                              style: t.labelLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (_variantSubtitle(selectedVariant).isNotEmpty)
                              Text(
                                _variantSubtitle(selectedVariant),
                                style: t.bodySmall?.copyWith(color: c.outline),
                              ),
                          ],
                        ),
                      ),
                      if (primaryBatch != null)
                        Text(
                          primaryBatch.batch.stickerBarcode,
                          style: t.labelSmall?.copyWith(
                            fontFamily: 'monospace',
                            color: c.outline,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _EconomicsGrid(
                  variant: selectedVariant,
                  primaryBatch: primaryBatch?.batch,
                  canViewCost: canViewCost,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),

        // 2. FEFO Banner
        if (fefoBatch != null && !node.product.isGeneric) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: c.secondaryContainer,
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      style: t.bodySmall?.copyWith(
                        color: c.onSecondaryContainer,
                      ),
                      children: [
                        const TextSpan(text: 'Selling Lot '),
                        TextSpan(
                          text: fefoBatch.batch.batchCode,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const TextSpan(text: ' first (nearest expiry)'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: c.onSecondaryContainer.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                  ),
                  child: Text(
                    'FEFO',
                    style: t.labelSmall?.copyWith(
                      color: c.onSecondaryContainer,
                      fontWeight: FontWeight.w700,
                      fontSize: 10,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],

        // 3. Batch Inventory Section
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'BATCH INVENTORY',
              style: t.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: c.onSurfaceVariant,
              ),
            ),
            Text(
              '${sortedBatches.length} Lot(s)',
              style: t.labelSmall?.copyWith(
                color: c.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (sortedBatches.isEmpty)
          PasalCard(
            padding: const EdgeInsets.all(14),
            child: Text(
              'No batches recorded for this variant yet.',
              style: t.bodySmall?.copyWith(color: c.outline),
            ),
          )
        else
          ...sortedBatches.map(
            (batchItem) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _BatchDetailCard(
                product: node.product,
                variant: selectedVariant!.variant,
                batchItem: batchItem,
                isFefoFirst: fefoBatch?.batch.id == batchItem.batch.id,
                canManage: canManage,
              ),
            ),
          ),

        // 4. Owner-Only Supplier & Last Invoice Card
        if (canViewCost) ...[
          const SizedBox(height: 6),
          _OwnerSourcingCard(purchaseAsync: purchaseAsync),
        ],

        // 5. Recent Stock Activity (Movement Audit Log)
        const SizedBox(height: 12),
        PasalCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'RECENT STOCK ACTIVITY',
                style: t.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: c.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              movementsAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(),
                ),
                error: (_, _) => Text(
                  'Unable to load stock activity.',
                  style: t.bodySmall?.copyWith(color: c.error),
                ),
                data: (movements) {
                  if (movements.isEmpty) {
                    return Text(
                      'No stock movements recorded yet.',
                      style: t.bodySmall?.copyWith(color: c.outline),
                    );
                  }
                  final recent = movements.take(8).toList(growable: false);
                  return Column(
                    children: [
                      for (var i = 0; i < recent.length; i++) ...[
                        if (i > 0)
                          Divider(
                            height: 14,
                            color: c.hairline.withValues(alpha: 0.5),
                          ),
                        _MovementAuditRow(movement: recent[i]),
                      ],
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _variantSubtitle(VariantCatalogNode v) {
    final parts = <String>[
      if (v.variant.sizeVolume != null && v.variant.sizeVolume!.isNotEmpty)
        v.variant.sizeVolume!,
      if (v.spfLabel != null) v.spfLabel!,
      if (v.skinTypeLabel != null && v.skinTypeLabel != 'All Skin')
        v.skinTypeLabel!,
    ];
    return parts.join(' • ');
  }
}

class _EconomicsGrid extends StatelessWidget {
  const _EconomicsGrid({
    required this.variant,
    required this.primaryBatch,
    required this.canViewCost,
  });

  final VariantCatalogNode variant;
  final BatchRow? primaryBatch;
  final bool canViewCost;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final sellingPaisa = primaryBatch?.sellingPrice ?? variant.minSellingPricePaisa;
    final costPaisa = canViewCost ? primaryBatch?.costPrice : null;

    String marginPctText = '—';
    String marginDiffText = 'Cost not set';
    bool isLoss = false;
    if (costPaisa != null && sellingPaisa > 0) {
      final diff = sellingPaisa - costPaisa;
      isLoss = diff < 0;
      final pct = ((diff / sellingPaisa) * 100).round();
      marginPctText = '${diff >= 0 ? '+' : ''}$pct%';
      marginDiffText = '${diff >= 0 ? '+' : '-'}${MoneyUtils.formatRs(diff.abs())} / pc';
    }

    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: c.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('SELLING', style: t.labelSmall?.copyWith(fontSize: 10)),
                const SizedBox(height: 2),
                PasalTabularText(
                  sellingPaisa > 0
                      ? MoneyUtils.formatRs(sellingPaisa)
                      : 'Pending',
                  style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (canViewCost && costPaisa != null) ...[
                  const SizedBox(height: 1),
                  PasalTabularText(
                    'Cost: ${MoneyUtils.formatRs(costPaisa)}',
                    style: t.bodySmall?.copyWith(
                      fontSize: 10,
                      color: c.outline,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (canViewCost) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              key: const ValueKey('product-detail-margin-card'),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isLoss
                    ? c.errorContainer.withValues(alpha: 0.6)
                    : c.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppRadii.md),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('MARGIN', style: t.labelSmall?.copyWith(fontSize: 10)),
                  const SizedBox(height: 2),
                  PasalTabularText(
                    marginPctText,
                    style: t.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: isLoss ? c.error : c.primary,
                    ),
                  ),
                  const SizedBox(height: 1),
                  PasalTabularText(
                    marginDiffText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodySmall?.copyWith(
                      fontSize: 10,
                      color: isLoss ? c.error : c.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: c.secondaryContainer,
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'IN STOCK',
                  style: t.labelSmall?.copyWith(
                    fontSize: 10,
                    color: c.onSecondaryContainer,
                  ),
                ),
                const SizedBox(height: 2),
                PasalTabularText(
                  '${variant.totalStock} pcs',
                  style: t.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: c.onSecondaryContainer,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  'Across ${variant.batches.length} lot(s)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodySmall?.copyWith(
                    fontSize: 10,
                    color: c.onSecondaryContainer,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _BatchDetailCard extends StatelessWidget {
  const _BatchDetailCard({
    required this.product,
    required this.variant,
    required this.batchItem,
    required this.isFefoFirst,
    required this.canManage,
  });

  final ProductRow product;
  final ProductVariantRow variant;
  final BatchCatalogItem batchItem;
  final bool isFefoFirst;
  final bool canManage;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final batch = batchItem.batch;

    String badgeText = 'Healthy';
    Color badgeBg = c.secondaryContainer;
    Color badgeFg = c.onSecondaryContainer;
    if (batchItem.expiryStatus == BatchExpiryStatus.expired) {
      badgeText = 'Expired';
      badgeBg = c.errorContainer;
      badgeFg = c.onErrorContainer;
    } else if (isFefoFirst) {
      badgeText = 'Sell 1st';
      badgeBg = c.primary;
      badgeFg = c.onPrimary;
    } else if (batchItem.expiryStatus == BatchExpiryStatus.expiringSoon) {
      badgeText = 'Expiring';
      badgeBg = c.warningContainer;
      badgeFg = c.onWarningContainer;
    }

    return PasalCard(
      padding: const EdgeInsets.all(14),
      borderColor: batchItem.expiryStatus == BatchExpiryStatus.expired
          ? c.error.withValues(alpha: 0.4)
          : c.hairline,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          batch.batchCode,
                          style: t.labelLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: badgeBg,
                            borderRadius: BorderRadius.circular(AppRadii.sm),
                          ),
                          child: Text(
                            badgeText.toUpperCase(),
                            style: t.labelSmall?.copyWith(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: badgeFg,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Exp: ${batchItem.displayExpiry} • ${batch.stickerBarcode}',
                      style: t.bodySmall?.copyWith(
                        color: batchItem.expiryStatus ==
                                BatchExpiryStatus.expired
                            ? c.error
                            : c.outline,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              PasalTabularText(
                '${batch.stockQuantity} pcs left',
                style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          if (canManage) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                alignment: WrapAlignment.end,
                children: [
                  FilledButton.tonal(
                    onPressed: () => showPrintLabelsSheet(
                      context,
                      product: product,
                      variant: variant,
                      batch: batch,
                    ),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    child: Text(
                      'Print Labels (${batch.stockQuantity > 0 ? batch.stockQuantity : 1})',
                    ),
                  ),
                  FilledButton(
                    onPressed: () => showStockAdjustmentSheet(
                      context,
                      product: product,
                      variant: variant,
                      batch: batch,
                    ),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    child: const Text('Count / Adjust'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _OwnerSourcingCard extends StatelessWidget {
  const _OwnerSourcingCard({required this.purchaseAsync});

  final AsyncValue<PurchaseDetailBundle?> purchaseAsync;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;

    return purchaseAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (bundle) {
        if (bundle == null) return const SizedBox.shrink();
        return PasalPressable(
          onTap: () => context.push('/history/purchase/${bundle.invoice.id}'),
          child: PasalCard(
            key: const ValueKey('product-detail-sourcing-card'),
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'SUPPLIER & LAST INVOICE',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: c.outline,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Open Bill →',
                      style: t.labelSmall?.copyWith(
                        color: c.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  bundle.supplier?.name ?? 'Registered Supplier',
                  style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  'Invoice #${bundle.invoice.invoiceNo} • '
                  'Total ${MoneyUtils.formatRs(bundle.invoice.totalAmount)}',
                  style: t.bodySmall?.copyWith(color: c.outline),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MovementAuditRow extends StatelessWidget {
  const _MovementAuditRow({required this.movement});

  final StockMovementRow movement;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final sign = movement.quantity > 0 ? '+' : '';
    final unit = movement.quantity.abs() == 1 ? 'pc' : 'pcs';

    final label = switch (movement.movementType) {
      'PURCHASE_INTAKE' => 'Stock Intake',
      'SALE' => 'Sold',
      'CUSTOMER_RETURN' => 'Customer Return',
      'COUNT_CORRECTION' => 'Count Adjustment',
      'DAMAGED_WRITEOFF' => 'Damaged Write-off',
      'EXPIRED_WRITEOFF' => 'Expired Write-off',
      'TESTER_CONVERSION' => 'Opened as Tester',
      _ => movement.movementType,
    };

    final dt = movement.createdAt.toLocal();
    final dateStr =
        '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    return Row(
      children: [
        Expanded(
          child: Text(
            '$sign${movement.quantity} $unit $label'
            '${movement.reason != null && movement.reason!.isNotEmpty ? ' (${movement.reason})' : ''}',
            style: t.bodySmall?.copyWith(
              color: movement.quantity < 0 ? c.onSurface : c.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          dateStr,
          style: t.bodySmall?.copyWith(color: c.outline, fontSize: 11),
        ),
      ],
    );
  }
}
