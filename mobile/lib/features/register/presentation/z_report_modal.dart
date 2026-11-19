import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Shows the Manager/Owner confirmation dialog to force-close a missing or
/// offline staff phone's active shift session (`FORCE_CLOSED`).
Future<bool> showForceCloseSessionDialog(
  BuildContext context,
  WidgetRef ref, {
  required StaffSessionWithUser target,
}) async {
  final c = context.pasalColors;
  final t = context.textTheme;
  final fmt = DateFormat('yyyy-MM-dd HH:mm');

  final confirmed = await showPasalDialog<bool>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        title: const Text('Force Punch-Out Staff?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${target.displayName} (Device ${target.session.deviceCode}) has not punched out yet.',
              style: t.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            PasalCard(
              color: c.surfaceContainerLow,
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('LAST SYNCED AT', style: t.labelSmall),
                  const SizedBox(height: 2),
                  PasalTabularText(
                    fmt.format(target.session.lastSyncedAt.toLocal()),
                    style: t.titleSmall,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Use Force Punch-Out only if the staff left early or their phone battery died. Any unsynced offline bills on that phone will sync when it reconnects.',
              style: t.bodySmall?.copyWith(color: c.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Force Punch-Out'),
          ),
        ],
      );
    },
  );

  if (confirmed != true) return false;
  final repo = ref.read(registerRepositoryProvider);
  final session = ref.read(ramKeyHolderProvider).session;
  if (repo == null || session == null) return false;

  await repo.forceCloseStaffSession(
    sessionId: target.session.id,
    managerUserId: session.userId,
    managerRole: session.role,
  );
  ref.read(syncOutboxWorkerProvider).scheduleImmediateSync();
  return true;
}

/// Opens the End-of-Day Z-Report & Bank Drop / Next-Day Float settlement modal.
Future<ZReportSettlementResult?> showZReportModal(
  BuildContext context,
  WidgetRef ref, {
  required RegisterShiftRow shift,
}) {
  return showPasalBottomSheet<ZReportSettlementResult>(
    context: context,
    useSafeArea: true,
    backgroundColor: context.pasalColors.surfaceContainerLowest,
    builder: (_) => _ZReportModal(shift: shift),
  );
}

class _ZReportModal extends ConsumerStatefulWidget {
  const _ZReportModal({required this.shift});

  final RegisterShiftRow shift;

  @override
  ConsumerState<_ZReportModal> createState() => _ZReportModalState();
}

class _ZReportModalState extends ConsumerState<_ZReportModal> {
  late final TextEditingController _countedCtrl;
  late final TextEditingController _floatCtrl;
  late final TextEditingController _notesCtrl;
  bool _printReceipt = true;
  bool _settling = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final expected = widget.shift.expectedCash.clamp(
      0,
      MoneyUtils.maxDecimal10_2Paisa,
    );
    _countedCtrl = TextEditingController(
      text: MoneyUtils.toDecimalString(expected),
    );
    // Suggest retaining opening float (up to counted cash) for next day.
    final suggestedFloat = widget.shift.openingFloat <= expected
        ? widget.shift.openingFloat
        : expected;
    _floatCtrl = TextEditingController(
      text: MoneyUtils.toDecimalString(suggestedFloat),
    );
    _notesCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _countedCtrl.dispose();
    _floatCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  int get _countedPaisa => MoneyUtils.tryParseToPaisa(_countedCtrl.text) ?? 0;
  int get _retainedFloatPaisa =>
      MoneyUtils.tryParseToPaisa(_floatCtrl.text) ?? 0;
  int get _bankDropPaisa => _countedPaisa - _retainedFloatPaisa;
  int get _discrepancyPaisa => _countedPaisa - widget.shift.expectedCash;

  Future<void> _finalize(List<StaffSessionWithUser> sessions) async {
    final activeCount = sessions.where((s) => s.isActive).length;
    if (activeCount > 0) {
      setState(() {
        _error =
            '$activeCount staff terminal(s) still ACTIVE. Punch out or Force Punch-Out all staff first.';
      });
      return;
    }

    final counted = MoneyUtils.tryParseToPaisa(_countedCtrl.text);
    final retainedFloat = MoneyUtils.tryParseToPaisa(_floatCtrl.text);
    if (counted == null || counted < 0) {
      setState(() => _error = 'Enter a valid non-negative Actual Cash Counted.');
      return;
    }
    if (retainedFloat == null || retainedFloat < 0) {
      setState(() => _error = 'Enter a valid non-negative Next-Day Float.');
      return;
    }
    if (retainedFloat > counted) {
      setState(
        () => _error =
            'Next-Day Float cannot exceed Actual Cash Counted (${MoneyUtils.formatRs(counted)}).',
      );
      return;
    }

    final repo = ref.read(registerRepositoryProvider);
    final session = ref.read(ramKeyHolderProvider).session;
    if (repo == null || session == null) return;

    setState(() {
      _settling = true;
      _error = null;
    });

    try {
      final bankDrop = counted - retainedFloat;
      final closedShift = await repo.closeShiftAndGenerateZReport(
        shiftId: widget.shift.id,
        closedByUserId: session.userId,
        closedByRole: session.role,
        actualCashCountedPaisa: counted,
        cashWithdrawnDepositPaisa: bankDrop,
        retainedNextDayFloatPaisa: retainedFloat,
        notes: _notesCtrl.text,
      );

      ref.read(authSessionControllerProvider).onShiftClosed(closedShift.id);
      ref.read(syncOutboxWorkerProvider).scheduleImmediateSync();

      Uint8List? printedBytes;
      if (_printReceipt) {
        try {
          final driver = ref.read(xlabPrinterDriverProvider);
          printedBytes = await driver.printZReport(
            ZReportPrintData(
              shiftId: closedShift.id,
              openedAt: closedShift.openedAt,
              closedAt: closedShift.closedAt ?? DateTime.now().toUtc(),
              closedByName: session.username,
              openingFloatPaisa: closedShift.openingFloat,
              cashSalesPaisa: closedShift.cashSales,
              digitalSalesPaisa: closedShift.digitalSales,
              khataCashRepaymentsPaisa: closedShift.khataCashRepayments,
              cashExpensesPaisa: closedShift.cashExpenses,
              expectedCashPaisa: closedShift.expectedCash,
              actualCashCountedPaisa: counted,
              discrepancyPaisa: closedShift.discrepancy ?? _discrepancyPaisa,
              cashWithdrawnDepositPaisa: bankDrop,
              retainedNextDayFloatPaisa: retainedFloat,
              notes: closedShift.notes,
            ),
          );
        } catch (_) {
          // Non-blocking: Z-Report is already saved & queued for sync even if
          // thermal printer is offline.
        }
      }

      if (mounted) {
        Navigator.of(context).pop(
          ZReportSettlementResult(
            closedShift: closedShift,
            discrepancyPaisa: closedShift.discrepancy ?? _discrepancyPaisa,
            receiptBytes: printedBytes,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _settling = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    final sessionsAsync = ref.watch(shiftStaffSessionsProvider(widget.shift.id));
    final sessions = sessionsAsync.value ?? const <StaffSessionWithUser>[];
    final activeCount = sessions.where((s) => s.isActive).length;
    final canFinalize = activeCount == 0 && !_settling;

    final disc = _discrepancyPaisa;
    final discColor = disc == 0 ? c.primary : c.error;
    final discPrefix = disc > 0 ? '+' : '';

    return PopScope(
      canPop: !_settling,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.gutterMobile,
          AppSpacing.md,
          AppSpacing.gutterMobile,
          AppSpacing.md + bottom,
        ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Close Register & Z-Report',
                    style: t.headlineMedium,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),

            // 1. Staff Punch-Out Pre-Flight Checklist
            PasalCard(
              color: c.surfaceContainerLow,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'STAFF PUNCH-OUT CHECKLIST',
                          style: t.labelMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      PasalStatusBadge(
                        label: activeCount == 0
                            ? 'All Clear'
                            : '$activeCount Active',
                        backgroundColor: activeCount == 0
                            ? c.secondaryContainer
                            : c.surfaceContainerHigh,
                        foregroundColor: activeCount == 0
                            ? c.onSecondaryContainer
                            : c.error,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  if (sessions.isEmpty)
                    Text('No staff sessions recorded.', style: t.bodySmall)
                  else
                    ...sessions.map(
                      (s) => Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.xs),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: c.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: PasalTabularText(
                                s.session.deviceCode,
                                style: t.labelSmall,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            Expanded(
                              child: Text(
                                s.displayName,
                                style: t.bodyMedium,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            if (s.isActive)
                              TextButton(
                                onPressed: () => showForceCloseSessionDialog(
                                  context,
                                  ref,
                                  target: s,
                                ),
                                child: Text(
                                  'Force Punch-Out',
                                  style: t.labelMedium?.copyWith(color: c.error),
                                ),
                              )
                            else
                              PasalStatusBadge(
                                label: s.isForceClosed
                                    ? 'Force Closed'
                                    : 'Punched Out',
                                backgroundColor: c.secondaryContainer,
                                foregroundColor: c.onSecondaryContainer,
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),

            // 2. Expected vs Actual Cash Counted
            PasalCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'EXPECTED DRAWER CASH',
                          style: t.labelSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      PasalTabularText(
                        MoneyUtils.formatRs(widget.shift.expectedCash),
                        style: t.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    controller: _countedCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'^\d*\.?\d{0,2}'),
                      ),
                    ],
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Actual Cash Counted in Galla (Rs.)',
                      prefixText: 'Rs. ',
                      suffixIcon: TextButton(
                        onPressed: () {
                          _countedCtrl.text = MoneyUtils.toDecimalString(
                            widget.shift.expectedCash
                                .clamp(0, MoneyUtils.maxDecimal10_2Paisa),
                          );
                          setState(() {});
                        },
                        child: const Text('Exact'),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'DISCREPANCY',
                          style: t.labelSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      PasalTabularText(
                        disc == 0
                            ? 'Balanced (Rs. 0.00)'
                            : '$discPrefix${MoneyUtils.formatRs(disc)}',
                        style: t.titleSmall?.copyWith(color: discColor),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),

            // 3. Bank Drop & Next-Day Float Rollover
            PasalCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('BANK DROP & NEXT-DAY FLOAT', style: t.labelMedium),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    controller: _floatCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'^\d*\.?\d{0,2}'),
                      ),
                    ],
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Retained Next-Day Float (Left in Galla)',
                      prefixText: 'Rs. ',
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          'Bank Drop / Owner Deposit',
                          style: t.bodyMedium,
                        ),
                      ),
                      PasalTabularText(
                        MoneyUtils.formatRs(_bankDropPaisa),
                        style: t.titleMedium?.copyWith(
                          color: _bankDropPaisa < 0 ? c.error : c.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    controller: _notesCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Closing Notes (Optional)',
                      hintText: 'e.g., Short Rs. 20 coin rounding',
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Print 80mm Z-Report Summary',
                          style: t.bodyMedium,
                        ),
                      ),
                      Switch.adaptive(
                        value: _printReceipt,
                        onChanged: (v) => setState(() => _printReceipt = v),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(_error!, style: t.bodySmall?.copyWith(color: c.error)),
            ],
            const SizedBox(height: AppSpacing.md),
            FilledButton.icon(
              onPressed: canFinalize ? () => _finalize(sessions) : null,
              icon: const Icon(Icons.lock_clock_outlined, size: 18),
              label: Text(
                _settling
                    ? 'Settling Z-Report...'
                    : 'Finalize Z-Report & Close Shift',
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

