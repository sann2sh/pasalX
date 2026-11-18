import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../security/ram_key_holder.dart';
import 'app_database.dart';

class SqlCipherUnavailableException implements Exception {
  const SqlCipherUnavailableException(this.message);
  final String message;

  @override
  String toString() => 'SqlCipherUnavailableException: $message';
}

/// Opens [AppDatabase] backed by a SQLCipher AES-256 encrypted `.db` file using
/// the volatile 256-bit DEK from [ramKeyHolder].
///
/// Relies on `package:sqlite3` Native Assets compiled with `source: sqlcipher`
/// (`SQLCipher 4.x`) configured in `pubspec.yaml`.
///
/// Security guarantees:
/// 1. Fails closed (`SqlCipherUnavailableException`) if `PRAGMA cipher_version`
///    returns empty so the app NEVER creates an unencrypted SQLite file.
/// 2. Injects the 256-bit DEK via raw hex literal `PRAGMA key = "x'...'"`
///    fetched solely from RAM at open time.
/// 3. Immediately probes `sqlite_master` so wrong-key errors fail fast.
/// 4. Registers a wipe listener on [ramKeyHolder] so wiping RAM immediately
///    closes the [AppDatabase] handle (Kill-Switch / lease expiry).
class SqlCipherDatabaseFactory {
  SqlCipherDatabaseFactory({
    this.databaseFileName = 'pasalx_vault.db',
    @visibleForTesting this.databaseFileOverride,
    @visibleForTesting this.hasCipherProbeOverride,
  });

  final String databaseFileName;
  final File? databaseFileOverride;

  /// Optional test-only override to simulate missing SQLCipher native library.
  final bool Function(sqlite.Database rawDb)? hasCipherProbeOverride;

  /// Resolves the default encrypted vault file path on disk.
  Future<File> resolveDatabaseFile({Directory? baseDir}) async {
    if (databaseFileOverride != null) return databaseFileOverride!;
    final dir = baseDir ?? await getApplicationSupportDirectory();
    return File(p.join(dir.path, databaseFileName));
  }

  /// Opens the encrypted [AppDatabase] using the DEK currently held in [ramKeyHolder].
  Future<AppDatabase> openEncrypted({
    required RamKeyHolder ramKeyHolder,
    File? file,
    bool useBackgroundIsolate = true,
  }) async {
    if (!ramKeyHolder.isUnlocked) {
      throw StateError(
        'Cannot open encrypted database while RamKeyHolder is locked',
      );
    }

    final dbFile = file ?? await resolveDatabaseFile();
    await dbFile.parent.create(recursive: true);
    final existedBefore = dbFile.existsSync();

    final keyLiteral = ramKeyHolder.withSqlCipherRawKey((literal) => literal);
    final setupCallback = _buildSetup(keyLiteral, hasCipherProbeOverride);

    final QueryExecutor executor = useBackgroundIsolate
        ? NativeDatabase.createInBackground(dbFile, setup: setupCallback)
        : NativeDatabase(dbFile, setup: setupCallback);

    final db = AppDatabase(executor);
    // Force opening immediately so wrong-key or missing-cipher errors fail on
    // open rather than lazily on the first widget query, closing executor on error.
    try {
      await db.customSelect('SELECT 1;').get();
    } catch (_) {
      await db.close();
      if (!existedBefore) {
        await _deleteIfExists(dbFile);
        await _deleteIfExists(File('${dbFile.path}-wal'));
        await _deleteIfExists(File('${dbFile.path}-shm'));
      }
      rethrow;
    }

    // Auto-close connection if RAM key is wiped or disposed, and remove listener
    // automatically if application code calls db.close() directly.
    late final VoidCallback lockListener;
    var closed = false;
    lockListener = () {
      if (!ramKeyHolder.isUnlocked && !closed) {
        closed = true;
        ramKeyHolder.removeLockListener(lockListener);
        db.close();
      }
    };
    ramKeyHolder.addLockListener(lockListener);
    db.addOnClose(() {
      closed = true;
      ramKeyHolder.removeLockListener(lockListener);
    });

    return db;
  }

  static Future<void> _deleteIfExists(File f) async {
    try {
      if (f.existsSync()) {
        await f.delete();
      }
    } catch (_) {
      // Best-effort cleanup of failed open artifact.
    }
  }

  static void Function(sqlite.Database) _buildSetup(
    String keyLiteral,
    bool Function(sqlite.Database)? probeOverride,
  ) {
    return (sqlite.Database rawDb) {
      final hasCipher = probeOverride != null
          ? probeOverride(rawDb)
          : _defaultHasCipher(rawDb);
      if (!hasCipher) {
        throw const SqlCipherUnavailableException(
          'SQLCipher library is not loaded; refusing plaintext database fallback.',
        );
      }
      if (!RegExp(r"^x'[0-9a-f]{64}'$").hasMatch(keyLiteral)) {
        throw StateError('Invalid SQLCipher raw key literal format');
      }

      rawDb.execute('PRAGMA cipher_memory_security = ON;');
      rawDb.execute('PRAGMA key = "$keyLiteral";');
      // Verify key validity / HMAC immediately; throws SqliteException on mismatch.
      rawDb.select('SELECT count(*) FROM sqlite_master;');
      rawDb.execute('PRAGMA foreign_keys = ON;');
      rawDb.execute('PRAGMA journal_mode = WAL;');
      rawDb.execute('PRAGMA synchronous = NORMAL;');
      rawDb.execute('PRAGMA temp_store = MEMORY;');
    };
  }

  static bool _defaultHasCipher(sqlite.Database rawDb) {
    final cipherRows = rawDb.select('PRAGMA cipher_version;');
    return cipherRows.isNotEmpty &&
        (cipherRows.first.values.first?.toString().trim().isNotEmpty ?? false);
  }
}
