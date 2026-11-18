import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/foundation_providers.dart';
import '../../../core/router/shell_scaffold.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../../auth/application/auth_session_controller.dart';

/// Account & Permanent Account Deletion screen (Google Play compliant).
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() =>
      _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final authCtrl = ref.watch(authSessionControllerProvider);
    final s = authCtrl.state;
    final role = ref.watch(ramKeyHolderProvider).session?.role;
    final isOwner = role == 'OWNER';
    final hasCachedAccountToken =
        s.accountSession != null && !s.accountSession!.isExpired;

    return Scaffold(
      backgroundColor: c.surface,
      appBar: const PasalStackAppBar(
        title: 'Account & Deletion',
        subtitle: 'Permanent Account Removal',
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.gutterMobile),
        children: [
          PasalCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Delete Your PasalX Account', style: t.titleMedium),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Your name, email, username, phone number, password hash, and PIN hash will be permanently anonymized and all active device sessions will be revoked.',
                  style: t.bodySmall,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Store sales, tax invoices, and accounting ledger entries remain with the store for statutory bookkeeping.',
                  style: t.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (isOwner)
            PasalCard(
              color: c.errorContainer,
              child: Text(
                'You are currently the Store Owner. Before deleting your account, go to Settings → Team & Devices → Owner Danger Zone and either Transfer Ownership to another team member or Close Store.',
                style: t.bodySmall?.copyWith(color: c.onErrorContainer),
              ),
            )
          else
            PasalCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (s.errorMessage != null) ...[
                    Text(
                      s.errorMessage!,
                      style: t.bodySmall?.copyWith(color: c.error),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  if (!hasCachedAccountToken) ...[
                    TextField(
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'Account Email',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  TextField(
                    controller: _passwordCtrl,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      labelText: 'Confirm Password',
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => _obscure = !_obscure),
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: c.error,
                      foregroundColor: c.onError,
                    ),
                    onPressed: s.busy
                        ? null
                        : () => authCtrl.deleteAccountWithPassword(
                              email: _emailCtrl.text,
                              password: _passwordCtrl.text,
                            ),
                    child: s.busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Permanently Delete Account'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

