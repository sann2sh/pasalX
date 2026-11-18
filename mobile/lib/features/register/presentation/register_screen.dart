import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/money.dart';
import '../../../core/printer/esc_pos_receipt_builder.dart';
import '../../../core/printer/printer_providers.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../../auth/application/auth_session_controller.dart';
import '../application/register_providers.dart';
import '../domain/register_models.dart';
import 'petty_expense_sheet.dart';
import 'z_report_modal.dart';

/// `/register` tab: Single-Galla Cash Drawer, Petty Expenses, Staff Punch-Out
/// Checklist, Force-Close Override, and End-of-Day Z-Report Settlement.
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  static final DateFormat _timeFmt = DateFormat('HH:mm');
  static final DateFormat _dateFmt = DateFormat('yyyy-MM-dd HH:mm');
  bool _punchingOut = false;

  Future<void> _handlePrintSummary(RegisterShiftRow shift) async {
    final session = ref.read(ramKeyHolderProvider).session;
    try {
      await ref.read(xlabPrinterDriverProvider).printZReport(
            ZReportPrintData(
              shiftId: shift.id,
              closedByName: session?.username ?? 'Cashier',
              openedAt: shift.openedAt,
              closedAt: DateTime.now(),
              openingFloatPaisa: shift.openingFloat,
              cashSalesPaisa: shift.cashSales,
              khataCashRepaymentsPaisa: shift.khataCashRepayments,
              cashExpensesPaisa: shift.cashExpenses,
              digitalSalesPaisa: shift.digitalSales,
              expectedCashPaisa: shift.expectedCash,
              actualCashCountedPaisa: shift.expectedCash,
              discrepancyPaisa: 0,
              cashWithdrawnDepositPaisa: 0,
              retainedNextDayFloatPaisa: shift.openingFloat,
            ),
          );
      if (mounted) {
        ref
            .read(pasalAlertProvider)
            .showSuccess('Mid-day shift summary printed.');
      }
    } catch (_) {
      if (mounted) {
        ref
            .read(pasalAlertProvider)
            .showError('Printer offline. Check Wi-Fi or IP.');
      }
    }
  }

  Future<void> _handlePunchOut(RegisterShiftRow shift) async {
    final repo = ref.read(registerRepositoryProvider);
    final session = ref.read(ramKeyHolderProvider).session;
    if (repo == null || session == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sync & Punch Out?'),
        content: const Text(
          'This will flush pending offline bills, mark your terminal session as PUNCHED OUT, and lock the encryption vault.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Punch Out & Lock'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _punchingOut = true);
    try {
      await repo.punchOutCurrentStaff(
        shiftId: shift.id,
        userId: session.userId,
        deviceCode: session.deviceCode,
      );
      await ref.read(syncOutboxWorkerProvider).syncNow();
      final pendingCount = ref.read(syncOutboxWorkerProvider).status.pendingCount;
      if (mounted && pendingCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Punched out offline: $pendingCount change(s) queued to sync on next sign-in.',
            ),
          ),
        );
      }
      await ref.read(authSessionControllerProvider).logout();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Punch-out failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _punchingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final session = ref.watch(ramKeyHolderProvider).session;
    final isManagerOrOwner =
        session != null && (session.role == 'OWNER' || session.role == 'MANAGER');
    final shiftAsync = ref.watch(activeRegisterShiftProvider);
    final lastClosedAsync = ref.watch(lastClosedShiftProvider);

    final activeShift = shiftAsync.value;
    final lastClosed = lastClosedAsync.value;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutterMobile,
        AppSpacing.gutterMobile,
        AppSpacing.gutterMobile,
        AppSpacing.xl,
      ),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Register & Shift', style: t.headlineLarge),
                  const SizedBox(height: 2),
                  Text(
                    'Single-Galla Cash Drawer & Z-Report Reconciliation',
                    style: t.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),

        if (activeShift != null) ...[
          _ActiveShiftDrawerCard(shift: activeShift),
          const SizedBox(height: AppSpacing.md),

          // Revenue Breakdown (Total + Cash vs Fonepay QR)
          _RevenueBreakdownGrid(shift: activeShift),
          const SizedBox(height: AppSpacing.md),

          // Today's Petty Cash Out (with inline + Log Expense)
          _ExpensesCard(
            shift: activeShift,
            timeFmt: _timeFmt,
            onLogExpense: () => showPettyExpenseSheet(
              context,
              ref,
              shiftId: activeShift.id,
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // Staff Punch-Out Checklist
          _StaffChecklistCard(
            shiftId: activeShift.id,
            isManagerOrOwner: isManagerOrOwner,
            timeFmt: _timeFmt,
          ),
          const SizedBox(height: AppSpacing.md),

          // Close Day & Staff Punch Out
          if (isManagerOrOwner) ...[
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () async {
                  final res = await showZReportModal(
                    context,
                    ref,
                    shift: activeShift,
                  );
                  if (res != null && context.mounted) {
                    ref.read(pasalAlertProvider).showSuccess(
                          'Z-Report finalized! Tomorrow float: ${MoneyUtils.formatRs(res.closedShift.retainedNextDayFloat)}',
                        );
                  }
                },
                icon: const Icon(Icons.fact_check_outlined, size: 20),
                label: const Text('Count Cash & Close Shift (Z-Report)'),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => _handlePrintSummary(activeShift),
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: const Text('Print Summary'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    backgroundColor: c.errorContainer,
                    foregroundColor: c.onErrorContainer,
                  ),
                  onPressed:
                      _punchingOut ? null : () => _handlePunchOut(activeShift),
                  icon: const Icon(Icons.logout_rounded, size: 18),
                  label: Text(_punchingOut ? 'Punching Out...' : 'Punch Out'),
                ),
              ),
            ],
          ),
        ] else ...[
          PasalCard(
            color: c.surfaceContainerLow,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('EXPECTED DRAWER CASH', style: t.labelSmall),
                const SizedBox(height: 4),
                PasalTabularText('Rs. 0.00', style: t.displayLarge),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    PasalStatusBadge(
                      label: 'Shift Not Opened',
                      backgroundColor: c.surfaceContainerHigh,
                      foregroundColor: c.onSurfaceVariant,
                    ),
                    if (session != null)
                      FilledButton.tonalIcon(
                        onPressed: () => ref
                            .read(authSessionControllerProvider)
                            .requestNewShiftOpen(),
                        icon: const Icon(Icons.lock_open_rounded, size: 18),
                        label: const Text('Open Next Shift'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (lastClosed != null) ...[
            const SizedBox(height: AppSpacing.md),
            _LastClosedZReportCard(shift: lastClosed, dateFmt: _dateFmt),
          ],
        ],
      ],
    );
  }
}

class _ActiveShiftDrawerCard extends StatelessWidget {
  const _ActiveShiftDrawerCard({required this.shift});

  final RegisterShiftRow shift;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final cashIn = shift.cashSales + shift.khataCashRepayments;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: c.primary,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'REGISTER CASH BALANCE',
                  style: t.labelSmall?.copyWith(color: c.onPrimaryContainer),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                Icons.account_balance_wallet_outlined,
                color: c.onPrimaryContainer,
                size: 20,
              ),
            ],
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: PasalTabularText(
              MoneyUtils.formatRs(shift.expectedCash),
              style: t.displayLarge?.copyWith(color: c.onPrimary),
            ),
          ),
          Text(
            'Expected physical cash in drawer',
            style: t.bodySmall?.copyWith(color: c.onPrimaryContainer),
          ),
          const SizedBox(height: AppSpacing.sm),
          Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: c.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                _HeroDrawerLine(
                  label: 'Opening Float',
                  value: '+ ${MoneyUtils.formatRs(shift.openingFloat)}',
                  color: c.onPrimary,
                  labelColor: c.onPrimaryContainer,
                ),
                const SizedBox(height: 4),
                _HeroDrawerLine(
                  label: 'Cash Sales & Khata Collected',
                  value: '+ ${MoneyUtils.formatRs(cashIn)}',
                  color: c.onPrimary,
                  labelColor: c.onPrimaryContainer,
                ),
                const SizedBox(height: 4),
                _HeroDrawerLine(
                  label: 'Cash Expenses Paid',
                  value: '- ${MoneyUtils.formatRs(shift.cashExpenses)}',
                  color: c.errorContainer,
                  labelColor: c.onPrimaryContainer,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroDrawerLine extends StatelessWidget {
  const _HeroDrawerLine({
    required this.label,
    required this.value,
    required this.color,
    required this.labelColor,
  });

  final String label;
  final String value;
  final Color color;
  final Color labelColor;

  @override
  Widget build(BuildContext context) {
    final t = context.textTheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: t.bodySmall?.copyWith(color: labelColor),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        PasalTabularText(
          value,
          style: t.labelMedium?.copyWith(color: color),
        ),
      ],
    );
  }
}

class _RevenueBreakdownGrid extends StatelessWidget {
  const _RevenueBreakdownGrid({required this.shift});

  final RegisterShiftRow shift;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final totalSales = shift.cashSales + shift.digitalSales;

    return Column(
      children: [
        PasalCard(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('TOTAL SHIFT SALES', style: t.labelSmall),
                    const SizedBox(height: 2),
                    PasalTabularText(
                      MoneyUtils.formatRs(totalSales),
                      style: t.titleLarge,
                    ),
                  ],
                ),
              ),
              PasalStatusBadge(
                label: 'Shift Open',
                backgroundColor: c.secondaryContainer,
                foregroundColor: c.onSecondaryContainer,
                dotColor: c.primary,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            Expanded(
              child: PasalCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('CASH', style: t.labelSmall),
                    const SizedBox(height: 2),
                    PasalTabularText(
                      MoneyUtils.formatRs(shift.cashSales),
                      style: t.titleMedium,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: PasalCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('FONEPAY QR', style: t.labelSmall),
                    const SizedBox(height: 2),
                    PasalTabularText(
                      MoneyUtils.formatRs(shift.digitalSales),
                      style: t.titleMedium,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _DrawerLine extends StatelessWidget {
  const _DrawerLine({
    required this.label,
    required this.amountPaisa,
  });

  final String label;
  final int amountPaisa;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: t.bodySmall?.copyWith(color: c.onSurface),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          PasalTabularText(
            MoneyUtils.formatRs(amountPaisa),
            style: t.titleSmall?.copyWith(color: c.onSurface),
          ),
        ],
      ),
    );
  }
}

class _StaffChecklistCard extends ConsumerWidget {
  const _StaffChecklistCard({
    required this.shiftId,
    required this.isManagerOrOwner,
    required this.timeFmt,
  });

  final String shiftId;
  final bool isManagerOrOwner;
  final DateFormat timeFmt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.textTheme;
    final sessionsAsync = ref.watch(shiftStaffSessionsProvider(shiftId));

    return PasalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('STAFF PUNCH-OUT CHECKLIST', style: t.labelMedium),
          const SizedBox(height: AppSpacing.xs),
          sessionsAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(AppSpacing.sm),
              child: LinearProgressIndicator(),
            ),
            error: (err, _) => Text('Error: $err', style: t.bodySmall),
            data: (sessions) {
              if (sessions.isEmpty) {
                return Text('No active staff sessions.', style: t.bodySmall);
              }
              return Column(
                children: sessions.map((s) {
                  return _StaffSessionTile(
                    item: s,
                    isManagerOrOwner: isManagerOrOwner,
                    timeFmt: timeFmt,
                    onForceClose: () => showForceCloseSessionDialog(
                      context,
                      ref,
                      target: s,
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _StaffSessionTile extends StatelessWidget {
  const _StaffSessionTile({
    required this.item,
    required this.isManagerOrOwner,
    required this.timeFmt,
    required this.onForceClose,
  });

  final StaffSessionWithUser item;
  final bool isManagerOrOwner;
  final DateFormat timeFmt;
  final VoidCallback onForceClose;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: c.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(6),
            ),
            child: PasalTabularText(
              item.session.deviceCode,
              style: t.labelSmall,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.displayName,
                  style: t.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  'In ${timeFmt.format(item.session.punchedInAt.toLocal())} • '
                  'Synced ${timeFmt.format(item.session.lastSyncedAt.toLocal())}',
                  style: t.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          if (item.isActive && isManagerOrOwner)
            TextButton(
              onPressed: onForceClose,
              child: Text(
                'Force Close',
                style: t.labelMedium?.copyWith(color: c.error),
              ),
            )
          else
            PasalStatusBadge(
              label: item.isActive
                  ? 'Active'
                  : (item.isForceClosed ? 'Force Closed' : 'Punched Out'),
              backgroundColor: item.isActive
                  ? c.surfaceContainerHigh
                  : c.secondaryContainer,
              foregroundColor:
                  item.isActive ? c.onSurfaceVariant : c.onSecondaryContainer,
            ),
        ],
      ),
    );
  }
}

class _ExpensesCard extends ConsumerWidget {
  const _ExpensesCard({
    required this.shift,
    required this.timeFmt,
    required this.onLogExpense,
  });

  final RegisterShiftRow shift;
  final DateFormat timeFmt;
  final VoidCallback onLogExpense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final expensesAsync = ref.watch(shiftExpensesProvider(shift.id));

    return PasalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('TODAY\'S PETTY CASH OUT', style: t.labelSmall),
                    PasalTabularText(
                      '${MoneyUtils.formatRs(shift.cashExpenses)} Total',
                      style: t.titleSmall,
                    ),
                  ],
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: onLogExpense,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Log Expense'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          expensesAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(AppSpacing.sm),
              child: LinearProgressIndicator(),
            ),
            error: (err, _) => Text('Error: $err', style: t.bodySmall),
            data: (expenses) {
              if (expenses.isEmpty) {
                return Text(
                  'No petty expenses logged for this shift.',
                  style: t.bodySmall,
                );
              }
              return Column(
                children: expenses.map((e) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                e.title,
                                style: t.titleSmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                '${e.category} • ${e.paymentMethod} • ${timeFmt.format(e.createdAt.toLocal())}',
                                style: t.bodySmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        PasalTabularText(
                          '-${MoneyUtils.formatRs(e.amount)}',
                          style: t.titleSmall?.copyWith(color: c.error),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _LastClosedZReportCard extends StatelessWidget {
  const _LastClosedZReportCard({required this.shift, required this.dateFmt});

  final RegisterShiftRow shift;
  final DateFormat dateFmt;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return PasalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'LAST CLOSED Z-REPORT',
                  style: t.labelMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              PasalStatusBadge(
                label: 'CLOSED',
                backgroundColor: c.secondaryContainer,
                foregroundColor: c.onSecondaryContainer,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          if (shift.closedAt != null)
            Text(
              'Settled: ${dateFmt.format(shift.closedAt!.toLocal())}',
              style: t.bodySmall,
            ),
          const SizedBox(height: AppSpacing.sm),
          _DrawerLine(
            label: 'Actual Cash Counted',
            amountPaisa: shift.actualCashCounted ?? shift.expectedCash,
          ),
          _DrawerLine(
            label: 'Bank Drop / Deposit',
            amountPaisa: shift.cashWithdrawnDeposit,
          ),
          _DrawerLine(
            label: 'Retained Next-Day Float',
            amountPaisa: shift.retainedNextDayFloat,
          ),
        ],
      ),
    );
  }
}
