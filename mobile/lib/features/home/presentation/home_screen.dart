import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/database/money.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../../register/presentation/petty_expense_sheet.dart';
import '../application/home_providers.dart';
import '../data/home_repository.dart';

/// Screen 3: Home Dashboard — Daily Sales Snapshot, Quick Actions, Top Selling,
/// and Cash in Drawer strip.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _syncing = false;

  Future<void> _triggerSync() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      await ref.read(syncOutboxWorkerProvider).syncNow();
      if (!mounted) return;
      final syncState = ref.read(syncOutboxWorkerProvider).status;
      if (syncState.lastError != null && syncState.lastError!.isNotEmpty) {
        ref.read(pasalAlertProvider).showWarning(
              'Offline or server unreachable — saved locally.',
            );
      } else {
        ref.read(pasalAlertProvider).showSuccess(
              'All sales and stock synced',
            );
      }
    } catch (_) {
      if (mounted) {
        ref.read(pasalAlertProvider).showWarning(
              'Could not sync right now — data is safe locally.',
            );
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final session = ref.watch(ramKeyHolderProvider).session;
    final role = (session?.role ?? 'STAFF').toUpperCase();
    final isOwnerOrManager = role == 'OWNER' || role == 'MANAGER';
    final displayName = _formatDisplayName(session?.username);
    final todayLabel =
        'TODAY • ${DateFormat('EEE, MMM d').format(DateTime.now()).toUpperCase()}';

    final asyncSnapshot = ref.watch(homeDashboardProvider);

    return asyncSnapshot.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Text('Unable to load dashboard: $err', style: t.bodyMedium),
        ),
      ),
      data: (snapshot) {
        final data = snapshot ??
            const HomeDashboardSnapshot(
              totalSalesPaisa: 0,
              dailyTargetPaisa: HomeDashboardSnapshot.defaultDailyTargetPaisa,
              billCount: 0,
              avgBillPaisa: 0,
              itemsSoldCount: 0,
              cashSalesPaisa: 0,
              qrSalesPaisa: 0,
              khataSalesPaisa: 0,
              khataDueTotalPaisa: 0,
              khataDueCustomersCount: 0,
              unpaidSuppliersCount: 0,
              unpaidSuppliersTotalPaisa: 0,
              nearExpiryBatchCount: 0,
              drawerCashPaisa: 0,
              activeShiftId: null,
              topSellingToday: <TopSellingItemSnapshot>[],
            );

        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(homeDashboardProvider);
            await ref.read(homeDashboardProvider.future);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutterMobile,
              AppSpacing.md,
              AppSpacing.gutterMobile,
              AppSpacing.lg,
            ),
            children: [
              // Greeting + Alerts Pill + Sync Icon
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          todayLabel,
                          style: t.labelSmall?.copyWith(
                            color: c.outline,
                            letterSpacing: 0.9,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Namaste, $displayName',
                          style: t.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (data.nearExpiryBatchCount > 0) ...[
                        _ExpiryAlertsPill(
                          count: data.nearExpiryBatchCount,
                          onTap: () {
                            final n = data.nearExpiryBatchCount;
                            ref.read(pasalAlertProvider).showWarning(
                                  '$n ${n == 1 ? 'batch expires' : 'batches expire'} within 30 days. Sell oldest stock first.',
                                  actionLabel: 'View',
                                  onAction: () => context.go(AppRoutes.inventory),
                                );
                          },
                        ),
                        const SizedBox(width: 8),
                      ],
                      PasalPressable(
                        onTap: _syncing ? null : _triggerSync,
                        borderRadius: BorderRadius.circular(AppRadii.pill),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: c.surfaceContainer,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: _syncing
                              ? SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: c.primary,
                                  ),
                                )
                              : Icon(
                                  Icons.sync_rounded,
                                  size: 19,
                                  color: c.primary,
                                ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),

              // Today's Sales Hero Card
              _SalesHeroCard(
                data: data,
                onViewBills: () => context.go(AppRoutes.history),
              ),
              const SizedBox(height: AppSpacing.md),

              // Quick Actions
              Text(
                'QUICK ACTIONS',
                style: t.labelSmall?.copyWith(
                  color: c.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              PasalPressable(
                onTap: () => context.go(AppRoutes.pos),
                borderRadius: BorderRadius.circular(AppRadii.lg),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: c.primary,
                    borderRadius: BorderRadius.circular(AppRadii.lg),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(AppRadii.md),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.qr_code_scanner_rounded,
                          color: c.onPrimary,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'New Sale / Open POS',
                              style: t.titleSmall?.copyWith(
                                color: c.onPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              'Scan barcode or search items',
                              style: t.bodySmall?.copyWith(
                                color: c.onPrimaryContainer,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward_rounded,
                        color: c.onPrimary,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm + 2),

              GridView.count(
                crossAxisCount: 2,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 1.52,
                children: [
                  _QuickActionTile(
                    icon: Icons.menu_book_rounded,
                    title: 'Customer Khata',
                    subtitle: '${MoneyUtils.formatRs(data.khataDueTotalPaisa)} due',
                    badgeText: data.khataDueCustomersCount > 0
                        ? '${data.khataDueCustomersCount} Dues'
                        : null,
                    badgeBackground: c.errorContainer,
                    badgeForeground: c.onErrorContainer,
                    onTap: () => context.push(AppRoutes.khata),
                  ),
                  _QuickActionTile(
                    icon: Icons.payments_outlined,
                    title: 'Record Expense',
                    subtitle: 'Tea, bags, courier',
                    trailingIcon: Icons.add_rounded,
                    onTap: () async {
                      final saved = await showPettyExpenseSheet(
                        context,
                        ref,
                        shiftId: data.activeShiftId,
                      );
                      if (saved == true && context.mounted) {
                        ref.read(pasalAlertProvider).showSuccess(
                              'Expense recorded in cash drawer',
                            );
                      }
                    },
                  ),
                  if (isOwnerOrManager)
                    _QuickActionTile(
                      icon: Icons.move_to_inbox_rounded,
                      title: 'Stock Inward',
                      subtitle: 'Add stock & tags',
                      trailingIcon: Icons.chevron_right_rounded,
                      onTap: () => context.push(AppRoutes.inventoryIntake),
                    ),
                  if (isOwnerOrManager)
                    _QuickActionTile(
                      icon: Icons.local_shipping_outlined,
                      title: 'Suppliers & Bills',
                      subtitle:
                          '${MoneyUtils.formatRs(data.unpaidSuppliersTotalPaisa)} due',
                      badgeText: data.unpaidSuppliersCount > 0
                          ? '${data.unpaidSuppliersCount} Unpaid'
                          : null,
                      badgeBackground: c.surfaceContainer,
                      badgeForeground: c.onSurfaceVariant,
                      onTap: () => context.push(AppRoutes.suppliers),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),

              // Top Selling Today
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'TOP SELLING TODAY',
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
                    onPressed: () => context.go(AppRoutes.inventory),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      'All Stock',
                      style: t.labelMedium?.copyWith(
                        color: c.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (data.topSellingToday.isEmpty)
                PasalCard(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  color: c.surfaceContainerLow,
                  child: Row(
                    children: [
                      Icon(Icons.trending_up_rounded, size: 18, color: c.outline),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'No sales billed today yet — tap New Sale to start.',
                          style: t.bodySmall?.copyWith(color: c.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                )
              else
                ...data.topSellingToday.map(
                  (item) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _TopSellingRow(
                      item: item,
                      onTap: () =>
                          context.push(AppRoutes.productDetail(item.productId)),
                    ),
                  ),
                ),

              const SizedBox(height: AppSpacing.sm),

              // Cash in Drawer Now Strip
              PasalPressable(
                onTap: () => context.go(AppRoutes.register),
                borderRadius: BorderRadius.circular(AppRadii.md),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    color: c.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(AppRadii.md),
                    border: Border.all(color: c.hairline),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.account_balance_wallet_outlined,
                            size: 19,
                            color: c.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Cash in Drawer Now',
                            style: t.labelLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      PasalTabularText(
                        MoneyUtils.formatRs(data.drawerCashPaisa),
                        style: t.titleMedium?.copyWith(
                          color: c.primary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _formatDisplayName(String? raw) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) return 'Team';
    final first = trimmed.split(RegExp(r'[\s._-]+')).first;
    if (first.isEmpty) return 'Team';
    return '${first[0].toUpperCase()}${first.substring(1)}';
  }
}

class _ExpiryAlertsPill extends StatelessWidget {
  const _ExpiryAlertsPill({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return PasalPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.pill),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: c.warningContainer,
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(color: c.warningBorder.withValues(alpha: 0.7)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded, size: 16, color: c.warning),
            const SizedBox(width: 4),
            PasalTabularText(
              '$count',
              style: t.labelMedium?.copyWith(
                color: c.onWarningContainer,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SalesHeroCard extends StatelessWidget {
  const _SalesHeroCard({required this.data, required this.onViewBills});

  final HomeDashboardSnapshot data;
  final VoidCallback onViewBills;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final targetFraction = data.dailyTargetPaisa <= 0
        ? 0.0
        : (data.totalSalesPaisa / data.dailyTargetPaisa).clamp(0.0, 1.0);

    final totalSplit =
        data.cashSalesPaisa + data.qrSalesPaisa + data.khataSalesPaisa;
    final cashFlex =
        totalSplit <= 0 ? 1 : (data.cashSalesPaisa * 100 / totalSplit).round();
    final qrFlex =
        totalSplit <= 0 ? 0 : (data.qrSalesPaisa * 100 / totalSplit).round();
    final khataFlex =
        totalSplit <= 0 ? 0 : (data.khataSalesPaisa * 100 / totalSplit).round();

    return PasalCard(
      padding: const EdgeInsets.all(AppSpacing.md),
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
                    Text(
                      "TODAY'S TOTAL SALES",
                      style: t.labelSmall?.copyWith(
                        color: c.onSurfaceVariant,
                        letterSpacing: 0.8,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: PasalTabularText(
                        MoneyUtils.formatRs(data.totalSalesPaisa),
                        style: t.displayMedium?.copyWith(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.6,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              PasalPressable(
                onTap: onViewBills,
                borderRadius: BorderRadius.circular(AppRadii.sm),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: c.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                  ),
                  child: Text(
                    'View Bills',
                    style: t.labelMedium?.copyWith(
                      color: c.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Daily Target Progress
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: c.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: PasalTabularText(
                        'Daily Target: ${MoneyUtils.formatRs(data.dailyTargetPaisa)}',
                        style: t.bodySmall?.copyWith(color: c.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    PasalTabularText(
                      '${data.targetPercent}%',
                      style: t.labelMedium?.copyWith(
                        color: c.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                  child: LinearProgressIndicator(
                    value: targetFraction,
                    minHeight: 6,
                    backgroundColor: c.surfaceContainer,
                    valueColor: AlwaysStoppedAnimation<Color>(c.primary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 3 Core Numbers
          Row(
            children: [
              Expanded(
                child: _MiniStatBox(
                  label: 'BILLS',
                  value: '${data.billCount}',
                  colors: c,
                  textTheme: t,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MiniStatBox(
                  label: 'AVG BILL',
                  value: MoneyUtils.formatRs(data.avgBillPaisa),
                  colors: c,
                  textTheme: t,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MiniStatBox(
                  label: 'ITEMS SOLD',
                  value: '${data.itemsSoldCount}',
                  colors: c,
                  textTheme: t,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Payment Split
          Row(
            children: [
              Expanded(
                child: Text(
                  'PAYMENT SPLIT',
                  style: t.labelSmall?.copyWith(
                    color: c.outline,
                    letterSpacing: 0.7,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Cash · QR · Khata',
                style: t.labelSmall?.copyWith(color: c.outline),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.pill),
            child: SizedBox(
              height: 6,
              child: totalSplit <= 0
                  ? Container(color: c.surfaceContainer)
                  : Row(
                      children: [
                        if (cashFlex > 0)
                          Expanded(
                            flex: cashFlex,
                            child: Container(color: c.primary),
                          ),
                        if (qrFlex > 0)
                          Expanded(
                            flex: qrFlex,
                            child: Container(color: c.secondaryContainer),
                          ),
                        if (khataFlex > 0)
                          Expanded(
                            flex: khataFlex,
                            child: Container(color: c.warningBorder),
                          ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _SplitMiniCard(
                  label: 'Cash',
                  amountPaisa: data.cashSalesPaisa,
                  colors: c,
                  textTheme: t,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _SplitMiniCard(
                  label: 'Fonepay QR',
                  amountPaisa: data.qrSalesPaisa,
                  colors: c,
                  textTheme: t,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _SplitMiniCard(
                  label: 'Khata',
                  amountPaisa: data.khataSalesPaisa,
                  colors: c,
                  textTheme: t,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniStatBox extends StatelessWidget {
  const _MiniStatBox({
    required this.label,
    required this.value,
    required this.colors,
    required this.textTheme,
  });

  final String label;
  final String value;
  final PasalColors colors;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: textTheme.labelSmall?.copyWith(
              fontSize: 10,
              color: colors.outline,
            ),
          ),
          const SizedBox(height: 2),
          PasalTabularText(
            value,
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _SplitMiniCard extends StatelessWidget {
  const _SplitMiniCard({
    required this.label,
    required this.amountPaisa,
    required this.colors,
    required this.textTheme,
  });

  final String label;
  final int amountPaisa;
  final PasalColors colors;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadii.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: textTheme.labelSmall?.copyWith(
              fontSize: 10,
              color: colors.outline,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          PasalTabularText(
            MoneyUtils.formatRs(amountPaisa),
            style: textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: colors.onSurface,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _QuickActionTile extends StatelessWidget {
  const _QuickActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badgeText,
    this.badgeBackground,
    this.badgeForeground,
    this.trailingIcon,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final String? badgeText;
  final Color? badgeBackground;
  final Color? badgeForeground;
  final IconData? trailingIcon;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return PasalPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: PasalCard(
        padding: const EdgeInsets.all(12),
        borderRadius: AppRadii.md,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: c.surfaceContainer,
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                  ),
                  alignment: Alignment.center,
                  child: Icon(icon, size: 18, color: c.primary),
                ),
                if (badgeText != null) ...[
                  const SizedBox(width: 4),
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: badgeBackground ?? c.surfaceContainer,
                        borderRadius: BorderRadius.circular(AppRadii.pill),
                      ),
                      child: Text(
                        badgeText!,
                        style: t.labelSmall?.copyWith(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: badgeForeground ?? c.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ] else if (trailingIcon != null)
                  Icon(trailingIcon, size: 16, color: c.outline),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: t.labelLarge?.copyWith(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                PasalTabularText(
                  subtitle,
                  style: t.bodySmall?.copyWith(
                    fontSize: 11,
                    color: c.outline,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TopSellingRow extends StatelessWidget {
  const _TopSellingRow({required this.item, required this.onTap});

  final TopSellingItemSnapshot item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final swatchColor = _parseHexColor(item.colorHex) ?? c.secondaryContainer;
    final subtitle = item.sizeVolume != null && item.sizeVolume!.isNotEmpty
        ? '${item.variantName} • ${item.sizeVolume}'
        : item.variantName;

    return PasalPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: PasalCard(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        borderRadius: AppRadii.md,
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: swatchColor,
                borderRadius: BorderRadius.circular(AppRadii.sm),
                border: Border.all(color: Colors.black.withValues(alpha: 0.1)),
              ),
              alignment: Alignment.center,
              child: Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.8),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.productName,
                    style: t.labelLarge?.copyWith(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    subtitle,
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
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                PasalTabularText(
                  '${item.quantitySold} sold',
                  style: t.labelMedium?.copyWith(
                    color: c.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                PasalTabularText(
                  MoneyUtils.formatRs(item.unitPricePaisa),
                  style: t.labelSmall?.copyWith(
                    fontSize: 10.5,
                    color: c.outline,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static Color? _parseHexColor(String? hex) {
    if (hex == null || hex.trim().isEmpty) return null;
    final clean = hex.trim().replaceFirst('#', '');
    if (clean.length == 6) {
      final val = int.tryParse('FF$clean', radix: 16);
      if (val != null) return Color(val);
    } else if (clean.length == 8) {
      final val = int.tryParse(clean, radix: 16);
      if (val != null) return Color(val);
    }
    return null;
  }
}
