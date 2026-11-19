import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pasalx_mobile/core/providers/foundation_providers.dart';
import 'package:pasalx_mobile/core/security/ram_key_holder.dart';
import 'package:pasalx_mobile/core/theme/app_theme.dart';
import 'package:pasalx_mobile/core/theme/pasal_widgets.dart';
import 'package:pasalx_mobile/features/auth/presentation/account_auth_screen.dart';
import 'package:pasalx_mobile/features/auth/presentation/store_setup_screen.dart';
import 'package:pasalx_mobile/features/pos/application/pos_providers.dart';
import 'package:pasalx_mobile/features/pos/domain/pos_models.dart';
import 'package:pasalx_mobile/features/pos/presentation/checkout_sheet.dart';
import 'package:pasalx_mobile/features/pos/presentation/pos_screen.dart';

PosScannedBatch _batch(String id, String name, int pricePaisa) {
  return PosScannedBatch(
    batchId: id,
    productId: 'p-$id',
    variantId: 'v-$id',
    productName: name,
    brand: 'Maybelline',
    category: 'Makeup - Lips',
    isGeneric: false,
    variantName: 'Shade #01',
    colorHex: '#A63A3A',
    batchCode: 'LOT-$id',
    stickerBarcode: '01000$id',
    sellingPricePaisa: pricePaisa,
    costPricePaisa: null,
    stockQuantity: 12,
    expiryDate: DateTime(2028, 12, 31),
  );
}

void main() {
  group('Phase 3 Screen Choreography', () {
    testWidgets(
      'PosScreen animates cart removal gap-close, qty pulse, and CheckoutSheet PasalClipSegmentedTabs',
      (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final now = DateTime.now().toUtc();
        final holder = RamKeyHolder()
          ..unlock(
            dekBytes: Uint8List(32),
            session: ActiveLeaseSession(
              userId: 'u1',
              username: 'sita',
              role: 'STAFF',
              deviceId: 'd1',
              deviceCode: '01',
              leaseId: 'l1',
              issuedAt: now,
              expiresAt: now.add(const Duration(hours: 12)),
            ),
          );

        final container = ProviderContainer(
          overrides: [
            ramKeyHolderProvider.overrideWith((ref) => holder),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(),
              home: const PasalAlertOverlay(
                child: Scaffold(body: PosScreen()),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final cartNotifier = container.read(posCartProvider.notifier);
        final item1 = _batch('1', 'SuperStay Matte Ink', 120000);
        final item2 = _batch('2', 'Fit Me Foundation', 95000);

        cartNotifier.addBatch(item1);
        cartNotifier.addBatch(item2);
        await tester.pumpAndSettle();

        expect(find.text('SuperStay Matte Ink'), findsOneWidget);
        expect(find.text('Fit Me Foundation'), findsOneWidget);

        // Increment item 2 -> triggers qty pulse without layout overflow.
        final key1 = container.read(posCartProvider).items[0].lineKey;
        final key2 = container.read(posCartProvider).items[1].lineKey;
        cartNotifier.incrementQty(key2);
        await tester.pump(const Duration(milliseconds: 80));
        await tester.pumpAndSettle();
        expect(find.text('2'), findsOneWidget);

        // Remove item 1 -> gap-close exit animation runs smoothly and removes row.
        final item2TopBefore = tester.getTopLeft(find.text('Fit Me Foundation')).dy;
        cartNotifier.removeItem(key1);
        await tester.pump(const Duration(milliseconds: 70));
        await tester.pumpAndSettle();

        expect(find.text('SuperStay Matte Ink'), findsNothing);
        expect(find.text('Fit Me Foundation'), findsOneWidget);
        final item2TopAfter = tester.getTopLeft(find.text('Fit Me Foundation')).dy;
        expect(item2TopAfter, lessThan(item2TopBefore));

        // Open CheckoutSheet via Cash button -> PasalClipSegmentedTabs switches smoothly.
        await tester.tap(find.text('Cash'));
        await tester.pumpAndSettle();

        expect(find.byType(PasalClipSegmentedTabs<CheckoutTab>), findsOneWidget);
        expect(find.text('Cash Tendered (Rs.)'), findsOneWidget);

        await tester.tap(find.text('Fonepay QR'));
        await tester.pumpAndSettle();
        expect(find.text('STATIC FONEPAY QR • OFFLINE READY'), findsOneWidget);

        await tester.tap(find.text('Khata').last);
        await tester.pumpAndSettle();
        expect(find.text('Pick Khata Customer'), findsOneWidget);
      },
    );

    testWidgets(
      'AccountAuthScreen and StoreSetupScreen use PasalClipSegmentedTabs with AnimatedSize',
      (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: AppTheme.light(),
              home: const AccountAuthScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(PasalClipSegmentedTabs<bool>), findsOneWidget);
        expect(find.text('Log In'), findsNWidgets(2)); // tab + button
        await tester.tap(find.text('Sign Up'));
        await tester.pumpAndSettle();
        expect(find.text('Full Name'), findsOneWidget);

        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: AppTheme.light(),
              home: const StoreSetupScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(PasalClipSegmentedTabs<bool>), findsOneWidget);
        expect(find.text('Store Name *'), findsOneWidget);
        await tester.tap(find.text('Join with Code'));
        await tester.pumpAndSettle();
        expect(find.text('Invite Code *'), findsOneWidget);
      },
    );
  });
}
