import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../application/auth_session_controller.dart';

/// Store onboarding screen (`storeSetupRequired`):
/// Create a new store (Owner) or Join an existing store with an Invite Code.
class StoreSetupScreen extends ConsumerStatefulWidget {
  const StoreSetupScreen({super.key});

  @override
  ConsumerState<StoreSetupScreen> createState() => _StoreSetupScreenState();
}

class _StoreSetupScreenState extends ConsumerState<StoreSetupScreen> {
  bool _joinMode = false;
  final _storeNameCtrl = TextEditingController();
  final _panCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _inviteCodeCtrl = TextEditingController();
  final _deviceNameCtrl = TextEditingController(text: 'Counter Phone');

  @override
  void dispose() {
    _storeNameCtrl.dispose();
    _panCtrl.dispose();
    _phoneCtrl.dispose();
    _addressCtrl.dispose();
    _inviteCodeCtrl.dispose();
    _deviceNameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final authCtrl = ref.watch(authSessionControllerProvider);
    final s = authCtrl.state;
    final membership = s.accountSession?.membership;

    return Scaffold(
      backgroundColor: c.surface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.gutterMobile),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Set Up Your Store', style: t.headlineSmall),
                            if (s.accountSession != null)
                              Text(
                                'Signed in as ${s.accountSession!.name}',
                                style: t.bodySmall,
                              ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: s.busy ? null : authCtrl.signOutAccount,
                        child: const Text('Sign Out'),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (s.errorMessage != null) ...[
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      decoration: BoxDecoration(
                        color: c.errorContainer,
                        borderRadius: BorderRadius.circular(AppRadii.md),
                      ),
                      child: Text(
                        s.errorMessage!,
                        style: t.bodySmall?.copyWith(color: c.onErrorContainer),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  if (membership != null) ...[
                    PasalCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Enroll This Phone',
                            style: t.titleMedium,
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            'Your account is a ${membership.role} of ${membership.storeName}. Name this phone to enroll it.',
                            style: t.bodySmall,
                          ),
                          const SizedBox(height: AppSpacing.md),
                          TextField(
                            controller: _deviceNameCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Phone Name',
                              hintText: 'e.g. Counter Phone 02',
                            ),
                          ),
                          const SizedBox(height: AppSpacing.md),
                          FilledButton(
                            onPressed: s.busy
                                ? null
                                : () => authCtrl.enrollExistingStoreDevice(
                                      deviceName: _deviceNameCtrl.text,
                                    ),
                            child: s.busy
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('Enroll This Phone'),
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment<bool>(
                          value: false,
                          label: Text('Create Store'),
                          icon: Icon(Icons.storefront_outlined, size: 18),
                        ),
                        ButtonSegment<bool>(
                          value: true,
                          label: Text('Join with Code'),
                          icon: Icon(Icons.vpn_key_outlined, size: 18),
                        ),
                      ],
                      selected: <bool>{_joinMode},
                      onSelectionChanged: s.busy
                          ? null
                          : (sel) => setState(() => _joinMode = sel.first),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    PasalCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!_joinMode) ...[
                            TextField(
                              controller: _storeNameCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Store Name *',
                                hintText: 'e.g. Himalayan Glow Cosmetics',
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            TextField(
                              controller: _panCtrl,
                              decoration: const InputDecoration(
                                labelText: 'PAN / VAT Number (optional)',
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            TextField(
                              controller: _phoneCtrl,
                              keyboardType: TextInputType.phone,
                              decoration: const InputDecoration(
                                labelText: 'Store Phone (optional)',
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            TextField(
                              controller: _addressCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Store Address (optional)',
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            TextField(
                              controller: _deviceNameCtrl,
                              decoration: const InputDecoration(
                                labelText: 'This Phone Name *',
                                hintText: 'e.g. Main Counter',
                              ),
                            ),
                            const SizedBox(height: AppSpacing.md),
                            FilledButton(
                              onPressed: s.busy
                                  ? null
                                  : () => authCtrl.createStoreAndEnroll(
                                        storeName: _storeNameCtrl.text,
                                        panNumber: _panCtrl.text,
                                        phone: _phoneCtrl.text,
                                        address: _addressCtrl.text,
                                        deviceName: _deviceNameCtrl.text,
                                      ),
                              child: s.busy
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text('Create Store & Start'),
                            ),
                          ] else ...[
                            TextField(
                              controller: _inviteCodeCtrl,
                              textCapitalization: TextCapitalization.characters,
                              decoration: const InputDecoration(
                                labelText: 'Invite Code *',
                                hintText: 'PSX-XXXXX-XXXXX',
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            TextField(
                              controller: _deviceNameCtrl,
                              decoration: const InputDecoration(
                                labelText: 'This Phone Name *',
                                hintText: 'e.g. Staff Phone',
                              ),
                            ),
                            const SizedBox(height: AppSpacing.md),
                            FilledButton(
                              onPressed: s.busy
                                  ? null
                                  : () => authCtrl.acceptInvitationCode(
                                        code: _inviteCodeCtrl.text,
                                        deviceName: _deviceNameCtrl.text,
                                      ),
                              child: s.busy
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text('Join Store'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

