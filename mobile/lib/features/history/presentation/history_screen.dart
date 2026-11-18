import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/money.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../../register/application/register_providers.dart';
import '../../register/presentation/petty_expense_sheet.dart';
import '../application/history_providers.dart';

enum _HistoryTab { sales, purchases, expenses }

/// Screen 4: Business History — Segmented Sales, Purchases (Owner/Manager only),
/// and Expenses with live search, Today/All toggle, and drilldowns.
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  _HistoryTab _activeTab = _HistoryTab.sales;
  bool _todayOnly = true;
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final role = (ref.watch(ramKeyHolderProvider).session?.role ?? 'STAFF')
        .toUpperCase();
    final canViewPurchases = role == 'OWNER' || role == 'MANAGER';
    final effectiveTab =
        (!canViewPurchases && _activeTab == _HistoryTab.purchases)
            ? _HistoryTab.sales
            : _activeTab;

    final salesAsync = ref.watch(historySalesProvider(_todayOnly));
    final purchasesAsync = canViewPurchases
        ? ref.watch(historyPurchasesProvider)
        : const AsyncValue<List<PurchaseInvoiceBundle>>.data(
            <PurchaseInvoiceBundle>[],
          );
    final expensesAsync = ref.watch(historyExpensesProvider(_todayOnly));
    final activeShift = ref.watch(activeRegisterShiftProvider).value;

    final sales = salesAsync.value ?? const <SaleOrderBundle>[];
    final purchases =
        purchasesAsync.value ?? const <PurchaseInvoiceBundle>[];
    final expenses = expensesAsync.value ?? const <ExpenseRow>[];

    final salesTotalPaisa =
        sales.fold<int>(0, (sum, b) => sum + b.order.totalAmount);
    final purchasesTotalPaisa =
        purchases.fold<int>(0, (sum, b) => sum + b.invoice.totalAmount);
    final expensesTotalPaisa =
        expenses.fold<int>(0, (sum, e) => sum + e.amount);

    final q = _query.trim().toLowerCase();

    final filteredSales = q.isEmpty
        ? sales
        : sales.where((b) {
            final o = b.order;
            if (o.billNo.toLowerCase().contains(q)) return true;
            if ((o.customerName ?? '').toLowerCase().contains(q)) return true;
            if ((o.customerPhone ?? '').toLowerCase().contains(q)) return true;
            return b.items.any(
              (i) =>
                  i.productName.toLowerCase().contains(q) ||
                  i.variantName.toLowerCase().contains(q),
            );
          }).toList(growable: false);

    final filteredPurchases = q.isEmpty
        ? purchases
        : purchases.where((b) {
            if (b.invoice.invoiceNo.toLowerCase().contains(q)) return true;
            if ((b.supplier?.name ?? '').toLowerCase().contains(q)) return true;
            if ((b.invoice.notes ?? '').toLowerCase().contains(q)) return true;
            return false;
          }).toList(growable: false);

    final filteredExpenses = q.isEmpty
        ? expenses
        : expenses.where((e) {
            return e.title.toLowerCase().contains(q) ||
                e.category.toLowerCase().contains(q) ||
                (e.paidTo ?? '').toLowerCase().contains(q);
          }).toList(growable: false);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutterMobile,
        AppSpacing.md,
        AppSpacing.gutterMobile,
        AppSpacing.lg,
      ),
      children: [
        // 3-Way Segmented Tabs
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: c.surfaceContainer,
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
          child: Row(
            children: [
              Expanded(
                child: _SegmentButton(
                  label: 'Sales (${sales.length})',
                  active: effectiveTab == _HistoryTab.sales,
                  onTap: () => setState(() => _activeTab = _HistoryTab.sales),
                ),
              ),
              if (canViewPurchases)
                Expanded(
                  child: _SegmentButton(
                    label: 'Purchases (${purchases.length})',
                    active: effectiveTab == _HistoryTab.purchases,
                    onTap: () =>
                        setState(() => _activeTab = _HistoryTab.purchases),
                  ),
                ),
              Expanded(
                child: _SegmentButton(
                  label: 'Expenses (${expenses.length})',
                  active: effectiveTab == _HistoryTab.expenses,
                  onTap: () =>
                      setState(() => _activeTab = _HistoryTab.expenses),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Search & Date Filter
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                style: t.bodyMedium?.copyWith(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Search bill #, customer, or note...',
                  hintStyle: t.bodySmall?.copyWith(color: c.outline),
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: c.outline,
                  ),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded, size: 16),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  filled: true,
                  fillColor: c.surfaceContainerLowest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadii.md),
                    borderSide: BorderSide(color: c.hairline),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadii.md),
                    borderSide: BorderSide(color: c.hairline),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            PasalPressable(
              onTap: () => setState(() => _todayOnly = !_todayOnly),
              borderRadius: BorderRadius.circular(AppRadii.md),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: _todayOnly
                      ? c.surfaceContainerLowest
                      : c.secondaryContainer,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  border: Border.all(color: c.hairline),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.calendar_today_rounded,
                      size: 14,
                      color: c.primary,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _todayOnly ? 'Today' : 'All Time',
                      style: t.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: c.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // KPI Strip
        Row(
          children: [
            Expanded(
              child: _HistoryKpiTile(
                label: _todayOnly ? 'Sales Today' : 'Total Sales',
                value: MoneyUtils.formatRs(salesTotalPaisa),
                valueColor: c.primary,
              ),
            ),
            if (canViewPurchases) ...[
              const SizedBox(width: 8),
              Expanded(
                child: _HistoryKpiTile(
                  label: 'Purchases',
                  value: MoneyUtils.formatRs(purchasesTotalPaisa),
                  valueColor: c.onSurface,
                ),
              ),
            ],
            const SizedBox(width: 8),
            Expanded(
              child: _HistoryKpiTile(
                label: 'Expenses',
                value: MoneyUtils.formatRs(expensesTotalPaisa),
                valueColor: c.error,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Tab Body
        if (effectiveTab == _HistoryTab.sales) ...[
          if (filteredSales.isEmpty)
            _EmptyHistoryCard(
              icon: Icons.receipt_long_outlined,
              message: _todayOnly
                  ? 'No bills recorded today yet.'
                  : 'No matching sales bills found.',
            )
          else
            ...filteredSales.map(
              (bundle) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _SaleHistoryRow(
                  bundle: bundle,
                  showDate: !_todayOnly,
                  onTap: () => context.push(
                    AppRoutes.saleDetail(bundle.order.id),
                  ),
                ),
              ),
            ),
        ] else if (effectiveTab == _HistoryTab.purchases) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  'SUPPLIER INVOICES',
                  style: t.labelSmall?.copyWith(
                    color: c.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => context.push(AppRoutes.inventoryIntake),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  '+ Inward Stock',
                  style: t.labelMedium?.copyWith(
                    color: c.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (filteredPurchases.isEmpty)
            const _EmptyHistoryCard(
              icon: Icons.inventory_2_outlined,
              message: 'No purchase invoices recorded yet.',
            )
          else
            ...filteredPurchases.map(
              (bundle) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _PurchaseHistoryRow(
                  bundle: bundle,
                  onTap: () => context.push(
                    AppRoutes.purchaseDetail(bundle.invoice.id),
                  ),
                ),
              ),
            ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  'DAILY PETTY CASH & EXPENSES',
                  style: t.labelSmall?.copyWith(
                    color: c.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () async {
                  final saved = await showPettyExpenseSheet(
                    context,
                    ref,
                    shiftId: activeShift?.id,
                  );
                  if (saved == true && context.mounted) {
                    ref.read(pasalAlertProvider).showSuccess(
                          'Expense added to register',
                        );
                  }
                },
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  '+ Add Expense',
                  style: t.labelMedium?.copyWith(
                    color: c.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (filteredExpenses.isEmpty)
            const _EmptyHistoryCard(
              icon: Icons.payments_outlined,
              message: 'No petty expenses logged for this period.',
            )
          else
            ...filteredExpenses.map(
              (expense) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ExpenseHistoryRow(
                  expense: expense,
                  showDate: !_todayOnly,
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _SegmentButton extends StatelessWidget {
  const _SegmentButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: AppMotion.popover,
        curve: AppMotion.easeOut,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: active ? c.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadii.sm),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: t.labelMedium?.copyWith(
            fontWeight: active ? FontWeight.w700 : FontWeight.w600,
            color: active ? c.onPrimary : c.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

class _HistoryKpiTile extends StatelessWidget {
  const _HistoryKpiTile({
    required this.label,
    required this.value,
    required this.valueColor,
  });

  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return PasalCard(
      padding: const EdgeInsets.all(10),
      borderRadius: AppRadii.md,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: t.labelSmall?.copyWith(fontSize: 10, color: c.outline),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          PasalTabularText(
            value,
            style: t.titleSmall?.copyWith(
              color: valueColor,
              fontWeight: FontWeight.w800,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _SaleHistoryRow extends StatelessWidget {
  const _SaleHistoryRow({
    required this.bundle,
    required this.showDate,
    required this.onTap,
  });

  final SaleOrderBundle bundle;
  final bool showDate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final o = bundle.order;
    final localTime = o.createdAt.toLocal();
    final timeStr = showDate
        ? DateFormat('MMM d, hh:mm a').format(localTime)
        : DateFormat('hh:mm a').format(localTime);

    final isKhata = o.paymentMode.toUpperCase().contains('KHATA');
    final badgeLabel = _paymentBadgeLabel(o.paymentMode);
    final itemPreview = bundle.items.isEmpty
        ? 'No line items'
        : bundle.items.map((i) => i.productName).take(2).join(', ');
    final totalQty = bundle.totalItemQuantity;

    return PasalPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: PasalCard(
        padding: const EdgeInsets.all(14),
        borderRadius: AppRadii.md,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: PasalTabularText(
                              '#${o.billNo}',
                              style: t.labelMedium?.copyWith(
                                color: c.primary,
                                fontWeight: FontWeight.w800,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            timeStr,
                            style: t.bodySmall?.copyWith(
                              fontSize: 11,
                              color: c.outline,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        (o.customerName ?? '').trim().isEmpty
                            ? 'Walk-in Customer'
                            : o.customerName!,
                        style: t.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (isKhata)
                        Text(
                          'Added to Khata Credit',
                          style: t.bodySmall?.copyWith(
                            fontSize: 11,
                            color: c.error,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      else if ((o.customerPhone ?? '').trim().isNotEmpty)
                        Text(
                          o.customerPhone!,
                          style: t.bodySmall?.copyWith(
                            fontSize: 11,
                            color: c.outline,
                          ),
                        )
                      else
                        Text(
                          'Cashier: ${o.cashierName}',
                          style: t.bodySmall?.copyWith(
                            fontSize: 11,
                            color: c.outline,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    PasalTabularText(
                      MoneyUtils.formatRs(o.totalAmount),
                      style: t.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: isKhata ? c.error : c.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color:
                            isKhata ? c.errorContainer : c.secondaryContainer,
                        borderRadius: BorderRadius.circular(AppRadii.pill),
                      ),
                      child: Text(
                        badgeLabel,
                        style: t.labelSmall?.copyWith(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: isKhata
                              ? c.onErrorContainer
                              : c.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: c.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppRadii.sm),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      itemPreview,
                      style: t.bodySmall?.copyWith(
                        fontSize: 11,
                        color: c.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  PasalTabularText(
                    '$totalQty ${totalQty == 1 ? 'item' : 'items'} →',
                    style: t.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: c.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _paymentBadgeLabel(String mode) {
    switch (mode.toUpperCase()) {
      case 'CASH':
        return 'Cash Paid';
      case 'FONEPAY_QR':
      case 'QR':
        return 'Fonepay QR';
      case 'KHATA_CREDIT':
      case 'KHATA':
        return 'Khata Due';
      case 'SPLIT':
        return 'Split Pay';
      default:
        return mode;
    }
  }
}

class _PurchaseHistoryRow extends StatelessWidget {
  const _PurchaseHistoryRow({
    required this.bundle,
    required this.onTap,
  });

  final PurchaseInvoiceBundle bundle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final inv = bundle.invoice;
    final isPaid = inv.dueAmount <= 0;
    final isPartial = inv.paidAmount > 0 && inv.dueAmount > 0;
    final statusText = isPaid
        ? 'Paid'
        : isPartial
            ? '${MoneyUtils.formatRs(inv.dueAmount)} Due'
            : 'Unpaid';

    return PasalPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: PasalCard(
        padding: const EdgeInsets.all(14),
        borderRadius: AppRadii.md,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      PasalTabularText(
                        '${inv.invoiceNo} • ${inv.invoiceDate}',
                        style: t.labelMedium?.copyWith(
                          color: c.primary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        bundle.supplier?.name ?? 'Supplier',
                        style: t.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (inv.paidAmount > 0)
                        PasalTabularText(
                          '${MoneyUtils.formatRs(inv.paidAmount)} paid',
                          style: t.bodySmall?.copyWith(
                            fontSize: 11,
                            color: c.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      else if ((inv.notes ?? '').trim().isNotEmpty)
                        Text(
                          inv.notes!,
                          style: t.bodySmall?.copyWith(
                            fontSize: 11,
                            color: c.outline,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    PasalTabularText(
                      MoneyUtils.formatRs(inv.totalAmount),
                      style: t.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
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
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: (!isPaid && !isPartial)
                              ? c.onErrorContainer
                              : c.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: c.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppRadii.sm),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: PasalTabularText(
                      '${bundle.totalQuantity} pcs across ${bundle.productCount} ${bundle.productCount == 1 ? 'product' : 'products'}',
                      style: t.bodySmall?.copyWith(
                        fontSize: 11,
                        color: c.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'View Bill →',
                    style: t.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: c.primary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpenseHistoryRow extends StatelessWidget {
  const _ExpenseHistoryRow({required this.expense, required this.showDate});

  final ExpenseRow expense;
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final localTime = expense.createdAt.toLocal();
    final timeStr = showDate
        ? DateFormat('MMM d, hh:mm a').format(localTime)
        : DateFormat('hh:mm a').format(localTime);
    final methodLabel = expense.paymentMethod.toUpperCase() == 'CASH'
        ? 'Cash from Drawer'
        : expense.paymentMethod;

    return PasalCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      borderRadius: AppRadii.md,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  expense.title,
                  style: t.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '$timeStr • $methodLabel',
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
            '- ${MoneyUtils.formatRs(expense.amount)}',
            style: t.titleSmall?.copyWith(
              color: c.error,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyHistoryCard extends StatelessWidget {
  const _EmptyHistoryCard({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return PasalCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      color: c.surfaceContainerLow,
      child: Column(
        children: [
          Icon(icon, size: 28, color: c.outline),
          const SizedBox(height: 8),
          Text(
            message,
            style: t.bodySmall?.copyWith(color: c.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
