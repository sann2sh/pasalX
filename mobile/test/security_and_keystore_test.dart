import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pasalx_mobile/core/security/envelope_crypto.dart';
import 'package:pasalx_mobile/core/security/keystore_dek_manager.dart';
import 'package:pasalx_mobile/core/security/ram_key_holder.dart';

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _bytesToHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('RamKeyHolder', () {
    test('enforces key length, 12h lease TTL, and zeros RAM on wipe()', () async {
      var now = DateTime.utc(2026, 11, 15, 4, 0, 0);
      final holder = RamKeyHolder(now: () => now);
      addTearDown(holder.dispose);
      var notifications = 0;
      holder.addListener(() => notifications++);

      final dek = _hexToBytes(
        '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff',
      );
      final session = ActiveLeaseSession(
        userId: 'user-1',
        username: 'sunita',
        role: 'STAFF',
        deviceId: 'dev-1',
        deviceCode: '01',
        leaseId: 'lease-1',
        issuedAt: now,
        expiresAt: now.add(const Duration(hours: 12)),
      );

      // Wrong DEK length rejected.
      expect(
        () => holder.unlock(dekBytes: Uint8List(16), session: session),
        throwsArgumentError,
      );

      // Valid unlock.
      holder.unlock(dekBytes: dek, session: session);
      RamKeyHolder.zeroBuffer(dek); // caller zeroes its copy
      expect(holder.isUnlocked, isTrue);
      expect(notifications, 1);

      final hexLiteral = holder.withSqlCipherRawKey((lit) => lit);
      expect(
        hexLiteral,
        "x'00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff'",
      );

      // Mutating a defensive copy never corrupts holder's key.
      final copy = holder.copyDekBytes();
      expect(_bytesToHex(copy),
          '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff');
      RamKeyHolder.zeroBuffer(copy);
      expect(
        holder.withSqlCipherRawKey((lit) => lit),
        "x'00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff'",
      );

      // Advance clock past 12 hours -> passive isUnlocked wipes DEK + runs lock
      // listener immediately and notifies UI listeners asynchronously (safe during build).
      var lockCallbacks = 0;
      holder.addLockListener(() => lockCallbacks++);
      now = now.add(const Duration(hours: 12, seconds: 1));
      expect(holder.isUnlocked, isFalse);
      expect(lockCallbacks, 1);
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 2);
      expect(
        () => holder.withSqlCipherRawKey((lit) => lit),
        throwsStateError,
      );

      // Re-unlock within fresh TTL, advance clock, and test active enforceLeaseValidity().
      final midDek = _hexToBytes(
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      holder.unlock(
        dekBytes: midDek,
        session: ActiveLeaseSession(
          userId: 'user-1',
          username: 'sunita',
          role: 'STAFF',
          deviceId: 'dev-1',
          deviceCode: '01',
          leaseId: 'lease-mid',
          issuedAt: now,
          expiresAt: now.add(const Duration(hours: 12)),
        ),
      );
      now = now.add(const Duration(hours: 12, seconds: 1));
      expect(holder.enforceLeaseValidity(), isFalse);
      expect(lockCallbacks, 2);
      expect(notifications, 4);

      // Re-unlock within fresh TTL & explicit wipe().
      final freshDek = _hexToBytes(
        'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100',
      );
      holder.unlock(
        dekBytes: freshDek,
        session: ActiveLeaseSession(
          userId: 'user-1',
          username: 'sunita',
          role: 'STAFF',
          deviceId: 'dev-1',
          deviceCode: '01',
          leaseId: 'lease-2',
          issuedAt: now,
          expiresAt: now.add(const Duration(hours: 12)),
        ),
      );
      expect(holder.isUnlocked, isTrue);
      holder.wipe();
      expect(lockCallbacks, 3);
      expect(holder.isUnlocked, isFalse);
      expect(holder.session, isNull);
    });
  });

  group('EnvelopeCrypto Go Interop', () {
    test('unwraps genuine 64-byte PX\\x01\\x00 server envelope & rejects tampering',
        () async {
      // Vector generated directly by Go auth.IssueLease (HKDF-SHA256 + AES-256-GCM).
      const expectedDekHex =
          '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
      final kek = base64Decode('q0wF1R4vNBVCMUs+gc7wG4EZB5WOmBotx+nk+qXRHt4=');
      final env = base64Decode(
        'UFgBAAmuOPwW0lGGd9TgfnNCls78V6WgPr28q4+sLxDZr6hLzjGFYKpcwmRzKYlDNoFVqRqmwzWRFCbMckrO8Q==',
      );
      final expiresAt = DateTime.parse('2026-11-15T16:00:00Z');
      const deviceId = 'device-1111-2222-3333-444444444444';
      const leaseId = 'lease-aaaa-bbbb-cccc-dddddddddddd';

      final unwrapped = await EnvelopeCrypto.unwrapServerEnvelope(
        kek: kek,
        envelope: env,
        deviceId: deviceId,
        leaseId: leaseId,
        expiresAt: expiresAt,
      );
      expect(_bytesToHex(unwrapped), expectedDekHex);

      // Tampered expiry AAD fails GCM authentication.
      await expectLater(
        () => EnvelopeCrypto.unwrapServerEnvelope(
          kek: kek,
          envelope: env,
          deviceId: deviceId,
          leaseId: leaseId,
          expiresAt: expiresAt.add(const Duration(hours: 1)),
        ),
        throwsA(isA<EnvelopeException>()),
      );

      // Tampered device_id fails GCM authentication.
      await expectLater(
        () => EnvelopeCrypto.unwrapServerEnvelope(
          kek: kek,
          envelope: env,
          deviceId: 'device-other',
          leaseId: leaseId,
          expiresAt: expiresAt,
        ),
        throwsA(isA<EnvelopeException>()),
      );

      // Flipped byte inside envelope fails.
      final badEnv = Uint8List.fromList(env);
      badEnv[20] ^= 0x01;
      await expectLater(
        () => EnvelopeCrypto.unwrapServerEnvelope(
          kek: kek,
          envelope: badEnv,
          deviceId: deviceId,
          leaseId: leaseId,
          expiresAt: expiresAt,
        ),
        throwsA(isA<EnvelopeException>()),
      );
    });
  });

  group('KeystoreDekManager Offline Reboot Recovery', () {
    test('provisions PIN-sealed slot, recovers DEK offline, blocks clock tamper & brute force',
        () async {
      var now = DateTime.utc(2026, 11, 15, 4, 0, 0);
      final store = InMemorySecureKeyValueStore();
      var holder = RamKeyHolder(now: () => now);
      var manager = KeystoreDekManager(
        store: store,
        ramKeyHolder: holder,
        now: () => now,
        pbkdf2Iterations: 1000, // fast deterministic PBKDF2 in unit test
      );

      final dek = _hexToBytes(
        'deadbeefcafebabe0123456789abcdefdeadbeefcafebabe0123456789abcdef',
      );
      final session = ActiveLeaseSession(
        userId: 'user-staff-1',
        username: 'sita',
        role: 'STAFF',
        deviceId: 'device-01',
        deviceCode: '01',
        leaseId: 'lease-01',
        issuedAt: now,
        expiresAt: now.add(const Duration(hours: 12)),
      );

      await manager.provisionOfflineRecoverySlot(
        session: session,
        dekBytes: dek,
        pin: '482910',
      );

      // Confirm plaintext DEK is never written in plaintext inside Keystore payload.
      final serializedStore = store.debugSnapshot.values.join('\n');
      expect(serializedStore.contains('deadbeef'), isFalse);
      expect(serializedStore.contains(base64Encode(dek)), isFalse);

      // Simulate reboot (new RamKeyHolder + KeystoreDekManager reading same Keystore).
      now = now.add(const Duration(hours: 2));
      holder = RamKeyHolder(now: () => now);
      manager = KeystoreDekManager(
        store: store,
        ramKeyHolder: holder,
        now: () => now,
        pbkdf2Iterations: 1000,
      );

      // Wrong PIN fails and decrements attempts without wiping yet.
      await expectLater(
        () => manager.recoverDekWithPin('111111'),
        throwsA(
          isA<OfflineRecoveryException>()
              .having((e) => e.wiped, 'wiped', isFalse)
              .having((e) => e.remainingAttempts, 'remaining', 4),
        ),
      );
      expect(holder.isUnlocked, isFalse);

      // Correct PIN unlocks RAM holder offline with exact original DEK.
      final recoveredSession = await manager.recoverDekWithPin('482910');
      expect(recoveredSession.username, 'sita');
      expect(holder.isUnlocked, isTrue);
      final recoveredDek = holder.copyDekBytes();
      expect(_bytesToHex(recoveredDek), _bytesToHex(dek));
      RamKeyHolder.zeroBuffer(recoveredDek);

      // Clock rollback > 5m detected -> wipes slot cleanly.
      now = now.subtract(const Duration(minutes: 10));
      holder.wipe();
      await expectLater(
        () => manager.recoverDekWithPin('482910'),
        throwsA(
          isA<OfflineRecoveryException>().having((e) => e.wiped, 'wiped', isTrue),
        ),
      );
      expect((await manager.inspectSlot()).hasSlot, isFalse);
    });

    test('wipes hardware Keystore slot automatically after 5 wrong offline PINs',
        () async {
      final now = DateTime.utc(2026, 11, 15, 4, 0, 0);
      final store = InMemorySecureKeyValueStore();
      final holder = RamKeyHolder(now: () => now);
      final manager = KeystoreDekManager(
        store: store,
        ramKeyHolder: holder,
        now: () => now,
        pbkdf2Iterations: 1000,
      );

      final dek = _hexToBytes(
        '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20',
      );
      await manager.provisionOfflineRecoverySlot(
        session: ActiveLeaseSession(
          userId: 'u1',
          username: 'anita',
          role: 'MANAGER',
          deviceId: 'd2',
          deviceCode: '02',
          leaseId: 'l2',
          issuedAt: now,
          expiresAt: now.add(const Duration(hours: 12)),
        ),
        dekBytes: dek,
        pin: '998877',
      );

      for (var i = 1; i <= 4; i++) {
        await expectLater(
          () => manager.recoverDekWithPin('000000'),
          throwsA(
            isA<OfflineRecoveryException>()
                .having((e) => e.wiped, 'wiped', isFalse)
                .having((e) => e.remainingAttempts, 'remaining', 5 - i),
          ),
        );
      }

      // 5th failure permanently wipes hardware slot.
      await expectLater(
        () => manager.recoverDekWithPin('000000'),
        throwsA(
          isA<OfflineRecoveryException>()
              .having((e) => e.wiped, 'wiped', isTrue)
              .having((e) => e.remainingAttempts, 'remaining', 0),
        ),
      );
      expect(store.debugSnapshot, isEmpty);
    });

    test(
        'rejects >12h provisioning, non-6-digit typos without wiping, tampered iterations, and missing attempt counter',
        () async {
      var now = DateTime.utc(2026, 11, 15, 4, 0, 0);
      final store = InMemorySecureKeyValueStore();
      final holder = RamKeyHolder(now: () => now);
      addTearDown(holder.dispose);
      final manager = KeystoreDekManager(
        store: store,
        ramKeyHolder: holder,
        now: () => now,
        pbkdf2Iterations: 1000,
      );

      final dek = _hexToBytes(
        '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20',
      );

      // Lease exceeding 12h + 60s cannot be provisioned into Keystore.
      await expectLater(
        () => manager.provisionOfflineRecoverySlot(
          session: ActiveLeaseSession(
            userId: 'u1',
            username: 'anita',
            role: 'MANAGER',
            deviceId: 'd2',
            deviceCode: '02',
            leaseId: 'l-too-long',
            issuedAt: now,
            expiresAt: now.add(const Duration(hours: 13)),
          ),
          dekBytes: dek,
          pin: '123456',
        ),
        throwsA(isA<OfflineRecoveryException>()),
      );

      await manager.provisionOfflineRecoverySlot(
        session: ActiveLeaseSession(
          userId: 'u1',
          username: 'anita',
          role: 'MANAGER',
          deviceId: 'd2',
          deviceCode: '02',
          leaseId: 'l-valid',
          issuedAt: now,
          expiresAt: now.add(const Duration(hours: 12)),
        ),
        dekBytes: dek,
        pin: '123456',
      );

      // Non-6-digit PIN typo does not burn an offline attempt.
      await expectLater(
        () => manager.recoverDekWithPin('123'),
        throwsA(
          isA<OfflineRecoveryException>()
              .having((e) => e.wiped, 'wiped', isFalse)
              .having((e) => e.remainingAttempts, 'remaining', 5),
        ),
      );
      expect((await manager.inspectSlot()).remainingAttempts, 5);

      // Tampered iteration count (0) wipes the slot safely as malformed/tampered.
      final slotKey = 'pasalx.keystore.offline_dek_slot.v1';
      final slotMap = jsonDecode((await store.read(slotKey))!) as Map<String, dynamic>;
      (slotMap['blob'] as Map<String, dynamic>)['iterations'] = 0;
      await store.write(slotKey, jsonEncode(slotMap));
      await expectLater(
        () => manager.recoverDekWithPin('123456'),
        throwsA(
          isA<OfflineRecoveryException>()
              .having((e) => e.remainingAttempts, 'remaining', 4),
        ),
      );

      // Missing / corrupted attempt counter fails closed and wipes slot.
      await store.delete('pasalx.keystore.offline_pin_attempts.v1');
      await expectLater(
        () => manager.recoverDekWithPin('123456'),
        throwsA(
          isA<OfflineRecoveryException>().having((e) => e.wiped, 'wiped', isTrue),
        ),
      );
      expect(store.debugSnapshot, isEmpty);

      // inspectSlot() automatically wipes expired slots rather than retaining them.
      await manager.provisionOfflineRecoverySlot(
        session: ActiveLeaseSession(
          userId: 'u1',
          username: 'anita',
          role: 'MANAGER',
          deviceId: 'd2',
          deviceCode: '02',
          leaseId: 'l-exp',
          issuedAt: now,
          expiresAt: now.add(const Duration(hours: 12)),
        ),
        dekBytes: dek,
        pin: '123456',
      );
      now = now.add(const Duration(hours: 12, seconds: 1));
      expect((await manager.inspectSlot()).hasSlot, isFalse);
      expect(store.debugSnapshot, isEmpty);
    });
  });
}

