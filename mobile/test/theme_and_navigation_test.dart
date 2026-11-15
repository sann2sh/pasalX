import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pasalx_mobile/app.dart';
import 'package:pasalx_mobile/core/router/app_router.dart';
import 'package:pasalx_mobile/core/theme/app_colors.dart';
import 'package:pasalx_mobile/core/theme/app_theme.dart';
import 'package:pasalx_mobile/core/theme/app_typography.dart';
import 'package:pasalx_mobile/core/theme/pasal_widgets.dart';

void main() {
  group('Nordic Botanical & Slate Theme', () {
    test('defines calibrated Stitch hex color tokens and typography', () {
      final theme = AppTheme.light();
      final ext = theme.extension<PasalColors>();

      expect(ext, isNotNull);
      expect(theme.colorScheme.primary, const Color(0xFF215542));
      expect(theme.colorScheme.primaryContainer, const Color(0xFF3B6E59));
      expect(theme.colorScheme.secondary, const Color(0xFF416657));
      expect(theme.colorScheme.secondaryContainer, const Color(0xFFC0E9D6));
      expect(theme.colorScheme.surface, const Color(0xFFF4FBF6));
      expect(theme.scaffoldBackgroundColor, const Color(0xFFF4FBF6));
      expect(theme.colorScheme.error, const Color(0xFFBA1A1A));
      expect(theme.colorScheme.errorContainer, const Color(0xFFFFDAD6));
      expect(ext!.surfaceContainerLow, const Color(0xFFEEF5F0));
      expect(ext.surfaceContainerLowest, const Color(0xFFFFFFFF));

      expect(theme.textTheme.headlineLarge?.fontFamily, 'Plus Jakarta Sans');
      expect(theme.textTheme.bodyMedium?.fontFamily, 'Plus Jakarta Sans');
      expect(theme.textTheme.labelMedium?.fontFamily, 'Inter');
      expect(
        theme.textTheme.displayLarge?.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
      expect(
        theme.textTheme.labelMedium?.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );

      final tabular = AppTypography.withTabularFigures(const TextStyle());
      expect(tabular.fontFeatures, contains(const FontFeature.tabularFigures()));
    });

    testWidgets('PasalTabularText applies tabularFigures fontFeature',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: PasalTabularText('Rs. 1,350.00'),
          ),
        ),
      );
      final widget = tester.widget<Text>(find.text('Rs. 1,350.00'));
      expect(
        widget.style?.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
    });
  });

  group('GoRouter 4-tab shell', () {
    testWidgets('navigates between /pos, /inventory, /register, and /settings on narrow viewport',
        (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final router = createAppRouter(initialLocation: AppRoutes.pos);
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          child: PasalXApp(routerOverride: router),
        ),
      );
      await tester.pumpAndSettle();

      // Starts on /pos
      expect(find.text('POS Counter'), findsOneWidget);

      // Tap Inventory tab -> /inventory
      await tester.tap(find.text('Inventory'));
      await tester.pumpAndSettle();
      expect(find.text('Inventory & Catalog'), findsOneWidget);
      expect(router.routeInformationProvider.value.uri.path, AppRoutes.inventory);

      // Tap Register tab -> /register
      await tester.tap(find.text('Register'));
      await tester.pumpAndSettle();
      expect(find.text('Register & Shift'), findsOneWidget);
      expect(router.routeInformationProvider.value.uri.path, AppRoutes.register);

      // Tap Settings tab -> /settings
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Settings & Security'), findsOneWidget);
      expect(router.routeInformationProvider.value.uri.path, AppRoutes.settings);

      // Deep-link back via GoRouter
      router.go(AppRoutes.pos);
      await tester.pumpAndSettle();
      expect(find.text('POS Counter'), findsOneWidget);
      expect(router.routeInformationProvider.value.uri.path, AppRoutes.pos);
    });
  });
}

