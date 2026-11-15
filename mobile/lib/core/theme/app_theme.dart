import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'app_spacing.dart';
import 'app_typography.dart';

/// Builds the canonical Material 3 "Nordic Botanical & Slate" theme for PasalX.
abstract final class AppTheme {
  static ThemeData light() {
    const colors = PasalColors.light;
    final textTheme = AppTypography.textTheme(colors);

    final colorScheme = ColorScheme(
      brightness: Brightness.light,
      primary: colors.primary,
      onPrimary: colors.onPrimary,
      primaryContainer: colors.primaryContainer,
      onPrimaryContainer: colors.onPrimaryContainer,
      secondary: colors.secondary,
      onSecondary: colors.onSecondary,
      secondaryContainer: colors.secondaryContainer,
      onSecondaryContainer: colors.onSecondaryContainer,
      tertiary: colors.tertiary,
      onTertiary: Colors.white,
      error: colors.error,
      onError: colors.onError,
      errorContainer: colors.errorContainer,
      onErrorContainer: colors.onErrorContainer,
      surface: colors.surface,
      onSurface: colors.onSurface,
      onSurfaceVariant: colors.onSurfaceVariant,
      outline: colors.outline,
      outlineVariant: colors.outlineVariant,
      inverseSurface: colors.inverseSurface,
      onInverseSurface: colors.inverseOnSurface,
      inversePrimary: colors.inversePrimary,
      surfaceContainerLowest: colors.surfaceContainerLowest,
      surfaceContainerLow: colors.surfaceContainerLow,
      surfaceContainer: colors.surfaceContainer,
      surfaceContainerHigh: colors.surfaceContainerHigh,
      surfaceContainerHighest: colors.surfaceContainerHighest,
      surfaceDim: colors.surfaceDim,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colors.surface,
      textTheme: textTheme,
      extensions: const <ThemeExtension<dynamic>>[colors],
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface,
        foregroundColor: colors.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.headlineSmall,
      ),
      cardTheme: CardThemeData(
        color: colors.surfaceContainerLowest,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          side: BorderSide(color: colors.hairline),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colors.hairline,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerLowest,
        hintStyle: textTheme.bodySmall?.copyWith(color: colors.outline),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          borderSide: BorderSide(color: colors.hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          borderSide: BorderSide(color: colors.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          borderSide: BorderSide(color: colors.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          borderSide: BorderSide(color: colors.error),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colors.primary,
          foregroundColor: colors.onPrimary,
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.lg),
          ),
          textStyle: textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.primary,
          minimumSize: const Size(0, 44),
          side: BorderSide(color: colors.outlineVariant),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.lg),
          ),
          textStyle: textTheme.labelLarge,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadii.sheetTop),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.inverseSurface,
        contentTextStyle: textTheme.bodySmall?.copyWith(
          color: colors.inverseOnSurface,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.pill),
        ),
      ),
    );
  }
}

/// Ergonomic extension on [BuildContext] for accessing Nordic Botanical tokens.
extension PasalThemeContext on BuildContext {
  PasalColors get pasalColors =>
      Theme.of(this).extension<PasalColors>() ?? PasalColors.light;

  TextTheme get textTheme => Theme.of(this).textTheme;
  ColorScheme get colorScheme => Theme.of(this).colorScheme;
}

