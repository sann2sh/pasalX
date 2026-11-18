import 'dart:async';

import 'package:flutter/material.dart';
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
  PasalAlertMessage? _current;
  int _nextId = 0;

  PasalAlertMessage? get current => _current;

  /// Displays a floating semantic popup at the top of the viewport.
  void show(
    PasalAlertSeverity severity,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(milliseconds: 3500),
  }) {
    _autoDismissTimer?.cancel();
    _current = PasalAlertMessage(
      id: ++_nextId,
      severity: severity,
      message: message,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    );
    notifyListeners();

    if (duration > Duration.zero) {
      _autoDismissTimer = Timer(duration, dismiss);
    }
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
            const SizedBox(width: 4),
            Semantics(
              button: true,
              label: 'Dismiss alert',
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadii.pill),
                onTap: onDismiss,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: fg.withValues(alpha: 0.75),
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

    return Stack(
      children: [
        child,
        Positioned(
          top: topPadding + 72,
          left: 14,
          right: 14,
          child: AnimatedSwitcher(
            duration: AppMotion.popover,
            switchInCurve: AppMotion.easeOut,
            switchOutCurve: AppMotion.easeOut,
            transitionBuilder: (widget, animation) {
              final slide = Tween<Offset>(
                begin: const Offset(0, -0.18),
                end: Offset.zero,
              ).animate(animation);
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(position: slide, child: widget),
              );
            },
            child: alert == null
                ? const SizedBox.shrink()
                : PasalAlertBanner(
                    key: ValueKey<int>(alert.id),
                    alert: alert,
                    onDismiss: controller.dismiss,
                  ),
          ),
        ),
      ],
    );
  }
}

