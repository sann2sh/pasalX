import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/auth_models.dart';
import '../../../core/printer/printer_config.dart';
import '../../../core/printer/printer_providers.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/router/shell_scaffold.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../../auth/application/auth_session_controller.dart';

/// Screen 18: Decluttered Settings Hub (Shop Profile, Printer & Backup links,
/// Business Books, Owner-only Staff Phone Access, and Lock / Log Out).
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  List<RegisteredDevice> _devices = const <RegisteredDevice>[];
  bool _devicesLoading = false;
  String? _devicesError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final role = ref.read(ramKeyHolderProvider).session?.role;
      if (role == 'OWNER') {
        _loadDevices();
      }
    });
  }

  Future<void> _loadDevices() async {
    final token = ref.read(activeAccessTokenProvider);
    if (token == null || token.isEmpty) {
      setState(() => _devicesError = 'Connect to internet to view staff phones.');
      return;
    }
    setState(() {
      _devicesLoading = true;
      _devicesError = null;
    });
    try {
      final list =
          await ref.read(pasalApiClientProvider).listDevices(accessToken: token);
      if (!mounted) return;
      setState(() {
        _devices = list;
        _devicesLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _devicesLoading = false;
        _devicesError = 'Could not load staff phones right now.';
      });
    }
  }

  Future<void> _showEditShopProfileDialog() async {
    final cfg = ref.read(printerConfigProvider);
    final result = await showDialog<({String name, String pan, String phone})>(
      context: context,
      builder: (ctx) => _EditShopProfileDialog(
        initialName: cfg.storeName,
        initialPan: cfg.storePan,
        initialPhone: cfg.storePhone,
      ),
    );

    if (result != null && mounted) {
      final storeName = result.name.trim().isEmpty
          ? 'Pasal Cosmetics'
          : result.name.trim();
      ref.read(printerConfigProvider.notifier).updateConfig(
            cfg.copyWith(
              storeName: storeName,
              storePan: result.pan.trim(),
              storePhone: result.phone.trim(),
            ),
          );
      ref.read(pasalAlertProvider).showSuccess('Shop profile updated.');
    }
  }

  Future<void> _confirmRevokeDevice(RegisteredDevice device) async {
    final currentCode = ref.read(ramKeyHolderProvider).session?.deviceCode;
    final isSelf = currentCode != null && device.code == currentCode;
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => _RevokeDeviceDialog(
        device: device,
        isSelf: isSelf,
        currentCode: currentCode,
      ),
    );
    if (reason == null) return;

    final token = ref.read(activeAccessTokenProvider);
    if (token == null || token.isEmpty) return;

    try {
      await ref.read(pasalApiClientProvider).revokeDevice(
            accessToken: token,
            deviceId: device.id,
            reason: reason.isEmpty ? 'Revoked by owner' : reason,
          );
      if (mounted) {
        ref
            .read(pasalAlertProvider)
            .showSuccess('Access revoked for ${device.name}.');
      }
      await _loadDevices();
    } catch (_) {
      if (mounted) {
        ref
            .read(pasalAlertProvider)
            .showError('Could not revoke phone right now.');
      }
    }
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return 'PX';
    if (parts.length == 1) return parts[0].substring(0, parts[0].length >= 2 ? 2 : 1).toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  String _roleLabel(String? role) {
    return switch (role) {
      'OWNER' => 'Owner',
      'MANAGER' => 'Manager',
      'STAFF' => 'Cashier',
      _ => 'Locked',
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final keyHolder = ref.watch(ramKeyHolderProvider);
    final syncWorker = ref.watch(syncOutboxWorkerProvider);
    final syncStatus = syncWorker.status;
    final authCtrl = ref.watch(authSessionControllerProvider);
    final printerCfg = ref.watch(printerConfigProvider);

    final session = keyHolder.session;
    final isOwner = session?.role == 'OWNER';
    final isManagerOrOwner =
        session != null && (session.role == 'OWNER' || session.role == 'MANAGER');

    final printerSummary =
        '${printerCfg.host}:${printerCfg.port} • ${printerCfg.preferredMode == PrinterMode.receipt ? 'Receipt Mode (80mm)' : 'Label Mode (62×20mm)'}';
    final backupSummary = !syncStatus.isOnline
        ? 'Offline • ${syncStatus.pendingCount} saved locally'
        : syncStatus.pendingCount > 0
            ? '${syncStatus.pendingCount} waiting to back up'
            : 'All backed up & synced';

    return Scaffold(
      backgroundColor: c.surface,
      appBar: const PasalStackAppBar(
        title: 'Settings',
        subtitle: 'Shop · Printer · Backup',
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutterMobile,
          AppSpacing.gutterMobile,
          AppSpacing.gutterMobile,
          AppSpacing.xl,
        ),
        children: [
          // 1. Shop Profile Card
          PasalCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: c.primary,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        _initials(printerCfg.storeName),
                        style: t.titleMedium?.copyWith(color: c.onPrimary),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  printerCfg.storeName,
                                  style: t.titleMedium,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              PasalStatusBadge(
                                label: _roleLabel(session?.role),
                                backgroundColor: c.secondaryContainer,
                                foregroundColor: c.onSecondaryContainer,
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          PasalTabularText(
                            [
                              if (printerCfg.storePhone.isNotEmpty)
                                printerCfg.storePhone,
                              if (printerCfg.storePan.isNotEmpty)
                                'PAN: ${printerCfg.storePan}',
                              if (printerCfg.storePhone.isEmpty &&
                                  printerCfg.storePan.isEmpty)
                                session?.username ?? 'Not signed in',
                            ].join(' • '),
                            style: t.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (isManagerOrOwner) ...[
                  const SizedBox(height: AppSpacing.sm),
                  const Divider(height: 1),
                  _SettingsNavRow(
                    icon: Icons.storefront_outlined,
                    title: 'Shop Profile & PAN Receipt Header',
                    onTap: _showEditShopProfileDialog,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // 2. Devices & Shop Backup (Dedicated Pages)
          PasalCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('DEVICES & SHOP BACKUP', style: t.labelMedium),
                const SizedBox(height: AppSpacing.xs),
                _SettingsNavRow(
                  icon: Icons.print_rounded,
                  title: 'Printer Settings',
                  subtitle: printerSummary,
                  onTap: () => context.push(AppRoutes.settingsPrinter),
                ),
                const Divider(height: 1),
                _SettingsNavRow(
                  icon: Icons.cloud_sync_rounded,
                  title: 'Backup & Sync',
                  subtitle: backupSummary,
                  subtitleColor: syncStatus.pendingCount > 0
                      ? c.onWarningContainer
                      : null,
                  onTap: () => context.push(AppRoutes.settingsBackup),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // 3. Business Books & Records
          PasalCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('BUSINESS BOOKS & RECORDS', style: t.labelMedium),
                const SizedBox(height: AppSpacing.xs),
                _SettingsNavRow(
                  icon: Icons.menu_book_rounded,
                  title: 'Customer Khata Book',
                  onTap: () => context.push(AppRoutes.khata),
                ),
                if (isManagerOrOwner) ...[
                  const Divider(height: 1),
                  _SettingsNavRow(
                    icon: Icons.local_shipping_outlined,
                    title: 'Suppliers & Bills',
                    onTap: () => context.push(AppRoutes.suppliers),
                  ),
                ],
                const Divider(height: 1),
                _SettingsNavRow(
                  icon: Icons.receipt_long_rounded,
                  title: 'Past Bills & Expenses',
                  onTap: () => context.go(AppRoutes.history),
                ),
              ],
            ),
          ),

          // 4. Owner-only Staff Phone Access
          if (isOwner) ...[
            const SizedBox(height: AppSpacing.md),
            PasalCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.phonelink_lock_rounded, size: 18, color: c.error),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text('STAFF PHONE ACCESS', style: t.labelMedium),
                      ),
                      IconButton(
                        tooltip: 'Refresh Phones',
                        onPressed: _devicesLoading ? null : _loadDevices,
                        icon: const Icon(Icons.refresh_rounded, size: 20),
                      ),
                    ],
                  ),
                  if (_devicesLoading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                      child: LinearProgressIndicator(),
                    )
                  else if (_devicesError != null)
                    Text(
                      _devicesError!,
                      style: t.bodySmall?.copyWith(color: c.error),
                    )
                  else if (_devices.isEmpty)
                    Text(
                      'No staff phones loaded. Tap refresh while online.',
                      style: t.bodySmall,
                    )
                  else
                    ..._devices.map((d) {
                      final isRevoked = d.status.toUpperCase() == 'REVOKED';
                      final isCurrent = d.code == session?.deviceCode;
                      return Container(
                        margin: const EdgeInsets.only(top: AppSpacing.xs),
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
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${d.name}${isCurrent ? ' (This Phone)' : ''}',
                                    style: t.titleSmall,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    [
                                      d.code,
                                      if (d.currentUserName != null)
                                        d.currentUserName!,
                                    ].join(' • '),
                                    style: t.bodySmall,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            if (isRevoked)
                              PasalStatusBadge(
                                label: 'Revoked',
                                backgroundColor: c.errorContainer,
                                foregroundColor: c.onErrorContainer,
                              )
                            else
                              FilledButton.tonal(
                                style: FilledButton.styleFrom(
                                  backgroundColor: c.errorContainer,
                                  foregroundColor: c.onErrorContainer,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  minimumSize: Size.zero,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                                onPressed: () => _confirmRevokeDevice(d),
                                child: const Text('Revoke'),
                              ),
                          ],
                        ),
                      );
                    }),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md),

          // 5. Lock Screen / Log Out
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: authCtrl.state.session != null
                      ? () => ref.read(authSessionControllerProvider).logout()
                      : null,
                  icon: Icon(Icons.lock_outline_rounded, size: 18, color: c.primary),
                  label: const Text('Lock Screen'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    backgroundColor: c.errorContainer,
                    foregroundColor: c.onErrorContainer,
                  ),
                  onPressed: authCtrl.state.session != null
                      ? () => ref.read(authSessionControllerProvider).logout()
                      : null,
                  icon: const Icon(Icons.logout_rounded, size: 18),
                  label: const Text('Log Out'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsNavRow extends StatelessWidget {
  const _SettingsNavRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.subtitleColor,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: c.surfaceContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 19, color: c.primary),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: t.titleSmall),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: t.bodySmall?.copyWith(color: subtitleColor),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: c.outline, size: 20),
          ],
        ),
      ),
    );
  }
}

class _EditShopProfileDialog extends StatefulWidget {
  const _EditShopProfileDialog({
    required this.initialName,
    required this.initialPan,
    required this.initialPhone,
  });

  final String initialName;
  final String initialPan;
  final String initialPhone;

  @override
  State<_EditShopProfileDialog> createState() => _EditShopProfileDialogState();
}

class _EditShopProfileDialogState extends State<_EditShopProfileDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _panCtrl;
  late final TextEditingController _phoneCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initialName);
    _panCtrl = TextEditingController(text: widget.initialPan);
    _phoneCtrl = TextEditingController(text: widget.initialPhone);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _panCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Shop Profile & PAN Header'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Shop Name'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _panCtrl,
              decoration: const InputDecoration(
                labelText: 'Shop PAN No.',
                hintText: 'Optional',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Shop Phone',
                hintText: '+977 98...',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((
            name: _nameCtrl.text,
            pan: _panCtrl.text,
            phone: _phoneCtrl.text,
          )),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _RevokeDeviceDialog extends StatefulWidget {
  const _RevokeDeviceDialog({
    required this.device,
    required this.isSelf,
    required this.currentCode,
  });

  final RegisteredDevice device;
  final bool isSelf;
  final String? currentCode;

  @override
  State<_RevokeDeviceDialog> createState() => _RevokeDeviceDialogState();
}

class _RevokeDeviceDialogState extends State<_RevokeDeviceDialog> {
  final _reasonCtrl = TextEditingController(text: 'Revoked by Store Owner');

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    return AlertDialog(
      title: Text('Revoke Access for ${widget.device.name}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.isSelf) ...[
            Text(
              'This is your current phone (${widget.currentCode}). Revoking it will sign you out immediately.',
              style: TextStyle(color: c.error, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
          Text(
            '"${widget.device.name}" (${widget.device.code}) will be signed out and blocked from accessing shop data.',
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _reasonCtrl,
            decoration: const InputDecoration(labelText: 'Note (Optional)'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: c.error),
          onPressed: () => Navigator.of(context).pop(_reasonCtrl.text.trim()),
          child: const Text('Revoke Access'),
        ),
      ],
    );
  }
}
