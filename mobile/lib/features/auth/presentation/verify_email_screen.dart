import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../application/auth_session_controller.dart';

/// 6-digit email verification screen (`emailVerificationRequired`).
class VerifyEmailScreen extends ConsumerStatefulWidget {
  const VerifyEmailScreen({super.key});

  @override
  ConsumerState<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends ConsumerState<VerifyEmailScreen> {
  final _emailCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  Timer? _cooldownTimer;
  int _resendSecondsLeft = 60;

  @override
  void initState() {
    super.initState();
    _emailCtrl.text =
        ref.read(authSessionControllerProvider).state.pendingEmail ?? '';
    _startCooldown();
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _resendSecondsLeft = 60);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendSecondsLeft <= 1) {
        timer.cancel();
        setState(() => _resendSecondsLeft = 0);
      } else {
        setState(() => _resendSecondsLeft--);
      }
    });
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final authCtrl = ref.watch(authSessionControllerProvider);
    final s = authCtrl.state;

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
                      Icons.mark_email_read_outlined,
                      size: 40,
                      color: c.primary,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'Verify Your Email',
                      style: t.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'Enter the 6-digit code sent to your inbox.',
                      style: t.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (s.errorMessage != null) ...[
                      Text(
                        s.errorMessage!,
                        style: t.bodySmall?.copyWith(color: c.error),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                    if (s.infoMessage != null) ...[
                      Text(
                        s.infoMessage!,
                        style: t.bodySmall?.copyWith(color: c.primary),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                    TextField(
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: 'Email'),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextField(
                      controller: _codeCtrl,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: '6-Digit Verification Code',
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    FilledButton(
                      onPressed: s.busy
                          ? null
                          : () => authCtrl.verifyEmailCode(
                                email: _emailCtrl.text,
                                code: _codeCtrl.text,
                              ),
                      child: s.busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Verify Email'),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    OutlinedButton(
                      onPressed: (s.busy || _resendSecondsLeft > 0)
                          ? null
                          : () async {
                              final ok = await authCtrl.resendVerificationCode(
                                email: _emailCtrl.text,
                              );
                              if (ok && mounted) _startCooldown();
                            },
                      child: Text(
                        _resendSecondsLeft > 0
                            ? 'Resend Code (${_resendSecondsLeft}s)'
                            : 'Resend Code',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    TextButton(
                      onPressed: s.busy ? null : authCtrl.signOutAccount,
                      child: const Text('Back to Sign In'),
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

