import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pasalx_mobile/core/database/app_database.dart';
import 'package:pasalx_mobile/core/providers/foundation_providers.dart';
import 'package:pasalx_mobile/core/security/ram_key_holder.dart';
import 'package:pasalx_mobile/core/theme/app_theme.dart';
import 'package:pasalx_mobile/core/theme/pasal_widgets.dart';
import 'package:pasalx_mobile/features/inventory/application/inventory_providers.dart';
import 'package:pasalx_mobile/features/inventory/domain/catalog_models.dart';
import 'package:pasalx_mobile/features/inventory/presentation/inventory_screen.dart';
import 'package:pasalx_mobile/features/pos/application/pos_providers.dart';
import 'package:pasalx_mobile/features/pos/domain/pos_models.dart';
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
  group('Phase 4 Direct-Manipulation Gestures & 120Hz Virtualization', () {
    testWidgets(
      'PasalAlertOverlay snaps back on short/downward drag and dismisses on upward fling',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(),
              home: const PasalAlertOverlay(
                child: Scaffold(body: SizedBox.expand()),
              ),
            ),
          ),
        );

        container.read(pasalAlertProvider).showWarning(
              'Swipe up to dismiss me',
              duration: Duration.zero,
            );
        await tester.pumpAndSettle();
        expect(find.text('Swipe up to dismiss me'), findsOneWidget);

        // Downward pull (rubber-band resistance) must NOT dismiss.
        await tester.drag(
          find.text('Swipe up to dismiss me'),
          const Offset(0, 40),
        );
        await tester.pumpAndSettle();
        expect(find.text('Swipe up to dismiss me'), findsOneWidget);

        // Upward drag past 28px threshold MUST dismiss.
        await tester.drag(
          find.text('Swipe up to dismiss me'),
          const Offset(0, -45),
        );
        await tester.pumpAndSettle();
        expect(find.text('Swipe up to dismiss me'), findsNothing);

        // Fast upward flick (post-slop ~17px < 28px distance threshold, so
        // dismissal proves velocity > 110 px/s detection works).
        container.read(pasalAlertProvider).showSuccess(
              'Fling me away',
              duration: Duration.zero,
            );
        await tester.pumpAndSettle();
        await tester.fling(
          find.text('Fling me away'),
          const Offset(0, -35),
          800,
        );
        await tester.pumpAndSettle();
        expect(find.text('Fling me away'), findsNothing);
      },
    );

    testWidgets(
      'PosScreen cart line snaps back on right/short drag and deletes on left swipe',
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
          overrides: [ramKeyHolderProvider.overrideWith((ref) => holder)],
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

        container.read(posCartProvider.notifier).addBatch(
              _batch('1', 'SuperStay Lipstick', 145000),
            );
        container.read(posCartProvider.notifier).addBatch(
              _batch('2', 'Fit Me Concealer', 89000),
            );
        await tester.pumpAndSettle();

        // Rightward drag (rubber-band) must NOT delete.
        await tester.drag(
          find.text('SuperStay Lipstick'),
          const Offset(80, 0),
        );
        await tester.pumpAndSettle();
        expect(find.text('SuperStay Lipstick'), findsOneWidget);

        // Slow short leftward drag (40px < 40% of 328px) must snap back.
        await tester.drag(
          find.text('SuperStay Lipstick'),
          const Offset(-40, 0),
        );
        await tester.pumpAndSettle();
        expect(find.text('SuperStay Lipstick'), findsOneWidget);

        // Full leftward swipe (> 40% width) deletes item cleanly.
        await tester.drag(
          find.text('SuperStay Lipstick'),
          const Offset(-180, 0),
        );
        await tester.pumpAndSettle();
        expect(find.text('SuperStay Lipstick'), findsNothing);
        expect(find.text('Fit Me Concealer'), findsOneWidget);
      },
    );

    testWidgets(
      'InventoryScreen virtualizes 1,000 SKUs via SliverList.builder (no eager mount)',
      (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final now = DateTime.utc(2026, 11, 19);
        final nodes = List<ProductCatalogNode>.generate(1000, (i) {
          final id = i.toString().padLeft(4, '0');
          return ProductCatalogNode(
            product: ProductRow(
              id: 'prod-$id',
              name: 'Cosmetic Item SKU-$id',
              brand: 'BrandX',
              category: 'Makeup - Lips',
              isGeneric: false,
              createdAt: now,
              updatedAt: now,
            ),
            variants: const <VariantCatalogNode>[],
            totalStock: 10,
            hasLowStock: false,
            hasExpiringOrExpired: false,
            minSellingPricePaisa: 50000,
            maxSellingPricePaisa: 50000,
          );
        });

        final holder = RamKeyHolder()
          ..unlock(
            dekBytes: Uint8List(32),
            session: ActiveLeaseSession(
              userId: 'u1',
              username: 'owner',
              role: 'OWNER',
              deviceId: 'd1',
              deviceCode: '01',
              leaseId: 'l1',
              issuedAt: now,
              expiresAt: now.add(const Duration(hours: 12)),
            ),
          );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ramKeyHolderProvider.overrideWith((ref) => holder),
              catalogNodesProvider.overrideWith((ref) => Stream.value(nodes)),
              inventorySuppliersProvider.overrideWith(
                (ref) => Stream.value(const <SupplierRow>[]),
              ),
            ],
            child: MaterialApp(
              theme: AppTheme.light(),
              home: const Scaffold(body: InventoryScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('1000 SKUs'), findsOneWidget);
        expect(find.text('Cosmetic Item SKU-0000'), findsOneWidget);
        // Item #999 must NOT be built offscreen!
        expect(find.text('Cosmetic Item SKU-0999'), findsNothing);

        // Scroll down and verify virtualization unmounts SKU-0000.
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -1500));
        await tester.pumpAndSettle();
        expect(find.text('Cosmetic Item SKU-0000'), findsNothing);
      },
    );
  });
}
