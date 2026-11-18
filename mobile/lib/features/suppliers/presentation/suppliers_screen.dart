import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/money.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../application/supplier_providers.dart';
import 'supplier_sheets.dart';

/// Role-gated (`OWNER` / `MANAGER`) Supplier Ledger & Payable Bills screen.
class SuppliersScreen extends ConsumerWidget {
  const SuppliersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final session = ref.watch(ramKeyHolderProvider).session;
    final canManage =
        session != null && (session.role == 'OWNER' || session.role == 'MANAGER');

    if (!canManage) {
      return Scaffold(
        appBar: AppBar(title: const Text('Suppliers & Bills')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.gutterMobile),
            child: PasalCard(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline_rounded, size: 40, color: c.error),
                  const SizedBox(height: AppSpacing.sm),
                  Text('Manager / Owner Access Required', style: t.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Wholesale supplier ledgers and bill settlements are hidden for Staff accounts.',
                    style: t.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final suppliersAsync = ref.watch(suppliersListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Suppliers & Bills'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: FilledButton.tonalIcon(
              onPressed: () => showSupplierFormSheet(context, ref),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Supplier'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutterMobile,
              AppSpacing.sm,
              AppSpacing.gutterMobile,
              AppSpacing.sm,
            ),
            child: TextField(
              onChanged: (v) =>
                  ref.read(supplierSearchQueryProvider.notifier).state = v,
              decoration: const InputDecoration(
                hintText: 'Search supplier name, phone, or PAN...',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          Expanded(
            child: suppliersAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => Center(
                child: Text('Failed to load suppliers: $err'),
              ),
              data: (suppliers) {
                final totalDue = suppliers.fold<int>(
                  0,
                  (sum, s) => sum + s.balanceDue,
                );
                return ListView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.gutterMobile,
                    0,
                    AppSpacing.gutterMobile,
                    AppSpacing.xl,
                  ),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: c.primary,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'TOTAL PAYABLE TO SUPPLIERS',
                                  style: t.labelSmall?.copyWith(
                                    color: c.onPrimaryContainer,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: PasalTabularText(
                                    MoneyUtils.formatRs(totalDue),
                                    style: t.displayMedium?.copyWith(
                                      color: c.onPrimary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          PasalStatusBadge(
                            label: '${suppliers.length} Suppliers',
                            backgroundColor: c.primaryContainer,
                            foregroundColor: c.onPrimary,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (suppliers.isEmpty)
                      PasalCard(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.lg,
                          ),
                          child: Column(
                            children: [
                              Icon(
                                Icons.local_shipping_outlined,
                                size: 36,
                                color: c.onSurfaceVariant,
                              ),
                              const SizedBox(height: AppSpacing.xs),
                              Text('No suppliers found', style: t.titleMedium),
                              const SizedBox(height: 4),
                              Text(
                                'Tap "+ Supplier" to add your cosmetic distributors.',
                                style: t.bodySmall,
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      ...suppliers.map((s) {
                        final hasDue = s.balanceDue > 0;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => showSupplierDetailSheet(
                              context,
                              ref,
                              supplierId: s.id,
                            ),
                            child: PasalCard(
                              child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            s.name,
                                            style: t.titleMedium,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          if (s.panVat != null ||
                                              s.phone != null) ...[
                                            const SizedBox(height: 2),
                                            Text(
                                              [
                                                if (s.panVat != null)
                                                  'PAN ${s.panVat}',
                                                if (s.phone != null) s.phone!,
                                              ].join(' • '),
                                              style: t.bodySmall,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: AppSpacing.sm),
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        Text('DUE', style: t.labelSmall),
                                        PasalTabularText(
                                          MoneyUtils.formatRs(s.balanceDue),
                                          style: t.titleMedium?.copyWith(
                                            color:
                                                hasDue ? c.error : c.primary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                const SizedBox(height: AppSpacing.sm),
                                Row(
                                  children: [
                                    Expanded(
                                      child: PasalTabularText(
                                        'Bought ${MoneyUtils.formatRs(s.totalPurchased)} • Paid ${MoneyUtils.formatRs(s.totalPaid)}',
                                        style: t.bodySmall,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: AppSpacing.xs),
                                    OutlinedButton(
                                      onPressed: () async {
                                        final repo = ref
                                            .read(supplierRepositoryProvider);
                                        final detail = await repo
                                            ?.loadSupplierDetail(s.id);
                                        if (!context.mounted) return;
                                        if (detail != null &&
                                            detail.invoices.isNotEmpty) {
                                          await context.push(
                                            AppRoutes.purchaseDetail(
                                              detail.invoices.first.id,
                                            ),
                                          );
                                        } else {
                                          await showSupplierDetailSheet(
                                            context,
                                            ref,
                                            supplierId: s.id,
                                          );
                                        }
                                      },
                                      child: const Text('All Bills'),
                                    ),
                                    if (hasDue) ...[
                                      const SizedBox(width: AppSpacing.xs),
                                      FilledButton.tonal(
                                        onPressed: () async {
                                          final repo = ref
                                              .read(supplierRepositoryProvider);
                                          final detail = await repo
                                              ?.loadSupplierDetail(s.id);
                                          if (!context.mounted) return;
                                          await showPaySupplierSheet(
                                            context,
                                            ref,
                                            supplier: s,
                                            openInvoices: detail?.invoices ??
                                                const [],
                                          );
                                        },
                                        child: const Text('Pay Supplier'),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                            ),
                          ),
                        );
                      }),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

