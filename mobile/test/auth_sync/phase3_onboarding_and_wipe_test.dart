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
import 'package:pasalx_mobile/core/database/app_database.dart';
import 'package:pasalx_mobile/core/database/sqlcipher_factory.dart';
import 'package:pasalx_mobile/core/network/api_config.dart';
import 'package:pasalx_mobile/core/network/auth_models.dart';
import 'package:pasalx_mobile/core/printer/printer_providers.dart';
import 'package:pasalx_mobile/core/providers/foundation_providers.dart';
import 'package:pasalx_mobile/core/security/device_credentials_store.dart';
import 'package:pasalx_mobile/core/security/envelope_crypto.dart';
import 'package:pasalx_mobile/core/security/keystore_dek_manager.dart';
import 'package:pasalx_mobile/features/auth/application/auth_session_controller.dart';
import 'package:pasalx_mobile/features/auth/presentation/account_auth_screen.dart';
import 'package:pasalx_mobile/features/auth/presentation/device_approval_pending_screen.dart';
import 'package:pasalx_mobile/features/auth/presentation/store_setup_screen.dart';
import 'package:pasalx_mobile/features/auth/presentation/verify_email_screen.dart';
import 'package:pasalx_mobile/features/settings/presentation/delete_account_screen.dart';
import 'package:pasalx_mobile/features/settings/presentation/team_settings_screen.dart';
import 'package:sqlite3/sqlite3.dart' as raw_sqlite;

String _jwtWithSid(String sid, {String aud = 'pasalx-device'}) {
  final hdr = base64Url
      .encode(utf8.encode('{"alg":"HS256","typ":"JWT"}'))
      .replaceAll('=', '');
  final pay = base64Url
      .encode(utf8.encode('{"sid":"$sid","aud":"$aud"}'))
      .replaceAll('=', '');
  return '$hdr.$pay.sig';
}

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

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pasalx_phase3_test_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Phase 3 Gate C: Onboarding, Store Sync, Isolation & Safe Wipe', () {
    test('ApiConfig enforces HTTPS in release mode', () {
      expect(
        ApiConfig.isValidBaseUrl(
          'https://pasalx.skisub.com',
          requireHttps: true,
        ),
        isTrue,
      );
      expect(
        ApiConfig.isValidBaseUrl(
          'http://pasalx.skisub.com',
          requireHttps: true,
        ),
        isFalse,
      );
      expect(
        ApiConfig.isValidBaseUrl(
          'http://127.0.0.1:8080',
          requireHttps: false,
        ),
        isTrue,
      );
    });

    test('Onboarding state machine: signup -> verify -> accountLogin -> invite -> rejected -> approved -> locked',
        () async {
      final store = InMemorySecureKeyValueStore();
      var pollCount = 0;
      final exp = DateTime.now().toUtc().add(const Duration(minutes: 15));

      final mockHttp = MockClient((req) async {
        if (req.url.path == '/api/auth/signup') {
          return http.Response(
            jsonEncode({
              'user': {
                'id': 'u-staff-1',
                'name': 'Sita Gurung',
                'username': 'sita',
                'role': 'STAFF',
              },
              'verification_required': true,
            }),
            201,
          );
        }
        if (req.url.path == '/api/auth/verify-email') {
          return http.Response(jsonEncode({'verified': true}), 200);
        }
        if (req.url.path == '/api/auth/account-login') {
          return http.Response(
            jsonEncode({
              'access_token': _jwtWithSid('', aud: 'pasalx-account'),
              'token_type': 'Bearer',
              'expires_at': exp.toIso8601String(),
              'user': {
                'id': 'u-staff-1',
                'name': 'Sita Gurung',
                'username': 'sita',
                'role': 'STAFF',
              },
              'membership': null,
            }),
            200,
          );
        }
        if (req.url.path == '/api/invitations/accept') {
          return http.Response(
            jsonEncode({
              'device_id': 'dev-pending-1',
              'device_name': 'Staff Phone',
              'platform': 'ANDROID',
              'status': 'PENDING',
              'store_id': 'store-a',
              'store_name': 'Himalayan Glow',
              'role': 'STAFF',
            }),
            202,
          );
        }
        if (req.url.path == '/api/devices/me/status') {
          pollCount++;
          if (pollCount == 1) {
            return http.Response(
              jsonEncode({
                'device_id': 'dev-pending-1',
                'device_name': 'Staff Phone',
                'platform': 'ANDROID',
                'status': 'REJECTED',
                'store_id': 'store-a',
                'store_name': 'Himalayan Glow',
                'role': 'STAFF',
                'revocation_reason': 'Wrong terminal name',
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'device_id': 'dev-pending-1',
              'device_code': '02',
              'device_name': 'Staff Phone',
              'platform': 'ANDROID',
              'status': 'ACTIVE',
              'store_id': 'store-a',
              'store_name': 'Himalayan Glow',
              'role': 'STAFF',
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });

      final container = ProviderContainer(
        overrides: [
          secureKeyValueStoreProvider.overrideWithValue(store),
          httpClientFactoryProvider.overrideWithValue(() => mockHttp),
          connectivityStreamProvider
              .overrideWithValue(const Stream<List<ConnectivityResult>>.empty()),
          connectivityCheckProvider
              .overrideWithValue(() async => [ConnectivityResult.wifi]),
        ],
      );
      addTearDown(container.dispose);

      final auth = container.read(authSessionControllerProvider);
      await auth.initialize();
      expect(auth.state.stage, AuthGateStage.accountAuthRequired);

      expect(
        await auth.signupAccount(
          name: 'Sita Gurung',
          email: 'sita@example.com',
          password: 'himalaya-tea-strong-2026',
          username: 'sita',
          pin: '246810',
        ),
        isTrue,
      );
      expect(auth.state.stage, AuthGateStage.emailVerificationRequired);

      expect(
        await auth.verifyEmailCode(email: 'sita@example.com', code: '123456'),
        isTrue,
      );
      expect(auth.state.stage, AuthGateStage.accountAuthRequired);

      expect(
        await auth.loginAccount(
          email: 'sita@example.com',
          password: 'himalaya-tea-strong-2026',
        ),
        isTrue,
      );
      expect(auth.state.stage, AuthGateStage.storeSetupRequired);

      expect(
        await auth.acceptInvitationCode(
          code: 'PSX-ABCDE-FGHIJ',
          deviceName: 'Staff Phone',
        ),
        isTrue,
      );
      expect(auth.state.stage, AuthGateStage.deviceApprovalPending);

      await auth.checkPendingDeviceStatus();
      expect(auth.state.stage, AuthGateStage.deviceRejected);
      expect(
        auth.state.pendingEnrollment?.revocationReason,
        'Wrong terminal name',
      );

      await auth.cancelPendingEnrollment();
      expect(auth.state.stage, AuthGateStage.storeSetupRequired);

      expect(
        await auth.acceptInvitationCode(
          code: 'PSX-ABCDE-FGHIJ',
          deviceName: 'Staff Phone',
        ),
        isTrue,
      );
      await auth.checkPendingDeviceStatus();
      expect(auth.state.stage, AuthGateStage.locked);
      expect(auth.state.enrolledDevice?.deviceCode, '02');
      expect(auth.state.enrolledDevice?.storeId, 'store-a');
    });

    test('createStoreAndEnroll pulls store profile into Drift + PrinterConfig and leaveStoreSafely guards outbox then wipes files',
        () async {
      final store = InMemorySecureKeyValueStore();
      final dbFile = File('${tempDir.path}/vault_store_a.db');
      final dek = Uint8List.fromList(List<int>.generate(32, (i) => i + 7));
      const storeId = 'store-himalaya-1';
      const devId = 'dev-owner-01';
      const leaseId = 'lease-owner-01';
      var leaveCalled = false;

      final mockHttp = MockClient((req) async {
        final now = DateTime.now().toUtc();
        final exp = now.add(const Duration(hours: 12));
        if (req.url.path == '/api/auth/account-login') {
          return http.Response(
            jsonEncode({
              'access_token': _jwtWithSid('', aud: 'pasalx-account'),
              'token_type': 'Bearer',
              'expires_at': exp.toIso8601String(),
              'user': {
                'id': 'u-owner-1',
                'name': 'Aarav',
                'username': 'aarav',
                'role': 'OWNER',
              },
              'membership': null,
            }),
            200,
          );
        }
        if (req.url.path == '/api/stores') {
          final lease = await _mintLease(
            dek: dek,
            deviceId: devId,
            leaseId: leaseId,
            expiresAt: exp,
          );
          return http.Response(
            jsonEncode({
              'store': {
                'id': storeId,
                'name': 'Himalayan Glow',
                'pan_number': '601234567',
                'phone': '9800000001',
                'address': 'Thamel, Kathmandu',
                'status': 'ACTIVE',
                'created_at': now.toIso8601String(),
                'updated_at': now.toIso8601String(),
              },
              'access_token': _jwtWithSid(storeId),
              'token_type': 'Bearer',
              'expires_at': exp.toIso8601String(),
              'user': {
                'id': 'u-owner-1',
                'name': 'Aarav',
                'username': 'aarav',
                'role': 'OWNER',
              },
              'device': {
                'id': devId,
                'store_id': storeId,
                'code': '01',
                'name': 'Main Counter',
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
            201,
          );
        }
        if (req.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'server_time': now.toIso8601String(),
              'since': '1970-01-01T00:00:00Z',
              'has_more': false,
              'role': 'OWNER',
              'changes': {
                'stores': [
                  {
                    'id': storeId,
                    'name': 'Himalayan Glow',
                    'pan_number': '601234567',
                    'phone': '9800000001',
                    'address': 'Thamel, Kathmandu',
                    'status': 'ACTIVE',
                    'updated_at': now.toIso8601String(),
                  }
                ],
                'store_members': [
                  {
                    'id': 'mem-1',
                    'user_id': 'u-owner-1',
                    'name': 'Aarav',
                    'username': 'aarav',
                    'role': 'OWNER',
                    'status': 'ACTIVE',
                    'updated_at': now.toIso8601String(),
                  }
                ],
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
                'register_shifts': [],
                'staff_shift_sessions': [],
                'expenses': [],
                'inventory_sync_audit': [],
              },
            }),
            200,
          );
        }
        if (req.url.path == '/api/stores/current/leave') {
          leaveCalled = true;
          return http.Response(jsonEncode({'status': 'LEFT'}), 200);
        }
        if (req.url.path == '/api/account' && req.method == 'DELETE') {
          return http.Response(jsonEncode({'status': 'ACCOUNT_DELETED'}), 200);
        }
        return http.Response('not found', 404);
      });

      final container = ProviderContainer(
        overrides: [
          secureKeyValueStoreProvider.overrideWithValue(store),
          httpClientFactoryProvider.overrideWithValue(() => mockHttp),
          connectivityStreamProvider
              .overrideWithValue(const Stream<List<ConnectivityResult>>.empty()),
          connectivityCheckProvider
              .overrideWithValue(() async => [ConnectivityResult.wifi]),
          sqlCipherDatabaseFactoryProvider.overrideWithValue(
            SqlCipherDatabaseFactory(databaseFileOverride: dbFile),
          ),
          databaseOpenerProvider.overrideWithValue(
            (holder) => SqlCipherDatabaseFactory().openEncrypted(
              ramKeyHolder: holder,
              file: dbFile,
              useBackgroundIsolate: false,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final auth = container.read(authSessionControllerProvider);
      await auth.initialize();
      await auth.loginAccount(
        email: 'aarav@example.com',
        password: 'himalaya-tea-strong-2026',
      );

      final created = await auth.createStoreAndEnroll(
        storeName: 'Himalayan Glow',
        panNumber: '601234567',
        phone: '9800000001',
        address: 'Thamel, Kathmandu',
        deviceName: 'Main Counter',
      );
      expect(created, isTrue);
      expect(auth.state.stage, AuthGateStage.shiftOpenRequired);
      expect(dbFile.existsSync(), isTrue);

      // Verify Drift stores table & PrinterConfig received store profile for offline receipts.
      final db = container.read(activeDatabaseProvider)!;
      final syncedStore = await db.fetchActiveStoreProfile();
      expect(syncedStore?.name, 'Himalayan Glow');
      expect(syncedStore?.panNumber, '601234567');

      final sub = container.listen(printerConfigProvider, (_, __) {});
      addTearDown(sub.close);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final printerCfg = container.read(printerConfigProvider);
      expect(printerCfg.storeName, 'Himalayan Glow');
      expect(printerCfg.storePan, '601234567');
      expect(printerCfg.storePhone, '9800000001');

      // Insert a pending outbox row -> leaveStoreSafely(discardUnsynced: false) MUST block!
      await db.into(db.syncOutbox).insert(
            SyncOutboxCompanion.insert(
              id: 'mut-pending-1',
              targetTable: 'sale_orders',
              recordId: 'sale-1',
              operation: 'INSERT',
              payloadJson: '{}',
              status: const Value('PENDING'),
            ),
          );

      final blocked = await auth.leaveStoreSafely(discardUnsynced: false);
      expect(blocked.left, isFalse);
      expect(blocked.unsyncedCount, 1);
      expect(leaveCalled, isFalse);
      expect(dbFile.existsSync(), isTrue);

      // Now confirm discardUnsynced: true -> leaves store & wipes DB, Keystore, credentials, RAM!
      final left = await auth.leaveStoreSafely(discardUnsynced: true);
      expect(left.left, isTrue);
      expect(leaveCalled, isTrue);
      expect(auth.state.stage, AuthGateStage.storeSetupRequired);
      expect(container.read(ramKeyHolderProvider).isUnlocked, isFalse);
      expect(
        await container.read(deviceCredentialsStoreProvider).readDevice(),
        isNull,
      );
      expect(
        await container.read(deviceCredentialsStoreProvider).readSession(),
        isNull,
      );
      expect(dbFile.existsSync(), isFalse);
      expect(File('${dbFile.path}-wal').existsSync(), isFalse);
      expect(File('${dbFile.path}-shm').existsSync(), isFalse);

      // Delete account wipes account session too.
      final deleted = await auth.deleteAccountWithPassword(
        email: 'aarav@example.com',
        password: 'himalaya-tea-strong-2026',
      );
      expect(deleted, isTrue);
      expect(auth.state.stage, AuthGateStage.accountAuthRequired);
      expect(
        await container
            .read(deviceCredentialsStoreProvider)
            .readAccountSession(),
        isNull,
      );
    });

    test('Kill-Switch executeRevocation immediately deletes local DB files on disk',
        () async {
      final store = InMemorySecureKeyValueStore();
      final dbFile = File('${tempDir.path}/killswitch_wipe.db');
      final now = DateTime.now().toUtc();
      final dek = EnvelopeCrypto.randomBytes(32);
      final lease = await _mintLease(
        dek: dek,
        deviceId: 'dev-rev-1',
        leaseId: 'lease-rev-1',
        expiresAt: now.add(const Duration(hours: 12)),
      );

      final mockHttp = MockClient((req) async {
        if (req.url.path == '/api/auth/login') {
          return http.Response(
            jsonEncode({
              'access_token': _jwtWithSid('store-1'),
              'token_type': 'Bearer',
              'expires_at': now.add(const Duration(hours: 12)).toIso8601String(),
              'user': {
                'id': 'u-staff',
                'name': 'Staff',
                'username': 'staff1',
                'role': 'STAFF',
              },
              'device': {
                'id': 'dev-rev-1',
                'store_id': 'store-1',
                'code': '02',
                'name': 'Counter 02',
                'platform': 'ANDROID',
                'status': 'ACTIVE',
              },
              'lease': {
                'lease_id': 'lease-rev-1',
                'issued_at': now.toIso8601String(),
                'expires_at': now.add(const Duration(hours: 12)).toIso8601String(),
                'expires_unix':
                    now.add(const Duration(hours: 12)).millisecondsSinceEpoch ~/
                        1000,
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
            jsonEncode({
              'server_time': now.toIso8601String(),
              'since': now.toIso8601String(),
              'has_more': false,
              'role': 'STAFF',
              'changes': <String, dynamic>{},
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      });

      final container = ProviderContainer(
        overrides: [
          secureKeyValueStoreProvider.overrideWithValue(store),
          httpClientFactoryProvider.overrideWithValue(() => mockHttp),
          connectivityStreamProvider
              .overrideWithValue(const Stream<List<ConnectivityResult>>.empty()),
          connectivityCheckProvider
              .overrideWithValue(() async => [ConnectivityResult.wifi]),
          sqlCipherDatabaseFactoryProvider.overrideWithValue(
            SqlCipherDatabaseFactory(databaseFileOverride: dbFile),
          ),
          databaseOpenerProvider.overrideWithValue(
            (holder) => SqlCipherDatabaseFactory().openEncrypted(
              ramKeyHolder: holder,
              file: dbFile,
              useBackgroundIsolate: false,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final creds = container.read(deviceCredentialsStoreProvider);
      await creds.saveDevice(
        const EnrolledDeviceInfo(
          deviceId: 'dev-rev-1',
          storeId: 'store-1',
          deviceCode: '02',
          deviceName: 'Counter 02',
          platform: 'ANDROID',
        ),
      );

      final auth = container.read(authSessionControllerProvider);
      await auth.initialize();
      final loggedIn = await auth.loginOnline(
        username: 'staff1',
        pin: '246810',
      );
      expect(loggedIn, isTrue);
      expect(dbFile.existsSync(), isTrue);

      await container
          .read(killSwitchServiceProvider)
          .executeRevocation(reason: 'Member removed');

      expect(auth.state.stage, AuthGateStage.revoked);
      expect(container.read(ramKeyHolderProvider).isUnlocked, isFalse);
      expect(dbFile.existsSync(), isFalse);
      expect(File('${dbFile.path}-wal').existsSync(), isFalse);
      expect(File('${dbFile.path}-shm').existsSync(), isFalse);
    });

    test('M3 isolation: legacy device without storeId or sid mismatch triggers controlled wipe',
        () async {
      final store = InMemorySecureKeyValueStore();
      final creds = DeviceCredentialsStore(store: store);

      // Legacy device without storeId
      await creds.saveDevice(
        const EnrolledDeviceInfo(
          deviceId: 'dev-legacy',
          deviceCode: '01',
          deviceName: 'Old Phone',
          platform: 'ANDROID',
        ),
      );

      final container1 = ProviderContainer(
        overrides: [secureKeyValueStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container1.dispose);
      final auth1 = container1.read(authSessionControllerProvider);
      await auth1.initialize();
      expect(auth1.state.stage, AuthGateStage.accountAuthRequired);
      expect(await creds.readDevice(), isNull);

      // Device with store-a, but persisted JWT has sid=store-b -> controlled wipe!
      await creds.saveDevice(
        const EnrolledDeviceInfo(
          deviceId: 'dev-a',
          storeId: 'store-a',
          deviceCode: '01',
          deviceName: 'Phone A',
          platform: 'ANDROID',
        ),
      );
      await creds.saveSession(
        PersistedAuthSession(
          accessToken: _jwtWithSid('store-b'),
          userId: 'u1',
          username: 'sita',
          displayName: 'Sita',
          role: 'STAFF',
          deviceId: 'dev-a',
          deviceCode: '01',
          leaseId: 'l1',
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        ),
      );

      final container2 = ProviderContainer(
        overrides: [secureKeyValueStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container2.dispose);
      final auth2 = container2.read(authSessionControllerProvider);
      await auth2.initialize();
      expect(auth2.state.stage, AuthGateStage.accountAuthRequired);
      expect(await creds.readDevice(), isNull);
      expect(await creds.readSession(), isNull);
    });

    test('Drift v1 -> v2 schema upgrade creates stores & store_members without crashing',
        () async {
      final v1File = File('${tempDir.path}/legacy_v1.db');
      final raw = raw_sqlite.sqlite3.open(v1File.path);
      raw.execute('''
        CREATE TABLE sync_metadata (
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL,
          updated_at TEXT NOT NULL DEFAULT '2026-01-01T00:00:00Z'
        );
      ''');
      raw.execute("INSERT INTO sync_metadata(key, value) VALUES ('k', 'v');");
      raw.execute('PRAGMA user_version = 1;');
      raw.dispose();

      final db = AppDatabase(NativeDatabase(v1File));
      addTearDown(db.close);

      expect(await db.getMetadata('k'), 'v');
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: 's1',
              name: 'Upgraded Store',
            ),
          );
      final fetched = await db.fetchActiveStoreProfile();
      expect(fetched?.name, 'Upgraded Store');
    });

    testWidgets('360x780 narrow-screen onboarding & TeamSettingsScreen render cleanly',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final store = InMemorySecureKeyValueStore();
      final mockHttp = MockClient((req) async {
        final now = DateTime.now().toUtc();
        if (req.url.path == '/api/stores/current/devices') {
          return http.Response(
            jsonEncode({
              'devices': [
                {
                  'id': 'dev-p1',
                  'code': '',
                  'name': 'Rina Phone',
                  'platform': 'ANDROID',
                  'status': 'PENDING',
                }
              ],
            }),
            200,
          );
        }
        if (req.url.path == '/api/stores/current/invitations') {
          if (req.method == 'POST') {
            return http.Response(
              jsonEncode({
                'invitation': {
                  'id': 'inv-1',
                  'store_id': 'store-1',
                  'role': 'STAFF',
                  'status': 'PENDING',
                  'expires_at': now.add(const Duration(hours: 48)).toIso8601String(),
                  'created_at': now.toIso8601String(),
                  'code': 'PSX-7K9M2-Q4X8N',
                },
              }),
              201,
            );
          }
          return http.Response(jsonEncode({'invitations': []}), 200);
        }
        if (req.url.path == '/api/stores/current/members') {
          return http.Response(
            jsonEncode({
              'members': [
                {
                  'user_id': 'u-1',
                  'name': 'Aarav',
                  'username': 'aarav',
                  'role': 'OWNER',
                  'status': 'ACTIVE',
                  'joined_at': now.toIso8601String(),
                },
                {
                  'user_id': 'u-2',
                  'name': 'Sita',
                  'username': 'sita',
                  'role': 'STAFF',
                  'status': 'ACTIVE',
                  'joined_at': now.toIso8601String(),
                },
              ],
            }),
            200,
          );
        }
        if (req.url.path == '/api/stores/current/devices/dev-p1/approve') {
          return http.Response(
            jsonEncode({
              'device': {
                'id': 'dev-p1',
                'code': '02',
                'name': 'Rina Phone',
                'platform': 'ANDROID',
                'status': 'ACTIVE',
              },
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      });

      final container = ProviderContainer(
        overrides: [
          secureKeyValueStoreProvider.overrideWithValue(store),
          httpClientFactoryProvider.overrideWithValue(() => mockHttp),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeAccessTokenProvider.notifier).setToken(
            _jwtWithSid('store-1'),
          );

      for (final screen in const [
        AccountAuthScreen(),
        VerifyEmailScreen(),
        StoreSetupScreen(),
        DeviceApprovalPendingScreen(),
        DeleteAccountScreen(),
      ]) {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(home: screen),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      }

      // Interactive TeamSettingsScreen: pending approval + create invite code once
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TeamSettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Pending Phone Approvals'), findsOneWidget);
      expect(find.text('Rina Phone'), findsOneWidget);
      expect(find.text('Team Members (2)'), findsOneWidget);

      await tester.tap(find.text('Generate Invite Code'));
      await tester.pumpAndSettle();
      expect(find.text('PSX-7K9M2-Q4X8N'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('SignupResult and AccountLoginResult handle omitted user.role from Go omitempty',
        () {
      final signup = SignupResult.fromJson({
        'user': {
          'id': 'u-1',
          'name': 'Santosh',
          'email': 'santosh@example.com',
          'username': 'santosh',
        },
        'verification_required': true,
      });
      expect(signup.user.role, '');
      expect(signup.verificationRequired, isTrue);

      final login = AccountLoginResult.fromJson({
        'access_token': 'acct.jwt.tok',
        'token_type': 'Bearer',
        'expires_at': '2026-11-19T04:00:00Z',
        'user': {
          'id': 'u-1',
          'name': 'Santosh',
          'email': 'santosh@example.com',
          'username': 'santosh',
        },
      });
      expect(login.user.role, '');
      expect(login.membership, isNull);
    });
  });
}
