import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:http/http.dart' as http;

import '../database/app_database.dart';
import '../database/sqlcipher_factory.dart';
import '../network/api_config.dart';
import '../network/pasal_api_client.dart';
import '../security/device_credentials_store.dart';
import '../security/keystore_dek_manager.dart';
import '../security/kill_switch_service.dart';
import '../security/ram_key_holder.dart';
import '../sync/sse_sync_client.dart';
import '../sync/sync_outbox_worker.dart';

/// Volatile RAM-only holder for the active 256-bit SQLCipher DEK.
///
/// Riverpod's `ChangeNotifierProvider` automatically disposes the returned
/// [RamKeyHolder] when the provider is disposed.
final ramKeyHolderProvider = ChangeNotifierProvider<RamKeyHolder>((ref) {
  return RamKeyHolder();
});

/// Platform hardware Keystore / Secure Enclave wrapper.
final secureKeyValueStoreProvider = Provider<SecureKeyValueStore>((ref) {
  return FlutterSecureStorageKeyValueStore();
});

/// Hardware Keystore / Secure Enclave persistence for terminal enrollment,
/// active JWT bearer token, and server URL.
final deviceCredentialsStoreProvider = Provider<DeviceCredentialsStore>((ref) {
  return DeviceCredentialsStore(
    store: ref.watch(secureKeyValueStoreProvider),
  );
});

/// Offline reboot recovery & Keystore DEK slot manager.
final Provider<KeystoreDekManager> keystoreDekManagerProvider =
    Provider<KeystoreDekManager>((ref) {
  return KeystoreDekManager(
    store: ref.watch(secureKeyValueStoreProvider),
    // Read rather than watch: RamKeyHolder mutates in place and notifies UI;
    // KeystoreDekManager & KillSwitchService must keep identity across unlock/wipe.
    ramKeyHolder: ref.read(ramKeyHolderProvider),
  );
});

/// SQLCipher AES-256 database opener factory.
final sqlCipherDatabaseFactoryProvider =
    Provider<SqlCipherDatabaseFactory>((ref) {
  return SqlCipherDatabaseFactory();
});

/// Signature for opening an unlocked [AppDatabase] (overridable in widget tests).
typedef DatabaseOpener = Future<AppDatabase> Function(RamKeyHolder ramKeyHolder);

final databaseOpenerProvider = Provider<DatabaseOpener>((ref) {
  final factory = ref.watch(sqlCipherDatabaseFactoryProvider);
  return (holder) => factory.openEncrypted(ramKeyHolder: holder);
});

/// Active unlocked [AppDatabase] instance (null when locked at Login / PIN gate).
///
/// Automatically closes the previous database when replaced or disposed, and
/// clears state to `null` immediately when [ramKeyHolderProvider] locks/wipes.
class ActiveDatabaseNotifier extends Notifier<AppDatabase?> {
  AppDatabase? _managedDb;

  @override
  AppDatabase? build() {
    ref.listen<RamKeyHolder>(ramKeyHolderProvider, (_, holder) {
      if (!holder.isUnlocked && _managedDb != null) {
        _closeManagedDb();
        state = null;
      }
    });
    ref.onDispose(_closeManagedDb);
    return _managedDb;
  }

  void setDatabase(AppDatabase? db) {
    if (identical(_managedDb, db)) return;
    final previous = _managedDb;
    _managedDb = db;
    if (previous != null) {
      unawaited(previous.close());
    }
    state = db;
  }

  void _closeManagedDb() {
    final db = _managedDb;
    _managedDb = null;
    if (db != null) {
      unawaited(db.close());
    }
  }
}

final activeDatabaseProvider =
    NotifierProvider<ActiveDatabaseNotifier, AppDatabase?>(
  ActiveDatabaseNotifier.new,
);

/// Mutable API endpoint configuration (persisted via [DeviceCredentialsStore]).
class ApiConfigNotifier extends Notifier<ApiConfig> {
  @override
  ApiConfig build() => const ApiConfig();

  void setBaseUrl(String url) {
    state = state.copyWith(baseUrl: url.trim());
  }
}

final apiConfigProvider = NotifierProvider<ApiConfigNotifier, ApiConfig>(
  ApiConfigNotifier.new,
);

/// Shared HTTP client factory (overridable in tests with `MockClient`).
final httpClientFactoryProvider = Provider<http.Client Function()>((ref) {
  return http.Client.new;
});

final httpClientProvider = Provider<http.Client>((ref) {
  final client = ref.watch(httpClientFactoryProvider)();
  ref.onDispose(client.close);
  return client;
});

/// Mutable active JWT bearer token synced by `AuthSessionController`.
class ActiveAccessTokenNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void setToken(String? token) {
    state = (token == null || token.trim().isEmpty) ? null : token.trim();
  }
}

final activeAccessTokenProvider =
    NotifierProvider<ActiveAccessTokenNotifier, String?>(
  ActiveAccessTokenNotifier.new,
);

/// Connectivity stream & checker overrides for `SyncOutboxWorker`.
final connectivityStreamProvider = Provider<Stream<List<ConnectivityResult>>>(
  (ref) => Connectivity().onConnectivityChanged,
);

final connectivityCheckProvider =
    Provider<Future<List<ConnectivityResult>> Function()>(
  (ref) => () => Connectivity().checkConnectivity(),
);

/// Typed HTTP client for Step 3 Auth & Step 4 Sync Go endpoints.
final Provider<PasalApiClient> pasalApiClientProvider =
    Provider<PasalApiClient>((ref) {
  final httpClient = ref.watch(httpClientProvider);
  return PasalApiClient(
    // Dynamic config lookup prevents URL updates from rebuilding SyncOutboxWorker.
    getConfig: () => ref.read(apiConfigProvider),
    httpClient: httpClient,
    onDeviceRevoked: (reason) => ref
        .read(killSwitchServiceProvider)
        .executeRevocation(reason: reason),
  );
});

/// Instant Kill-Switch revocation coordinator (`DEVICE_REVOKED`).
final Provider<KillSwitchService> killSwitchServiceProvider =
    Provider<KillSwitchService>((ref) {
  return KillSwitchService(
    keystoreDekManager: ref.watch(keystoreDekManagerProvider),
    credentialsStore: ref.watch(deviceCredentialsStoreProvider),
    onWillExecute: () {
      unawaited(ref.read(sseSyncClientProvider).stop());
      unawaited(ref.read(syncOutboxWorkerProvider).stop());
      ref.read(activeAccessTokenProvider.notifier).setToken(null);
    },
  );
});

/// Background outbox push (`LIMIT 50`) & cursor delta pull coordinator.
final ChangeNotifierProvider<SyncOutboxWorker> syncOutboxWorkerProvider =
    ChangeNotifierProvider<SyncOutboxWorker>((ref) {
  final worker = SyncOutboxWorker(
    getDatabase: () => ref.read(activeDatabaseProvider),
    getAccessToken: () => ref.read(activeAccessTokenProvider),
    apiClient: ref.watch(pasalApiClientProvider),
    connectivityStream: ref.watch(connectivityStreamProvider),
    checkConnectivity: ref.watch(connectivityCheckProvider),
    onDeviceRevoked: (reason) => ref
        .read(killSwitchServiceProvider)
        .executeRevocation(reason: reason),
    onAuthInvalidated: (err) async {
      await ref.read(sseSyncClientProvider).stop();
      await ref.read(syncOutboxWorkerProvider).stop();
      ref.read(activeAccessTokenProvider.notifier).setToken(null);
      if (err.code == 'USER_DISABLED' || err.code == 'DEVICE_NOT_ACTIVE') {
        await ref.read(keystoreDekManagerProvider).wipeAll();
        await ref.read(deviceCredentialsStoreProvider).clearSession();
      } else {
        ref.read(ramKeyHolderProvider).wipe();
      }
    },
    onOnlineReconnected: () => ref.read(sseSyncClientProvider).reconnectNow(),
  );
  return worker;
});

/// Real-time Server-Sent Events stream client (`GET /api/sync/events`).
final Provider<SseSyncClient> sseSyncClientProvider =
    Provider<SseSyncClient>((ref) {
  final client = SseSyncClient(
    getConfig: () => ref.read(apiConfigProvider),
    getAccessToken: () => ref.read(activeAccessTokenProvider),
    clientFactory: ref.watch(httpClientFactoryProvider),
    onConnectedChanged: (connected) =>
        ref.read(syncOutboxWorkerProvider).setSseConnected(connected),
    onDataChanged: (_) => ref.read(syncOutboxWorkerProvider).pullNow(),
    onDeviceRevoked: (reason) => ref
        .read(killSwitchServiceProvider)
        .executeRevocation(reason: reason),
    onSessionExpired: () async {
      ref.read(ramKeyHolderProvider).wipe();
      ref.read(activeAccessTokenProvider.notifier).setToken(null);
      await ref.read(deviceCredentialsStoreProvider).clearSession();
    },
  );
  ref.onDispose(() {
    unawaited(client.stop(notify: false));
  });
  return client;
});
