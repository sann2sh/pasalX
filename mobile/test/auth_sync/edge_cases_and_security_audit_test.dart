import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pasalx_mobile/app.dart';
import 'package:pasalx_mobile/core/database/app_database.dart';
import 'package:pasalx_mobile/core/database/money.dart';
import 'package:pasalx_mobile/core/network/api_config.dart';
import 'package:pasalx_mobile/core/network/api_exceptions.dart';
import 'package:pasalx_mobile/core/network/pasal_api_client.dart';
import 'package:pasalx_mobile/core/network/sync_models.dart';
import 'package:pasalx_mobile/core/providers/foundation_providers.dart';
import 'package:pasalx_mobile/core/security/device_credentials_store.dart';
import 'package:pasalx_mobile/core/security/envelope_crypto.dart';
import 'package:pasalx_mobile/core/security/keystore_dek_manager.dart';
import 'package:pasalx_mobile/core/security/ram_key_holder.dart';
import 'package:pasalx_mobile/core/sync/pull_applier.dart';
import 'package:pasalx_mobile/core/sync/sse_sync_client.dart';
import 'package:pasalx_mobile/core/sync/sync_outbox_worker.dart';
import 'package:pasalx_mobile/features/auth/application/auth_session_controller.dart';

Future<({Uint8List kek, Uint8List envelope})> _mintLease({
  required Uint8List dek,
  required String deviceId,
  required String leaseId,
  required DateTime expiresAt,
}) async {
  final kek = EnvelopeCrypto.randomBytes(32);
  final nonce = EnvelopeCrypto.randomBytes(12);
  final expiresUnix = expiresAt.toUtc().millisecondsSinceEpoch ~/ 1000;
  final aad = <int>[
    ...EnvelopeCrypto.serverMagicHeader,
    ...utf8.encode('$deviceId|$leaseId|$expiresUnix'),
  ];
  final box = await AesGcm.with256bits().encrypt(
    dek,
    secretKey: SecretKey(kek),
    nonce: nonce,
    aad: aad,
  );
  final env = Uint8List.fromList(<int>[
    ...EnvelopeCrypto.serverMagicHeader,
    ...box.nonce,
    ...box.cipherText,
    ...box.mac.bytes,
  ]);
  return (kek: kek, envelope: env);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('Step 7 Security Audit & Shared Terminal Edge Cases', () {
    test('enforceRolePrivacy scrubs OWNER costs/suppliers on STAFF login & resets cursor on OWNER upgrade',
        () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final pullOwner = SyncPullResult.fromJson({
        'server_time': '2026-11-16T08:00:00Z',
        'since': '1970-01-01T00:00:00Z',
        'has_more': false,
        'role': 'OWNER',
        'changes': {
          'suppliers': [
            {
              'id': 'sup-1',
              'name': 'Kathmandu Cosmetics Distributors',
              'total_purchased': 85000.00,
              'total_paid': 40000.00,
              'balance_due': 45000.00,
              'updated_at': '2026-11-16T07:50:00Z',
            }
          ],
          'purchase_invoices': [
            {
              'id': 'pinv-1',
              'supplier_id': 'sup-1',
              'invoice_no': 'INV-900',
              'invoice_date': '2026-11-16',
              'total_amount': 85000.00,
              'paid_amount': 40000.00,
              'due_amount': 45000.00,
              'status': 'PARTIAL',
              'created_by_user_id': 'owner-1',
              'updated_at': '2026-11-16T07:50:00Z',
            }
          ],
          'products': [
            {
              'id': 'prod-1',
              'name': 'Velvet Lipstick',
              'brand': 'Loreal',
              'category': 'Makeup - Lips',
              'is_generic': false,
              'updated_at': '2026-11-16T07:50:00Z',
            }
          ],
          'product_variants': [
            {
              'id': 'var-1',
              'product_id': 'prod-1',
              'variant_name': 'Crimson',
              'updated_at': '2026-11-16T07:50:00Z',
            }
          ],
          'batches': [
            {
              'id': 'batch-1',
              'variant_id': 'var-1',
              'supplier_id': 'sup-1',
              'purchase_invoice_id': 'pinv-1',
              'batch_code': 'L1',
              'sticker_barcode': '100001',
              'cost_price': 650.00,
              'selling_price': 1200.00,
              'stock_quantity': 10,
              'expiry_date': '2028-12-01',
              'updated_at': '2026-11-16T07:50:00Z',
            }
          ],
          'sale_orders': [
            {
              'id': 'so-1',
              'bill_no': '01-0001',
              'cashier_user_id': 'owner-1',
              'cashier_name': 'Owner',
              'subtotal': 1200.00,
              'discount_amount': 0.00,
              'total_amount': 1200.00,
              'cost_total': 650.00,
              'net_profit': 550.00,
              'payment_mode': 'CASH',
              'updated_at': '2026-11-16T08:00:00Z',
            }
          ],
          'sale_items': [
            {
              'id': 'si-1',
              'sale_order_id': 'so-1',
              'batch_id': 'batch-1',
              'product_name': 'Velvet Lipstick',
              'variant_name': 'Crimson',
              'quantity': 1,
              'cost_price': 650.00,
              'selling_price': 1200.00,
              'total_price': 1200.00,
            }
          ],
        },
      });

      await PullApplier.apply(db, pullOwner);
      await db.enforceRolePrivacy('OWNER');
      expect((await (db.select(db.batches)..where((t) => t.id.equals('batch-1'))).getSingle()).costPrice, 65000);
      expect(await db.select(db.suppliers).get(), hasLength(1));

      // STAFF unlocks same shared device DB -> all wholesale costs & suppliers must scrub cleanly!
      await db.enforceRolePrivacy('STAFF');
      final scrubbedBatch =
          await (db.select(db.batches)..where((t) => t.id.equals('batch-1')))
              .getSingle();
      expect(scrubbedBatch.costPrice, isNull);
      expect(scrubbedBatch.supplierId, isNull);
      expect(scrubbedBatch.purchaseInvoiceId, isNull);
      expect(scrubbedBatch.sellingPrice, 120000);
      final scrubbedOrder =
          await (db.select(db.saleOrders)..where((t) => t.id.equals('so-1')))
              .getSingle();
      expect(scrubbedOrder.costTotal, isNull);
      expect(scrubbedOrder.netProfit, isNull);
      expect(await db.select(db.suppliers).get(), isEmpty);
      expect(await db.select(db.purchaseInvoices).get(), isEmpty);

      // OWNER returns later -> pull cursor resets so unmasked ledger can re-sync cleanly.
      expect(await PullApplier.readCursor(db), isNotNull);
      await db.enforceRolePrivacy('OWNER');
      expect(await PullApplier.readCursor(db), isNull);
    });

    test('password-only online login clears prior staff offline Keystore slot & failed DB open rolls back credentials',
        () async {
      final store = InMemorySecureKeyValueStore();
      final openedDbs = <AppDatabase>[];
      addTearDown(() async {
        for (final d in openedDbs) {
          await d.close();
        }
      });

      final dek = Uint8List.fromList(List<int>.filled(32, 5));
      const deviceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const leaseId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

      var failDbOpen = false;
      var loginRole = 'STAFF';
      var loginUser = 'sunita';

      final mockHttp = MockClient((req) async {
        if (req.url.path == '/api/auth/login') {
          final now = DateTime.now().toUtc();
          final exp = now.add(const Duration(hours: 12));
          final lease = await _mintLease(
            dek: dek,
            deviceId: deviceId,
            leaseId: leaseId,
            expiresAt: exp,
          );
          return http.Response(
            jsonEncode({
              'access_token': 'jwt-$loginUser',
              'token_type': 'Bearer',
              'expires_at': exp.toIso8601String(),
              'user': {
                'id': 'cccccccc-cccc-4ccc-8ccc-$loginUser'.padRight(36, '0').substring(0, 36),
                'name': loginUser,
                'username': loginUser,
                'role': loginRole,
              },
              'device': {
                'id': deviceId,
                'code': '01',
                'name': 'Counter 01',
                'platform': 'ANDROID',
                'status': 'ACTIVE',
              },
              'lease': {
                'lease_id': leaseId,
                'issued_at': now.toIso8601String(),
                'expires_at': exp.toIso8601String(),
                'expires_unix': exp.millisecondsSinceEpoch ~/ 1000,
                'ttl_seconds': 43200,
                'kek_b64': base64Encode(lease.kek),
                'envelope_b64': base64Encode(lease.envelope),
                'envelope_version': 1,
              },
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'server_time': DateTime.now().toUtc().toIso8601String(),
            'since': '1970-01-01T00:00:00Z',
            'has_more': false,
            'role': loginRole,
            'changes': {},
          }),
          200,
        );
      });

      final container = ProviderContainer(
        overrides: [
          secureKeyValueStoreProvider.overrideWithValue(store),
          httpClientFactoryProvider.overrideWithValue(() => mockHttp),
          connectivityStreamProvider
              .overrideWithValue(const Stream<List<ConnectivityResult>>.empty()),
          connectivityCheckProvider
              .overrideWithValue(() async => [ConnectivityResult.wifi]),
          keystoreDekManagerProvider.overrideWith((ref) {
            return KeystoreDekManager(
              store: ref.watch(secureKeyValueStoreProvider),
              ramKeyHolder: ref.read(ramKeyHolderProvider),
              pbkdf2Iterations: 1000,
            );
          }),
          databaseOpenerProvider.overrideWithValue((_) async {
            if (failDbOpen) {
              throw StateError('Simulated SQLCipher HMAC mismatch');
            }
            final opened = AppDatabase(NativeDatabase.memory());
            openedDbs.add(opened);
            return opened;
          }),
        ],
      );
      addTearDown(container.dispose);

      await container.read(deviceCredentialsStoreProvider).saveDevice(
            const EnrolledDeviceInfo(
              deviceId: deviceId,
              deviceCode: '01',
              deviceName: 'Counter 01',
              platform: 'ANDROID',
            ),
          );

      final auth = container.read(authSessionControllerProvider);
      await auth.initialize();

      // 1. Staff logs in with PIN -> offline Keystore slot provisioned.
      expect(await auth.loginOnline(username: 'sunita', pin: '123456'), isTrue);
      expect(
        (await container.read(keystoreDekManagerProvider).inspectSlot()).hasSlot,
        isTrue,
      );

      // Simulate passive RAM lock leaving Keystore slot present -> Owner signs in with PASSWORD.
      container.read(ramKeyHolderProvider).wipe();
      await Future<void>.delayed(Duration.zero);
      loginRole = 'OWNER';
      loginUser = 'owner';
      expect(
        await auth.loginOnline(username: 'owner', password: 'OwnerPassword!'),
        isTrue,
      );
      // Staff's prior Keystore PIN slot MUST have been wiped!
      expect(
        (await container.read(keystoreDekManagerProvider).inspectSlot()).hasSlot,
        isFalse,
      );

      // 2. If DB open fails on a PIN login, Keystore slot & JWT session must roll back cleanly.
      await auth.logout();
      failDbOpen = true;
      loginRole = 'STAFF';
      loginUser = 'sunita';
      expect(await auth.loginOnline(username: 'sunita', pin: '123456'), isFalse);
      expect(container.read(ramKeyHolderProvider).isUnlocked, isFalse);
      expect(
        (await container.read(keystoreDekManagerProvider).inspectSlot()).hasSlot,
        isFalse,
      );
      expect(
        await container.read(deviceCredentialsStoreProvider).readSession(),
        isNull,
      );
    });

    test('updating server URL preserves SyncOutboxWorker instance and validates URL & DECIMAL(10,2) float',
        () async {
      final store = InMemorySecureKeyValueStore();
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final container = ProviderContainer(
        overrides: [
          secureKeyValueStoreProvider.overrideWithValue(store),
          connectivityStreamProvider
              .overrideWithValue(const Stream<List<ConnectivityResult>>.empty()),
          connectivityCheckProvider
              .overrideWithValue(() async => [ConnectivityResult.none]),
          databaseOpenerProvider.overrideWithValue((_) async => db),
        ],
      );
      addTearDown(container.dispose);

      final workerBefore = container.read(syncOutboxWorkerProvider);
      await workerBefore.start(runInitialSync: false);

      final auth = container.read(authSessionControllerProvider);
      await auth.initialize();

      // Invalid URL rejected safely without mutating config.
      await auth.updateServerUrl('not-a-url');
      expect(auth.state.errorMessage, contains('valid http:// or https://'));

      // Valid URL updates dynamically WITHOUT rebuilding SyncOutboxWorker!
      await auth.updateServerUrl('https://pasal.shop.np:8443');
      final workerAfter = container.read(syncOutboxWorkerProvider);
      expect(identical(workerBefore, workerAfter), isTrue);
      expect(workerAfter.isRunning, isTrue);
      expect(
        container.read(pasalApiClientProvider).config.baseUrl,
        'https://pasal.shop.np:8443',
      );

      // DECIMAL(10,2) ceiling enforced on opening float.
      expect(
        () => db.openRegisterShiftAndPunchIn(
          userId: 'u1',
          deviceCode: '01',
          openingFloatPaisa: MoneyUtils.maxDecimal10_2Paisa + 1,
        ),
        throwsArgumentError,
      );
    });

    test('offline unlock after expired JWT surfaces sync re-auth error & invalid login creds blocked pre-network',
        () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.enqueueOutboxMutation(
        mutationId: 'm-expired-jwt',
        targetTable: 'expenses',
        recordId: 'e1',
        operation: 'INSERT',
        payloadJson: jsonEncode({'id': 'e1'}),
      );

      final client = PasalApiClient(
        config: const ApiConfig(baseUrl: 'http://test.local'),
        httpClient: MockClient((_) async => throw StateError('must not hit network')),
      );
      await expectLater(
        () => client.login(username: 'sunita', deviceId: 'dev-1'),
        throwsA(isA<ApiException>()),
      );

      final worker = SyncOutboxWorker(
        getDatabase: () => db,
        getAccessToken: () => null, // JWT expired during extended offline outage
        apiClient: client,
        connectivityStream: const Stream.empty(),
        checkConnectivity: () async => [ConnectivityResult.wifi],
      );
      addTearDown(worker.dispose);

      await worker.start(runInitialSync: false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await worker.syncNow();
      expect(worker.status.state, SyncHealthState.error);
      expect(worker.status.lastError, contains('Online sign-in required'));
    });

    test('SseSyncClient handles multi-line data, no-space data, HTTP 401 revoke, SESSION_EXPIRED, and safe dispose',
        () async {
      var attempt = 0;
      var changedCount = 0;
      var revokedReason = '';
      var expiredCount = 0;

      final mockHttp = MockClient.streaming((req, bodyStream) async {
        attempt++;
        if (attempt == 1) {
          final ctrl = StreamController<List<int>>();
          ctrl.add(utf8.encode(': keepalive\n\n'));
          ctrl.add(utf8.encode('event: CONNECTED\ndata:{"device_code":"01"}\n\n'));
          ctrl.add(utf8.encode(
            'id: 1\n'
            'event: DATA_CHANGED\n'
            'data: {"origin_device_code":"02",\n'
            'data: "has_discrepancy":true}\n\n',
          ));
          ctrl.add(utf8.encode('event: SESSION_EXPIRED\ndata:{}\n\n'));
          unawaited(ctrl.close());
          return http.StreamedResponse(ctrl.stream, 200);
        }
        // Attempt 2: HTTP 401 DEVICE_REVOKED via header only.
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode('')),
          401,
          headers: {'www-authenticate': 'Bearer error="DEVICE_REVOKED"'},
        );
      });

      final sse = SseSyncClient(
        getConfig: () => const ApiConfig(baseUrl: 'http://test.local'),
        getAccessToken: () => 'jwt',
        clientFactory: () => mockHttp,
        onDataChanged: (ev) {
          if (ev.hasDiscrepancy && ev.originDeviceCode == '02') {
            changedCount++;
          }
        },
        onSessionExpired: () => expiredCount++,
        onDeviceRevoked: (reason) => revokedReason = reason,
      );
      addTearDown(() => sse.stop(notify: false));

      sse.start();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(changedCount, 1);
      expect(expiredCount, 1);
      expect(sse.isRunning, isFalse);

      // Re-start -> attempt 2 hits 401 DEVICE_REVOKED header.
      sse.start();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(revokedReason, isNotEmpty);
      expect(sse.isRunning, isFalse);

      // Verify stop(notify: false) never triggers onConnectedChanged(false) even during cancel.
      var spuriousFalse = false;
      final hangCtrl = StreamController<List<int>>();
      final hangSse = SseSyncClient(
        getConfig: () => const ApiConfig(baseUrl: 'http://test.local'),
        getAccessToken: () => 'jwt',
        clientFactory: () => MockClient.streaming((_, __) async {
          return http.StreamedResponse(hangCtrl.stream, 200);
        }),
        onConnectedChanged: (c) {
          if (!c) spuriousFalse = true;
        },
      );
      hangSse.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await hangSse.stop(notify: false);
      unawaited(hangCtrl.close());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(spuriousFalse, isFalse);
    });

    testWidgets('5 wrong offline PIN attempts wipe Keystore slot and auto-fallback UI to Online PIN login',
        (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final store = InMemorySecureKeyValueStore();
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final container = ProviderContainer(
        overrides: [
          secureKeyValueStoreProvider.overrideWithValue(store),
          connectivityStreamProvider
              .overrideWithValue(const Stream<List<ConnectivityResult>>.empty()),
          connectivityCheckProvider
              .overrideWithValue(() async => [ConnectivityResult.none]),
          keystoreDekManagerProvider.overrideWith((ref) {
            return KeystoreDekManager(
              store: ref.watch(secureKeyValueStoreProvider),
              ramKeyHolder: ref.read(ramKeyHolderProvider),
              pbkdf2Iterations: 1000,
            );
          }),
          databaseOpenerProvider.overrideWithValue((_) async => db),
        ],
      );
      addTearDown(container.dispose);

      // Provision device + offline recovery slot cleanly before booting UI.
      await container.read(deviceCredentialsStoreProvider).saveDevice(
            const EnrolledDeviceInfo(
              deviceId: 'dev-ui-offline',
              deviceCode: '01',
              deviceName: 'Counter Phone 01',
              platform: 'ANDROID',
            ),
          );
      final now = DateTime.now().toUtc();
      await container.read(keystoreDekManagerProvider).provisionOfflineRecoverySlot(
            session: ActiveLeaseSession(
              userId: 'u1',
              username: 'sunita',
              role: 'STAFF',
              deviceId: 'dev-ui-offline',
              deviceCode: '01',
              leaseId: 'lease-1',
              issuedAt: now,
              expiresAt: now.add(const Duration(hours: 12)),
            ),
            dekBytes: Uint8List.fromList(List<int>.filled(32, 4)),
            pin: '246810',
          );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const PasalXApp(),
        ),
      );
      await tester.pumpAndSettle();

      // Tapping the Offline Reboot Recovery card switches straight into Offline PIN mode.
      await tester.tap(find.text('Offline Reboot Recovery Active'));
      await tester.pumpAndSettle();
      expect(find.text('Unlock Offline Vault'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Staff Username'), findsNothing);

      // Enter wrong PIN 5 times until hardware slot wipes cleanly.
      for (var attempt = 0; attempt < 5; attempt++) {
        await tester.ensureVisible(
          find.byKey(const ValueKey<String>('pin-key-0')),
        );
        for (var i = 0; i < 6; i++) {
          await tester.tap(find.byKey(const ValueKey<String>('pin-key-0')));
          await tester.pump();
        }
        await tester.ensureVisible(find.text('Unlock Offline Vault'));
        await tester.tap(find.text('Unlock Offline Vault'));
        await tester.pumpAndSettle();
      }

      // Slot is wiped -> UI must automatically exit hidden-username Offline mode to Online PIN login!
      expect(find.text('Offline Reboot Recovery Active'), findsNothing);
      expect(find.widgetWithText(TextField, 'Staff Username'), findsOneWidget);
      expect(find.text('Verify PIN & Sign In'), findsOneWidget);
    });
  });
}
