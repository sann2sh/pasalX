import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pasalx_mobile/app.dart';
import 'package:pasalx_mobile/core/providers/foundation_providers.dart';
import 'package:pasalx_mobile/core/router/app_router.dart';
import 'package:pasalx_mobile/core/security/ram_key_holder.dart';
import 'package:pasalx_mobile/core/theme/app_colors.dart';
import 'package:pasalx_mobile/core/theme/app_theme.dart';
import 'package:pasalx_mobile/core/theme/app_typography.dart';
import 'package:pasalx_mobile/core/theme/pasal_widgets.dart';

void main() {
  group('Nordic Botanical & Slate Theme', () {
    test('defines calibrated Stitch hex color tokens, warning surface, and typography', () {
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

      // Semantic warning & success fixed tokens for subtle popups
      expect(ext.warningContainer, const Color(0xFFFEF3C7));
      expect(ext.warningBorder, const Color(0xFFF59E0B));
      expect(ext.onWarningContainer, const Color(0xFF78350F));
      expect(ext.onPrimaryFixed, const Color(0xFF002115));

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

  group('PasalAlertOverlay subtle popups', () {
    testWidgets('renders warning, error, success popups, triggers action & auto-dismisses',
        (tester) async {
      final router = createAppRouter(initialLocation: AppRoutes.home);
      addTearDown(router.dispose);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: PasalXApp(routerOverride: router),
        ),
      );
      await tester.pumpAndSettle();

      var actionCalled = false;
      final alerts = container.read(pasalAlertProvider);

      // 1. Yellow Warning with action pill
      alerts.showWarning(
        '2 batches expire within 30 days',
        actionLabel: 'View',
        onAction: () => actionCalled = true,
        duration: Duration.zero,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('pasal-alert-warning')), findsOneWidget);
      expect(find.text('2 batches expire within 30 days'), findsOneWidget);
      expect(find.text('View'), findsOneWidget);

      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      expect(actionCalled, isTrue);
      expect(find.byKey(const ValueKey<String>('pasal-alert-warning')), findsNothing);

      // 2. Red Error + dismiss button
      alerts.showError(
        'Printer offline. Check Wi-Fi or IP.',
        duration: Duration.zero,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('pasal-alert-error')), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('pasal-alert-error')), findsNothing);

      // 3. Dark Botanical Success + auto-dismiss timer
      alerts.showSuccess(
        'Backup & sync complete',
        duration: const Duration(milliseconds: 500),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('pasal-alert-success')), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('pasal-alert-success')), findsNothing);
    });
  });

  group('GoRouter 5-tab shell', () {
    testWidgets(
        'navigates across Home, History, Sale (+), Stock, Shift, stack routes & profile Settings',
        (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final now = DateTime.now().toUtc();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(ramKeyHolderProvider).unlock(
        dekBytes: Uint8List.fromList(List<int>.filled(32, 7)),
        session: ActiveLeaseSession(
          userId: 'user-owner-1',
          username: 'Ramesh',
          role: 'OWNER',
          deviceId: 'dev-1',
          deviceCode: '01',
          leaseId: 'lease-1',
          issuedAt: now,
          expiresAt: now.add(const Duration(hours: 12)),
        ),
      );

      final router = createAppRouter(initialLocation: AppRoutes.home);
      addTearDown(router.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: PasalXApp(routerOverride: router),
        ),
      );
      await tester.pumpAndSettle();

      // Starts on /home with single profile avatar (no duplicate settings tab)
      expect(find.text("TODAY'S TOTAL SALES"), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('topbar-profile-btn')), findsOneWidget);
      expect(find.text('RA'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('topbar-intake-btn')), findsNothing);

      // Tap History tab -> /history
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(find.text('Sales (0)'), findsOneWidget);
      expect(router.routeInformationProvider.value.uri.path, AppRoutes.history);

      // Tap center elevated Sale (+) tab -> /pos
      await tester.tap(find.text('Sale'));
      await tester.pumpAndSettle();
      expect(find.text('POS Counter'), findsWidgets);
      expect(router.routeInformationProvider.value.uri.path, AppRoutes.pos);

      // Tap Stock tab -> /inventory (shows + Intake for Owner)
      await tester.tap(find.text('Stock'));
      await tester.pumpAndSettle();
      expect(find.text('Stock Catalog'), findsOneWidget);
      expect(find.text('ACTIVE SKUS'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('topbar-intake-btn')), findsOneWidget);
      expect(router.routeInformationProvider.value.uri.path, AppRoutes.inventory);

      // Tap Shift tab -> /register
      await tester.tap(find.text('Shift'));
      await tester.pumpAndSettle();
      expect(find.text("Today's Shift"), findsOneWidget);
      expect(router.routeInformationProvider.value.uri.path, AppRoutes.register);

      // Tap Profile Avatar -> pushes /settings stack route (with Back arrow)
      await tester.tap(find.byKey(const ValueKey<String>('topbar-profile-btn')));
      await tester.pumpAndSettle();
      expect(find.text('DEVICES & SHOP BACKUP'), findsOneWidget);
      expect(
        router.routerDelegate.currentConfiguration.matches.last.matchedLocation,
        AppRoutes.settings,
      );

      // Navigate to new stack routes cleanly
      router.push(AppRoutes.settingsPrinter);
      await tester.pumpAndSettle();
      expect(find.text('Printer Settings'), findsWidgets);
      expect(
        router.routerDelegate.currentConfiguration.matches.last.matchedLocation,
        AppRoutes.settingsPrinter,
      );

      router.push(AppRoutes.settingsBackup);
      await tester.pumpAndSettle();
      expect(find.text('Backup & Sync'), findsWidgets);
      expect(
        router.routerDelegate.currentConfiguration.matches.last.matchedLocation,
        AppRoutes.settingsBackup,
      );

      router.push(AppRoutes.khata);
      await tester.pumpAndSettle();
      expect(find.text('Customer Khata'), findsWidgets);
      expect(
        router.routerDelegate.currentConfiguration.matches.last.matchedLocation,
        AppRoutes.khata,
      );

      // Deep-link back via GoRouter to /home
      router.go(AppRoutes.home);
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, AppRoutes.home);
    });
  });
}
