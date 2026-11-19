import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../application/auth_session_controller.dart';

/// Account Sign In / Sign Up screen (`accountAuthRequired`).
class AccountAuthScreen extends ConsumerStatefulWidget {
  const AccountAuthScreen({super.key});

  @override
  ConsumerState<AccountAuthScreen> createState() => _AccountAuthScreenState();
}

class _AccountAuthScreenState extends ConsumerState<AccountAuthScreen> {
  bool _isSignUp = false;
  bool _obscurePassword = true;
  bool _showServerField = false;

  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  final _serverCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _serverCtrl.text = ref.read(authSessionControllerProvider).state.serverUrl;
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _nameCtrl.dispose();
    _usernameCtrl.dispose();
    _pinCtrl.dispose();
    _serverCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final ctrl = ref.read(authSessionControllerProvider);
    if (_showServerField && _serverCtrl.text.trim().isNotEmpty) {
      await ctrl.updateServerUrl(_serverCtrl.text.trim());
      if (ctrl.state.errorMessage != null) return;
    }

    if (_isSignUp) {
      await ctrl.signupAccount(
        name: _nameCtrl.text,
        email: _emailCtrl.text,
        password: _passwordCtrl.text,
        username: _usernameCtrl.text,
        pin: _pinCtrl.text,
      );
    } else {
      await ctrl.loginAccount(
        email: _emailCtrl.text,
        password: _passwordCtrl.text,
      );
    }
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: c.primary,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          'PX',
                          style: t.titleMedium?.copyWith(color: c.onPrimary),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('PasalX', style: t.headlineSmall),
                            Text(
                              _isSignUp
                                  ? 'Create your store or staff account'
                                  : 'Sign in to your PasalX account',
                              style: t.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  PasalClipSegmentedTabs<bool>(
                    selectedValue: _isSignUp,
                    activePillColor: c.primary,
                    activeForegroundColor: c.onPrimary,
                    onChanged: (v) {
                      if (!s.busy) setState(() => _isSignUp = v);
                    },
                    options: const [
                      PasalSegmentOption<bool>(
                        value: false,
                        label: 'Log In',
                        icon: Icons.login_rounded,
                      ),
                      PasalSegmentOption<bool>(
                        value: true,
                        label: 'Sign Up',
                        icon: Icons.person_add_alt_1_rounded,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (s.infoMessage != null) ...[
                    _BannerBox(
                      message: s.infoMessage!,
                      backgroundColor: c.secondaryContainer,
                      foregroundColor: c.onSecondaryContainer,
                      icon: Icons.info_outline_rounded,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  if (s.errorMessage != null) ...[
                    _BannerBox(
                      message: s.errorMessage!,
                      backgroundColor: c.errorContainer,
                      foregroundColor: c.onErrorContainer,
                      icon: Icons.error_outline_rounded,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  PasalCard(
                    child: AnimatedSize(
                      duration:
                          AppMotion.resolveDuration(context, AppMotion.popover),
                      curve: AppMotion.easeOut,
                      alignment: Alignment.topCenter,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                        if (_isSignUp) ...[
                          TextField(
                            controller: _nameCtrl,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'Full Name',
                              hintText: 'e.g. Sita Gurung',
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          TextField(
                            controller: _usernameCtrl,
                            autocorrect: false,
                            enableSuggestions: false,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'Username (for daily POS login)',
                              hintText: 'e.g. sita',
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                        ],
                        TextField(
                          controller: _emailCtrl,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          enableSuggestions: false,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'Email Address',
                            hintText: 'you@example.com',
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        TextField(
                          controller: _passwordCtrl,
                          obscureText: _obscurePassword,
                          textInputAction: _isSignUp
                              ? TextInputAction.next
                              : TextInputAction.done,
                          onSubmitted: (_) {
                            if (!_isSignUp && !s.busy) _submit();
                          },
                          decoration: InputDecoration(
                            labelText: 'Password',
                            helperText: _isSignUp
                                ? '10+ characters, not your name or email'
                                : null,
                            suffixIcon: IconButton(
                              onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword,
                              ),
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                        ),
                        if (_isSignUp) ...[
                          const SizedBox(height: AppSpacing.sm),
                          TextField(
                            controller: _pinCtrl,
                            keyboardType: TextInputType.number,
                            obscureText: true,
                            maxLength: 6,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            decoration: const InputDecoration(
                              labelText: '6-Digit Daily POS PIN',
                              hintText: 'Used for quick daily register unlock',
                              counterText: '',
                            ),
                          ),
                        ],
                        const SizedBox(height: AppSpacing.md),
                        FilledButton(
                          onPressed: s.busy ? null : _submit,
                          child: s.busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(_isSignUp ? 'Create Account' : 'Log In'),
                        ),
                        if (!_isSignUp) ...[
                          const SizedBox(height: AppSpacing.xs),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: s.busy
                                  ? null
                                  : () => context.push(AppRoutes.forgotPassword),
                              child: const Text('Forgot Password?'),
                            ),
                          ),
                        ],
                      ],
                    ),
                    ),
                  ),
                  if (!kReleaseMode) ...[
                    const SizedBox(height: AppSpacing.sm),
                    TextButton.icon(
                      onPressed: () =>
                          setState(() => _showServerField = !_showServerField),
                      icon: const Icon(Icons.dns_outlined, size: 18),
                      label: Text(
                        _showServerField
                            ? 'Hide Server URL'
                            : 'Server: ${s.serverUrl}',
                      ),
                    ),
                    if (_showServerField)
                      PasalCard(
                        child: TextField(
                          controller: _serverCtrl,
                          keyboardType: TextInputType.url,
                          decoration: const InputDecoration(
                            labelText: 'API Server URL',
                            hintText: 'https://pasalx.skisub.com',
                          ),
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

class _BannerBox extends StatelessWidget {
  const _BannerBox({
    required this.message,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.icon,
  });

  final String message;
  final Color backgroundColor;
  final Color foregroundColor;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: foregroundColor),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: foregroundColor),
            ),
          ),
        ],
      ),
    );
  }
}
