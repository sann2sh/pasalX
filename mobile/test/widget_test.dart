import 'package:flutter_test/flutter_test.dart';
import 'package:pasalx_mobile/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const PasalXApp());
    expect(find.text('PasalX Mobile POS & Inventory'), findsOneWidget);
  });
}
