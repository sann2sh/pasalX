import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../application/auth_session_controller.dart';

/// Pending / Rejected device approval waiting screen
/// (`deviceApprovalPending` and `deviceRejected`).
class DeviceApprovalPendingScreen extends ConsumerStatefulWidget {
  const DeviceApprovalPendingScreen({super.key});

  @override
  ConsumerState<DeviceApprovalPendingScreen> createState() =>
      _DeviceApprovalPendingScreenState();
}

class _DeviceApprovalPendingScreenState
    extends ConsumerState<DeviceApprovalPendingScreen> {
  Timer? _pollTimer;
  int _pollIntervalSeconds = 3;

  @override
  void initState() {
    super.initState();
    _scheduleNextPoll();
  }

  void _scheduleNextPoll() {
    _pollTimer?.cancel();
    final stage = ref.read(authSessionControllerProvider).state.stage;
    if (stage != AuthGateStage.deviceApprovalPending) return;
    _pollTimer = Timer(Duration(seconds: _pollIntervalSeconds), () async {
      if (!mounted) return;
      await ref
          .read(authSessionControllerProvider)
          .checkPendingDeviceStatus();
      if (!mounted) return;
      // Backoff: 3s -> 5s -> 10s
      if (_pollIntervalSeconds < 5) {
        _pollIntervalSeconds = 5;
      } else if (_pollIntervalSeconds < 10) {
        _pollIntervalSeconds = 10;
      }
      _scheduleNextPoll();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final authCtrl = ref.watch(authSessionControllerProvider);
    final s = authCtrl.state;
    final pending = s.pendingEnrollment;
    final isRejected = s.stage == AuthGateStage.deviceRejected;

    return Scaffold(
      backgroundColor: c.surface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.gutterMobile),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: PasalCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      isRejected
                          ? Icons.block_rounded
                          : Icons.hourglass_top_rounded,
                      size: 44,
                      color: isRejected ? c.error : c.primary,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      isRejected
                          ? 'Device Request Rejected'
                          : 'Waiting for Owner Approval',
                      style: t.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      isRejected
                          ? (pending?.revocationReason ??
                              'The store owner rejected this device request.')
                          : 'Ask the store owner to open Settings → Team & Devices and approve "${pending?.deviceName ?? 'this phone'}".',
                      style: t.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                    if (pending != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      Container(
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        decoration: BoxDecoration(
                          color: c.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(AppRadii.md),
                          border: Border.all(color: c.hairline),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              pending.storeName,
                              style: t.titleSmall,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${pending.deviceName} • Role: ${pending.role}',
                              style: t.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    if (!isRejected) ...[
                      FilledButton.icon(
                        onPressed: s.busy
                            ? null
                            : () => authCtrl.checkPendingDeviceStatus(),
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Check Status Now'),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                    ],
                    OutlinedButton(
                      onPressed:
                          s.busy ? null : authCtrl.cancelPendingEnrollment,
                      child: Text(
                        isRejected ? 'Back to Store Setup' : 'Cancel Request',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

