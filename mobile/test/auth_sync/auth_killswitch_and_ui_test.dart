import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'package:pasalx_mobile/core/database/sqlcipher_factory.dart';
import 'package:pasalx_mobile/core/network/api_config.dart';
import 'package:pasalx_mobile/core/providers/foundation_providers.dart';
import 'package:pasalx_mobile/core/security/envelope_crypto.dart';
import 'package:pasalx_mobile/core/security/keystore_dek_manager.dart';
import 'package:pasalx_mobile/core/security/ram_key_holder.dart';
import 'package:pasalx_mobile/features/auth/application/auth_session_controller.dart';

/// Mints a genuine Go-compatible 64-byte `PX\x01\x00` envelope for tests.
Future<({Uint8List kek, Uint8List envelope})> _mintGoCompatibleLease({
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

Map<String, dynamic> _emptyPullJson(
  DateTime ts, {
  List<Map<String, dynamic>> registerShifts = const [],
}) {
  return <String, dynamic>{
    'server_time': ts.toUtc().toIso8601String(),
    'since': '1970-01-01T00:00:00Z',
    'has_more': false,
    'role': 'STAFF',
    'changes': <String, dynamic>{
      'products': [],
      'product_variants': [],
      'batches': [],
      'customers': [],
      'customer_shade_profiles': [],
      'customer_transactions': [],
      'suppliers': [],
      'purchase_invoices': [],
      'purchase_invoice_items': [],
      'supplier_payments': [],
      'stock_movements': [],
      'sale_orders': [],
      'sale_items': [],
      'sale_payments': [],
      'register_shifts': registerShifts,
      'staff_shift_sessions': [],
      'expenses': [],
      'inventory_sync_audit': [],
    },
  };
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pasalx_step7_test_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Step 7 Auth, Encrypted Reboot Recovery & Kill-Switch', () {
    test(
        'online enroll -> PIN login -> PX\\x01\\x00 unwrap -> SQLCipher vault -> shift open -> offline reboot recovery -> HTTP 401 Kill-Switch wipe',
        () async {
      final store = InMemorySecureKeyValueStore();
      final dbFile = File('${tempDir.path}/vault_01.db');
      final dek = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      const deviceId = '11111111-1111-4111-8111-111111111111';
      const userId = '22222222-2222-4222-8222-222222222222';
      const leaseId = '33333333-3333-4333-8333-333333333333';

      var serverRevoked = false;
      final pushedTables = <String>[];
      var isNetworkOffline = false;

      MockClient buildMockHttp() => MockClient((req) async {
            if (isNetworkOffline) {
              throw const SocketException('Shop Wi-Fi unreachable');
            }
            if (req.url.path == '/api/auth/devices/register') {
              return http.Response(
                jsonEncode({
                  'device': {
                    'id': deviceId,
                    'code': '01',
                    'name': 'Counter Phone 01',
                    'platform': 'ANDROID',
                    'status': 'ACTIVE',
                  },
                }),
                201,
              );
            }
            if (req.url.path == '/api/auth/login') {
              final now = DateTime.now().toUtc();
              final expiresAt = now.add(const Duration(hours: 12));
              final lease = await _mintGoCompatibleLease(
                dek: dek,
                deviceId: deviceId,
                leaseId: leaseId,
                expiresAt: expiresAt,
              );
              return http.Response(
                jsonEncode({
                  'access_token': 'jwt-staff-01',
                  'token_type': 'Bearer',
                  'expires_at': expiresAt.toIso8601String(),
                  'user': {
                    'id': userId,
                    'name': 'Sunita Shrestha',
                    'username': 'sunita',
                    'role': 'STAFF',
                  },
                  'device': {
                    'id': deviceId,
                    'code': '01',
                    'name': 'Counter Phone 01',
                    'platform': 'ANDROID',
                    'status': 'ACTIVE',
                  },
                  'lease': {
                    'lease_id': leaseId,
                    'issued_at': now.toIso8601String(),
                    'expires_at': expiresAt.toIso8601String(),
                    'expires_unix': expiresAt.millisecondsSinceEpoch ~/ 1000,
                    'ttl_seconds': 43200,
                    'kek_b64': base64Encode(lease.kek),
                    'envelope_b64': base64Encode(lease.envelope),
                    'envelope_version': 1,
                  },
                }),
                200,
              );
            }
            if (serverRevoked) {
              return http.Response(
                jsonEncode({
                  'error': 'DEVICE_REVOKED',
                  'message': 'This device has been revoked by the owner',
                }),
                401,
                headers: {
                  'www-authenticate': 'Bearer error="DEVICE_REVOKED"',
                },
              );
            }
            if (req.url.path == '/api/sync/pull') {
              return http.Response(
                jsonEncode(_emptyPullJson(DateTime.now().toUtc())),
                200,
              );
            }
            if (req.url.path == '/api/sync/push') {
              final body = jsonDecode(req.body) as Map<String, dynamic>;
              final muts = (body['mutations'] as List<dynamic>)
                  .cast<Map<String, dynamic>>();
              pushedTables.addAll(muts.map((m) => m['table_name'] as String));
              return http.Response(
                jsonEncode({
                  'server_time': DateTime.now().toUtc().toIso8601String(),
                  'processed_count': muts.length,
                  'applied_count': muts.length,
                  'duplicate_count': 0,
                  'results': muts
                      .map((m) => {
                            'id': m['id'],
                            'table_name': m['table_name'],
                            'record_id': m['record_id'],
                            'status': 'APPLIED',
                          })
                      .toList(),
                  'discrepancies': [],
                }),
                200,
              );
            }
            return http.Response('unexpected', 404);
          });

      ProviderContainer createAppContainer() {
        return ProviderContainer(
          overrides: [
            secureKeyValueStoreProvider.overrideWithValue(store),
            apiConfigProvider.overrideWith(() => _TestApiConfigNotifier()),
            httpClientFactoryProvider.overrideWithValue(buildMockHttp),
            connectivityStreamProvider
                .overrideWithValue(const Stream<List<ConnectivityResult>>.empty()),
            connectivityCheckProvider.overrideWithValue(
              () async => [
                if (isNetworkOffline)
                  ConnectivityResult.none
                else
                  ConnectivityResult.wifi,
              ],
            ),
            keystoreDekManagerProvider.overrideWith((ref) {
              return KeystoreDekManager(
                store: ref.watch(secureKeyValueStoreProvider),
                ramKeyHolder: ref.read(ramKeyHolderProvider),
                pbkdf2Iterations: 1000,
              );
            }),
            databaseOpenerProvider.overrideWithValue(
              (holder) => SqlCipherDatabaseFactory().openEncrypted(
                ramKeyHolder: holder,
                file: dbFile,
                useBackgroundIsolate: false,
              ),
            ),
          ],
        );
      }

      // 1. Fresh terminal enrollment + online 6-digit PIN login.
      final c1 = createAppContainer();
      final auth1 = c1.read(authSessionControllerProvider);
      await auth1.initialize();
      expect(auth1.state.stage, AuthGateStage.unregistered);

      final regOk = await auth1.registerTerminal(
        ownerUsername: 'owner',
        ownerPassword: 'OwnerPass!123',
        deviceName: 'Counter Phone 01',
      );
      expect(regOk, isTrue);
      expect(auth1.state.stage, AuthGateStage.locked);
      expect(auth1.state.enrolledDevice?.deviceCode, '01');

      final loginOk = await auth1.loginOnline(username: 'sunita', pin: '246810');
      expect(loginOk, isTrue);
      expect(auth1.state.stage, AuthGateStage.shiftOpenRequired);
      expect(c1.read(ramKeyHolderProvider).isUnlocked, isTrue);

      final db1 = c1.read(activeDatabaseProvider);
      expect(db1, isNotNull);
      expect(await db1!.readCipherVersion(), isNotNull);

      // 2. Open Morning Register Float Rs. 5,000 -> FIFO outbox push.
      final openedOk =
          await auth1.openNewShiftWithFloat(openingFloatPaisa: 500000);
      expect(openedOk, isTrue);
      expect(auth1.state.stage, AuthGateStage.ready);

      await c1.read(syncOutboxWorkerProvider).syncNow();
      expect(pushedTables, ['register_shifts', 'staff_shift_sessions']);
      expect(await db1.fetchPendingOutbox(), isEmpty);

      // Tear down container 1 (simulating phone battery death).
      c1.dispose();

      // 3. Phone reboots completely OFFLINE: recover encrypted DB + active shift via 6-digit PIN!
      isNetworkOffline = true;
      final c2 = createAppContainer();
      addTearDown(c2.dispose);
      final auth2 = c2.read(authSessionControllerProvider);
      await auth2.initialize();
      expect(auth2.state.stage, AuthGateStage.locked);
      expect(auth2.state.offlineRecovery.hasSlot, isTrue);

      // Wrong PIN decrements attempts cleanly without crashing.
      final badPin = await auth2.unlockOfflineWithPin('000000');
      expect(badPin, isFalse);
      expect(auth2.state.offlineRecovery.remainingAttempts, 4);

      // Correct PIN unlocks RAM DEK, opens encrypted SQLCipher vault, and auto-resumes active shift!
      final goodPin = await auth2.unlockOfflineWithPin('246810');
      expect(goodPin, isTrue);
      expect(auth2.state.stage, AuthGateStage.ready);
      expect(auth2.state.activeShift?.openingFloat, 500000);
      final db2 = c2.read(activeDatabaseProvider)!;

      // 4. Wi-Fi reconnects after owner revoked device -> HTTP 401 DEVICE_REVOKED wipes RAM, Keystore & closes DB!
      isNetworkOffline = false;
      serverRevoked = true;
      await c2.read(syncOutboxWorkerProvider).syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(c2.read(ramKeyHolderProvider).isUnlocked, isFalse);
      expect(c2.read(activeDatabaseProvider), isNull);
      expect(
        () => db2.customSelect('SELECT 1;').get(),
        throwsA(anything),
      );
      expect((await c2.read(keystoreDekManagerProvider).inspectSlot()).hasSlot,
          isFalse);
      expect(await c2.read(deviceCredentialsStoreProvider).readSession(), isNull);
      expect(auth2.state.stage, AuthGateStage.revoked);
    });

    test('FCM push Kill-Switch wipes active vault immediately', () async {
      final store = InMemorySecureKeyValueStore();
      final container = ProviderContainer(
        overrides: [
          secureKeyValueStoreProvider.overrideWithValue(store),
          connectivityStreamProvider
              .overrideWithValue(const Stream<List<ConnectivityResult>>.empty()),
          connectivityCheckProvider
              .overrideWithValue(() async => [ConnectivityResult.none]),
          databaseOpenerProvider.overrideWithValue((_) async {
            throw UnimplementedError();
          }),
        ],
      );
      addTearDown(container.dispose);

      final holder = container.read(ramKeyHolderProvider);
      final keystore = container.read(keystoreDekManagerProvider);
      final dek = Uint8List.fromList(List<int>.filled(32, 7));
      final now = DateTime.now().toUtc();
      final session = ActiveLeaseSession(
        userId: 'u1',
        username: 'sunita',
        role: 'STAFF',
        deviceId: 'dev-02',
        deviceCode: '02',
        leaseId: 'lease-fcm',
        issuedAt: now,
        expiresAt: now.add(const Duration(hours: 12)),
      );
      holder.unlock(dekBytes: dek, session: session);
      await keystore.provisionOfflineRecoverySlot(
        session: session,
        dekBytes: dek,
        pin: '135790',
      );
      expect(holder.isUnlocked, isTrue);

      final handled = await container
          .read(killSwitchServiceProvider)
          .handlePushNotificationPayload(
        <String, dynamic>{
          'event': 'DEVICE_REVOKED',
          'device_code': '02',
          'reason': 'Lost phone on bus',
        },
        currentDeviceCode: '02',
      );
      expect(handled, isTrue);
      expect(holder.isUnlocked, isFalse);
      expect((await keystore.inspectSlot()).hasSlot, isFalse);
    });

    test('Phone 02 pulls existing OPEN Single-Galla shift and punches in without duplicate register_shifts',
        () async {
      final store = InMemorySecureKeyValueStore();
      final db = AppDatabase(
        // Use in-memory Drift instance for multi-phone shift test.
        // ignore: invalid_use_of_visible_for_testing_member
        await _openInMemoryDb(),
      );
      final dek = Uint8List.fromList(List<int>.filled(32, 9));
      const deviceId = '44444444-4444-4444-8444-444444444444';
      const userId = '55555555-5555-4555-8555-555555555555';
      const leaseId = '66666666-6666-4666-8666-666666666666';

      final mockHttp = MockClient((req) async {
        if (req.url.path == '/api/auth/devices/register') {
          return http.Response(
            jsonEncode({
              'device': {
                'id': deviceId,
                'code': '02',
                'name': 'Counter Phone 02',
                'platform': 'ANDROID',
                'status': 'ACTIVE',
              },
            }),
            201,
          );
        }
        if (req.url.path == '/api/auth/login') {
          final now = DateTime.now().toUtc();
          final exp = now.add(const Duration(hours: 12));
          final lease = await _mintGoCompatibleLease(
            dek: dek,
            deviceId: deviceId,
            leaseId: leaseId,
            expiresAt: exp,
          );
          return http.Response(
            jsonEncode({
              'access_token': 'jwt-02',
              'token_type': 'Bearer',
              'expires_at': exp.toIso8601String(),
              'user': {
                'id': userId,
                'name': 'Rina Tamang',
                'username': 'rina',
                'role': 'STAFF',
              },
              'device': {
                'id': deviceId,
                'code': '02',
                'name': 'Counter Phone 02',
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
        if (req.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode(
              _emptyPullJson(
                DateTime.now().toUtc(),
                registerShifts: [
                  {
                    'id': 'shared-galla-01',
                    'opened_by_user_id': 'owner-uuid-1',
                    'opened_at': DateTime.now().toUtc().toIso8601String(),
                    'opening_float': 3000.00,
                    'cash_sales': 0.00,
                    'digital_sales': 0.00,
                    'khata_cash_repayments': 0.00,
                    'cash_expenses': 0.00,
                    'expected_cash': 3000.00,
                    'cash_withdrawn_deposit': 0.00,
                    'retained_next_day_float': 0.00,
                    'status': 'OPEN',
                    'updated_at': DateTime.now().toUtc().toIso8601String(),
                  }
                ],
              ),
            ),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'server_time': DateTime.now().toUtc().toIso8601String(),
            'processed_count': 1,
            'applied_count': 1,
            'duplicate_count': 0,
            'results': [],
            'discrepancies': [],
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
          databaseOpenerProvider.overrideWithValue((_) async => db),
        ],
      );
      addTearDown(container.dispose);

      final auth = container.read(authSessionControllerProvider);
      await auth.initialize();
      await auth.registerTerminal(
        ownerUsername: 'owner',
        ownerPassword: 'pw',
        deviceName: 'Phone 02',
      );
      await auth.loginOnline(username: 'rina', pin: '654321');

      expect(auth.state.stage, AuthGateStage.shiftOpenRequired);
      expect(auth.state.activeShift?.id, 'shared-galla-01');

      final joined = await auth.joinExistingOpenShift();
      expect(joined, isTrue);
      expect(auth.state.stage, AuthGateStage.ready);

      final pending = await db.fetchPendingOutbox();
      expect(pending.map((m) => m.targetTable).toList(), ['staff_shift_sessions']);
      expect(await db.select(db.registerShifts).get(), hasLength(1));
    });
  });

  group('ShiftOpenLoginScreen narrow 360x780 UI flow & router redirect', () {
    testWidgets(
        'enrolls -> 6-digit PIN login -> Rs. 3,000 float preset -> enters /pos -> revokes back to /login',
        (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final store = InMemorySecureKeyValueStore();
      final db = AppDatabase(await _openInMemoryDb());
      final dek = Uint8List.fromList(List<int>.filled(32, 3));
      const deviceId = '77777777-7777-4777-8777-777777777777';
      const userId = '88888888-8888-4888-8888-888888888888';
      const leaseId = '99999999-9999-4999-8999-999999999999';

      final mockHttp = MockClient((req) async {
        if (req.url.path == '/api/auth/devices/register') {
          return http.Response(
            jsonEncode({
              'device': {
                'id': deviceId,
                'code': '01',
                'name': 'Counter Phone 01',
                'platform': 'ANDROID',
                'status': 'ACTIVE',
              },
            }),
            201,
          );
        }
        if (req.url.path == '/api/auth/login') {
          final now = DateTime.now().toUtc();
          final exp = now.add(const Duration(hours: 12));
          final lease = await _mintGoCompatibleLease(
            dek: dek,
            deviceId: deviceId,
            leaseId: leaseId,
            expiresAt: exp,
          );
          return http.Response(
            jsonEncode({
              'access_token': 'jwt-ui-01',
              'token_type': 'Bearer',
              'expires_at': exp.toIso8601String(),
              'user': {
                'id': userId,
                'name': 'Sunita Shrestha',
                'username': 'sunita',
                'role': 'STAFF',
              },
              'device': {
                'id': deviceId,
                'code': '01',
                'name': 'Counter Phone 01',
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
        if (req.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode(_emptyPullJson(DateTime.now().toUtc())),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'server_time': DateTime.now().toUtc().toIso8601String(),
            'processed_count': 2,
            'applied_count': 2,
            'duplicate_count': 0,
            'results': [],
            'discrepancies': [],
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
          databaseOpenerProvider.overrideWithValue((_) async => db),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const PasalXApp(),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Terminal enrollment card renders cleanly (no Server URL or platform chips).
      expect(find.text('Terminal Enrollment'), findsOneWidget);
      expect(find.text('ANDROID'), findsNothing);
      expect(find.text('IOS'), findsNothing);
      expect(find.text('LINUX'), findsNothing);
      expect(find.textContaining('Server URL'), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextField, 'Owner Password'),
        'OwnerPass123',
      );
      await tester.tap(find.text('Enroll Shop Terminal'));
      await tester.pumpAndSettle();

      // 2. Online 6-digit PIN keypad login (6 dots, no mode ChoiceChips).
      expect(find.text('Morning Shift Login'), findsOneWidget);
      for (var i = 0; i < 6; i++) {
        expect(find.byKey(ValueKey<String>('pin-dot-$i')), findsOneWidget);
      }
      expect(find.byType(ChoiceChip), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextField, 'Staff Username'),
        'sunita',
      );
      for (final d in ['1', '2', '3', '4', '5', '6']) {
        await tester.tap(find.byKey(ValueKey<String>('pin-key-$d')));
        await tester.pump();
      }
      expect(find.text('6 Digits Ready'), findsOneWidget);
      await tester.ensureVisible(find.text('Verify PIN & Sign In'));
      await tester.tap(find.text('Verify PIN & Sign In'));
      await tester.pumpAndSettle();

      // 3. Step 2 Opening Cash Float card appears -> tap Rs. 3,000 preset & open shift.
      expect(find.text('Opening Cash & Details'), findsOneWidget);
      expect(find.text('OPENING CASH FLOAT'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
      await tester.tap(find.text('Rs. 3,000'));
      await tester.pump();
      await tester.ensureVisible(find.text('Open Register & Start Billing'));
      await tester.tap(find.text('Open Register & Start Billing'));
      await tester.pumpAndSettle();

      // 4. Router redirects straight into Home Dashboard 5-tab shell!
      expect(find.text("TODAY'S TOTAL SALES"), findsOneWidget);
      expect(find.text('Sale'), findsOneWidget);

      // 5. Trigger Kill-Switch -> forces immediate lock to /login showing revocation banner.
      await container
          .read(killSwitchServiceProvider)
          .executeRevocation(reason: 'Owner triggered remote Kill-Switch');
      await tester.pumpAndSettle();

      expect(find.text('DEVICE REVOKED BY OWNER'), findsOneWidget);
      expect(
        find.text('Owner triggered remote Kill-Switch'),
        findsOneWidget,
      );
    });
  });
}

class _TestApiConfigNotifier extends ApiConfigNotifier {
  @override
  ApiConfig build() => const ApiConfig(baseUrl: 'http://test.local');
}

Future<QueryExecutor> _openInMemoryDb() async {
  return NativeDatabase.memory();
}
