import 'package:flutter/animation.dart';

/// Design spacing & radius tokens mapped from the Stitch Tailwind config.
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 40;
  static const double gutterMobile = 16;
  static const double marginMobile = 20;
  static const double minTouchTarget = 44;
}

abstract final class AppRadii {
  static const double sm = 4;
  static const double md = 8;
  static const double lg = 12;
  static const double xl = 16;
  static const double sheetTop = 20;
  static const double pill = 999;
}

/// Custom UI motion constants following Emil Kowalski's design engineering rules
/// (`emil-design-eng`): strong ease-out curves, <=300ms transitions, zero ease-in.
abstract final class AppMotion {
  /// Strong ease-out curve matching `--ease-out: cubic-bezier(0.23, 1, 0.32, 1)`.
  static const Curve easeOut = Cubic(0.23, 1.0, 0.32, 1.0);

  /// Strong ease-in-out curve matching `--ease-in-out: cubic-bezier(0.77, 0, 0.175, 1)`.
  static const Curve easeInOut = Cubic(0.77, 0.0, 0.175, 1.0);

  /// Tactile sheet / drawer curve matching `--ease-drawer: cubic-bezier(0.32, 0.72, 0, 1)`.
  static const Curve easeDrawer = Cubic(0.32, 0.72, 0.0, 1.0);

  static const Duration buttonPress = Duration(milliseconds: 120);
  static const Duration popover = Duration(milliseconds: 180);
  static const Duration modalSheet = Duration(milliseconds: 260);
  static const double pressScale = 0.97;
}

