import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'package:pasalx_mobile/core/database/money.dart';
import 'package:pasalx_mobile/core/printer/printer.dart';
import 'package:pasalx_mobile/core/providers/foundation_providers.dart';
import 'package:pasalx_mobile/core/security/ram_key_holder.dart';
import 'package:pasalx_mobile/core/theme/app_theme.dart';
import 'package:pasalx_mobile/features/inventory/data/inventory_repository.dart';
import 'package:pasalx_mobile/features/inventory/domain/catalog_models.dart';
import 'package:pasalx_mobile/features/inventory/presentation/inventory_screen.dart';
import 'package:pasalx_mobile/features/inventory/presentation/product_detail_screen.dart';
import 'package:pasalx_mobile/features/inventory/presentation/smart_intake_screen.dart';

ActiveLeaseSession _fakeSession(String role) {
  final now = DateTime.now().toUtc();
  return ActiveLeaseSession(
    userId: '11111111-1111-1111-1111-111111111111',
    username: role.toLowerCase(),
    role: role,
    deviceId: '22222222-2222-2222-2222-222222222222',
    deviceCode: '01',
    leaseId: '33333333-3333-3333-3333-333333333333',
    issuedAt: now,
    expiresAt: now.add(const Duration(hours: 12)),
  );
}

class _FakeServerSocket {
  _FakeServerSocket._(this._server);

  final ServerSocket _server;
  final List<List<int>> connections = <List<int>>[];
  final List<Socket> _accepted = <Socket>[];

  int get port => _server.port;

  static Future<_FakeServerSocket> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeServerSocket._(server);
    server.listen((socket) {
      fake._accepted.add(socket);
      final chunk = <int>[];
      socket.listen(
        chunk.addAll,
        onDone: () {
          fake.connections.add(List<int>.from(chunk));
        },
        onError: (_) {},
        cancelOnError: true,
      );
    });
    return fake;
  }

  List<int> get allBytes =>
      connections.expand((c) => c).toList(growable: false);

  Future<void> close() async {
    for (final s in _accepted) {
      s.destroy();
    }
    _accepted.clear();
    await _server.close();
  }
}

/// Capturing [Xlab365tDriver] for FakeAsync `testWidgets` runs — runs the real
/// [TsplLabelBuilder] encoder and optionally simulates an unreachable printer.
class _CapturingXlabDriver extends Xlab365tDriver {
  _CapturingXlabDriver({
    this.failWith,
  });

  final PrinterException? failWith;
  final List<Uint8List> printedPayloads = <Uint8List>[];

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
    if (failWith != null) {
      throw failWith!;
    }
    final frame = Uint8List.fromList(<int>[
      ...TsplLabelBuilder.modeSwitchCommand,
      ...payload,
    ]);
    printedPayloads.add(frame);
    return frame;
  }
}

Future<void> _unmountWidgetTree(WidgetTester tester, AppDatabase db) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await db.close();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('Step 8 Gate 4: InventoryRepository, RBAC Cost Lock & Outbox Sync', () {
    late AppDatabase db;
    late InventoryRepository repo;
    var mutationCallbacks = 0;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      mutationCallbacks = 0;
      repo = InventoryRepository(
        db: db,
        onMutationCommitted: () => mutationCallbacks++,
      );
    });

    tearDown(() async {
      await db.close();
    });

    test(
      'Lipstick and Skincare intake saves 3 tiers atomically, queues FIFO sync_outbox compatible with Go, and prints via real TCP 9100 ServerSocket',
      () async {
        const supplierId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
        await db.into(db.suppliers).insert(
              SuppliersCompanion.insert(
                id: supplierId,
                name: 'Nepal Beauty Distributors',
                panVat: const Value('302918291'),
              ),
            );

        // 1. Lipstick Intake (`Makeup - Lips`)
        final lipstick = await repo.submitSmartIntake(
          actorRole: 'OWNER',
          actorUserName: 'owner1',
          submission: const SmartIntakeSubmission(
            category: SmartIntakeCategory.lipsNails,
            productName: 'MAC Velvet Teddy Lipstick',
            brand: 'MAC Cosmetics',
            variantName: 'Velvet Teddy',
            sizeVolume: '3.0g',
            colorHex: '#ad6d62',
            supplierId: supplierId,
            batchCode: 'LOT-MAC-01',
            stickerBarcode: '01100024',
            costPricePaisa: 140000,
            sellingPricePaisa: 265000,
            quantity: 4,
            expiryIsoDate: '05/2028',
          ),
        );

        expect(lipstick.product.category, 'Makeup - Lips');
        expect(lipstick.product.isGeneric, isFalse);
        expect(lipstick.variant.colorHex, '#AD6D62');
        expect(lipstick.batch.costPrice, 140000);
        expect(lipstick.batch.sellingPrice, 265000);
        expect(lipstick.batch.stockQuantity, 4);
        expect(lipstick.batch.expiryDate, '2028-05-31');
        expect(lipstick.stockMovement.movementType, 'PURCHASE_INTAKE');
        expect(lipstick.stockMovement.quantity, 4);
        expect(mutationCallbacks, 1);

        // Dispatch saved batch over REAL TCP 9100 ServerSocket via Xlab365tDriver
        final fakePrinter = await _FakeServerSocket.start();
        try {
          final driver = Xlab365tDriver(
            config: PrinterConfig(
              host: InternetAddress.loopbackIPv4.address,
              port: fakePrinter.port,
              modeSwitchDelay: const Duration(milliseconds: 20),
            ),
          );
          await driver.printBatchCopies(
            BatchLabelData(
              productName: lipstick.product.name,
              variantName: lipstick.variant.variantName,
              stickerBarcode: lipstick.batch.stickerBarcode,
              sellingPricePaisa: lipstick.batch.sellingPrice,
              expiryDate: InventoryDateUtils.parseIsoDate(
                lipstick.batch.expiryDate,
              )!,
              batchCode: lipstick.batch.batchCode,
            ),
            quantity: lipstick.batch.stockQuantity,
          );
          // Give loopback socket listener a moment to flush onDone
          final deadline = DateTime.now().add(const Duration(seconds: 2));
          while (fakePrinter.connections.length < 2 &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          final wireBytes = fakePrinter.allBytes;
          expect(
            wireBytes.sublist(0, 8),
            equals(const <int>[0x1F, 0x1B, 0x1F, 0x02, 0x20, 0x30, 0x0D, 0x0A]),
          );
          final tspl = ascii.decode(wireBytes.sublist(8));
          expect(tspl, contains('MAC Velvet Teddy'));
          expect(tspl, contains('BARCODE 0,50,"128",40,1,0,2,2,"01100024"'));
          expect(tspl, contains('BARCODE 238,50,"128",40,1,0,2,2,"01100024"'));
          expect(tspl, contains('PRINT 2,1'));
        } finally {
          await fakePrinter.close();
        }

        // 2. Skincare Intake (`Skincare` with SPF + Skin Type JSON attributes)
        final skincare = await repo.submitSmartIntake(
          actorRole: 'OWNER',
          actorUserName: 'owner1',
          submission: const SmartIntakeSubmission(
            category: SmartIntakeCategory.skincare,
            productName: 'La Roche-Posay Anthelios',
            brand: 'La Roche-Posay',
            variantName: '50ml · SPF 50+ · Sensitive',
            sizeVolume: '50ml',
            spf: 'SPF 50+',
            skinType: 'Sensitive',
            batchCode: 'LOT-LRP-50',
            stickerBarcode: '01100025',
            costPricePaisa: 185000,
            sellingPricePaisa: 285000,
            quantity: 6,
            expiryIsoDate: '2027-11-30',
          ),
        );

        expect(skincare.product.category, 'Skincare');
        expect(skincare.variant.colorHex, isNull);
        final decodedAttrs =
            jsonDecode(skincare.variant.attributes) as Map<String, dynamic>;
        expect(decodedAttrs['spf'], 'SPF 50+');
        expect(decodedAttrs['skin_type'], 'Sensitive');

        // Verify exact FIFO outbox ordering:
        // [products, product_variants, batches, stock_movements] x2
        final outbox = await db.fetchPendingOutbox(limit: 50);
        expect(outbox.length, 8);
        expect(
          outbox.map((e) => e.targetTable).toList(),
          equals(<String>[
            'products',
            'product_variants',
            'batches',
            'stock_movements',
            'products',
            'product_variants',
            'batches',
            'stock_movements',
          ]),
        );

        final batchPayload =
            jsonDecode(outbox[2].payloadJson) as Map<String, dynamic>;
        expect(batchPayload['stock_quantity'], 0);
        expect(batchPayload['cost_price'], '1400.00');
        expect(batchPayload['selling_price'], '2650.00');
        expect(batchPayload['expiry_date'], '2028-05-31');

        final skincareVarPayload =
            jsonDecode(outbox[5].payloadJson) as Map<String, dynamic>;
        expect(skincareVarPayload['attributes'], isA<Map<String, dynamic>>());
        expect(
          (skincareVarPayload['attributes'] as Map<String, dynamic>)['spf'],
          'SPF 50+',
        );

        final movPayload =
            jsonDecode(outbox[3].payloadJson) as Map<String, dynamic>;
        expect(movPayload['movement_type'], 'PURCHASE_INTAKE');
        expect(movPayload['quantity'], 4);
        expect(movPayload['quantity_change'], 4);
      },
    );

    test(
      'RBAC security lock strips cost_price for MANAGER and blocks STAFF intake/adjustments/suppliers',
      () async {
        const supplierId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
        await db.into(db.suppliers).insert(
              SuppliersCompanion.insert(
                id: supplierId,
                name: 'Confidential Wholesaler',
              ),
            );

        final mgrSuppliers = await repo.watchSuppliersForRole('MANAGER').first;
        expect(mgrSuppliers.length, 1);

        final mgrIntake = await repo.submitSmartIntake(
          actorRole: 'MANAGER',
          actorUserName: 'mgr1',
          submission: const SmartIntakeSubmission(
            category: SmartIntakeCategory.haircare,
            productName: 'Loreal Total Repair Shampoo',
            brand: 'Loreal',
            variantName: '400ml',
            sizeVolume: '400ml',
            batchCode: 'LOT-LOR-01',
            stickerBarcode: '01200010',
            costPricePaisa: 95000, // Even if passed directly, MUST be nulled!
            sellingPricePaisa: 155000,
            quantity: 10,
            expiryIsoDate: '09/2028',
          ),
        );

        expect(mgrIntake.batch.costPrice, isNull);
        final outbox = await db.fetchPendingOutbox(limit: 10);
        final batchJson =
            jsonDecode(outbox[2].payloadJson) as Map<String, dynamic>;
        expect(batchJson.containsKey('cost_price'), isFalse);

        final staffSuppliers = await repo.watchSuppliersForRole('STAFF').first;
        expect(staffSuppliers, isEmpty);

        await expectLater(
          () => repo.submitSmartIntake(
            actorRole: 'STAFF',
            actorUserName: 'staff1',
            submission: const SmartIntakeSubmission(
              category: SmartIntakeCategory.generic,
              productName: 'Silk Hair Bands',
              brand: 'Generic',
              variantName: 'Standard',
              batchCode: 'LOT-GEN-1',
              stickerBarcode: '01200011',
              sellingPricePaisa: 15000,
              quantity: 5,
              expiryIsoDate: InventoryDateUtils.nonPerishableIsoDate,
            ),
          ),
          throwsA(isA<InventoryPermissionException>()),
        );

        await expectLater(
          () => repo.adjustBatchStock(
            batchId: mgrIntake.batch.id,
            reason: StockAdjustmentReason.damagedWriteoff,
            quantityDelta: -1,
            actorRole: 'STAFF',
            actorUserName: 'staff1',
          ),
          throwsA(isA<InventoryPermissionException>()),
        );
      },
    );

    test(
      'Validates duplicate barcodes, TSPL width bounds, DECIMAL(10,2), Generic non-expiry, and atomic adjustments',
      () async {
        final generic = await repo.submitSmartIntake(
          actorRole: 'OWNER',
          actorUserName: 'owner1',
          submission: const SmartIntakeSubmission(
            category: SmartIntakeCategory.generic,
            productName: 'Silk Scrunchies',
            brand: 'Pasal Basics',
            variantName: 'Pastel Set',
            batchCode: 'LOT-GEN-01',
            stickerBarcode: '01300001',
            costPricePaisa: 6000,
            sellingPricePaisa: 15000,
            quantity: 20,
            expiryIsoDate: '',
          ),
        );
        expect(generic.product.isGeneric, isTrue);
        expect(
          generic.batch.expiryDate,
          InventoryDateUtils.nonPerishableIsoDate,
        );

        await expectLater(
          () => repo.submitSmartIntake(
            actorRole: 'OWNER',
            actorUserName: 'owner1',
            submission: const SmartIntakeSubmission(
              category: SmartIntakeCategory.generic,
              productName: 'Another Item',
              brand: 'Pasal',
              variantName: 'Standard',
              batchCode: 'LOT-GEN-02',
              stickerBarcode: '01300001',
              sellingPricePaisa: 10000,
              quantity: 5,
              expiryIsoDate: '',
            ),
          ),
          throwsA(isA<InventoryValidationException>()),
        );

        await expectLater(
          () => repo.submitSmartIntake(
            actorRole: 'OWNER',
            actorUserName: 'owner1',
            submission: const SmartIntakeSubmission(
              category: SmartIntakeCategory.haircare,
              productName: 'Serum',
              brand: 'Brand',
              variantName: '100ml',
              batchCode: 'LOT-2',
              stickerBarcode: 'ABCDEFGHIJKLMNOPQ',
              sellingPricePaisa: 50000,
              quantity: 5,
              expiryIsoDate: '12/2027',
            ),
          ),
          throwsA(isA<InventoryValidationException>()),
        );

        await expectLater(
          () => repo.submitSmartIntake(
            actorRole: 'OWNER',
            actorUserName: 'owner1',
            submission: const SmartIntakeSubmission(
              category: SmartIntakeCategory.haircare,
              productName: 'Luxury Oil',
              brand: 'Brand',
              variantName: '100ml',
              batchCode: 'LOT-3',
              stickerBarcode: '01300003',
              sellingPricePaisa: MoneyUtils.maxDecimal10_2Paisa + 1,
              quantity: 1,
              expiryIsoDate: '12/2027',
            ),
          ),
          throwsA(isA<InventoryValidationException>()),
        );

        await expectLater(
          () => repo.adjustBatchStock(
            batchId: generic.batch.id,
            reason: StockAdjustmentReason.damagedWriteoff,
            quantityDelta: 2,
            actorRole: 'OWNER',
            actorUserName: 'owner1',
          ),
          throwsA(isA<InventoryValidationException>()),
        );

        final afterWriteoff = await repo.adjustBatchStock(
          batchId: generic.batch.id,
          reason: StockAdjustmentReason.damagedWriteoff,
          quantityDelta: -4,
          actorRole: 'OWNER',
          actorUserName: 'owner1',
          note: 'Display tray tear',
        );
        expect(afterWriteoff.stockQuantity, 16);

        final tree = await repo.watchCatalogHierarchy().first;
        expect(tree.length, 1);
        expect(tree.first.totalStock, 16);
      },
    );
  });

  group('Step 8 Gate 4 UI, Role Security & TSPL Label Dispatch', () {
    late AppDatabase db;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
    });

    Widget buildHarness({
      required String initialLocation,
      required String role,
      required _CapturingXlabDriver driver,
    }) {
      final holder = RamKeyHolder()
        ..unlock(
          dekBytes: Uint8List(32),
          session: _fakeSession(role),
        );
      final router = GoRouter(
        initialLocation: initialLocation,
        routes: <RouteBase>[
          GoRoute(
            path: '/inventory',
            builder: (context, state) => const Scaffold(body: InventoryScreen()),
            routes: [
              GoRoute(
                path: 'intake',
                builder: (context, state) => SmartIntakeScreen(
                  initialProductId: state.uri.queryParameters['productId'],
                  initialVariantId: state.uri.queryParameters['variantId'],
                ),
              ),
              GoRoute(
                path: 'product/:id',
                builder: (context, state) => ProductDetailScreen(
                  productId: state.pathParameters['id']!,
                ),
              ),
            ],
          ),
        ],
      );

      return ProviderScope(
        overrides: [
          ramKeyHolderProvider.overrideWith((ref) => holder),
          activeDatabaseProvider.overrideWith(
            () => _FixedDatabaseNotifier(db),
          ),
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
      );
    }

    testWidgets(
      'Gate 4 E2E on 360x780: OWNER adds Lipstick + Skincare batches, dispatches TSPL labels, searches & adjusts stock',
      (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final driver = _CapturingXlabDriver();
        await tester.pumpWidget(
          buildHarness(
            initialLocation: '/inventory',
            role: 'OWNER',
            driver: driver,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('ACTIVE SKUS'), findsOneWidget);
        expect(find.text('No products in vault yet'), findsOneWidget);

        // Navigate to 1-Screen Smart Intake
        await tester.tap(find.byKey(const ValueKey('catalog-inward-btn')));
        await tester.pumpAndSettle();

        expect(find.text('DIRECT 1-SCREEN INWARD'), findsOneWidget);
        expect(find.byKey(const ValueKey('intake-cost-price')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('intake-cost-locked-box')),
          findsNothing,
        );

        // Lipstick dynamic fields (`Lips & Nails`)
        expect(find.text('SHADE & VISUAL COLOR DOT'), findsOneWidget);
        expect(find.text('SPF PROTECTION'), findsNothing);

        await tester.enterText(
          find.byKey(const ValueKey('intake-product-name')),
          'Maybelline SuperStay Matte Ink',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-brand')),
          'Maybelline',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-shade-name')),
          '#65 Seductress',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-cost-price')),
          '850',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-selling-price')),
          '1450',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-lot-code')),
          'LOT-INK-65',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-expiry-date')),
          '08/2028',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-qty')),
          '4',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-sticker-barcode')),
          '01400065',
        );
        await tester.pumpAndSettle();

        expect(find.text('MARGIN RS. 600 (41%)'), findsOneWidget);

        // Scroll to Dual 62x20mm Preview + Save & Print
        await tester.scrollUntilVisible(
          find.text('DUAL 62×20MM LABEL PREVIEW'),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(find.text('DUAL 62×20MM LABEL PREVIEW'), findsOneWidget);
        expect(find.textContaining('SUBSET C'), findsOneWidget);

        final printBtn =
            find.byKey(const ValueKey('intake-save-and-print-btn'));
        await tester.scrollUntilVisible(
          printBtn,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(printBtn);
        await tester.pumpAndSettle();

        expect(driver.printedPayloads.length, 1);
        final allBytes = driver.printedPayloads.first;
        expect(
          allBytes.sublist(0, 8),
          equals(const <int>[0x1F, 0x1B, 0x1F, 0x02, 0x20, 0x30, 0x0D, 0x0A]),
        );
        final tsplStr = ascii.decode(allBytes.sublist(8));
        expect(tsplStr, contains('SIZE 62 mm,20 mm'));
        expect(tsplStr, contains('Maybelline SuperStay'));
        expect(tsplStr, contains('#65 Seductress'));
        expect(tsplStr, contains('BARCODE 0,50,"128",40,1,0,2,2,"01400065"'));
        expect(
          tsplStr,
          contains('BARCODE 238,50,"128",40,1,0,2,2,"01400065"'),
        );
        expect(tsplStr, contains('PRINT 2,1'));

        // Back on Catalog, add a Skincare batch without printing
        expect(find.text('Maybelline SuperStay Matte Ink'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('catalog-inward-btn')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('intake-category-skincare')));
        await tester.pumpAndSettle();
        expect(find.text('SHADE & VISUAL COLOR DOT'), findsNothing);
        expect(find.text('SPF PROTECTION'), findsOneWidget);

        await tester.enterText(
          find.byKey(const ValueKey('intake-product-name')),
          'La Roche-Posay Anthelios',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-brand')),
          'La Roche-Posay',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-size-volume')),
          '50ml',
        );
        final spfChip = find.byKey(const ValueKey('intake-spf-SPF 50+'));
        await tester.scrollUntilVisible(
          spfChip,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(spfChip);
        final skinChip = find.byKey(const ValueKey('intake-skin-Sensitive'));
        await tester.scrollUntilVisible(
          skinChip,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(skinChip);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('intake-cost-price')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('intake-cost-price')),
          '1900',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-selling-price')),
          '2850',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-lot-code')),
          'LOT-LRP-01',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-expiry-date')),
          '11/2027',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-qty')),
          '10',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-sticker-barcode')),
          '01400099',
        );
        await tester.pumpAndSettle();

        // Dismiss any bottom SnackBar from prior step before tapping bottom CTA.
        ScaffoldMessenger.of(
          tester.element(find.byType(SmartIntakeScreen)),
        ).clearSnackBars();
        await tester.pumpAndSettle();

        final saveOnlyBtn =
            find.byKey(const ValueKey('intake-save-only-btn'));
        await tester.scrollUntilVisible(
          saveOnlyBtn,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(saveOnlyBtn);
        await tester.pumpAndSettle();

        final storedBatches = await db.select(db.batches).get();
        expect(storedBatches.length, 2);
        expect(find.text('La Roche-Posay Anthelios'), findsOneWidget);
        expect(find.textContaining('Cost: Rs. 1,900'), findsOneWidget);

        // Search filter by sticker barcode isolates exact match
        await tester.enterText(
          find.byKey(const ValueKey('catalog-search-input')),
          '01400065',
        );
        await tester.pumpAndSettle();
        expect(find.text('Maybelline SuperStay Matte Ink'), findsOneWidget);
        expect(find.textContaining('Cost: Rs. 850'), findsOneWidget);
        expect(find.text('La Roche-Posay Anthelios'), findsNothing);

        // Adjust Stock modal increments Lipstick stock 4 -> 6 via stepper +1
        ScaffoldMessenger.of(
          tester.element(find.byType(InventoryScreen)),
        ).clearSnackBars();
        await tester.pumpAndSettle();

        final lipstickBatch = storedBatches
            .firstWhere((b) => b.stickerBarcode == '01400065');
        final adjustBtn = find.byKey(
          ValueKey('batch-adjust-btn-${lipstickBatch.id}'),
        );
        await tester.scrollUntilVisible(
          adjustBtn,
          150,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(adjustBtn);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('adjust-qty-increment')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('confirm-stock-adjustment-btn')),
        );
        await tester.pumpAndSettle();

        final refreshedLipstick = await (db.select(db.batches)
              ..where((t) => t.id.equals(lipstickBatch.id)))
            .getSingle();
        expect(refreshedLipstick.stockQuantity, 6);

        await _unmountWidgetTree(tester, db);
      },
    );

    testWidgets(
      'MANAGER sees Cost Locked in Catalog and Smart Intake (Task 8.3)',
      (tester) async {
        const prodId = 'p1';
        const varId = 'v1';
        const batchId = 'b1';
        await db.into(db.products).insert(
              ProductsCompanion.insert(
                id: prodId,
                name: 'Fit Me Matte Foundation',
                brand: 'Maybelline',
                category: 'Makeup - Face',
              ),
            );
        await db.into(db.productVariants).insert(
              ProductVariantsCompanion.insert(
                id: varId,
                productId: prodId,
                variantName: '#128 Warm Nude',
                colorHex: const Value('#E0B083'),
              ),
            );
        await db.into(db.batches).insert(
              BatchesCompanion.insert(
                id: batchId,
                variantId: varId,
                batchCode: 'LOT-FM-1',
                stickerBarcode: '01500001',
                costPrice: const Value(null),
                sellingPrice: 135000,
                stockQuantity: const Value(14),
                expiryDate: '2028-05-31',
              ),
            );

        await tester.pumpWidget(
          buildHarness(
            initialLocation: '/inventory',
            role: 'MANAGER',
            driver: _CapturingXlabDriver(),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Fit Me Matte Foundation'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('cost-locked-badge-$batchId')),
          findsOneWidget,
        );
        expect(find.textContaining('Cost: Rs.'), findsNothing);

        await tester.tap(find.byKey(const ValueKey('catalog-inward-btn')));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('intake-cost-price')), findsNothing);
        expect(
          find.byKey(const ValueKey('intake-cost-locked-box')),
          findsOneWidget,
        );

        await _unmountWidgetTree(tester, db);
      },
    );

    testWidgets(
      'STAFF has read-only Catalog view and is blocked from Smart Intake route',
      (tester) async {
        const prodId = 'p2';
        const varId = 'v2';
        const batchId = 'b2';
        await db.into(db.products).insert(
              ProductsCompanion.insert(
                id: prodId,
                name: 'Cetaphil Cleanser',
                brand: 'Galderma',
                category: 'Skincare',
              ),
            );
        await db.into(db.productVariants).insert(
              ProductVariantsCompanion.insert(
                id: varId,
                productId: prodId,
                variantName: '250ml',
              ),
            );
        await db.into(db.batches).insert(
              BatchesCompanion.insert(
                id: batchId,
                variantId: varId,
                batchCode: 'LOT-CET-1',
                stickerBarcode: '01600001',
                sellingPrice: 120000,
                stockQuantity: const Value(9),
                expiryDate: '2027-09-30',
              ),
            );

        await tester.pumpWidget(
          buildHarness(
            initialLocation: '/inventory',
            role: 'STAFF',
            driver: _CapturingXlabDriver(),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('STAFF READ-ONLY'), findsOneWidget);
        expect(find.text('Locked'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('batch-adjust-btn-$batchId')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('batch-print-btn-$batchId')),
          findsNothing,
        );

        await tester.tap(find.byKey(const ValueKey('catalog-inward-btn')));
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Stock intake is restricted to Manager or Store Owner accounts.',
          ),
          findsOneWidget,
        );

        await _unmountWidgetTree(tester, db);
      },
    );

    testWidgets(
      'Direct navigation to /inventory/intake as STAFF renders Manager/Owner RBAC lock',
      (tester) async {
        await tester.pumpWidget(
          buildHarness(
            initialLocation: '/inventory/intake',
            role: 'STAFF',
            driver: _CapturingXlabDriver(),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Manager or Owner Required'), findsOneWidget);

        await _unmountWidgetTree(tester, db);
      },
    );

    testWidgets(
      'Printer failure during Smart Intake preserves saved SQLite batch and offers Retry Print without double-save',
      (tester) async {
        final failingDriver = _CapturingXlabDriver(
          failWith: const PrinterConnectionException(
            'Timed out connecting to 192.168.1.100:9100',
          ),
        );

        await tester.pumpWidget(
          buildHarness(
            initialLocation: '/inventory/intake',
            role: 'OWNER',
            driver: failingDriver,
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const ValueKey('intake-product-name')),
          'CeraVe Moisturising Cream',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-brand')),
          'CeraVe',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-shade-name')),
          'Ceramides',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-selling-price')),
          '2200',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-sticker-barcode')),
          '01700001',
        );
        await tester.enterText(
          find.byKey(const ValueKey('intake-qty')),
          '3',
        );
        await tester.pumpAndSettle();

        final printBtn =
            find.byKey(const ValueKey('intake-save-and-print-btn'));
        await tester.scrollUntilVisible(
          printBtn,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(printBtn);
        await tester.pumpAndSettle();

        final batches = await db.select(db.batches).get();
        expect(batches.length, 1);
        expect(batches.first.stickerBarcode, '01700001');

        final retryBtn =
            find.byKey(const ValueKey('intake-retry-print-btn'));
        await tester.scrollUntilVisible(
          retryBtn,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(retryBtn, findsOneWidget);

        await _unmountWidgetTree(tester, db);
      },
    );

    testWidgets(
      'Phase 5: OWNER sees Stock Value KPI and ProductDetailScreen FEFO, Margin, Sourcing & Movements on 360x780',
      (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await db.into(db.suppliers).insert(
              SuppliersCompanion.insert(
                id: 'sup-p5',
                name: 'Nepal Beauty Distributors',
              ),
            );
        await db.into(db.purchaseInvoices).insert(
              PurchaseInvoicesCompanion.insert(
                id: 'pinv-p5',
                supplierId: 'sup-p5',
                invoiceNo: 'PINV-8821',
                invoiceDate: '2026-11-10',
                totalAmount: 1700000,
                dueAmount: 1700000,
              ),
            );
        await db.into(db.products).insert(
              ProductsCompanion.insert(
                id: 'prod-p5',
                name: 'Fit Me Matte Foundation',
                brand: 'Maybelline',
                category: 'Makeup - Face',
              ),
            );
        await db.into(db.productVariants).insert(
              ProductVariantsCompanion.insert(
                id: 'var-p5',
                productId: 'prod-p5',
                variantName: '#128 Warm Nude',
                colorHex: const Value('#D69F7E'),
              ),
            );
        await db.into(db.batches).insert(
              BatchesCompanion.insert(
                id: 'batch-p5-a',
                variantId: 'var-p5',
                supplierId: const Value('sup-p5'),
                purchaseInvoiceId: const Value('pinv-p5'),
                batchCode: 'LOT-MAY-A',
                stickerBarcode: '01900001',
                costPrice: const Value(85000),
                sellingPrice: 135000,
                stockQuantity: const Value(4),
                expiryDate: '2026-12-31',
              ),
            );
        await db.into(db.batches).insert(
              BatchesCompanion.insert(
                id: 'batch-p5-b',
                variantId: 'var-p5',
                supplierId: const Value('sup-p5'),
                purchaseInvoiceId: const Value('pinv-p5'),
                batchCode: 'LOT-MAY-B',
                stickerBarcode: '01900002',
                costPrice: const Value(85000),
                sellingPrice: 135000,
                stockQuantity: const Value(20),
                expiryDate: '2027-12-31',
              ),
            );
        await db.into(db.stockMovements).insert(
              StockMovementsCompanion.insert(
                id: 'mov-p5-1',
                batchId: 'batch-p5-a',
                movementType: 'PURCHASE_INTAKE',
                quantity: 4,
                staffName: 'owner1',
              ),
            );

        await tester.pumpWidget(
          buildHarness(
            initialLocation: '/inventory',
            role: 'OWNER',
            driver: _CapturingXlabDriver(),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('catalog-stock-value-kpi')),
          findsOneWidget,
        );
        expect(find.text('Rs. 20,400'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('product-card-prod-p5')));
        await tester.pumpAndSettle();

        expect(find.text('Product Details'), findsOneWidget);
        expect(find.text('FEFO'), findsOneWidget);
        expect(find.textContaining('LOT-MAY-A'), findsWidgets);
        expect(
          find.byKey(const ValueKey('product-detail-margin-card')),
          findsOneWidget,
        );
        expect(find.text('+37%'), findsOneWidget);

        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('product-detail-sourcing-card')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('product-detail-sourcing-card')),
          findsOneWidget,
        );
        expect(find.textContaining('PINV-8821'), findsOneWidget);

        await tester.scrollUntilVisible(
          find.text('RECENT STOCK ACTIVITY'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('+4 pcs Stock Intake'), findsOneWidget);

        await _unmountWidgetTree(tester, db);
      },
    );

    testWidgets(
      'Phase 5: STAFF cannot see Stock Value KPI, Margin, Cost, or Sourcing Invoice on ProductDetailScreen',
      (tester) async {
        await db.into(db.suppliers).insert(
              SuppliersCompanion.insert(
                id: 'sup-p5-staff',
                name: 'Confidential Wholesaler',
              ),
            );
        await db.into(db.purchaseInvoices).insert(
              PurchaseInvoicesCompanion.insert(
                id: 'pinv-p5-staff',
                supplierId: 'sup-p5-staff',
                invoiceNo: 'PINV-9999',
                invoiceDate: '2026-11-10',
                totalAmount: 500000,
                dueAmount: 500000,
              ),
            );
        await db.into(db.products).insert(
              ProductsCompanion.insert(
                id: 'prod-p5-staff',
                name: 'Cerave Foaming Cleanser',
                brand: 'CeraVe',
                category: 'Skincare',
              ),
            );
        await db.into(db.productVariants).insert(
              ProductVariantsCompanion.insert(
                id: 'var-p5-staff',
                productId: 'prod-p5-staff',
                variantName: '236ml',
              ),
            );
        await db.into(db.batches).insert(
              BatchesCompanion.insert(
                id: 'batch-p5-staff',
                variantId: 'var-p5-staff',
                supplierId: const Value('sup-p5-staff'),
                purchaseInvoiceId: const Value('pinv-p5-staff'),
                batchCode: 'LOT-CRV-1',
                stickerBarcode: '01900099',
                costPrice: const Value(110000),
                sellingPrice: 185000,
                stockQuantity: const Value(8),
                expiryDate: '2027-08-31',
              ),
            );

        await tester.pumpWidget(
          buildHarness(
            initialLocation: '/inventory',
            role: 'STAFF',
            driver: _CapturingXlabDriver(),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('catalog-stock-value-kpi')),
          findsNothing,
        );
        expect(find.textContaining('Cost:'), findsNothing);

        await tester.tap(
          find.byKey(const ValueKey('product-card-prod-p5-staff')),
        );
        await tester.pumpAndSettle();

        expect(find.text('Product Details'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('product-detail-margin-card')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('product-detail-sourcing-card')),
          findsNothing,
        );
        expect(find.textContaining('Cost:'), findsNothing);
        expect(find.textContaining('PINV-9999'), findsNothing);
        expect(find.text('Print Labels (8)'), findsNothing);
        expect(find.text('Count / Adjust'), findsNothing);

        await _unmountWidgetTree(tester, db);
      },
    );
  });
}

class _FixedDatabaseNotifier extends ActiveDatabaseNotifier {
  _FixedDatabaseNotifier(this._db);
  final AppDatabase _db;

  @override
  AppDatabase? build() => _db;
}
