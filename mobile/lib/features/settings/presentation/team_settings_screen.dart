import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exceptions.dart';
import '../../../core/network/auth_models.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../../core/router/shell_scaffold.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../../auth/application/auth_session_controller.dart';

/// Owner-only Team, Invitations, Device Approvals & Store Danger Zone screen.
class TeamSettingsScreen extends ConsumerStatefulWidget {
  const TeamSettingsScreen({super.key});

  @override
  ConsumerState<TeamSettingsScreen> createState() => _TeamSettingsScreenState();
}

class _TeamSettingsScreenState extends ConsumerState<TeamSettingsScreen> {
  bool _loading = true;
  String? _error;

  List<RegisteredDevice> _pendingDevices = const [];
  List<InvitationInfo> _invitations = const [];
  List<MemberInfo> _members = const [];

  String _inviteRole = 'STAFF';
  final _inviteEmailCtrl = TextEditingController();
  InvitationInfo? _justCreatedInvite;
  bool _creatingInvite = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  @override
  void dispose() {
    _inviteEmailCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    final token = ref.read(activeAccessTokenProvider);
    if (token == null || token.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'Connect to the internet to manage your team.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final api = ref.read(pasalApiClientProvider);
      final results = await Future.wait([
        api.listStoreDevices(accessToken: token, status: 'PENDING'),
        api.listInvitations(accessToken: token),
        api.listMembers(accessToken: token),
      ]);
      if (!mounted) return;
      setState(() {
        _pendingDevices = results[0] as List<RegisteredDevice>;
        _invitations = results[1] as List<InvitationInfo>;
        _members = results[2] as List<MemberInfo>;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Failed to load team data: $e';
      });
    }
  }

  Future<void> _createInvite() async {
    final token = ref.read(activeAccessTokenProvider);
    if (token == null || token.isEmpty) return;

    setState(() => _creatingInvite = true);
    try {
      final email = _inviteEmailCtrl.text.trim();
      final inv = await ref.read(pasalApiClientProvider).createInvitation(
            accessToken: token,
            role: _inviteRole,
            invitedEmail: email.isEmpty ? null : email,
            sendEmail: email.isNotEmpty,
          );
      if (!mounted) return;
      _inviteEmailCtrl.clear();
      setState(() {
        _justCreatedInvite = inv;
        _creatingInvite = false;
      });
      await _loadAll();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _creatingInvite = false);
      ref.read(pasalAlertProvider).showError(e.message);
    }
  }

  Future<void> _approveDevice(RegisteredDevice device) async {
    final token = ref.read(activeAccessTokenProvider);
    if (token == null || token.isEmpty) return;
    try {
      await ref
          .read(pasalApiClientProvider)
          .approveDevice(accessToken: token, deviceId: device.id);
      if (!mounted) return;
      ref.read(pasalAlertProvider).showSuccess('Approved ${device.name}.');
      await _loadAll();
    } on ApiException catch (e) {
      if (!mounted) return;
      ref.read(pasalAlertProvider).showError(e.message);
    }
  }

  Future<void> _rejectDevice(RegisteredDevice device) async {
    final token = ref.read(activeAccessTokenProvider);
    if (token == null || token.isEmpty) return;
    try {
      await ref.read(pasalApiClientProvider).rejectDevice(
            accessToken: token,
            deviceId: device.id,
            reason: 'Rejected by store owner',
          );
      if (!mounted) return;
      ref.read(pasalAlertProvider).showSuccess('Rejected ${device.name}.');
      await _loadAll();
    } on ApiException catch (e) {
      if (!mounted) return;
      ref.read(pasalAlertProvider).showError(e.message);
    }
  }

  Future<void> _revokeInvite(InvitationInfo inv) async {
    final token = ref.read(activeAccessTokenProvider);
    if (token == null || token.isEmpty) return;
    try {
      await ref
          .read(pasalApiClientProvider)
          .revokeInvitation(accessToken: token, invitationId: inv.id);
      if (!mounted) return;
      ref.read(pasalAlertProvider).showSuccess('Invitation revoked.');
      await _loadAll();
    } on ApiException catch (e) {
      if (!mounted) return;
      ref.read(pasalAlertProvider).showError(e.message);
    }
  }

  Future<void> _changeMemberRole(MemberInfo member, String newRole) async {
    final token = ref.read(activeAccessTokenProvider);
    if (token == null || token.isEmpty) return;
    try {
      await ref.read(pasalApiClientProvider).updateMemberRole(
            accessToken: token,
            userId: member.userId,
            role: newRole,
          );
      if (!mounted) return;
      ref
          .read(pasalAlertProvider)
          .showSuccess('${member.name} is now $newRole.');
      await _loadAll();
    } on ApiException catch (e) {
      if (!mounted) return;
      ref.read(pasalAlertProvider).showError(e.message);
    }
  }

  Future<void> _promptResetPin(MemberInfo member) async {
    final pinCtrl = TextEditingController();
    final newPin = await showPasalDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reset PIN for ${member.name}'),
        content: TextField(
          controller: pinCtrl,
          keyboardType: TextInputType.number,
          obscureText: true,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'New 6-Digit PIN',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, pinCtrl.text.trim()),
            child: const Text('Reset PIN'),
          ),
        ],
      ),
    );
    pinCtrl.dispose();
    if (newPin == null || newPin.isEmpty) return;

    final token = ref.read(activeAccessTokenProvider);
    if (token == null || token.isEmpty) return;
    try {
      await ref.read(pasalApiClientProvider).resetMemberPin(
            accessToken: token,
            userId: member.userId,
            newPin: newPin,
          );
      if (!mounted) return;
      ref
          .read(pasalAlertProvider)
          .showSuccess('PIN reset for ${member.name}.');
    } on ApiException catch (e) {
      if (!mounted) return;
      ref.read(pasalAlertProvider).showError(e.message);
    }
  }

  Future<void> _confirmRemoveMember(MemberInfo member) async {
    final confirmed = await showPasalDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${member.name}?'),
        content: const Text(
          'Removing this member will immediately force punch-out any active shift on their phones and revoke their devices.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove Member'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final token = ref.read(activeAccessTokenProvider);
    if (token == null || token.isEmpty) return;
    try {
      await ref
          .read(pasalApiClientProvider)
          .removeMember(accessToken: token, userId: member.userId);
      if (!mounted) return;
      ref.read(pasalAlertProvider).showSuccess('${member.name} removed.');
      await _loadAll();
    } on ApiException catch (e) {
      if (!mounted) return;
      ref.read(pasalAlertProvider).showError(e.message);
    }
  }

  Future<void> _promptTransferOwnership() async {
    final candidates =
        _members.where((m) => m.role != 'OWNER' && m.status == 'ACTIVE').toList();
    if (candidates.isEmpty) {
      ref
          .read(pasalAlertProvider)
          .showError('No other active team members to transfer ownership to.');
      return;
    }

    String selectedUserId = candidates.first.userId;
    final passCtrl = TextEditingController();
    final result = await showPasalDialog<({String userId, String password})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: const Text('Transfer Store Ownership'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: selectedUserId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'New Owner'),
                items: candidates
                    .map(
                      (m) => DropdownMenuItem(
                        value: m.userId,
                        child: Text(
                          '${m.name} (@${m.username})',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v != null) setDlgState(() => selectedUserId = v);
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: passCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Your Password'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                ctx,
                (userId: selectedUserId, password: passCtrl.text),
              ),
              child: const Text('Transfer'),
            ),
          ],
        ),
      ),
    );
    passCtrl.dispose();
    if (result == null || result.password.isEmpty) return;

    final token = ref.read(activeAccessTokenProvider);
    if (token == null || token.isEmpty) return;
    try {
      await ref.read(pasalApiClientProvider).transferOwnership(
            accessToken: token,
            targetUserId: result.userId,
            password: result.password,
          );
      if (!mounted) return;
      ref
          .read(pasalAlertProvider)
          .showSuccess('Ownership transferred. Signing out...');
      await ref.read(authSessionControllerProvider).logout();
    } on ApiException catch (e) {
      if (!mounted) return;
      ref.read(pasalAlertProvider).showError(e.message);
    }
  }

  Future<void> _exportStore() async {
    final token = ref.read(activeAccessTokenProvider);
    if (token == null || token.isEmpty) return;
    try {
      final data =
          await ref.read(pasalApiClientProvider).exportStore(accessToken: token);
      final encoded = const JsonEncoder.withIndent('  ').convert(data);
      await Clipboard.setData(ClipboardData(text: encoded));
      if (!mounted) return;
      ref.read(pasalAlertProvider).showSuccess(
            'Store export (${encoded.length} bytes JSON) copied to clipboard.',
          );
    } on ApiException catch (e) {
      if (!mounted) return;
      ref.read(pasalAlertProvider).showError(e.message);
    }
  }

  Future<void> _promptCloseStore() async {
    final passCtrl = TextEditingController();
    final password = await showPasalDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Close Store Permanently?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Closing the store revokes all phones immediately and schedules store data for permanent purge after 30 days.',
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: passCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Your Password'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, passCtrl.text),
            child: const Text('Close Store'),
          ),
        ],
      ),
    );
    passCtrl.dispose();
    if (password == null || password.isEmpty) return;

    final token = ref.read(activeAccessTokenProvider);
    if (token == null || token.isEmpty) return;
    try {
      await ref
          .read(pasalApiClientProvider)
          .closeStore(accessToken: token, password: password);
      if (!mounted) return;
      await ref.read(authSessionControllerProvider).resetRevokedEnrollment();
    } on ApiException catch (e) {
      if (!mounted) return;
      ref.read(pasalAlertProvider).showError(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;

    return Scaffold(
      backgroundColor: c.surface,
      appBar: const PasalStackAppBar(
        title: 'Team & Devices',
        subtitle: 'Invites · Approvals · Roles',
      ),
      body: RefreshIndicator(
        onRefresh: _loadAll,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.gutterMobile),
          children: [
            if (_error != null) ...[
              PasalCard(
                color: c.errorContainer,
                child: Text(
                  _error!,
                  style: t.bodySmall?.copyWith(color: c.onErrorContainer),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              if (_pendingDevices.isNotEmpty) ...[
                Text('Pending Phone Approvals', style: t.titleMedium),
                const SizedBox(height: AppSpacing.xs),
                ..._pendingDevices.map(
                  (d) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                    child: PasalCard(
                      borderColor: c.primary,
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(d.name, style: t.titleSmall),
                                Text(
                                  '${d.platform} • Waiting for approval',
                                  style: t.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          TextButton(
                            onPressed: () => _rejectDevice(d),
                            child: Text(
                              'Reject',
                              style: TextStyle(color: c.error),
                            ),
                          ),
                          FilledButton(
                            onPressed: () => _approveDevice(d),
                            child: const Text('Approve'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
              ],

              Text('Invite Team Member', style: t.titleMedium),
              const SizedBox(height: AppSpacing.xs),
              PasalCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PasalClipSegmentedTabs<String>(
                      selectedValue: _inviteRole,
                      activePillColor: c.primary,
                      activeForegroundColor: c.onPrimary,
                      onChanged: (role) => setState(() => _inviteRole = role),
                      options: const [
                        PasalSegmentOption<String>(
                          value: 'STAFF',
                          label: 'Cashier',
                        ),
                        PasalSegmentOption<String>(
                          value: 'MANAGER',
                          label: 'Manager',
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextField(
                      controller: _inviteEmailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'Staff Email (optional)',
                        hintText: 'Locks invite to this email if provided',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    FilledButton.icon(
                      onPressed: _creatingInvite ? null : _createInvite,
                      icon: const Icon(Icons.person_add_outlined, size: 18),
                      label: const Text('Generate Invite Code'),
                    ),
                    if (_justCreatedInvite?.code != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Container(
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        decoration: BoxDecoration(
                          color: c.secondaryContainer,
                          borderRadius: BorderRadius.circular(AppRadii.md),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Share once (48h expiry):',
                                    style: t.labelSmall,
                                  ),
                                  SelectableText(
                                    _justCreatedInvite!.code!,
                                    style: t.titleMedium?.copyWith(
                                      letterSpacing: 1.2,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: () {
                                Clipboard.setData(
                                  ClipboardData(
                                    text: _justCreatedInvite!.code!,
                                  ),
                                );
                                ref
                                    .read(pasalAlertProvider)
                                    .showSuccess('Invite code copied.');
                              },
                              icon: const Icon(Icons.copy_rounded),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),

              if (_invitations.isNotEmpty) ...[
                Text('Pending Invitations', style: t.titleMedium),
                const SizedBox(height: AppSpacing.xs),
                ..._invitations.map(
                  (inv) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                    child: PasalCard(
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${inv.role} Invite',
                                  style: t.titleSmall,
                                ),
                                Text(
                                  inv.invitedEmail ?? 'Anyone with code',
                                  style: t.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          TextButton(
                            onPressed: () => _revokeInvite(inv),
                            child: Text(
                              'Revoke',
                              style: TextStyle(color: c.error),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
              ],

              Text('Team Members (${_members.length})', style: t.titleMedium),
              const SizedBox(height: AppSpacing.xs),
              ..._members.map(
                (m) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: PasalCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(m.name, style: t.titleSmall),
                                  Text('@${m.username}', style: t.bodySmall),
                                ],
                              ),
                            ),
                            PasalStatusBadge(
                              label: m.role,
                              backgroundColor: c.secondaryContainer,
                              foregroundColor: c.onSecondaryContainer,
                            ),
                          ],
                        ),
                        if (m.role != 'OWNER') ...[
                          const SizedBox(height: AppSpacing.xs),
                          Wrap(
                            spacing: AppSpacing.xs,
                            children: [
                              ActionChip(
                                label: Text(
                                  m.role == 'MANAGER'
                                      ? 'Make Cashier'
                                      : 'Make Manager',
                                ),
                                onPressed: () => _changeMemberRole(
                                  m,
                                  m.role == 'MANAGER' ? 'STAFF' : 'MANAGER',
                                ),
                              ),
                              ActionChip(
                                label: const Text('Reset PIN'),
                                onPressed: () => _promptResetPin(m),
                              ),
                              ActionChip(
                                label: Text(
                                  'Remove',
                                  style: TextStyle(color: c.error),
                                ),
                                onPressed: () => _confirmRemoveMember(m),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),

              Text('Owner Danger Zone', style: t.titleMedium),
              const SizedBox(height: AppSpacing.xs),
              PasalCard(
                borderColor: c.error.withValues(alpha: 0.4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _exportStore,
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: const Text('Export Store Data (JSON)'),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    OutlinedButton.icon(
                      onPressed: _promptTransferOwnership,
                      icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                      label: const Text('Transfer Store Ownership'),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    PasalHoldToConfirmButton(
                      label: 'Hold to Close Store',
                      holdingLabel: 'Keep holding to confirm...',
                      icon: Icons.delete_forever_outlined,
                      onConfirmed: _promptCloseStore,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

