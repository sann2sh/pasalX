import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pasalx_mobile/app.dart';
import 'package:pasalx_mobile/core/providers/foundation_providers.dart';
import 'package:pasalx_mobile/core/router/app_router.dart';
import 'package:pasalx_mobile/core/security/keystore_dek_manager.dart';

void main() {
  testWidgets('PasalXApp boots into Auth & Shift Gate when terminal is locked',
      (WidgetTester tester) async {
    final store = InMemorySecureKeyValueStore();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureKeyValueStoreProvider.overrideWithValue(store),
        ],
        child: const PasalXApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('PasalX'), findsOneWidget);
    expect(find.text('Sign in to your PasalX account'), findsOneWidget);

    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.theme?.colorScheme.primary, const Color(0xFF215542));
  });

  testWidgets('PasalXApp renders 5-tab Nordic Botanical shell when routed',
      (WidgetTester tester) async {
    final router = createAppRouter(initialLocation: AppRoutes.home);
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: PasalXApp(routerOverride: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('PasalX'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    expect(find.text('Sale'), findsOneWidget);
    expect(find.text('Stock'), findsOneWidget);
    expect(find.text('Shift'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('topbar-profile-btn')), findsOneWidget);
  });
}
