import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/app_database.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../../core/router/shell_scaffold.dart';
import '../../../core/sync/sync_outbox_worker.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';

final _pendingOutboxRowsProvider =
    StreamProvider.autoDispose<List<SyncOutboxRow>>((ref) {
  final db = ref.watch(activeDatabaseProvider);
  if (db == null) return Stream.value(const <SyncOutboxRow>[]);
  return db.watchPendingSyncOutboxRows();
});

/// Screen 20: Dedicated Backup & Sync Status screen (plain-language outbox & cloud status).
class BackupSettingsScreen extends ConsumerStatefulWidget {
  const BackupSettingsScreen({super.key});

  @override
  ConsumerState<BackupSettingsScreen> createState() =>
      _BackupSettingsScreenState();
}

class _BackupSettingsScreenState extends ConsumerState<BackupSettingsScreen> {
  static final DateFormat _timeFmt = DateFormat('hh:mm a');
  bool _syncing = false;
  DateTime? _lastCheckedAt;

  String _friendlyRowTitle(SyncOutboxRow row) {
    final table = row.targetTable.toLowerCase();
    return switch (table) {
      'sale_orders' || 'sale_items' || 'sale_payments' => 'Sales Bill',
      'batches' || 'products' || 'product_variants' || 'stock_movements' =>
        'Stock Update',
      'customers' || 'customer_transactions' || 'customer_shade_profiles' =>
        'Customer Khata',
      'register_shifts' || 'staff_shift_sessions' => 'Shift Record',
      'expenses' => 'Petty Cash Expense',
      'suppliers' || 'supplier_payments' || 'purchase_invoices' =>
        'Supplier & Purchase',
      _ => 'Shop Record',
    };
  }

  Future<void> _checkStatus() async {
    setState(() {
      _syncing = true;
      _lastCheckedAt = DateTime.now();
    });
    try {
      await ref.read(syncOutboxWorkerProvider).syncNow();
      if (!mounted) return;
      final status = ref.read(syncOutboxWorkerProvider).status;
      if (!status.isOnline) {
        ref.read(pasalAlertProvider).showWarning(
              'Phone is offline. Changes are safely saved locally.',
            );
      } else if (status.pendingCount > 0) {
        ref.read(pasalAlertProvider).showWarning(
              '${status.pendingCount} item(s) still waiting to back up.',
            );
      } else {
        ref.read(pasalAlertProvider).showSuccess('Shop backup is up to date.');
      }
    } catch (_) {
      if (!mounted) return;
      ref.read(pasalAlertProvider).showError(
            'Could not reach shop cloud. Check internet connection.',
          );
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _runBackupAndSync() async {
    setState(() {
      _syncing = true;
      _lastCheckedAt = DateTime.now();
    });
    try {
      await ref.read(syncOutboxWorkerProvider).syncNow();
      if (!mounted) return;
      final status = ref.read(syncOutboxWorkerProvider).status;
      if (!status.isOnline) {
        ref.read(pasalAlertProvider).showWarning(
              'No internet right now. Your bills are safe and will sync automatically.',
            );
      } else if (status.state == SyncHealthState.error) {
        ref.read(pasalAlertProvider).showError(
              'Backup paused. Please try again in a moment.',
            );
      } else {
        ref.read(pasalAlertProvider).showSuccess(
              status.pendingCount == 0
                  ? 'All shop records backed up & synced.'
                  : 'Synced! ${status.pendingCount} item(s) remaining.',
            );
      }
    } catch (_) {
      if (!mounted) return;
      ref
          .read(pasalAlertProvider)
          .showError('Backup failed. Check internet connection.');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final syncWorker = ref.watch(syncOutboxWorkerProvider);
    final syncStatus = syncWorker.status;
    final outboxAsync = ref.watch(_pendingOutboxRowsProvider);
    final pendingRows = outboxAsync.value ?? const <SyncOutboxRow>[];

    final hasPending = pendingRows.isNotEmpty || syncStatus.pendingCount > 0;
    final isError = syncStatus.state == SyncHealthState.error;
    final isOffline = !syncStatus.isOnline;

    final heroBg = isError
        ? c.errorContainer
        : (hasPending || isOffline
            ? c.warningContainer
            : c.secondaryContainer);
    final heroBorder = isError
        ? c.error
        : (hasPending || isOffline ? c.warningBorder : c.primary);
    final heroFg = isError
        ? c.onErrorContainer
        : (hasPending || isOffline
            ? c.onWarningContainer
            : c.onSecondaryContainer);
    final heroIcon = isError
        ? Icons.cloud_off_rounded
        : (hasPending || isOffline
            ? Icons.cloud_upload_rounded
            : Icons.cloud_done_rounded);
    final heroTitle = isError
        ? 'Backup Needs Attention'
        : isOffline
            ? 'Offline — Saved on This Phone'
            : hasPending
                ? 'Backup & Updates Pending'
                : 'All Backed Up & Synced';
    final checkedTime = _lastCheckedAt ?? syncStatus.lastSyncedAt;
    final checkedText = checkedTime == null
        ? 'Last checked: Just now'
        : 'Last checked: ${_timeFmt.format(checkedTime.toLocal())}';

    return Scaffold(
      backgroundColor: c.surface,
      appBar: const PasalStackAppBar(
        title: 'Backup & Sync',
        subtitle: 'Cloud & Device Status',
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutterMobile,
          AppSpacing.gutterMobile,
          AppSpacing.gutterMobile,
          AppSpacing.xl,
        ),
        children: [
          // Overall Status Hero
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: heroBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: heroBorder.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                Icon(heroIcon, color: heroFg, size: 28),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        heroTitle,
                        style: t.titleMedium?.copyWith(color: heroFg),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        checkedText,
                        style: t.bodySmall?.copyWith(
                          color: heroFg.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // 1. Local Outbox (Phone -> Cloud)
          PasalCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'NOT BACKED UP YET (THIS PHONE)',
                        style: t.labelMedium,
                      ),
                    ),
                    PasalStatusBadge(
                      label: '${pendingRows.length} pending',
                      backgroundColor: pendingRows.isEmpty
                          ? c.secondaryContainer
                          : c.warningContainer,
                      foregroundColor: pendingRows.isEmpty
                          ? c.onSecondaryContainer
                          : c.onWarningContainer,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                if (pendingRows.isEmpty)
                  Text(
                    'Everything on this phone is safely backed up.',
                    style: t.bodySmall,
                  )
                else
                  ...pendingRows.take(15).map((row) {
                    final isFailed = row.status.toUpperCase() == 'FAILED';
                    return Container(
                      margin: const EdgeInsets.only(bottom: AppSpacing.xs),
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: AppSpacing.xs,
                      ),
                      decoration: BoxDecoration(
                        color: c.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${_friendlyRowTitle(row)} • ${_timeFmt.format(row.createdAt.toLocal())}',
                              style: t.bodySmall?.copyWith(
                                color: c.onSurface,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            isFailed ? 'Retry Needed' : 'Waiting',
                            style: t.labelSmall?.copyWith(
                              color: isFailed ? c.error : c.onWarningContainer,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // 2. Server Updates (Cloud -> Phone)
          PasalCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('WAITING FROM SERVER', style: t.labelMedium),
                    ),
                    PasalStatusBadge(
                      label: syncStatus.isOnline
                          ? (syncStatus.sseConnected ? 'Live' : 'Connected')
                          : 'Offline',
                      backgroundColor: syncStatus.isOnline
                          ? c.secondaryContainer
                          : c.surfaceContainerHigh,
                      foregroundColor: syncStatus.isOnline
                          ? c.onSecondaryContainer
                          : c.onSurfaceVariant,
                      dotColor: syncStatus.isOnline ? c.primary : c.outline,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: c.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          syncStatus.isOnline
                              ? 'Shop cloud is reachable for updates'
                              : 'Waiting for internet to check shop updates',
                          style: t.bodySmall,
                        ),
                      ),
                      Text(
                        syncStatus.isOnline ? 'Ready' : 'Offline',
                        style: t.labelSmall?.copyWith(
                          color: syncStatus.isOnline ? c.primary : c.outline,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // Action Buttons
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: _syncing ? null : _checkStatus,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Check Status'),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _syncing ? null : _runBackupAndSync,
              icon: const Icon(Icons.cloud_sync_rounded, size: 20),
              label: Text(_syncing ? 'Syncing...' : 'Backup & Sync Now'),
            ),
          ),
        ],
      ),
    );
  }
}
