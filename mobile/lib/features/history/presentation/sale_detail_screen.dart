import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/money.dart';
import '../../../core/printer/esc_pos_receipt_builder.dart';
import '../../../core/printer/printer_providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../application/history_providers.dart';

/// Screen 14: Sale Receipt Details — Bill summary, customer Khata link,
/// frozen line items, Store PAN Bill breakdown, Share Bill & Reprint Slip.
class SaleDetailScreen extends ConsumerStatefulWidget {
  const SaleDetailScreen({super.key, required this.saleId});

  final String saleId;

  @override
  ConsumerState<SaleDetailScreen> createState() => _SaleDetailScreenState();
}

class _SaleDetailScreenState extends ConsumerState<SaleDetailScreen> {
  bool _reprinting = false;

  Future<void> _shareBill(SaleDetailBundle bundle) async {
    final o = bundle.order;
    final buf = StringBuffer()
      ..writeln('PasalX Store PAN Bill (No VAT)')
      ..writeln('Bill #${o.billNo}')
      ..writeln(
        'Date: ${DateFormat('yyyy-MM-dd hh:mm a').format(o.createdAt.toLocal())}',
      )
      ..writeln(
        'Customer: ${(o.customerName ?? '').isEmpty ? 'Walk-in Customer' : o.customerName}',
      )
      ..writeln('---');
    for (final item in bundle.items) {
      buf.writeln(
        '${item.productName} (${item.variantName}) x${item.quantity} = ${MoneyUtils.formatRs(item.totalPrice)}',
      );
    }
    buf
      ..writeln('---')
      ..writeln('Subtotal: ${MoneyUtils.formatRs(o.subtotal)}')
      ..writeln('Discount: ${MoneyUtils.formatRs(o.discountAmount)}')
      ..writeln('Total: ${MoneyUtils.formatRs(o.totalAmount)}');

    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (mounted) {
      ref.read(pasalAlertProvider).showSuccess(
            'Bill summary copied to share on WhatsApp/SMS',
          );
    }
  }

  Future<void> _reprintSlip(SaleDetailBundle bundle) async {
    if (_reprinting) return;
    setState(() => _reprinting = true);
    try {
      final o = bundle.order;
      final data = ReceiptPrintData(
        billNo: o.billNo,
        printedAt: o.createdAt.toLocal(),
        cashierName: o.cashierName,
        items: bundle.items
            .map(
              (i) => ReceiptLineItem(
                productName: i.productName,
                variantName: i.variantName,
                quantity: i.quantity,
                unitPricePaisa: i.sellingPrice,
                lineTotalPaisa: i.totalPrice,
              ),
            )
            .toList(growable: false),
        subtotalPaisa: o.subtotal,
        discountPaisa: o.discountAmount,
        totalPaisa: o.totalAmount,
        paymentMode: o.paymentMode,
        payments: bundle.payments
            .map(
              (p) => ReceiptPaymentLine(
                method: p.method,
                amountPaisa: p.amount,
                reference: p.transactionRef,
              ),
            )
            .toList(growable: false),
        customerName: o.customerName,
        customerPhone: o.customerPhone,
        khataBalanceAfterPaisa: bundle.customer?.currentBalanceDue,
      );
      await ref.read(xlabPrinterDriverProvider).printReceipt(data);
      if (mounted) {
        ref.read(pasalAlertProvider).showSuccess(
              'Reprinted receipt #${o.billNo}',
            );
      }
    } catch (e) {
      if (mounted) {
        ref.read(pasalAlertProvider).showError(
              'Could not reach printer — check IP in Printer Settings.',
            );
      }
    } finally {
      if (mounted) setState(() => _reprinting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final detailAsync = ref.watch(saleDetailProvider(widget.saleId));

    return Scaffold(
      backgroundColor: c.surface,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Sale Receipt'),
            Text(
              detailAsync.value == null
                  ? 'Bill Details'
                  : '#${detailAsync.value!.order.billNo}',
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
            child: Text('Unable to load receipt: $err', style: t.bodyMedium),
          ),
        ),
        data: (bundle) {
          if (bundle == null) {
            return Center(
              child: Text('Receipt not found.', style: t.bodyMedium),
            );
          }

          final o = bundle.order;
          final isKhata = o.paymentMode.toUpperCase().contains('KHATA');
          final statusLabel = _paymentStatusLabel(o.paymentMode);
          final customerName = (o.customerName ?? '').trim().isEmpty
              ? 'Walk-in Customer'
              : o.customerName!.trim();
          final initials = _initials(customerName);

          return ListView(
            padding: const EdgeInsets.all(AppSpacing.gutterMobile),
            children: [
              // Bill Hero Card
              PasalCard(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: PasalTabularText(
                            'Bill #${o.billNo}',
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
                            color: isKhata
                                ? c.errorContainer
                                : c.secondaryContainer,
                            borderRadius: BorderRadius.circular(AppRadii.pill),
                          ),
                          child: Text(
                            statusLabel,
                            style: t.labelSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: isKhata
                                  ? c.onErrorContainer
                                  : c.onSecondaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'TOTAL SETTLED',
                      style: t.labelSmall?.copyWith(
                        fontSize: 10,
                        color: c.outline,
                      ),
                    ),
                    PasalTabularText(
                      MoneyUtils.formatRs(o.totalAmount),
                      style: t.displayMedium?.copyWith(
                        fontSize: 28,
                        color: isKhata ? c.error : c.primary,
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
                                  'Date & Time',
                                  style: t.labelSmall?.copyWith(
                                    fontSize: 10,
                                    color: c.outline,
                                  ),
                                ),
                                Text(
                                  DateFormat('MMM d, hh:mm a')
                                      .format(o.createdAt.toLocal()),
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
                                  'Cashier',
                                  style: t.labelSmall?.copyWith(
                                    fontSize: 10,
                                    color: c.outline,
                                  ),
                                ),
                                Text(
                                  o.cashierName,
                                  style: t.labelLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
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

              // Customer Card
              PasalPressable(
                onTap: o.customerId == null
                    ? null
                    : () => context.push(AppRoutes.khata),
                borderRadius: BorderRadius.circular(AppRadii.md),
                child: PasalCard(
                  padding: const EdgeInsets.all(14),
                  borderRadius: AppRadii.md,
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: c.primary,
                        foregroundColor: c.onPrimary,
                        child: Text(
                          initials,
                          style: t.labelMedium?.copyWith(
                            color: c.onPrimary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              customerName,
                              style: t.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if ((o.customerPhone ?? '').trim().isNotEmpty)
                              Text(
                                o.customerPhone!,
                                style: t.bodySmall?.copyWith(color: c.outline),
                              ),
                          ],
                        ),
                      ),
                      if (o.customerId != null)
                        Text(
                          'Khata Profile →',
                          style: t.labelMedium?.copyWith(
                            color: c.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Purchased Items
              PasalCard(
                padding: const EdgeInsets.all(14),
                borderRadius: AppRadii.md,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'PURCHASED ITEMS (${bundle.items.length})',
                      style: t.labelSmall?.copyWith(
                        color: c.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ...bundle.items.map(
                      (item) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: c.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(AppRadii.sm),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.productName,
                                      style: t.labelLarge?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    PasalTabularText(
                                      '${item.variantName} • ${item.quantity} × ${MoneyUtils.formatRs(item.sellingPrice)}',
                                      style: t.bodySmall?.copyWith(
                                        fontSize: 11,
                                        color: c.outline,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              PasalTabularText(
                                MoneyUtils.formatRs(item.totalPrice),
                                style: t.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Settlement Breakdown (Store PAN Bill - No VAT)
              PasalCard(
                padding: const EdgeInsets.all(14),
                borderRadius: AppRadii.md,
                child: Column(
                  children: [
                    _SettlementRow(
                      label: 'Subtotal',
                      value: MoneyUtils.formatRs(o.subtotal),
                      muted: true,
                    ),
                    const SizedBox(height: 6),
                    _SettlementRow(
                      label: 'Discount',
                      value: MoneyUtils.formatRs(o.discountAmount),
                      muted: true,
                    ),
                    const Divider(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Grand Total',
                                style: t.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                'Store PAN Bill • No VAT',
                                style: t.bodySmall?.copyWith(
                                  fontSize: 10.5,
                                  color: c.outline,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        PasalTabularText(
                          MoneyUtils.formatRs(o.totalAmount),
                          style: t.titleMedium?.copyWith(
                            color: c.primary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          'Backup Status',
                          style: t.bodySmall?.copyWith(color: c.outline),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            o.syncStatus.toUpperCase() == 'SYNCED'
                                ? 'Synced to Cloud'
                                : 'Saved Locally',
                            textAlign: TextAlign.end,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.labelSmall?.copyWith(
                              color: c.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Action Buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _shareBill(bundle),
                      icon: const Icon(Icons.share_rounded, size: 18),
                      label: const Text('Share Bill'),
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
                      onPressed:
                          _reprinting ? null : () => _reprintSlip(bundle),
                      icon: _reprinting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.print_rounded, size: 18),
                      label: Text(_reprinting ? 'Printing...' : 'Reprint Slip'),
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

  static String _paymentStatusLabel(String mode) {
    switch (mode.toUpperCase()) {
      case 'CASH':
        return 'Paid • Cash';
      case 'FONEPAY_QR':
      case 'QR':
        return 'Paid • Fonepay QR';
      case 'KHATA_CREDIT':
      case 'KHATA':
        return 'Khata Due';
      case 'SPLIT':
        return 'Paid • Split';
      default:
        return mode;
    }
  }

  static String _initials(String name) {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts[1][0]}'.toUpperCase();
    }
    if (name.length >= 2) return name.substring(0, 2).toUpperCase();
    return 'WC';
  }
}

class _SettlementRow extends StatelessWidget {
  const _SettlementRow({
    required this.label,
    required this.value,
    this.muted = false,
  });

  final String label;
  final String value;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: t.bodySmall?.copyWith(color: muted ? c.outline : c.onSurface),
        ),
        PasalTabularText(
          value,
          style: t.bodySmall?.copyWith(
            color: muted ? c.outline : c.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
