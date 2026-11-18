import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pasalx_mobile/core/database/app_database.dart';
import 'package:pasalx_mobile/core/database/money.dart';
import 'package:pasalx_mobile/core/database/sqlcipher_factory.dart';
import 'package:pasalx_mobile/core/providers/foundation_providers.dart';
import 'package:pasalx_mobile/core/security/keystore_dek_manager.dart';
import 'package:pasalx_mobile/core/security/ram_key_holder.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

ActiveLeaseSession _testSession(DateTime now) {
  return ActiveLeaseSession(
    userId: 'user-owner-1',
    username: 'owner',
    role: 'OWNER',
    deviceId: 'device-01-uuid',
    deviceCode: '01',
    leaseId: 'lease-01-uuid',
    issuedAt: now,
    expiresAt: now.add(const Duration(hours: 12)),
  );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('MoneyUtils fixed-point arithmetic', () {
    test('parses and formats paisa without floating-point rounding drift', () {
      expect(MoneyUtils.parseToPaisa('1350.50'), 135050);
      expect(MoneyUtils.parseToPaisa(1350), 135000);
      expect(MoneyUtils.parseToPaisa('-25.05'), -2505);
      expect(MoneyUtils.toDecimalString(135050), '1350.50');
      expect(MoneyUtils.toDecimalString(-5), '-0.05');
      expect(MoneyUtils.formatRs(135000), 'Rs. 1,350');
      expect(MoneyUtils.formatRs(135050), 'Rs. 1,350.50');
      expect(MoneyUtils.parseToPaisa('9999999999.99'), 999999999999);
      expect(MoneyUtils.formatRs(-5), '-Rs. 0.05');
      expect(
        () => MoneyUtils.parseToPaisa('10.123'),
        throwsFormatException,
      );
      expect(
        () => MoneyUtils.parseToPaisa('10000000000.00'),
        throwsFormatException,
      );
      expect(
        () => MoneyUtils.parseToPaisa('999999999999999999999.00'),
        throwsFormatException,
      );
    });
  });

  group('Encrypted Drift + SQLCipher AES-256 Vault', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pasalx_vault_test_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('fails closed if SQLCipher cipher_version probe returns empty',
        () async {
      final now = DateTime.utc(2026, 11, 15, 5, 0, 0);
      final holder = RamKeyHolder(now: () => now)
        ..unlock(
          dekBytes: _hexToBytes(
            '1111111111111111111111111111111111111111111111111111111111111111',
          ),
          session: _testSession(now),
        );
      final dbFile = File('${tempDir.path}/plaintext_rejected.db');

      final factory = SqlCipherDatabaseFactory(
        hasCipherProbeOverride: (_) => false,
      );

      await expectLater(
        () => factory.openEncrypted(
          ramKeyHolder: holder,
          file: dbFile,
          useBackgroundIsolate: false,
        ),
        throwsA(isA<SqlCipherUnavailableException>()),
      );
      // Verify newly created empty file was cleaned up on failed open.
      expect(dbFile.existsSync(), isFalse);
      holder.dispose();
    });

    test(
        'creates verified AES-256 encrypted 21-table DB, blocks wrong key, recovers offline via PIN & closes on RAM wipe',
        () async {
      var now = DateTime.utc(2026, 11, 15, 5, 0, 0);
      final dek = _hexToBytes(
        'a3b2c1d0e4f567890123456789abcdefa3b2c1d0e4f567890123456789abcdef',
      );
      final wrongDek = _hexToBytes(
        'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
      );
      final dbFile = File('${tempDir.path}/pasalx_vault.db');

      final store = InMemorySecureKeyValueStore();
      var holder = RamKeyHolder(now: () => now);
      addTearDown(() => holder.dispose());
      var keystore = KeystoreDekManager(
        store: store,
        ramKeyHolder: holder,
        now: () => now,
        pbkdf2Iterations: 1000,
      );

      final session = _testSession(now);
      holder.unlock(dekBytes: dek, session: session);
      await keystore.provisionOfflineRecoverySlot(
        session: session,
        dekBytes: dek,
        pin: '654321',
      );
      RamKeyHolder.zeroBuffer(dek);

      final factory = SqlCipherDatabaseFactory();

      final db = await factory.openEncrypted(
        ramKeyHolder: holder,
        file: dbFile,
        useBackgroundIsolate: false,
      );

      // 1. Confirm genuine SQLCipher 4.x library active.
      final cipherVer = await db.readCipherVersion();
      expect(cipherVer, isNotNull);
      expect(cipherVer, startsWith('4.'));

      // 2. Confirm all 21 tables exist (19 core/synced + sync_outbox + sync_metadata).
      final tables = await db.listTableNames();
      const expectedTables = <String>[
        'batches',
        'customer_shade_profiles',
        'customer_transactions',
        'customers',
        'expenses',
        'inventory_sync_audit',
        'product_variants',
        'products',
        'purchase_invoice_items',
        'purchase_invoices',
        'register_shifts',
        'sale_items',
        'sale_orders',
        'sale_payments',
        'staff_shift_sessions',
        'stock_movements',
        'store_members',
        'stores',
        'supplier_payments',
        'suppliers',
        'sync_metadata',
        'sync_outbox',
        'users',
      ];
      expect(tables, containsAll(expectedTables));
      expect(tables.length, expectedTables.length);

      // 3. Insert realistic 3-tier catalog, masked STAFF-compatible nullable cost,
      //    and offline outbox record.
      await db.into(db.products).insert(
            ProductsCompanion.insert(
              id: 'prod-maybelline-fitme',
              name: 'Fit Me Matte Foundation',
              brand: 'Maybelline',
              category: 'Makeup - Face',
            ),
          );
      await db.into(db.productVariants).insert(
            ProductVariantsCompanion.insert(
              id: 'var-128-warm-nude',
              productId: 'prod-maybelline-fitme',
              variantName: '#128 Warm Nude',
              sizeVolume: const Value('30ml'),
              colorHex: const Value('#DCB38F'),
            ),
          );
      await db.into(db.batches).insert(
            BatchesCompanion.insert(
              id: 'batch-10024',
              variantId: 'var-128-warm-nude',
              batchCode: 'LOT-2026-A',
              stickerBarcode: '100024',
              sellingPrice: 135000, // Rs. 1,350.00
              costPrice: const Value(null), // masked on STAFF phones
              stockQuantity: const Value(24),
              expiryDate: '2028-05-01',
            ),
          );
      await db.enqueueOutboxMutation(
        mutationId: 'mut-001',
        targetTable: 'batches',
        recordId: 'batch-10024',
        operation: 'INSERT',
        payloadJson: jsonEncode({'id': 'batch-10024', 'sticker_barcode': '100024'}),
      );
      await db.setMetadata('last_pull_cursor', '2026-11-15T05:00:00Z');

      // Verify microsecond DateTime precision & deterministic FIFO rowid outbox ordering
      // when multiple mutations share the exact same timestamp.
      final microTs = DateTime.utc(2026, 11, 15, 5, 1, 2, 123, 456);
      await db.enqueueOutboxMutation(
        mutationId: 'mut-z-first',
        targetTable: 'products',
        recordId: 'prod-1',
        operation: 'INSERT',
        payloadJson: '{}',
        clientUpdatedAt: microTs,
        createdAt: microTs,
      );
      await db.enqueueOutboxMutation(
        mutationId: 'mut-a-second',
        targetTable: 'product_variants',
        recordId: 'var-1',
        operation: 'INSERT',
        payloadJson: '{}',
        clientUpdatedAt: microTs,
        createdAt: microTs,
      );
      final ordered = await db.fetchPendingOutbox();
      expect(
        ordered.map((e) => e.id).toList(),
        ['mut-001', 'mut-z-first', 'mut-a-second'],
      );
      expect(
        ordered[1].clientUpdatedAt?.toUtc().microsecondsSinceEpoch,
        microTs.microsecondsSinceEpoch,
      );

      // 4. Verify reactive outbox watch & relational read.
      expect(await db.watchPendingOutboxCount().first, 3);
      final fetchedBatch = await (db.select(db.batches)
            ..where((b) => b.stickerBarcode.equals('100024')))
          .getSingle();
      expect(fetchedBatch.sellingPrice, 135000);
      expect(fetchedBatch.costPrice, isNull);

      // Close DB cleanly so WAL checkpoints to disk and we can inspect raw file.
      await db.close();

      // 5. Inspect raw `.db` file bytes on disk -> must be completely encrypted!
      expect(dbFile.existsSync(), isTrue);
      final rawBytes = dbFile.readAsBytesSync();
      expect(rawBytes.length, greaterThan(4096));
      final headerString = utf8.decode(rawBytes.sublist(0, 15), allowMalformed: true);
      expect(headerString, isNot('SQLite format 3'));

      // Plaintext catalog data must NEVER appear anywhere on disk!
      final rawLatin1 = latin1.decode(rawBytes);
      expect(rawLatin1.contains('Fit Me Matte Foundation'), isFalse);
      expect(rawLatin1.contains('100024'), isFalse);
      expect(rawLatin1.contains('Warm Nude'), isFalse);

      // 6. Attempt open with wrong 256-bit DEK -> must fail with SqliteException.
      final wrongHolder = RamKeyHolder(now: () => now)
        ..unlock(dekBytes: wrongDek, session: session);
      await expectLater(
        () => factory.openEncrypted(
          ramKeyHolder: wrongHolder,
          file: dbFile,
          useBackgroundIsolate: false,
        ),
        throwsA(isA<sqlite.SqliteException>()),
      );
      wrongHolder.dispose();

      // 7. Simulate phone reboot offline -> recover DEK via PIN from Keystore ->
      //    reopen encrypted Drift DB and read persisted records!
      now = now.add(const Duration(hours: 1));
      holder = RamKeyHolder(now: () => now);
      keystore = KeystoreDekManager(
        store: store,
        ramKeyHolder: holder,
        now: () => now,
        pbkdf2Iterations: 1000,
      );
      await keystore.recoverDekWithPin('654321');

      final reopenedDb = await factory.openEncrypted(
        ramKeyHolder: holder,
        file: dbFile,
        useBackgroundIsolate: true, // Also exercises background Drift isolate path!
      );
      expect(
        await reopenedDb.getMetadata('last_pull_cursor'),
        '2026-11-15T05:00:00Z',
      );
      final pending = await reopenedDb.fetchPendingOutbox();
      expect(pending, hasLength(3));
      expect(pending.first.recordId, 'batch-10024');

      // 8. Verify ActiveDatabaseNotifier closes & clears state automatically on wipe.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final realNow = DateTime.now().toUtc();
      container.read(ramKeyHolderProvider).unlock(
            dekBytes: _hexToBytes(
              'a3b2c1d0e4f567890123456789abcdefa3b2c1d0e4f567890123456789abcdef',
            ),
            session: _testSession(realNow),
          );
      final managedDb = await factory.openEncrypted(
        ramKeyHolder: container.read(ramKeyHolderProvider),
        file: dbFile,
        useBackgroundIsolate: false,
      );
      container.read(activeDatabaseProvider.notifier).setDatabase(managedDb);
      expect(container.read(activeDatabaseProvider), same(managedDb));
      container.read(ramKeyHolderProvider).wipe();
      expect(container.read(activeDatabaseProvider), isNull);

      // 9. Simulate Kill-Switch (`wipeAll()`) -> wipes RAM & Keystore AND closes DB!
      await keystore.wipeAll();
      expect(holder.isUnlocked, isFalse);
      expect((await keystore.inspectSlot()).hasSlot, isFalse);
      await expectLater(
        () => reopenedDb.listTableNames(),
        throwsA(anything),
      );
    });
  });
}
