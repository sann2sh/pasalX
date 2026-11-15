import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pasalx_mobile/app.dart';

void main() {
  testWidgets('PasalXApp boots into 4-tab Nordic Botanical shell',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: PasalXApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('PasalX'), findsOneWidget);
    expect(find.text('POS Counter'), findsOneWidget);
    expect(find.text('POS'), findsOneWidget);
    expect(find.text('Inventory'), findsOneWidget);
    expect(find.text('Register'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);

    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.theme?.colorScheme.primary, const Color(0xFF215542));
  });
}
