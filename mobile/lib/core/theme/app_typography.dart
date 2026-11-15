import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Typographic matrix combining `Plus Jakarta Sans` (headlines/body) and
/// `Inter` (micro-caps labels & tabular numerals) per `TECHNICAL_SPEC.md` §8.1.
abstract final class AppTypography {
  static const String displayFontFamily = 'Plus Jakarta Sans';
  static const String labelFontFamily = 'Inter';
  static const List<String> fallbackFamilies = ['Roboto', 'sans-serif'];

  static const List<FontFeature> tabularFeatures = [
    FontFeature.tabularFigures(),
  ];

  /// Ensures tabular numeral alignment for prices, batches, counts, and timestamps.
  static TextStyle withTabularFigures(TextStyle style) {
    return style.copyWith(fontFeatures: tabularFeatures);
  }

  static TextTheme textTheme(PasalColors colors) {
    return TextTheme(
      displayLarge: TextStyle(
        fontFamily: displayFontFamily,
        fontFamilyFallback: fallbackFamilies,
        fontSize: 36, // 2.25rem mobile hero figure
        height: 44 / 36,
        letterSpacing: -0.02 * 36,
        fontWeight: FontWeight.w700,
        color: colors.onSurface,
        fontFeatures: tabularFeatures,
      ),
      headlineLarge: TextStyle(
        fontFamily: displayFontFamily,
        fontFamilyFallback: fallbackFamilies,
        fontSize: 24, // 1.5rem
        height: 32 / 24,
        letterSpacing: -0.015 * 24,
        fontWeight: FontWeight.w600,
        color: colors.onSurface,
      ),
      headlineSmall: TextStyle(
        fontFamily: displayFontFamily,
        fontFamilyFallback: fallbackFamilies,
        fontSize: 20, // 1.25rem
        height: 28 / 20,
        letterSpacing: -0.01 * 20,
        fontWeight: FontWeight.w600,
        color: colors.onSurface,
      ),
      titleMedium: TextStyle(
        fontFamily: displayFontFamily,
        fontFamilyFallback: fallbackFamilies,
        fontSize: 16,
        height: 22 / 16,
        letterSpacing: -0.005 * 16,
        fontWeight: FontWeight.w600,
        color: colors.onSurface,
      ),
      bodyLarge: TextStyle(
        fontFamily: displayFontFamily,
        fontFamilyFallback: fallbackFamilies,
        fontSize: 18, // 1.125rem
        height: 28 / 18,
        letterSpacing: -0.005 * 18,
        fontWeight: FontWeight.w400,
        color: colors.onSurface,
      ),
      bodyMedium: TextStyle(
        fontFamily: displayFontFamily,
        fontFamilyFallback: fallbackFamilies,
        fontSize: 15, // 0.9375rem
        height: 24 / 15,
        letterSpacing: 0,
        fontWeight: FontWeight.w400,
        color: colors.onSurface,
      ),
      bodySmall: TextStyle(
        fontFamily: displayFontFamily,
        fontFamilyFallback: fallbackFamilies,
        fontSize: 13, // 0.8125rem
        height: 20 / 13,
        letterSpacing: 0.01 * 13,
        fontWeight: FontWeight.w400,
        color: colors.onSurfaceVariant,
      ),
      labelLarge: TextStyle(
        fontFamily: labelFontFamily,
        fontFamilyFallback: fallbackFamilies,
        fontSize: 13,
        height: 18 / 13,
        letterSpacing: 0.04 * 13,
        fontWeight: FontWeight.w600,
        color: colors.onSurface,
        fontFeatures: tabularFeatures,
      ),
      labelMedium: TextStyle(
        fontFamily: labelFontFamily,
        fontFamilyFallback: fallbackFamilies,
        fontSize: 12, // 0.75rem
        height: 16 / 12,
        letterSpacing: 0.08 * 12,
        fontWeight: FontWeight.w600,
        color: colors.onSurfaceVariant,
        fontFeatures: tabularFeatures,
      ),
      labelSmall: TextStyle(
        fontFamily: labelFontFamily,
        fontFamilyFallback: fallbackFamilies,
        fontSize: 11, // 0.6875rem
        height: 14 / 11,
        letterSpacing: 0.10 * 11,
        fontWeight: FontWeight.w500,
        color: colors.outline,
        fontFeatures: tabularFeatures,
      ),
    );
  }
}

