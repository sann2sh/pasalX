import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'app_spacing.dart';
import 'app_theme.dart';
import 'pasal_widgets.dart';

/// Semantic severity levels for floating PasalX subtle popups.
enum PasalAlertSeverity {
  warning,
  error,
  success,
}

/// Immutable payload for a subtle floating banner alert.
@immutable
class PasalAlertMessage {
  const PasalAlertMessage({
    required this.id,
    required this.severity,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.duration = const Duration(milliseconds: 3500),
  });

  final int id;
  final PasalAlertSeverity severity;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Duration duration;
}

/// Controls the single active floating subtle alert across the app.
class PasalAlertController extends ChangeNotifier {
  Timer? _autoDismissTimer;
  DateTime? _timerStartedAt;
  Duration? _remainingDuration;
  bool _isPaused = false;
  PasalAlertMessage? _current;
  int _nextId = 0;

  PasalAlertMessage? get current => _current;
  bool get isTimerPaused => _isPaused;

  /// Displays a floating semantic popup at the top of the viewport.
  void show(
    PasalAlertSeverity severity,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(milliseconds: 3500),
  }) {
    _autoDismissTimer?.cancel();
    _autoDismissTimer = null;
    _isPaused = false;
    _current = PasalAlertMessage(
      id: ++_nextId,
      severity: severity,
      message: message,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    );
    _remainingDuration = duration > Duration.zero ? duration : null;
    notifyListeners();

    _startTimerIfNeeded();
  }

  void _startTimerIfNeeded() {
    _autoDismissTimer?.cancel();
    _autoDismissTimer = null;
    final rem = _remainingDuration;
    if (_isPaused || rem == null || rem <= Duration.zero) return;
    _timerStartedAt = DateTime.now();
    _autoDismissTimer = Timer(rem, dismiss);
  }

  /// Pauses the auto-dismiss countdown while the user is touching/reading the alert.
  void pauseTimer() {
    if (_isPaused || _current == null) return;
    _isPaused = true;
    if (_autoDismissTimer != null &&
        _timerStartedAt != null &&
        _remainingDuration != null) {
      final elapsed = DateTime.now().difference(_timerStartedAt!);
      final left = _remainingDuration! - elapsed;
      _remainingDuration = left > Duration.zero ? left : const Duration(milliseconds: 250);
    }
    _autoDismissTimer?.cancel();
    _autoDismissTimer = null;
    _timerStartedAt = null;
  }

  /// Resumes the auto-dismiss countdown when the user lifts their finger.
  void resumeTimer() {
    if (!_isPaused || _current == null) return;
    _isPaused = false;
    _startTimerIfNeeded();
  }

  /// Displays a subtle amber warning popup.
  void showWarning(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(milliseconds: 3500),
  }) {
    show(
      PasalAlertSeverity.warning,
      message,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    );
  }

  /// Displays a crisp crimson error popup.
  void showError(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(milliseconds: 3500),
  }) {
    show(
      PasalAlertSeverity.error,
      message,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    );
  }

  /// Displays a dark botanical success popup.
  void showSuccess(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(milliseconds: 3500),
  }) {
    show(
      PasalAlertSeverity.success,
      message,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    );
  }

  /// Dismisses the active popup immediately.
  void dismiss() {
    _autoDismissTimer?.cancel();
    _autoDismissTimer = null;
    _timerStartedAt = null;
    _remainingDuration = null;
    _isPaused = false;
    if (_current == null) return;
    _current = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    super.dispose();
  }
}

/// Global Riverpod controller for subtle warning / error / success popups.
final pasalAlertProvider = ChangeNotifierProvider<PasalAlertController>((ref) {
  return PasalAlertController();
});

/// Floating rounded-2xl semantic popup matching `#phone-alert` in the Stitch prototype.
class PasalAlertBanner extends StatelessWidget {
  const PasalAlertBanner({
    super.key,
    required this.alert,
    required this.onDismiss,
  });

  final PasalAlertMessage alert;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;

    final Color bg;
    final Color borderColor;
    final Color fg;
    final Color actionBg;
    final Color actionFg;
    final IconData icon;

    switch (alert.severity) {
      case PasalAlertSeverity.warning:
        bg = c.warningContainer;
        borderColor = c.warningBorder.withValues(alpha: 0.50);
        fg = c.onWarningContainer;
        actionBg = c.warning;
        actionFg = Colors.white;
        icon = Icons.warning_amber_rounded;
      case PasalAlertSeverity.error:
        bg = c.errorContainer;
        borderColor = c.error.withValues(alpha: 0.40);
        fg = c.onErrorContainer;
        actionBg = c.error;
        actionFg = c.onError;
        icon = Icons.error_outline_rounded;
      case PasalAlertSeverity.success:
        bg = c.inverseSurface;
        borderColor = Colors.transparent;
        fg = c.inverseOnSurface;
        actionBg = c.primaryFixed;
        actionFg = c.onPrimaryFixed;
        icon = Icons.check_circle_outline_rounded;
    }

    return Material(
      type: MaterialType.transparency,
      child: Container(
        key: ValueKey<String>('pasal-alert-${alert.severity.name}'),
        padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(AppRadii.xl),
          border: Border.all(color: borderColor),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.14),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: fg),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                alert.message,
                style: t.labelMedium?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
            ),
            if (alert.actionLabel != null && alert.onAction != null) ...[
              const SizedBox(width: 8),
              PasalPressable(
                borderRadius: BorderRadius.circular(AppRadii.sm),
                onTap: () {
                  final callback = alert.onAction;
                  onDismiss();
                  callback?.call();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: actionBg,
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                  ),
                  child: Text(
                    alert.actionLabel!,
                    style: t.labelSmall?.copyWith(
                      color: actionFg,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(width: 2),
            Semantics(
              button: true,
              label: 'Dismiss alert',
              child: InkWell(
                key: const ValueKey<String>('pasal-alert-dismiss-btn'),
                borderRadius: BorderRadius.circular(AppRadii.pill),
                onTap: onDismiss,
                child: SizedBox(
                  width: AppSpacing.minTouchTarget,
                  height: AppSpacing.minTouchTarget,
                  child: Center(
                    child: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: fg.withValues(alpha: 0.75),
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
}

/// Hosts floating subtle warning, error, and success popups above route views.
class PasalAlertOverlay extends ConsumerWidget {
  const PasalAlertOverlay({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(pasalAlertProvider);
    final alert = controller.current;
    final topPadding = MediaQuery.paddingOf(context).top;
    final reduceMotion = AppMotion.shouldReduceMotion(context);

    return Stack(
      children: [
        child,
        Positioned(
          top: topPadding + 72,
          left: 14,
          right: 14,
          child: AnimatedSwitcher(
            duration: AppMotion.resolveDuration(context, AppMotion.alertEnter),
            reverseDuration: AppMotion.resolveDuration(
              context,
              AppMotion.alertExit,
            ),
            switchInCurve: AppMotion.easeOut,
            switchOutCurve: AppMotion.easeOut,
            transitionBuilder: (widget, animation) {
              if (reduceMotion) {
                return FadeTransition(opacity: animation, child: widget);
              }
              final slide = Tween<Offset>(
                begin: const Offset(0, -1.0),
                end: Offset.zero,
              ).animate(animation);
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(position: slide, child: widget),
              );
            },
            child: alert == null
                ? const SizedBox.shrink()
                : Listener(
                    key: ValueKey<int>(alert.id),
                    onPointerDown: (_) => controller.pauseTimer(),
                    onPointerUp: (_) => controller.resumeTimer(),
                    onPointerCancel: (_) => controller.resumeTimer(),
                    child: _SwipeDismissAlertWrapper(
                      onDismiss: controller.dismiss,
                      child: PasalAlertBanner(
                        alert: alert,
                        onDismiss: controller.dismiss,
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

/// 1:1 vertical swipe-up-to-dismiss wrapper with downward rubber-band damping
/// and critically damped spring snap-back (`gestures` & `apple-design`).
class _SwipeDismissAlertWrapper extends StatefulWidget {
  const _SwipeDismissAlertWrapper({
    required this.onDismiss,
    required this.child,
  });

  final VoidCallback onDismiss;
  final Widget child;

  @override
  State<_SwipeDismissAlertWrapper> createState() =>
      _SwipeDismissAlertWrapperState();
}

class _SwipeDismissAlertWrapperState extends State<_SwipeDismissAlertWrapper>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dragCtrl;

  static const SpringDescription _snapSpring = SpringDescription(
    mass: 1.0,
    stiffness: 380.0,
    damping: 39.0, // ~1.0 damping ratio (critically damped)
  );

  @override
  void initState() {
    super.initState();
    _dragCtrl = AnimationController.unbounded(vsync: this, value: 0.0);
  }

  @override
  void dispose() {
    _dragCtrl.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails _) {
    _dragCtrl.stop();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0.0;
    final next = _dragCtrl.value + delta;
    if (next <= 0.0) {
      _dragCtrl.value = next;
    } else {
      // Rubber-band resistance when pulling downward against the top anchor.
      _dragCtrl.value = _dragCtrl.value + delta * 0.25;
    }
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0.0;
    // Dismiss if dragged >= 28px up or flicked faster than 0.11 px/ms (110 px/s).
    if (_dragCtrl.value <= -28.0 || velocity < -110.0) {
      HapticFeedback.lightImpact();
      widget.onDismiss();
      return;
    }
    _dragCtrl.animateWith(
      SpringSimulation(_snapSpring, _dragCtrl.value, 0.0, velocity),
    );
  }

  void _onDragCancel() {
    _dragCtrl.animateWith(
      SpringSimulation(_snapSpring, _dragCtrl.value, 0.0, 0.0),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _onDragStart,
      onVerticalDragUpdate: _onDragUpdate,
      onVerticalDragEnd: _onDragEnd,
      onVerticalDragCancel: _onDragCancel,
      child: AnimatedBuilder(
        animation: _dragCtrl,
        builder: (context, child) {
          final dy = _dragCtrl.value;
          final opacity =
              dy < 0 ? (1.0 - (-dy / 96.0)).clamp(0.25, 1.0) : 1.0;
          return Transform.translate(
            offset: Offset(0, dy),
            child: Opacity(opacity: opacity, child: child),
          );
        },
        child: widget.child,
      ),
    );
  }
}

