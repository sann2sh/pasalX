import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pasalx_mobile/core/database/app_database.dart';
import 'package:pasalx_mobile/core/printer/printer.dart';
import 'package:pasalx_mobile/core/providers/foundation_providers.dart';
import 'package:pasalx_mobile/core/security/ram_key_holder.dart';
import 'package:pasalx_mobile/core/theme/app_theme.dart';
import 'package:pasalx_mobile/features/inventory/data/inventory_repository.dart';
import 'package:pasalx_mobile/features/inventory/domain/catalog_models.dart';
import 'package:pasalx_mobile/features/inventory/presentation/inventory_screen.dart';
import 'package:pasalx_mobile/features/inventory/presentation/smart_intake_screen.dart';

ActiveLeaseSession _ownerSession() {
  final now = DateTime.now().toUtc();
  return ActiveLeaseSession(
    userId: '11111111-1111-1111-1111-111111111111',
    username: 'owner1',
    role: 'OWNER',
    deviceId: '22222222-2222-2222-2222-222222222222',
    deviceCode: '01',
    leaseId: '33333333-3333-3333-3333-333333333333',
    issuedAt: now,
    expiresAt: now.add(const Duration(hours: 12)),
  );
}

class _CapturingDriver extends Xlab365tDriver {
  final List<({Uint8List bytes, TsplLabelStyle style, int qty})> jobs =
      <({Uint8List bytes, TsplLabelStyle style, int qty})>[];

  @override
  Future<Uint8List> printBatchCopies(
    BatchLabelData label, {
    required int quantity,
    TsplLabelStyle style = TsplLabelStyle.barcode128,
    int density = 13,
    int speed = 4,
    bool? autoSwitch,
  }) async {
    final payload = TsplLabelBuilder(density: density, speed: speed)
        .buildBatchCopies(label, quantity: quantity, style: style);
    jobs.add((bytes: payload, style: style, qty: quantity));
    return payload;
  }
}

class _FixedDatabaseNotifier extends ActiveDatabaseNotifier {
  _FixedDatabaseNotifier(this._db);
  final AppDatabase _db;

  @override
  AppDatabase? build() => _db;
}

Future<void> _cleanUnmount(WidgetTester tester, AppDatabase db) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await db.close();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('Step 8 Edge Cases & Security Audit', () {
    late AppDatabase db;
    late InventoryRepository repo;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = InventoryRepository(
        db: db,
        clock: () => DateTime(2026, 11, 16),
      );
    });

    tearDown(() async {
      await db.close();
    });

    test(
      'Depleted old lot (0 units) + healthy new lot (20 units) on same variant does not trigger false LOW alert',
      () async {
        const prodId = 'prod-1';
        const varId = 'var-1';
        await db.into(db.products).insert(
              ProductsCompanion.insert(
                id: prodId,
                name: 'Fit Me Foundation',
                brand: 'Maybelline',
                category: 'Makeup - Face',
              ),
            );
        await db.into(db.productVariants).insert(
              ProductVariantsCompanion.insert(
                id: varId,
                productId: prodId,
                variantName: '#128 Warm Nude',
              ),
            );
        // Old depleted lot
        await db.into(db.batches).insert(
              BatchesCompanion.insert(
                id: 'batch-old',
                variantId: varId,
                batchCode: 'LOT-OLD',
                stickerBarcode: '01100001',
                sellingPrice: 135000,
                stockQuantity: const Value(0),
                expiryDate: '2026-12-31', // Within 60 days of 2026-11-16 -> expiringSoon
              ),
            );
        // Healthy new lot
        await db.into(db.batches).insert(
              BatchesCompanion.insert(
                id: 'batch-new',
                variantId: varId,
                batchCode: 'LOT-NEW',
                stickerBarcode: '01100002',
                sellingPrice: 135000,
                stockQuantity: const Value(20),
                expiryDate: '2028-05-31',
              ),
            );

        final tree = await repo.watchCatalogHierarchy().first;
        expect(tree.length, 1);
        expect(tree.first.totalStock, 20);
        expect(tree.first.hasLowStock, isFalse);
        expect(tree.first.hasExpiringOrExpired, isTrue);
      },
    );

    test(
      'Adding batch to existing Product & Variant queues only batches + stock_movements (no duplicate product/variant)',
      () async {
        final first = await repo.submitSmartIntake(
          actorRole: 'OWNER',
          actorUserName: 'owner1',
          submission: const SmartIntakeSubmission(
            category: SmartIntakeCategory.lipsNails,
            productName: 'MAC Ruby Woo',
            brand: 'MAC',
            variantName: 'Ruby Woo',
            colorHex: '#9E2A2B',
            batchCode: 'LOT-RW-1',
            stickerBarcode: '01800001',
            costPricePaisa: 140000,
            sellingPricePaisa: 265000,
            quantity: 5,
            expiryIsoDate: '06/2028',
          ),
        );

        final second = await repo.submitSmartIntake(
          actorRole: 'OWNER',
          actorUserName: 'owner1',
          submission: SmartIntakeSubmission(
            existingProductId: first.product.id,
            existingVariantId: first.variant.id,
            category: SmartIntakeCategory.lipsNails,
            productName: 'MAC Ruby Woo',
            brand: 'MAC',
            variantName: 'Ruby Woo',
            batchCode: 'LOT-RW-2',
            stickerBarcode: '01800002',
            costPricePaisa: 145000,
            sellingPricePaisa: 270000,
            quantity: 10,
            expiryIsoDate: '12/2028',
          ),
        );

        expect(second.product.id, first.product.id);
        expect(second.variant.id, first.variant.id);

        final allOutbox = await db.fetchPendingOutbox(limit: 50);
        // 4 mutations for first intake + 2 mutations for second intake = 6 total
        expect(allOutbox.length, 6);
        expect(
          allOutbox.sublist(4).map((m) => m.targetTable).toList(),
          equals(<String>['batches', 'stock_movements']),
        );

        final tree = await repo.watchCatalogHierarchy().first;
        expect(tree.length, 1);
        expect(tree.first.totalStock, 15);
        expect(tree.first.hasLowStock, isFalse);
      },
    );

    test(
      'Rejects TSPL command-injection characters, Postgres VARCHAR overflows, and invalid stock deltas',
      () async {
        for (final badBarcode in <String>[
          'PRL"123',
          r'PRL\123',
          'PRL~123',
          'PRL\n123',
          '',
        ]) {
          await expectLater(
            () => repo.submitSmartIntake(
              actorRole: 'OWNER',
              actorUserName: 'owner1',
              submission: SmartIntakeSubmission(
                category: SmartIntakeCategory.generic,
                productName: 'Clips',
                brand: 'Pasal',
                variantName: 'Standard',
                batchCode: 'LOT-1',
                stickerBarcode: badBarcode,
                sellingPricePaisa: 5000,
                quantity: 2,
                expiryIsoDate: InventoryDateUtils.nonPerishableIsoDate,
              ),
            ),
            throwsA(isA<InventoryValidationException>()),
          );
        }

        // Oversized productName (>255) rejected before DB write
        await expectLater(
          () => repo.submitSmartIntake(
            actorRole: 'OWNER',
            actorUserName: 'owner1',
            submission: SmartIntakeSubmission(
              category: SmartIntakeCategory.haircare,
              productName: 'A' * 256,
              brand: 'Brand',
              variantName: '200ml',
              batchCode: 'LOT-1',
              stickerBarcode: '01800099',
              sellingPricePaisa: 50000,
              quantity: 2,
              expiryIsoDate: '05/2028',
            ),
          ),
          throwsA(isA<InventoryValidationException>()),
        );

        final valid = await repo.submitSmartIntake(
          actorRole: 'OWNER',
          actorUserName: 'owner1',
          submission: const SmartIntakeSubmission(
            category: SmartIntakeCategory.haircare,
            productName: 'Argan Oil',
            brand: 'Moroccanoil',
            variantName: '100ml',
            batchCode: 'LOT-AO-1',
            stickerBarcode: '01800050',
            sellingPricePaisa: 320000,
            quantity: 5,
            expiryIsoDate: '05/2028',
          ),
        );

        // Zero delta, negative on CUSTOMER_RETURN, >1,000,000, and below-zero drop all rejected
        for (final badCall in <Future<BatchRow> Function()>[
          () => repo.adjustBatchStock(
                batchId: valid.batch.id,
                reason: StockAdjustmentReason.countCorrection,
                quantityDelta: 0,
                actorRole: 'OWNER',
                actorUserName: 'owner1',
              ),
          () => repo.adjustBatchStock(
                batchId: valid.batch.id,
                reason: StockAdjustmentReason.customerReturn,
                quantityDelta: -1,
                actorRole: 'OWNER',
                actorUserName: 'owner1',
              ),
          () => repo.adjustBatchStock(
                batchId: valid.batch.id,
                reason: StockAdjustmentReason.purchaseIntake,
                quantityDelta: 1000001,
                actorRole: 'OWNER',
                actorUserName: 'owner1',
              ),
          () => repo.adjustBatchStock(
                batchId: valid.batch.id,
                reason: StockAdjustmentReason.expiredWriteoff,
                quantityDelta: -6,
                actorRole: 'OWNER',
                actorUserName: 'owner1',
              ),
        ]) {
          await expectLater(badCall, throwsA(isA<InventoryValidationException>()));
        }
      },
    );

    test('InventoryDateUtils handles leap years, invalid months, and 60-day boundary', () {
      expect(InventoryDateUtils.normalizeExpiryInputToIso('02/2028'), '2028-02-29');
      expect(InventoryDateUtils.normalizeExpiryInputToIso('02/2027'), '2027-02-28');
      expect(InventoryDateUtils.normalizeExpiryInputToIso('13/2028'), isNull);
      expect(InventoryDateUtils.normalizeExpiryInputToIso('00/2028'), isNull);

      final ref = DateTime(2026, 11, 16);
      expect(
        InventoryDateUtils.classifyExpiry('2026-11-15', now: ref),
        BatchExpiryStatus.expired,
      );
      expect(
        InventoryDateUtils.classifyExpiry('2027-01-15', now: ref),
        BatchExpiryStatus.expiringSoon,
      );
      expect(
        InventoryDateUtils.classifyExpiry('2027-01-16', now: ref),
        BatchExpiryStatus.fresh,
      );
      expect(
        InventoryDateUtils.classifyExpiry('2099-12-31', now: ref),
        BatchExpiryStatus.nonPerishable,
      );
    });
  });

  group('Step 8 UI Edge Cases (360x780, Cost > MRP, Long Names, Print Sheet)', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
    });

    testWidgets(
      'Displays Cost > MRP loss warning badge and supports QR Side label print from Catalog sheet without overflow',
      (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final driver = _CapturingDriver();
        final holder = RamKeyHolder()
          ..unlock(dekBytes: Uint8List(32), session: _ownerSession());

        const prodId = 'long-prod';
        const varId = 'long-var';
        const batchId = 'long-batch';
        await db.into(db.products).insert(
              ProductsCompanion.insert(
                id: prodId,
                name:
                    "L'Oréal Paris Revitalift 1.5% Hyaluronic Acid Serum 30ml Extra Long",
                brand: "L'Oréal Paris Dermatological",
                category: 'Skincare',
              ),
            );
        await db.into(db.productVariants).insert(
              ProductVariantsCompanion.insert(
                id: varId,
                productId: prodId,
                variantName: '30ml · Hyaluronic Concentrated Serum',
                sizeVolume: const Value('30ml'),
              ),
            );
        await db.into(db.batches).insert(
              BatchesCompanion.insert(
                id: batchId,
                variantId: varId,
                batchCode: 'LOT-LOR-2026-LONG',
                stickerBarcode: '01900012',
                costPrice: const Value(80000),
                sellingPrice: 99999900, // Rs. 9,99,999
                stockQuantity: const Value(4),
                expiryDate: '2028-02-29',
              ),
            );

        final router = GoRouter(
          initialLocation: '/inventory',
          routes: <RouteBase>[
            GoRoute(
              path: '/inventory',
              builder: (context, state) => const Scaffold(body: InventoryScreen()),
              routes: [
                GoRoute(
                  path: 'intake',
                  builder: (context, state) => const SmartIntakeScreen(),
                ),
              ],
            ),
          ],
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ramKeyHolderProvider.overrideWith((ref) => holder),
              activeDatabaseProvider.overrideWith(() => _FixedDatabaseNotifier(db)),
              connectivityStreamProvider.overrideWithValue(
                const Stream<List<ConnectivityResult>>.empty(),
              ),
              connectivityCheckProvider.overrideWithValue(
                () async => const <ConnectivityResult>[ConnectivityResult.none],
              ),
              httpClientFactoryProvider.overrideWithValue(
                () => MockClient((_) async => http.Response('{}', 200)),
              ),
              xlabPrinterDriverProvider.overrideWithValue(driver),
            ],
            child: MaterialApp.router(
              theme: AppTheme.light(),
              routerConfig: router,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Worst-case long name & Rs. 9,99,999 render cleanly on 360x780
        expect(find.textContaining("L'Oréal Paris Revitalift"), findsOneWidget);

        // Open 1-tap Print Labels sheet, switch to QR Side, and dispatch
        final printBtn = find.byKey(const ValueKey('batch-print-btn-$batchId'));
        await tester.scrollUntilVisible(
          printBtn,
          150,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(printBtn);
        await tester.pumpAndSettle();

        await tester.tap(find.text('QR Side'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('dispatch-tspl-print-btn')));
        await tester.pumpAndSettle();

        expect(driver.jobs.length, 1);
        expect(driver.jobs.first.style, TsplLabelStyle.qrSideBySide);
        expect(driver.jobs.first.qty, 4);
        final tspl = ascii.decode(driver.jobs.first.bytes);
        expect(tspl, contains('QRCODE '));

        // Close Print Labels sheet and open Smart Intake to test Cost > MRP warning badge
        Navigator.of(tester.element(find.byType(InventoryScreen))).pop();
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('catalog-inward-btn')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const ValueKey('intake-cost-price')),
          '2000',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-selling-price')),
          '1500',
        );
        await tester.pumpAndSettle();

        expect(
          find.text('LOSS -RS. 500 (COST > MRP)'),
          findsOneWidget,
        );

        await _cleanUnmount(tester, db);
      },
    );
  });
}

