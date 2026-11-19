import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/money.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../../register/application/register_providers.dart';
import '../application/auth_session_controller.dart';

/// Auth & Shift Gate screen implementing the 2-step Shift Open & 6-digit
/// Staff Sign-In flow, one-time Owner terminal activation (using hardcoded
/// `ApiConfig.defaultBaseUrl`), and fail-closed `DEVICE_REVOKED` lockout.
class ShiftOpenLoginScreen extends ConsumerStatefulWidget {
  const ShiftOpenLoginScreen({super.key});

  @override
  ConsumerState<ShiftOpenLoginScreen> createState() =>
      _ShiftOpenLoginScreenState();
}

enum _LoginInputMode { onlinePin, onlinePassword, offlineRecovery }

class _ShiftOpenLoginScreenState extends ConsumerState<ShiftOpenLoginScreen>
    with SingleTickerProviderStateMixin {
  final _ownerUsernameController = TextEditingController(text: 'owner');
  final _ownerPasswordController = TextEditingController();
  final _deviceNameController = TextEditingController(text: 'Counter Phone 01');

  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _floatController = TextEditingController(text: '5000');
  final _floatFocusNode = FocusNode();
  final _shiftNotesController = TextEditingController();

  late final AnimationController _pinShakeCtrl;
  String? _lastShakenError;

  String _enteredPin = '';
  final String _platform = _defaultPlatform();
  _LoginInputMode _loginMode = _LoginInputMode.onlinePin;
  int _selectedPresetRs = 5000;
  bool _floatUserEdited = false;
  bool _editingUsername = false;
  String? _seededFromShiftId;

  String _savedUsernameFor(AuthSessionState s) {
    final candidate = s.enrolledDevice?.lastUsername ??
        s.accountSession?.username ??
        s.offlineRecovery.username ??
        '';
    return candidate.trim();
  }

  static String _defaultPlatform() {
    if (Platform.isIOS) return 'IOS';
    if (Platform.isLinux) return 'LINUX';
    return 'ANDROID';
  }

  @override
  void initState() {
    super.initState();
    _pinShakeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(authSessionControllerProvider).initialize();
      }
    });
  }

  @override
  void dispose() {
    _pinShakeCtrl.dispose();
    _ownerUsernameController.dispose();
    _ownerPasswordController.dispose();
    _deviceNameController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _floatController.dispose();
    _floatFocusNode.dispose();
    _shiftNotesController.dispose();
    super.dispose();
  }

  void _appendPinDigit(String digit) {
    if (_enteredPin.length >= 6) return;
    setState(() {
      _enteredPin += digit;
    });
  }

  void _backspacePin() {
    if (_enteredPin.isEmpty) return;
    setState(() {
      _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1);
    });
  }

  void _clearPin() {
    if (_enteredPin.isEmpty) return;
    setState(() {
      _enteredPin = '';
    });
  }

  void _selectFloatPreset(int rupees) {
    setState(() {
      _floatUserEdited = true;
      _selectedPresetRs = rupees;
      _floatController.text = rupees.toString();
    });
  }

  void _focusAndSelectFloat() {
    _floatFocusNode.requestFocus();
    _floatController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _floatController.text.length,
    );
  }

  void _syncCarriedOverFloat(RegisterShiftRow? lastClosed) {
    if (lastClosed == null ||
        lastClosed.retainedNextDayFloat <= 0 ||
        _floatUserEdited ||
        _seededFromShiftId == lastClosed.id) {
      return;
    }
    _seededFromShiftId = lastClosed.id;
    final paisa = lastClosed.retainedNextDayFloat;
    final formatted = paisa % 100 == 0
        ? (paisa ~/ 100).toString()
        : MoneyUtils.toDecimalString(paisa);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _floatUserEdited) return;
      setState(() {
        _floatController.text = formatted;
        _selectedPresetRs = paisa % 100 == 0 ? (paisa ~/ 100) : -1;
      });
    });
  }

  Future<void> _submitRegisterTerminal() async {
    final ctrl = ref.read(authSessionControllerProvider);
    await ctrl.registerTerminal(
      ownerUsername: _ownerUsernameController.text,
      ownerPassword: _ownerPasswordController.text,
      deviceName: _deviceNameController.text,
      platform: _platform,
    );
  }

  Future<void> _submitLogin() async {
    final ctrl = ref.read(authSessionControllerProvider);
    final authState = ctrl.state;
    final effectiveMode =
        (_loginMode == _LoginInputMode.offlineRecovery &&
                !authState.offlineRecovery.hasSlot)
            ? _LoginInputMode.onlinePin
            : _loginMode;

    if (effectiveMode == _LoginInputMode.offlineRecovery) {
      final ok = await ctrl.unlockOfflineWithPin(_enteredPin);
      if (mounted && !ok) {
        setState(() {
          _enteredPin = '';
          if (!ctrl.state.offlineRecovery.hasSlot) {
            _loginMode = _LoginInputMode.onlinePin;
          }
        });
      }
      return;
    }

    final savedUsername = _savedUsernameFor(ctrl.state);
    final username = (savedUsername.isNotEmpty && !_editingUsername)
        ? savedUsername
        : _usernameController.text.trim();
    if (username.isEmpty) {
      ref
          .read(pasalAlertProvider)
          .showWarning('Enter staff username to continue.');
      return;
    }

    if (effectiveMode == _LoginInputMode.onlinePin) {
      if (_enteredPin.length != 6) {
        ref
            .read(pasalAlertProvider)
            .showWarning('Enter full 6-digit Security PIN.');
        return;
      }
      final ok = await ctrl.loginOnline(username: username, pin: _enteredPin);
      if (mounted && !ok) {
        setState(() => _enteredPin = '');
      }
    } else {
      final ok = await ctrl.loginOnline(
        username: username,
        password: _passwordController.text,
      );
      if (mounted && ok) {
        _passwordController.clear();
      }
    }
  }

  Future<void> _submitOpenShift() async {
    final raw = _floatController.text.replaceAll(',', '').trim();
    final int paisa;
    try {
      paisa = MoneyUtils.parseToPaisa(raw.isEmpty ? '0' : raw);
    } on FormatException catch (e) {
      ref
          .read(pasalAlertProvider)
          .showError('Invalid opening float amount: ${e.message}');
      return;
    }
    if (paisa < 0 || paisa > MoneyUtils.maxDecimal10_2Paisa) {
      ref.read(pasalAlertProvider).showError(
            'Opening float must be between Rs. 0 and Rs. 9,99,99,999.99.',
          );
      return;
    }

    await ref.read(authSessionControllerProvider).openNewShiftWithFloat(
          openingFloatPaisa: paisa,
          notes: _shiftNotesController.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final authCtrl = ref.watch(authSessionControllerProvider);
    final s = authCtrl.state;

    if (s.stage == AuthGateStage.locked &&
        (_floatUserEdited || _seededFromShiftId != null)) {
      _floatUserEdited = false;
      _seededFromShiftId = null;
    }

    if (s.stage == AuthGateStage.locked &&
        s.errorMessage != null &&
        s.errorMessage != _lastShakenError) {
      _lastShakenError = s.errorMessage;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        HapticFeedback.heavyImpact();
        if (!AppMotion.shouldReduceMotion(context)) {
          _pinShakeCtrl.forward(from: 0.0);
        }
      });
    } else if (s.errorMessage == null) {
      _lastShakenError = null;
    }

    final reduceMotion = AppMotion.shouldReduceMotion(context);

    return Scaffold(
      backgroundColor: c.surface,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopHeader(context, s),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutterMobile,
                  AppSpacing.md,
                  AppSpacing.gutterMobile,
                  AppSpacing.xl,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (s.errorMessage != null &&
                            s.stage != AuthGateStage.revoked) ...[
                          _buildErrorBanner(context, s.errorMessage!),
                          const SizedBox(height: AppSpacing.md),
                        ],
                        AnimatedSwitcher(
                          duration: AppMotion.resolveDuration(
                            context,
                            const Duration(milliseconds: 220),
                          ),
                          switchInCurve: AppMotion.easeOut,
                          switchOutCurve: AppMotion.easeOut,
                          layoutBuilder: (currentChild, previousChildren) {
                            return Stack(
                              alignment: Alignment.topCenter,
                              children: [
                                ...previousChildren,
                                ?currentChild,
                              ],
                            );
                          },
                          transitionBuilder: (child, animation) {
                            if (reduceMotion) {
                              return FadeTransition(
                                opacity: animation,
                                child: child,
                              );
                            }
                            final slide = Tween<Offset>(
                              begin: const Offset(0.05, 0),
                              end: Offset.zero,
                            ).animate(animation);
                            return FadeTransition(
                              opacity: animation,
                              child: SlideTransition(position: slide, child: child),
                            );
                          },
                          child: KeyedSubtree(
                            key: ValueKey<AuthGateStage>(s.stage),
                            child: switch (s.stage) {
                              AuthGateStage.initializing => const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 64),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                ),
                              AuthGateStage.revoked =>
                                _buildRevokedCard(context, authCtrl, s),
                              AuthGateStage.locked =>
                                _buildLoginCard(context, s),
                              AuthGateStage.shiftOpenRequired =>
                                _buildShiftOpenView(context, authCtrl, s),
                              AuthGateStage.ready => const SizedBox.shrink(),
                              AuthGateStage.accountAuthRequired ||
                              AuthGateStage.emailVerificationRequired ||
                              AuthGateStage.storeSetupRequired ||
                              AuthGateStage.deviceApprovalPending ||
                              AuthGateStage.deviceRejected =>
                                _buildEnrollTerminalCard(context, s),
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopHeader(BuildContext context, AuthSessionState s) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final deviceCode = s.enrolledDevice?.deviceCode;
    final subtitle = switch (s.stage) {
      AuthGateStage.initializing => 'STARTING UP',
      AuthGateStage.accountAuthRequired => 'ACCOUNT SIGN-IN',
      AuthGateStage.emailVerificationRequired => 'VERIFY EMAIL',
      AuthGateStage.storeSetupRequired => 'STORE SETUP',
      AuthGateStage.deviceApprovalPending => 'PENDING APPROVAL',
      AuthGateStage.deviceRejected => 'DEVICE REJECTED',
      AuthGateStage.locked => 'STAFF SIGN-IN',
      AuthGateStage.shiftOpenRequired => 'OPENING CASH & DETAILS',
      AuthGateStage.ready => 'SHIFT ACTIVE',
      AuthGateStage.revoked => 'DEVICE REVOKED',
    };

    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutterMobile),
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.94),
        border: Border(bottom: BorderSide(color: c.hairline)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'PasalX',
                      style: t.headlineSmall?.copyWith(
                        height: 1.0,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: t.labelSmall?.copyWith(
                        color: c.onSurfaceVariant,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: AppSpacing.sm),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: PasalStatusBadge(
                      label: s.stage == AuthGateStage.revoked
                          ? 'Revoked'
                          : (deviceCode != null
                              ? 'Terminal #$deviceCode'
                              : 'Setup'),
                      dotColor: s.stage == AuthGateStage.revoked
                          ? c.error
                          : (s.session != null ? c.primary : c.secondary),
                      backgroundColor: s.stage == AuthGateStage.revoked
                          ? c.errorContainer
                          : c.secondaryContainer,
                      foregroundColor: s.stage == AuthGateStage.revoked
                          ? c.onErrorContainer
                          : c.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(BuildContext context, String message) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: c.errorContainer,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: c.error.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, color: c.error, size: 20),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: t.bodySmall?.copyWith(
                color: c.onErrorContainer,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRevokedCard(
    BuildContext context,
    AuthSessionController ctrl,
    AuthSessionState s,
  ) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return PasalCard(
      color: c.errorContainer,
      borderColor: c.error.withValues(alpha: 0.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.gpp_bad_rounded, color: c.error, size: 26),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'DEVICE REVOKED BY OWNER',
                  style: t.titleMedium?.copyWith(
                    color: c.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            s.revocationReason ??
                'This terminal has been remotely revoked by the store owner.',
            style: t.bodyMedium?.copyWith(color: c.onErrorContainer),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Local store data on this phone was cleared for security. Ask the owner to re-activate it.',
            style: t.bodySmall?.copyWith(
              color: c.onErrorContainer.withValues(alpha: 0.85),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: c.error,
                foregroundColor: c.onError,
              ),
              onPressed: ctrl.resetRevokedEnrollment,
              icon: const Icon(Icons.restart_alt_rounded),
              label: const Text('Reset & Re-Enroll Terminal (Owner)'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEnrollTerminalCard(BuildContext context, AuthSessionState s) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Terminal Enrollment', style: t.headlineLarge),
        const SizedBox(height: 4),
        Text(
          'Activate this counter phone once with Owner credentials.',
          style: t.bodySmall,
        ),
        const SizedBox(height: AppSpacing.md),
        PasalCard(
          color: c.surfaceContainerLow,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _deviceNameController,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Phone Name',
                  hintText: 'Counter Phone 01',
                  prefixIcon: Icon(Icons.smartphone_rounded),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _ownerUsernameController,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Owner Username',
                  prefixIcon: Icon(Icons.person_outline_rounded),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _ownerPasswordController,
                obscureText: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submitRegisterTerminal(),
                decoration: const InputDecoration(
                  labelText: 'Owner Password',
                  prefixIcon: Icon(Icons.lock_outline_rounded),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              FilledButton.icon(
                onPressed: s.busy ? null : _submitRegisterTerminal,
                icon: const Icon(Icons.verified_user_outlined),
                label: Text(s.busy ? 'Activating...' : 'Enroll Shop Terminal'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLoginCard(BuildContext context, AuthSessionState s) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final hasOfflineSlot = s.offlineRecovery.hasSlot;
    final effectiveMode =
        (_loginMode == _LoginInputMode.offlineRecovery && !hasOfflineSlot)
            ? _LoginInputMode.onlinePin
            : _loginMode;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text('Morning Shift Login', style: t.headlineLarge),
            ),
            PasalStatusBadge(
              label: 'Locked',
              dotColor: c.secondary,
              backgroundColor: c.surfaceContainerHigh,
              foregroundColor: c.onSurfaceVariant,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          s.enrolledDevice != null
              ? '${s.enrolledDevice!.deviceName} • Code #${s.enrolledDevice!.deviceCode}'
              : 'Enter your 6-digit PIN to start billing',
          style: t.bodySmall,
        ),
        const SizedBox(height: AppSpacing.md),
        if (hasOfflineSlot) ...[
          PasalPressable(
            onTap: () => setState(() {
              _loginMode = _LoginInputMode.offlineRecovery;
              _enteredPin = '';
            }),
            child: PasalCard(
              color: effectiveMode == _LoginInputMode.offlineRecovery
                  ? c.secondaryContainer
                  : c.secondaryContainer.withValues(alpha: 0.45),
              borderColor: effectiveMode == _LoginInputMode.offlineRecovery
                  ? c.primary.withValues(alpha: 0.45)
                  : null,
              child: Row(
                children: [
                  Icon(Icons.offline_bolt_outlined, color: c.primary),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Offline Reboot Recovery Active',
                          style: t.labelLarge?.copyWith(color: c.primary),
                        ),
                        Text(
                          '${s.offlineRecovery.username ?? "Staff"} • '
                          '${s.offlineRecovery.remainingAttempts} PIN attempts left',
                          style: t.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: c.primary),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        PasalCard(
          color: c.surfaceContainerLow,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (effectiveMode != _LoginInputMode.offlineRecovery) ...[
                if (_savedUsernameFor(s).isNotEmpty && !_editingUsername) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.sm,
                    ),
                    decoration: BoxDecoration(
                      color: c.surfaceContainerHigh.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(AppRadii.md),
                      border: Border.all(
                        color: c.outlineVariant.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.person_outline_rounded,
                          size: 20,
                          color: c.primary,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Signed-in User', style: t.labelSmall),
                              Text(
                                '@${_savedUsernameFor(s)}',
                                style: t.titleMedium,
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: s.busy
                              ? null
                              : () {
                                  _usernameController.text =
                                      _savedUsernameFor(s);
                                  setState(() {
                                    _editingUsername = true;
                                    _enteredPin = '';
                                  });
                                },
                          child: const Text('Switch user'),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  TextField(
                    controller: _usernameController,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: 'Staff Username',
                      hintText: 'sunita',
                      prefixIcon: const Icon(Icons.person_outline_rounded),
                      suffixIcon: _savedUsernameFor(s).isNotEmpty
                          ? TextButton(
                              onPressed: s.busy
                                  ? null
                                  : () => setState(() {
                                        _editingUsername = false;
                                        _enteredPin = '';
                                      }),
                              child: const Text('Use saved'),
                            )
                          : null,
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
              ],
              if (effectiveMode == _LoginInputMode.onlinePassword) ...[
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submitLogin(),
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    prefixIcon: Icon(Icons.lock_outline_rounded),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                FilledButton.icon(
                  onPressed: s.busy ? null : _submitLogin,
                  icon: const Icon(Icons.lock_open_rounded),
                  label: Text(s.busy ? 'Unlocking...' : 'Sign In & Unlock'),
                ),
                const SizedBox(height: AppSpacing.xs),
                Center(
                  child: TextButton(
                    onPressed: s.busy
                        ? null
                        : () => setState(() {
                              _loginMode = _LoginInputMode.onlinePin;
                              _enteredPin = '';
                            }),
                    child: const Text('Use 6-Digit PIN instead'),
                  ),
                ),
              ] else ...[
                _buildPinStepHeader(context),
                const SizedBox(height: AppSpacing.md),
                _buildPinDots(context),
                const SizedBox(height: AppSpacing.sm),
                Center(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      shape: const StadiumBorder(),
                      side: BorderSide(color: c.hairline),
                      backgroundColor: c.surfaceContainerLowest,
                    ),
                    onPressed: s.busy
                        ? null
                        : () {
                            ref.read(pasalAlertProvider).showWarning(
                                  'Biometric unlock is not set up — enter your 6-digit PIN.',
                                );
                          },
                    icon: Icon(
                      Icons.fingerprint_rounded,
                      size: 16,
                      color: c.primary,
                    ),
                    label: Text(
                      'Use Fingerprint / Face ID',
                      style: t.labelMedium,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                _buildPinKeypad(context),
                const SizedBox(height: AppSpacing.md),
                FilledButton.icon(
                  onPressed:
                      s.busy || _enteredPin.length != 6 ? null : _submitLogin,
                  icon: const Icon(Icons.verified_user_rounded),
                  label: Text(
                    s.busy
                        ? 'Verifying...'
                        : (effectiveMode == _LoginInputMode.offlineRecovery
                            ? 'Unlock Offline Vault'
                            : 'Verify PIN & Sign In'),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Center(
                  child: TextButton(
                    onPressed: s.busy
                        ? null
                        : () => setState(() {
                              _loginMode =
                                  effectiveMode == _LoginInputMode.offlineRecovery
                                      ? _LoginInputMode.onlinePin
                                      : _LoginInputMode.onlinePassword;
                              _enteredPin = '';
                            }),
                    child: Text(
                      effectiveMode == _LoginInputMode.offlineRecovery
                          ? 'Sign in with Username & PIN'
                          : 'Use Password instead',
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPinStepHeader(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final remaining = 6 - _enteredPin.length;
    return Row(
      children: [
        Expanded(
          child: Text(
            'Enter your 6-digit security PIN',
            style: t.bodySmall?.copyWith(color: c.onSurfaceVariant),
          ),
        ),
        Text(
          remaining == 0 ? '6 Digits Ready' : '$remaining Left',
          style: t.labelSmall?.copyWith(
            color: remaining == 0 ? c.primary : c.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _buildPinDots(BuildContext context) {
    final c = context.pasalColors;
    final reduceMotion = AppMotion.shouldReduceMotion(context);
    return AnimatedBuilder(
      animation: _pinShakeCtrl,
      builder: (context, child) {
        final v = _pinShakeCtrl.value;
        final dx = v == 0.0 || v == 1.0
            ? 0.0
            : math.sin(v * math.pi * 3) * (1.0 - v) * 8.0;
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(6, (idx) {
          final filled = idx < _enteredPin.length;
          return AnimatedScale(
            scale: filled || reduceMotion ? 1.0 : 0.85,
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 100),
            curve: AppMotion.easeOut,
            child: AnimatedContainer(
              key: ValueKey<String>('pin-dot-$idx'),
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 90),
              margin: const EdgeInsets.symmetric(horizontal: 7),
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: filled ? c.primary : c.surfaceContainerHighest,
                border: Border.all(
                  color: filled ? c.primary : c.outlineVariant,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildPinKeypad(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    const keys = <String>[
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      'CLR',
      '0',
      'DEL',
    ];

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: keys.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.85,
          ),
          itemBuilder: (context, index) {
            final label = keys[index];
            final isControl = label == 'CLR' || label == 'DEL';
            return PasalPressable(
              key: ValueKey<String>('pin-key-$label'),
              haptic: PasalHaptic.selection,
              borderRadius: BorderRadius.circular(AppRadii.md),
              onTap: () {
                if (label == 'CLR') {
                  _clearPin();
                } else if (label == 'DEL') {
                  _backspacePin();
                } else {
                  _appendPinDigit(label);
                }
              },
              child: Container(
                decoration: BoxDecoration(
                  color: isControl ? c.surfaceContainer : c.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  border: Border.all(color: c.hairline),
                ),
                alignment: Alignment.center,
                child: label == 'DEL'
                    ? Icon(
                        Icons.backspace_outlined,
                        size: 20,
                        color: c.onSurfaceVariant,
                      )
                    : (label == 'CLR'
                        ? Text(
                            'CLR',
                            style: t.labelMedium?.copyWith(
                              color: c.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                            ),
                          )
                        : PasalTabularText(
                            label,
                            style: t.headlineSmall,
                          )),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildShiftOpenView(
    BuildContext context,
    AuthSessionController ctrl,
    AuthSessionState s,
  ) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final existingShift = s.activeShift;
    final name = s.displayName ?? s.session?.username ?? 'Staff';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ACTIVE CASHIER',
                    style: t.labelSmall?.copyWith(
                      color: c.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text('Opening Cash & Details', style: t.headlineLarge),
                ],
              ),
            ),
            PasalStatusBadge(
              label: existingShift != null ? 'Shared Galla' : 'Morning Shift',
              dotColor: c.primary,
              backgroundColor: c.secondaryContainer,
              foregroundColor: c.onSecondaryContainer,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        PasalCard(
          color: c.surfaceContainerLowest,
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: c.primary,
                foregroundColor: c.onPrimary,
                child: Text(
                  _initials(name),
                  style: t.labelLarge?.copyWith(
                    color: c.onPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (s.session?.role ?? 'STAFF').toUpperCase(),
                      style: t.labelSmall?.copyWith(
                        color: c.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      name,
                      style: t.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: s.busy ? null : ctrl.logout,
                icon: const Icon(Icons.lock_outline_rounded, size: 18),
                label: const Text('Lock'),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (existingShift != null)
          _buildJoinExistingShiftCard(context, ctrl, s, existingShift)
        else
          _buildOpeningFloatCard(context, s),
      ],
    );
  }

  Widget _buildJoinExistingShiftCard(
    BuildContext context,
    AuthSessionController ctrl,
    AuthSessionState s,
    RegisterShiftRow existingShift,
  ) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return PasalCard(
      color: c.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              PasalStatusBadge(
                label: 'Shared Galla Open',
                dotColor: c.primary,
              ),
              const Spacer(),
              Text(
                'Single Register',
                style: t.labelSmall?.copyWith(color: c.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text('EXPECTED DRAWER CASH', style: t.labelSmall),
          const SizedBox(height: 4),
          PasalTabularText(
            MoneyUtils.formatRs(existingShift.expectedCash),
            style: t.displayLarge,
          ),
          const SizedBox(height: AppSpacing.xs),
          PasalTabularText(
            'Opening Float: ${MoneyUtils.formatRs(existingShift.openingFloat)}',
            style: t.bodySmall,
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: s.busy ? null : ctrl.joinExistingOpenShift,
            icon: const Icon(Icons.login_rounded),
            label: Text(
              s.busy ? 'Joining...' : 'Punch In & Start Billing',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOpeningFloatCard(BuildContext context, AuthSessionState s) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final lastClosed = ref.watch(lastClosedShiftProvider).value;
    _syncCarriedOverFloat(lastClosed);
    const presets = <int>[3000, 5000, 10000];

    final currentPaisa = _tryParseFloatPaisa(_floatController.text);
    final matchesLastClosed = lastClosed != null &&
        lastClosed.retainedNextDayFloat > 0 &&
        currentPaisa == lastClosed.retainedNextDayFloat;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PasalCard(
          color: c.surfaceContainerLow,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'OPENING CASH FLOAT',
                      style: t.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (lastClosed != null &&
                      lastClosed.retainedNextDayFloat > 0)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.sync_rounded, size: 14, color: c.primary),
                        const SizedBox(width: 4),
                        Text(
                          'Carried Over',
                          style: t.labelSmall?.copyWith(
                            color: c.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    )
                  else
                    Text(
                      'Single Galla',
                      style: t.labelSmall?.copyWith(color: c.secondary),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: c.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  border: Border.all(color: c.hairline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('CASH IN GALLA', style: t.labelSmall),
                              const SizedBox(height: 4),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Text(
                                    'Rs.',
                                    style: t.headlineSmall?.copyWith(
                                      color: c.primary,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: TextField(
                                      controller: _floatController,
                                      focusNode: _floatFocusNode,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                      inputFormatters: [
                                        FilteringTextInputFormatter.allow(
                                          RegExp(r'[\d.,]'),
                                        ),
                                      ],
                                      onChanged: (_) => setState(() {
                                        _floatUserEdited = true;
                                        _selectedPresetRs = -1;
                                      }),
                                      style: t.displayLarge?.copyWith(
                                        fontFeatures: const [
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                      decoration: const InputDecoration(
                                        border: InputBorder.none,
                                        enabledBorder: InputBorder.none,
                                        focusedBorder: InputBorder.none,
                                        filled: false,
                                        isDense: true,
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            backgroundColor: c.surfaceContainer,
                            side: BorderSide(color: c.hairline),
                          ),
                          onPressed: _focusAndSelectFloat,
                          icon: const Icon(Icons.edit_outlined, size: 15),
                          label: const Text('Edit'),
                        ),
                      ],
                    ),
                    if (matchesLastClosed) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            Icons.check_circle_rounded,
                            size: 14,
                            color: c.primary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Matches yesterday\'s closing float',
                            style: t.labelSmall?.copyWith(color: c.primary),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: presets.map((amount) {
                  final selected = _selectedPresetRs == amount;
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                        right: amount == presets.last ? 0 : AppSpacing.xs,
                      ),
                      child: PasalPressable(
                        borderRadius: BorderRadius.circular(AppRadii.md),
                        onTap: () => _selectFloatPreset(amount),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 10,
                            horizontal: 4,
                          ),
                          decoration: BoxDecoration(
                            color: selected
                                ? c.primary
                                : c.surfaceContainerLowest,
                            borderRadius: BorderRadius.circular(AppRadii.md),
                            border: Border.all(
                              color: selected ? c.primary : c.hairline,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: PasalTabularText(
                              MoneyUtils.formatRs(amount * 100),
                              style: t.labelMedium?.copyWith(
                                color: selected ? c.onPrimary : c.onSurface,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Count the cash already in the drawer before confirming.',
                style: t.bodySmall,
              ),
            ],
          ),
        ),
        if (lastClosed != null) ...[
          const SizedBox(height: AppSpacing.md),
          _buildYesterdayHandoverCard(context, lastClosed),
        ],
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _shiftNotesController,
          decoration: const InputDecoration(
            labelText: 'Opening Notes (Optional)',
            hintText: 'Morning till counted by cashier',
            isDense: true,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        FilledButton.icon(
          onPressed: s.busy ? null : _submitOpenShift,
          icon: const Icon(Icons.lock_open_rounded),
          label: Text(
            s.busy ? 'Opening Register...' : 'Open Register & Start Billing',
          ),
        ),
      ],
    );
  }

  Widget _buildYesterdayHandoverCard(
    BuildContext context,
    RegisterShiftRow lastClosed,
  ) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return PasalCard(
      color: c.surfaceContainerLowest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'YESTERDAY\'S HANDOVER',
                  style: t.labelMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.verified_rounded, size: 14, color: c.primary),
                  const SizedBox(width: 4),
                  Text(
                    (lastClosed.discrepancy ?? 0) == 0
                        ? 'Closed Clean'
                        : 'Closed',
                    style: t.labelSmall?.copyWith(
                      color: c.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const Divider(height: AppSpacing.md),
          _handoverRow(
            context,
            'Closing Cash Retained',
            MoneyUtils.formatRs(lastClosed.retainedNextDayFloat),
            bold: true,
          ),
          const SizedBox(height: 6),
          _handoverRow(
            context,
            'Cash Sales',
            MoneyUtils.formatRs(lastClosed.cashSales),
          ),
          const SizedBox(height: 6),
          _handoverRow(
            context,
            'Digital Sales (QR)',
            MoneyUtils.formatRs(lastClosed.digitalSales),
          ),
          const SizedBox(height: 6),
          _handoverRow(
            context,
            'Cash Expenses',
            MoneyUtils.formatRs(lastClosed.cashExpenses),
          ),
          if (lastClosed.closedAt != null) ...[
            const SizedBox(height: 6),
            _handoverRow(
              context,
              'Closed At',
              _formatShortDateTime(lastClosed.closedAt!.toLocal()),
            ),
          ],
        ],
      ),
    );
  }

  Widget _handoverRow(
    BuildContext context,
    String label,
    String value, {
    bool bold = false,
  }) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: t.bodySmall?.copyWith(color: c.onSurfaceVariant)),
        PasalTabularText(
          value,
          style: t.bodySmall?.copyWith(
            color: c.onSurface,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );
  }

  int? _tryParseFloatPaisa(String text) {
    final raw = text.replaceAll(',', '').trim();
    if (raw.isEmpty) return 0;
    try {
      return MoneyUtils.parseToPaisa(raw);
    } on FormatException {
      return null;
    }
  }

  String _initials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'PX';
    if (parts.length == 1) {
      return parts.first.substring(0, parts.first.length >= 2 ? 2 : 1).toUpperCase();
    }
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  String _formatShortDateTime(DateTime dt) {
    final hour12 = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final amPm = dt.hour >= 12 ? 'PM' : 'AM';
    final min = dt.minute.toString().padLeft(2, '0');
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[dt.month - 1]} ${dt.day}, $hour12:$min $amPm';
  }
}
