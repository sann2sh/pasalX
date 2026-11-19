import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_spacing.dart';
import 'app_theme.dart';
import 'app_typography.dart';

export 'pasal_alert.dart';

/// Shared text & grapheme-safe formatting utilities (`break-ui`).
abstract final class PasalTextUtils {
  /// Extracts up to 2 uppercase grapheme-cluster initials without splitting
  /// UTF-16 surrogate pairs or crashing on 1-character names.
  static String initials(String raw, {String fallback = 'PX'}) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return fallback;
    final parts = trimmed
        .split(RegExp(r'[\s._-]+'))
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) return fallback;
    if (parts.length >= 2) {
      final first = parts.first.characters.first;
      final last = parts.last.characters.first;
      return '$first$last'.toUpperCase();
    }
    final chars = parts.first.characters;
    return chars.take(2).toString().toUpperCase();
  }

  /// Formats singular/plural count labels (`1 SKU`, `2 SKUs`).
  static String plural(int count, String singular, [String? pluralForm]) {
    final word = count == 1 ? singular : (pluralForm ?? '${singular}s');
    return '$count $word';
  }
}

/// Haptic intensity triggered on pointer-down for tactile controls.
enum PasalHaptic { none, light, selection }

/// Tactile press wrapper applying Emil Kowalski's responsive `scale(0.97)`
/// press state on pointer-down (0ms gesture-arena lag) with a strong ease-out curve.
class PasalPressable extends StatefulWidget {
  const PasalPressable({
    super.key,
    required this.onTap,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(AppRadii.lg)),
    this.enabled = true,
    this.haptic = PasalHaptic.none,
    this.ensureMinTouchTarget = false,
  });

  final VoidCallback? onTap;
  final Widget child;
  final BorderRadius borderRadius;
  final bool enabled;
  final PasalHaptic haptic;
  final bool ensureMinTouchTarget;

  @override
  State<PasalPressable> createState() => _PasalPressableState();
}

class _PasalPressableState extends State<PasalPressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (!widget.enabled || widget.onTap == null) return;
    if (_pressed != value) {
      setState(() => _pressed = value);
    }
  }

  void _triggerHaptic() {
    switch (widget.haptic) {
      case PasalHaptic.none:
        return;
      case PasalHaptic.light:
        HapticFeedback.lightImpact();
      case PasalHaptic.selection:
        HapticFeedback.selectionClick();
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = AppMotion.shouldReduceMotion(context);
    final duration = reduceMotion
        ? Duration.zero
        : (_pressed ? AppMotion.buttonPress : AppMotion.buttonRelease);

    Widget content = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (widget.enabled && widget.onTap != null) {
          _triggerHaptic();
          _setPressed(true);
        }
      },
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: (_pressed && !reduceMotion) ? AppMotion.pressScale : 1.0,
        duration: duration,
        curve: AppMotion.easeOut,
        child: Material(
          color: Colors.transparent,
          borderRadius: widget.borderRadius,
          child: InkWell(
            onTap: widget.enabled ? widget.onTap : null,
            onTapCancel: () => _setPressed(false),
            borderRadius: widget.borderRadius,
            child: widget.child,
          ),
        ),
      ),
    );

    if (widget.ensureMinTouchTarget) {
      content = ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: AppSpacing.minTouchTarget,
          minHeight: AppSpacing.minTouchTarget,
        ),
        child: content,
      );
    }

    return content;
  }
}

/// Crossfades between keyed child states (e.g. `Sync` -> `Syncing...` -> `Done`)
/// using a subtle transient `<= 2px` blur to bridge the two visual states cleanly.
class PasalBlurStateSwitcher extends StatelessWidget {
  const PasalBlurStateSwitcher({
    super.key,
    required this.child,
    this.duration = AppMotion.popover,
    this.maxBlurSigma = 2.0,
  });

  final Widget child;
  final Duration duration;
  final double maxBlurSigma;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = AppMotion.shouldReduceMotion(context);
    final effectiveDuration = AppMotion.resolveDuration(context, duration);

    return AnimatedSwitcher(
      duration: effectiveDuration,
      reverseDuration: AppMotion.resolveDuration(
        context,
        AppMotion.popoverExit,
      ),
      switchInCurve: AppMotion.easeOut,
      switchOutCurve: AppMotion.easeOut,
      transitionBuilder: (widget, animation) {
        if (reduceMotion) {
          return FadeTransition(opacity: animation, child: widget);
        }
        return AnimatedBuilder(
          animation: animation,
          builder: (ctx, childWidget) {
            final sigma = (1.0 - animation.value).clamp(0.0, 1.0) * maxBlurSigma;
            final faded = FadeTransition(
              opacity: animation,
              child: childWidget,
            );
            if (sigma < 0.08) return faded;
            return ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: faded,
            );
          },
          child: widget,
        );
      },
      child: child,
    );
  }
}

/// Option descriptor for [PasalClipSegmentedTabs].
@immutable
class PasalSegmentOption<T> {
  const PasalSegmentOption({
    required this.value,
    required this.label,
    this.icon,
    this.key,
  });

  final T value;
  final String label;
  final IconData? icon;
  final Key? key;
}

/// Segmented tab bar using a sliding pill and `ShaderMask` clip boundary so
/// text colors transition seamlessly across glyphs without duplicate `Text` nodes.
class PasalClipSegmentedTabs<T> extends StatelessWidget {
  const PasalClipSegmentedTabs({
    super.key,
    required this.options,
    required this.selectedValue,
    required this.onChanged,
    this.height = 38,
    this.activePillColor,
    this.activeForegroundColor,
    this.inactiveForegroundColor,
    this.trackColor,
  });

  final List<PasalSegmentOption<T>> options;
  final T selectedValue;
  final ValueChanged<T> onChanged;
  final double height;
  final Color? activePillColor;
  final Color? activeForegroundColor;
  final Color? inactiveForegroundColor;
  final Color? trackColor;

  @override
  Widget build(BuildContext context) {
    assert(options.isNotEmpty, 'PasalClipSegmentedTabs requires >= 1 option');
    final c = context.pasalColors;
    final t = context.textTheme;
    final count = options.length;
    final rawIndex = options.indexWhere((o) => o.value == selectedValue);
    final selectedIndex = rawIndex < 0 ? 0 : rawIndex;

    final track = trackColor ?? c.surfaceContainer;
    final pill = activePillColor ?? c.surfaceContainerLowest;
    final activeFg = activeForegroundColor ?? c.primary;
    final inactiveFg = inactiveForegroundColor ?? c.onSurfaceVariant;

    final duration = AppMotion.shouldReduceMotion(context)
        ? Duration.zero
        : AppMotion.popover;

    return Container(
      height: height + 8,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: track,
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final totalW = constraints.maxWidth;
          final segW = totalW / count;

          return TweenAnimationBuilder<double>(
            tween: Tween<double>(end: selectedIndex.toDouble()),
            duration: duration,
            curve: AppMotion.easeOut,
            builder: (context, animIndex, _) {
              final leftPx = animIndex * segW;
              final startStop = (animIndex / count).clamp(0.0, 1.0);
              final endStop = ((animIndex + 1.0) / count).clamp(0.0, 1.0);

              return Stack(
                children: [
                  Positioned(
                    left: leftPx,
                    top: 0,
                    bottom: 0,
                    width: segW,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: pill,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: c.hairline),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.04),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ),
                  ShaderMask(
                    blendMode: BlendMode.srcIn,
                    shaderCallback: (bounds) {
                      return LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          inactiveFg,
                          inactiveFg,
                          activeFg,
                          activeFg,
                          inactiveFg,
                          inactiveFg,
                        ],
                        stops: [
                          0.0,
                          startStop,
                          startStop,
                          endStop,
                          endStop,
                          1.0,
                        ],
                      ).createShader(bounds);
                    },
                    child: Row(
                      children: [
                        for (final opt in options)
                          Expanded(
                            child: Semantics(
                              button: true,
                              selected: opt.value == selectedValue,
                              child: InkWell(
                                key: opt.key,
                                borderRadius: BorderRadius.circular(6),
                                onTap: () {
                                  if (opt.value != selectedValue) {
                                    HapticFeedback.selectionClick();
                                    onChanged(opt.value);
                                  }
                                },
                                child: SizedBox(
                                  height: height,
                                  child: Center(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          if (opt.icon != null) ...[
                                            Icon(
                                              opt.icon,
                                              size: 15,
                                              color: Colors.white,
                                            ),
                                            const SizedBox(width: 4),
                                          ],
                                          Flexible(
                                            child: Text(
                                              opt.label,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: t.labelMedium?.copyWith(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Asymmetric hold-to-confirm destructive action button:
/// 2s linear fill while held + `scale(0.97)` press feedback, snapping back
/// over `200ms easeOut` if released early.
class PasalHoldToConfirmButton extends StatefulWidget {
  const PasalHoldToConfirmButton({
    super.key,
    required this.label,
    required this.onConfirmed,
    this.holdingLabel,
    this.icon,
    this.duration = AppMotion.holdConfirm,
    this.enabled = true,
    this.backgroundColor,
    this.fillColor,
    this.foregroundColor,
    this.fillForegroundColor,
  });

  final String label;
  final String? holdingLabel;
  final VoidCallback onConfirmed;
  final IconData? icon;
  final Duration duration;
  final bool enabled;
  final Color? backgroundColor;
  final Color? fillColor;
  final Color? foregroundColor;
  final Color? fillForegroundColor;

  @override
  State<PasalHoldToConfirmButton> createState() =>
      _PasalHoldToConfirmButtonState();
}

class _PasalHoldToConfirmButtonState extends State<PasalHoldToConfirmButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fillCtrl;
  bool _pressed = false;
  bool _fired = false;

  @override
  void initState() {
    super.initState();
    _fillCtrl = AnimationController(
      vsync: this,
      duration: widget.duration,
      reverseDuration: AppMotion.holdSnapBack,
    );
    _fillCtrl.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_fired && mounted) {
        _fired = true;
        _pressed = false;
        HapticFeedback.heavyImpact();
        widget.onConfirmed();
      }
    });
  }

  @override
  void didUpdateWidget(covariant PasalHoldToConfirmButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _fillCtrl.duration = widget.duration;
    }
  }

  @override
  void dispose() {
    _fillCtrl.dispose();
    super.dispose();
  }

  void _startHold() {
    if (!widget.enabled) return;
    _fired = false;
    setState(() => _pressed = true);
    HapticFeedback.lightImpact();
    _fillCtrl.forward(from: _fillCtrl.value);
  }

  void _cancelHold() {
    if (!_pressed && _fillCtrl.value == 0) return;
    setState(() => _pressed = false);
    if (!_fired) {
      _fillCtrl.animateBack(
        0.0,
        duration: AppMotion.holdSnapBack,
        curve: AppMotion.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final reduceMotion = AppMotion.shouldReduceMotion(context);

    final bg = widget.backgroundColor ?? c.errorContainer;
    final fill = widget.fillColor ?? c.error;
    final fg = widget.foregroundColor ?? c.onErrorContainer;
    final fillFg = widget.fillForegroundColor ?? c.onError;
    final displayText =
        (_pressed && widget.holdingLabel != null) ? widget.holdingLabel! : widget.label;

    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      hint: 'Hold for 2 seconds to confirm',
      child: Listener(
        onPointerDown: (_) => _startHold(),
        onPointerUp: (_) => _cancelHold(),
        onPointerCancel: (_) => _cancelHold(),
        child: AnimatedScale(
          scale: (_pressed && !reduceMotion) ? AppMotion.pressScale : 1.0,
          duration: reduceMotion ? Duration.zero : AppMotion.buttonPress,
          curve: AppMotion.easeOut,
          child: Opacity(
            opacity: widget.enabled ? 1.0 : 0.45,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.lg),
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(AppRadii.lg),
                  border: Border.all(color: fill.withValues(alpha: 0.35)),
                ),
                child: AnimatedBuilder(
                  animation: _fillCtrl,
                  builder: (context, _) {
                    final progress = _fillCtrl.value.clamp(0.0, 1.0);
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        Positioned.fill(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: progress,
                              heightFactor: 1.0,
                              child: ColoredBox(color: fill),
                            ),
                          ),
                        ),
                        ShaderMask(
                          blendMode: BlendMode.srcIn,
                          shaderCallback: (bounds) {
                            return LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: [fillFg, fillFg, fg, fg],
                              stops: [0.0, progress, progress, 1.0],
                            ).createShader(bounds);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.md,
                              vertical: 12,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (widget.icon != null) ...[
                                  Icon(widget.icon, size: 18, color: Colors.white),
                                  const SizedBox(width: 8),
                                ],
                                Flexible(
                                  child: Text(
                                    displayText,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: t.labelLarge?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows a modal dialog entering from `scale(0.95) + opacity: 0` over `180ms`
/// (`AppMotion.easeOut`) instead of `scale(0)` or weak default curves.
Future<T?> showPasalDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  String? barrierLabel,
}) {
  final reduceMotion = AppMotion.shouldReduceMotion(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: barrierLabel ??
        MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration:
        reduceMotion ? const Duration(milliseconds: 120) : AppMotion.popover,
    pageBuilder: (ctx, _, _) => builder(ctx),
    transitionBuilder: (ctx, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: AppMotion.easeOut,
        reverseCurve: AppMotion.easeOut,
      );
      if (reduceMotion) {
        return FadeTransition(opacity: curved, child: child);
      }
      final scale = Tween<double>(
        begin: AppMotion.enterScale,
        end: 1.0,
      ).animate(curved);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: scale,
          child: child,
        ),
      );
    },
  );
}

/// Shows a modal bottom sheet using the steep iOS/Vaul drawer curve
/// (`Cubic(0.32, 0.72, 0, 1)`) with asymmetric `260ms` enter / `200ms` exit.
Future<T?> showPasalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = true,
  bool isDismissible = true,
  bool enableDrag = true,
  bool useSafeArea = false,
  Color? backgroundColor = Colors.transparent,
}) {
  final reduceMotion = AppMotion.shouldReduceMotion(context);
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    useSafeArea: useSafeArea,
    backgroundColor: backgroundColor,
    sheetAnimationStyle: AnimationStyle(
      duration:
          reduceMotion ? const Duration(milliseconds: 120) : AppMotion.modalSheet,
      reverseDuration: reduceMotion
          ? const Duration(milliseconds: 100)
          : AppMotion.modalSheetExit,
      curve: AppMotion.easeDrawer,
      reverseCurve: AppMotion.easeOut,
    ),
    builder: builder,
  );
}

/// Hairline-framed Nordic Botanical surface card.
class PasalCard extends StatelessWidget {
  const PasalCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.md),
    this.color,
    this.borderColor,
    this.borderRadius = AppRadii.lg,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? borderColor;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? c.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: borderColor ?? c.hairline),
      ),
      child: child,
    );
  }
}

/// Renders money / quantities with guaranteed `FontFeature.tabularFigures()`.
class PasalTabularText extends StatelessWidget {
  const PasalTabularText(
    this.text, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
  });

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final base = style ?? context.textTheme.bodyMedium!;
    return Text(
      text,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      style: AppTypography.withTabularFigures(base),
    );
  }
}

/// Small Stitch status badge pill (e.g. `TILL ACTIVE`, `LOW RESERVE`).
class PasalStatusBadge extends StatelessWidget {
  const PasalStatusBadge({
    super.key,
    required this.label,
    this.backgroundColor,
    this.foregroundColor,
    this.dotColor,
    this.icon,
  });

  final String label;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final Color? dotColor;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final bg = backgroundColor ?? c.secondaryContainer;
    final fg = foregroundColor ?? c.onSecondaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dotColor != null) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          if (icon != null) ...[
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.labelSmall?.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.7,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

