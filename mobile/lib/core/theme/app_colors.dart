import 'package:flutter/material.dart';

/// Nordic Botanical & Slate color tokens calibrated from Stitch (`google_stitch.html`
/// and `stitch_supplementary_screens.html`) and `TECHNICAL_SPEC.md` §8.1.
@immutable
class PasalColors extends ThemeExtension<PasalColors> {
  const PasalColors({
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.primaryFixed,
    required this.primaryFixedDim,
    required this.secondary,
    required this.onSecondary,
    required this.secondaryContainer,
    required this.onSecondaryContainer,
    required this.tertiary,
    required this.surface,
    required this.surfaceContainerLowest,
    required this.surfaceContainerLow,
    required this.surfaceContainer,
    required this.surfaceContainerHigh,
    required this.surfaceContainerHighest,
    required this.surfaceDim,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.outline,
    required this.outlineVariant,
    required this.inverseSurface,
    required this.inverseOnSurface,
    required this.inversePrimary,
    required this.error,
    required this.onError,
    required this.errorContainer,
    required this.onErrorContainer,
    required this.warning,
    required this.warningContainer,
    required this.onWarningContainer,
  });

  final Color primary;
  final Color onPrimary;
  final Color primaryContainer;
  final Color onPrimaryContainer;
  final Color primaryFixed;
  final Color primaryFixedDim;
  final Color secondary;
  final Color onSecondary;
  final Color secondaryContainer;
  final Color onSecondaryContainer;
  final Color tertiary;
  final Color surface;
  final Color surfaceContainerLowest;
  final Color surfaceContainerLow;
  final Color surfaceContainer;
  final Color surfaceContainerHigh;
  final Color surfaceContainerHighest;
  final Color surfaceDim;
  final Color onSurface;
  final Color onSurfaceVariant;
  final Color outline;
  final Color outlineVariant;
  final Color inverseSurface;
  final Color inverseOnSurface;
  final Color inversePrimary;
  final Color error;
  final Color onError;
  final Color errorContainer;
  final Color onErrorContainer;
  final Color warning;
  final Color warningContainer;
  final Color onWarningContainer;

  /// Canonical Nordic Botanical light palette.
  static const PasalColors light = PasalColors(
    primary: Color(0xFF215542),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFF3B6E59),
    onPrimaryContainer: Color(0xFFB7EED4),
    primaryFixed: Color(0xFFB8EED4),
    primaryFixedDim: Color(0xFF9CD2B9),
    secondary: Color(0xFF416657),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFC0E9D6),
    onSecondaryContainer: Color(0xFF456A5B),
    tertiary: Color(0xFF454F4B),
    surface: Color(0xFFF4FBF6),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFEEF5F0),
    surfaceContainer: Color(0xFFE8F0EA),
    surfaceContainerHigh: Color(0xFFE3EAE5),
    surfaceContainerHighest: Color(0xFFDDE4DF),
    surfaceDim: Color(0xFFD4DCD7),
    onSurface: Color(0xFF161D1A),
    onSurfaceVariant: Color(0xFF404944),
    outline: Color(0xFF707974),
    outlineVariant: Color(0xFFC0C9C2),
    inverseSurface: Color(0xFF2B322F),
    inverseOnSurface: Color(0xFFEBF2ED),
    inversePrimary: Color(0xFF9CD2B9),
    error: Color(0xFFBA1A1A),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFFFDAD6),
    onErrorContainer: Color(0xFF93000A),
    warning: Color(0xFFB45309),
    warningContainer: Color(0xFFFEF3C7),
    onWarningContainer: Color(0xFF78350F),
  );

  /// Subtle hairline border color matching Stitch whisper stroke.
  Color get hairline => outlineVariant.withValues(alpha: 0.45);

  @override
  PasalColors copyWith({
    Color? primary,
    Color? onPrimary,
    Color? primaryContainer,
    Color? onPrimaryContainer,
    Color? primaryFixed,
    Color? primaryFixedDim,
    Color? secondary,
    Color? onSecondary,
    Color? secondaryContainer,
    Color? onSecondaryContainer,
    Color? tertiary,
    Color? surface,
    Color? surfaceContainerLowest,
    Color? surfaceContainerLow,
    Color? surfaceContainer,
    Color? surfaceContainerHigh,
    Color? surfaceContainerHighest,
    Color? surfaceDim,
    Color? onSurface,
    Color? onSurfaceVariant,
    Color? outline,
    Color? outlineVariant,
    Color? inverseSurface,
    Color? inverseOnSurface,
    Color? inversePrimary,
    Color? error,
    Color? onError,
    Color? errorContainer,
    Color? onErrorContainer,
    Color? warning,
    Color? warningContainer,
    Color? onWarningContainer,
  }) {
    return PasalColors(
      primary: primary ?? this.primary,
      onPrimary: onPrimary ?? this.onPrimary,
      primaryContainer: primaryContainer ?? this.primaryContainer,
      onPrimaryContainer: onPrimaryContainer ?? this.onPrimaryContainer,
      primaryFixed: primaryFixed ?? this.primaryFixed,
      primaryFixedDim: primaryFixedDim ?? this.primaryFixedDim,
      secondary: secondary ?? this.secondary,
      onSecondary: onSecondary ?? this.onSecondary,
      secondaryContainer: secondaryContainer ?? this.secondaryContainer,
      onSecondaryContainer: onSecondaryContainer ?? this.onSecondaryContainer,
      tertiary: tertiary ?? this.tertiary,
      surface: surface ?? this.surface,
      surfaceContainerLowest:
          surfaceContainerLowest ?? this.surfaceContainerLowest,
      surfaceContainerLow: surfaceContainerLow ?? this.surfaceContainerLow,
      surfaceContainer: surfaceContainer ?? this.surfaceContainer,
      surfaceContainerHigh: surfaceContainerHigh ?? this.surfaceContainerHigh,
      surfaceContainerHighest:
          surfaceContainerHighest ?? this.surfaceContainerHighest,
      surfaceDim: surfaceDim ?? this.surfaceDim,
      onSurface: onSurface ?? this.onSurface,
      onSurfaceVariant: onSurfaceVariant ?? this.onSurfaceVariant,
      outline: outline ?? this.outline,
      outlineVariant: outlineVariant ?? this.outlineVariant,
      inverseSurface: inverseSurface ?? this.inverseSurface,
      inverseOnSurface: inverseOnSurface ?? this.inverseOnSurface,
      inversePrimary: inversePrimary ?? this.inversePrimary,
      error: error ?? this.error,
      onError: onError ?? this.onError,
      errorContainer: errorContainer ?? this.errorContainer,
      onErrorContainer: onErrorContainer ?? this.onErrorContainer,
      warning: warning ?? this.warning,
      warningContainer: warningContainer ?? this.warningContainer,
      onWarningContainer: onWarningContainer ?? this.onWarningContainer,
    );
  }

  @override
  PasalColors lerp(ThemeExtension<PasalColors>? other, double t) {
    if (other is! PasalColors) return this;
    return PasalColors(
      primary: Color.lerp(primary, other.primary, t)!,
      onPrimary: Color.lerp(onPrimary, other.onPrimary, t)!,
      primaryContainer: Color.lerp(primaryContainer, other.primaryContainer, t)!,
      onPrimaryContainer:
          Color.lerp(onPrimaryContainer, other.onPrimaryContainer, t)!,
      primaryFixed: Color.lerp(primaryFixed, other.primaryFixed, t)!,
      primaryFixedDim: Color.lerp(primaryFixedDim, other.primaryFixedDim, t)!,
      secondary: Color.lerp(secondary, other.secondary, t)!,
      onSecondary: Color.lerp(onSecondary, other.onSecondary, t)!,
      secondaryContainer:
          Color.lerp(secondaryContainer, other.secondaryContainer, t)!,
      onSecondaryContainer:
          Color.lerp(onSecondaryContainer, other.onSecondaryContainer, t)!,
      tertiary: Color.lerp(tertiary, other.tertiary, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceContainerLowest:
          Color.lerp(surfaceContainerLowest, other.surfaceContainerLowest, t)!,
      surfaceContainerLow:
          Color.lerp(surfaceContainerLow, other.surfaceContainerLow, t)!,
      surfaceContainer: Color.lerp(surfaceContainer, other.surfaceContainer, t)!,
      surfaceContainerHigh:
          Color.lerp(surfaceContainerHigh, other.surfaceContainerHigh, t)!,
      surfaceContainerHighest: Color.lerp(
          surfaceContainerHighest, other.surfaceContainerHighest, t)!,
      surfaceDim: Color.lerp(surfaceDim, other.surfaceDim, t)!,
      onSurface: Color.lerp(onSurface, other.onSurface, t)!,
      onSurfaceVariant: Color.lerp(onSurfaceVariant, other.onSurfaceVariant, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      outlineVariant: Color.lerp(outlineVariant, other.outlineVariant, t)!,
      inverseSurface: Color.lerp(inverseSurface, other.inverseSurface, t)!,
      inverseOnSurface: Color.lerp(inverseOnSurface, other.inverseOnSurface, t)!,
      inversePrimary: Color.lerp(inversePrimary, other.inversePrimary, t)!,
      error: Color.lerp(error, other.error, t)!,
      onError: Color.lerp(onError, other.onError, t)!,
      errorContainer: Color.lerp(errorContainer, other.errorContainer, t)!,
      onErrorContainer: Color.lerp(onErrorContainer, other.onErrorContainer, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningContainer: Color.lerp(warningContainer, other.warningContainer, t)!,
      onWarningContainer:
          Color.lerp(onWarningContainer, other.onWarningContainer, t)!,
    );
  }
}

