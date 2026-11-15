import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import '../database/app_database.dart';
import '../database/sqlcipher_factory.dart';
import '../security/keystore_dek_manager.dart';
import '../security/ram_key_holder.dart';

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

/// Offline reboot recovery & Keystore DEK slot manager.
final keystoreDekManagerProvider = Provider<KeystoreDekManager>((ref) {
  return KeystoreDekManager(
    store: ref.watch(secureKeyValueStoreProvider),
    ramKeyHolder: ref.watch(ramKeyHolderProvider),
  );
});

/// SQLCipher AES-256 database opener factory.
final sqlCipherDatabaseFactoryProvider =
    Provider<SqlCipherDatabaseFactory>((ref) {
  return SqlCipherDatabaseFactory();
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
