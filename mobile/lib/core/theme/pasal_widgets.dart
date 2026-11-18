import 'package:flutter/material.dart';
import 'app_spacing.dart';
import 'app_theme.dart';
import 'app_typography.dart';

export 'pasal_alert.dart';

/// Tactile press wrapper applying Emil Kowalski's responsive `scale(0.97)`
/// press state with a fast strong ease-out curve.
class PasalPressable extends StatefulWidget {
  const PasalPressable({
    super.key,
    required this.onTap,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(AppRadii.lg)),
    this.enabled = true,
  });

  final VoidCallback? onTap;
  final Widget child;
  final BorderRadius borderRadius;
  final bool enabled;

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

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _pressed ? AppMotion.pressScale : 1.0,
      duration: AppMotion.buttonPress,
      curve: AppMotion.easeOut,
      child: Material(
        color: Colors.transparent,
        borderRadius: widget.borderRadius,
        child: InkWell(
          onTap: widget.enabled ? widget.onTap : null,
          onTapDown: (_) => _setPressed(true),
          onTapUp: (_) => _setPressed(false),
          onTapCancel: () => _setPressed(false),
          borderRadius: widget.borderRadius,
          child: widget.child,
        ),
      ),
    );
  }
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

