import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/money.dart';
import '../../../core/printer/printer_providers.dart';
import '../../../core/printer/tspl_label_builder.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../../history/application/history_providers.dart';
import '../../inventory/domain/catalog_models.dart';
import 'supplier_sheets.dart';

/// Screen 15: Purchase Invoice Details — Invoice summary, vendor card,
/// inward lots with Owner-only wholesale costs/margins, Reprint Labels & Pay Supplier.
class PurchaseDetailScreen extends ConsumerStatefulWidget {
  const PurchaseDetailScreen({super.key, required this.purchaseId});

  final String purchaseId;

  @override
  ConsumerState<PurchaseDetailScreen> createState() =>
      _PurchaseDetailScreenState();
}

class _PurchaseDetailScreenState extends ConsumerState<PurchaseDetailScreen> {
  bool _printingLabels = false;

  Future<void> _reprintLabels(PurchaseDetailBundle bundle) async {
    if (_printingLabels) return;
    final batchById = {for (final b in bundle.batches) b.id: b};
    final labels = <BatchLabelData>[];
    for (final item in bundle.items) {
      final batch = item.batchId == null ? null : batchById[item.batchId!];
      final barcode = batch?.stickerBarcode ?? item.batchCode ?? item.id;
      final expiry = InventoryDateUtils.parseIsoDate(item.expiryDate) ??
          DateTime.now().add(const Duration(days: 365));
      final count = item.quantityReceived.clamp(1, 200);
      for (var i = 0; i < count; i++) {
        labels.add(
          BatchLabelData(
            productName: item.productName,
            variantName: item.variantName,
            stickerBarcode: barcode,
            sellingPricePaisa: item.unitSellingPrice,
            expiryDate: expiry,
            batchCode: item.batchCode ?? batch?.batchCode,
          ),
        );
      }
    }

    if (labels.isEmpty) {
      ref.read(pasalAlertProvider).showWarning(
            'No batch stickers available for this invoice.',
          );
      return;
    }

    setState(() => _printingLabels = true);
    try {
      await ref.read(xlabPrinterDriverProvider).printLabels(labels);
      if (mounted) {
        ref.read(pasalAlertProvider).showSuccess(
              '${labels.length} batch labels sent to printer',
            );
      }
    } catch (_) {
      if (mounted) {
        ref.read(pasalAlertProvider).showError(
              'Could not reach printer — check IP in Printer Settings.',
            );
      }
    } finally {
      if (mounted) setState(() => _printingLabels = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final role = (ref.watch(ramKeyHolderProvider).session?.role ?? 'STAFF')
        .toUpperCase();
    final isOwner = role == 'OWNER';
    final isAllowed = role == 'OWNER' || role == 'MANAGER';

    if (!isAllowed) {
      return Scaffold(
        backgroundColor: c.surface,
        appBar: AppBar(title: const Text('Purchase Bill')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: PasalCard(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline_rounded, size: 32, color: c.error),
                  const SizedBox(height: 10),
                  Text('Access Restricted', style: t.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Only Owner or Manager accounts can view supplier bills.',
                    style: t.bodySmall?.copyWith(color: c.outline),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final detailAsync = ref.watch(purchaseDetailProvider(widget.purchaseId));

    return Scaffold(
      backgroundColor: c.surface,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Purchase Bill'),
            Text(
              detailAsync.value == null
                  ? 'Supplier Invoice'
                  : '#${detailAsync.value!.invoice.invoiceNo}',
              style: t.labelSmall?.copyWith(color: c.onSurfaceVariant),
            ),
          ],
        ),
      ),
      body: detailAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Text('Unable to load invoice: $err', style: t.bodyMedium),
          ),
        ),
        data: (bundle) {
          if (bundle == null) {
            return Center(
              child: Text('Purchase invoice not found.', style: t.bodyMedium),
            );
          }

          final inv = bundle.invoice;
          final supplier = bundle.supplier;
          final isPaid = inv.dueAmount <= 0;
          final isPartial = inv.paidAmount > 0 && inv.dueAmount > 0;
          final statusText = isPaid
              ? 'Paid'
              : isPartial
                  ? 'Partial (${MoneyUtils.formatRs(inv.dueAmount)} Due)'
                  : 'Unpaid';

          final totalQty = bundle.items.fold<int>(
            0,
            (sum, i) => sum + i.quantityReceived,
          );

          return ListView(
            padding: const EdgeInsets.all(AppSpacing.gutterMobile),
            children: [
              // Invoice Hero Card
              PasalCard(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: PasalTabularText(
                            'Invoice #${inv.invoiceNo}',
                            style: t.labelLarge?.copyWith(
                              color: c.primary,
                              fontWeight: FontWeight.w800,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: (!isPaid && !isPartial)
                                ? c.errorContainer
                                : c.secondaryContainer,
                            borderRadius: BorderRadius.circular(AppRadii.pill),
                          ),
                          child: Text(
                            statusText,
                            style: t.labelSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: (!isPaid && !isPartial)
                                  ? c.onErrorContainer
                                  : c.onSecondaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'TOTAL INVOICE AMOUNT',
                      style: t.labelSmall?.copyWith(
                        fontSize: 10,
                        color: c.outline,
                      ),
                    ),
                    PasalTabularText(
                      MoneyUtils.formatRs(inv.totalAmount),
                      style: t.displayMedium?.copyWith(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: c.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(AppRadii.md),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Issued',
                                  style: t.labelSmall?.copyWith(
                                    fontSize: 10,
                                    color: c.outline,
                                  ),
                                ),
                                PasalTabularText(
                                  inv.invoiceDate,
                                  style: t.labelLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Balance Due',
                                  style: t.labelSmall?.copyWith(
                                    fontSize: 10,
                                    color: c.outline,
                                  ),
                                ),
                                PasalTabularText(
                                  MoneyUtils.formatRs(inv.dueAmount),
                                  style: t.labelLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: inv.dueAmount > 0
                                        ? c.error
                                        : c.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Vendor Card
              PasalCard(
                padding: const EdgeInsets.all(14),
                borderRadius: AppRadii.md,
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'SUPPLIER',
                            style: t.labelSmall?.copyWith(
                              fontSize: 10,
                              color: c.outline,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            supplier?.name ?? 'Unknown Supplier',
                            style: t.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          PasalTabularText(
                            [
                              if ((supplier?.panVat ?? '').trim().isNotEmpty)
                                'PAN: ${supplier!.panVat}',
                              if ((supplier?.phone ?? '').trim().isNotEmpty)
                                supplier!.phone!,
                            ].join(' • '),
                            style: t.bodySmall?.copyWith(color: c.outline),
                          ),
                        ],
                      ),
                    ),
                    if ((supplier?.phone ?? '').trim().isNotEmpty)
                      PasalPressable(
                        onTap: () async {
                          final phone = supplier!.phone!.trim();
                          await Clipboard.setData(ClipboardData(text: phone));
                          if (context.mounted) {
                            ref.read(pasalAlertProvider).showSuccess(
                                  'Supplier phone copied: $phone',
                                );
                          }
                        },
                        borderRadius: BorderRadius.circular(AppRadii.pill),
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: c.surfaceContainer,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.call_rounded,
                            size: 18,
                            color: c.primary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // Inward Items
              Text(
                'ITEMS RECEIVED (${bundle.items.length} PRODUCTS • $totalQty PCS)',
                style: t.labelSmall?.copyWith(
                  color: c.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 8),
              ...bundle.items.map((item) {
                final costPaisa = isOwner ? item.unitCostPrice : null;
                final totalCostPaisa = isOwner ? item.totalCost : null;
                final marginPct = (costPaisa != null &&
                        item.unitSellingPrice > 0 &&
                        costPaisa <= item.unitSellingPrice)
                    ? (((item.unitSellingPrice - costPaisa) * 100) /
                            item.unitSellingPrice)
                        .round()
                    : null;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: PasalCard(
                    padding: const EdgeInsets.all(12),
                    borderRadius: AppRadii.md,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                '${item.productName} ${item.variantName} (${item.quantityReceived} pcs)',
                                style: t.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (totalCostPaisa != null) ...[
                              const SizedBox(width: 8),
                              PasalTabularText(
                                MoneyUtils.formatRs(totalCostPaisa),
                                style: t.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: PasalTabularText(
                                costPaisa != null
                                    ? 'Cost: ${MoneyUtils.formatRs(costPaisa)} | Retail: ${MoneyUtils.formatRs(item.unitSellingPrice)}'
                                    : 'Retail: ${MoneyUtils.formatRs(item.unitSellingPrice)}',
                                style: t.bodySmall?.copyWith(
                                  fontSize: 11,
                                  color: c.outline,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (marginPct != null) ...[
                              const SizedBox(width: 8),
                              PasalTabularText(
                                '+$marginPct% Margin',
                                style: t.labelSmall?.copyWith(
                                  color: c.primary,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }),
              const SizedBox(height: 12),

              // Action Buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _printingLabels
                          ? null
                          : () => _reprintLabels(bundle),
                      icon: _printingLabels
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.print_rounded, size: 18),
                      label: Text(
                        _printingLabels ? 'Printing...' : 'Reprint Labels',
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadii.md),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: (supplier == null || inv.dueAmount <= 0)
                          ? null
                          : () async {
                              final paid = await showPaySupplierSheet(
                                context,
                                ref,
                                supplier: supplier,
                                openInvoices: bundle.openSupplierInvoices,
                                preselectedInvoice: inv,
                              );
                              if (paid == true && context.mounted) {
                                ref.read(pasalAlertProvider).showSuccess(
                                      'Supplier payment recorded',
                                    );
                              }
                            },
                      icon: const Icon(Icons.payments_rounded, size: 18),
                      label: Text(
                        inv.dueAmount <= 0 ? 'Fully Paid' : 'Pay Supplier',
                      ),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadii.md),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
