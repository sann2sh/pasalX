import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'envelope_crypto.dart';
import 'ram_key_holder.dart';

/// Abstraction over hardware-backed platform key/value storage (Android Keystore
/// / iOS Secure Enclave) so tests can swap an in-memory store without mocking
/// platform channels globally.
abstract interface class SecureKeyValueStore {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}

/// Production [SecureKeyValueStore] backed by [FlutterSecureStorage] using
/// hardware-backed Keystore (`encryptedSharedPreferences: true`) on Android and
/// non-migrating `unlocked_this_device` Keychain accessibility on iOS.
class FlutterSecureStorageKeyValueStore implements SecureKeyValueStore {
  FlutterSecureStorageKeyValueStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                encryptedSharedPreferences: true,
                resetOnError: false,
              ),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.unlocked_this_device,
              ),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Metadata + recovery status describing the local Keystore DEK slot.
class OfflineRecoveryStatus {
  const OfflineRecoveryStatus({
    required this.hasSlot,
    this.username,
    this.role,
    this.deviceCode,
    this.expiresAt,
    this.remainingAttempts = KeystoreDekManager.maxOfflinePinAttempts,
    this.isExpired = false,
  });

  final bool hasSlot;
  final String? username;
  final String? role;
  final String? deviceCode;
  final DateTime? expiresAt;
  final int remainingAttempts;
  final bool isExpired;
}

class OfflineRecoveryException implements Exception {
  const OfflineRecoveryException(
    this.message, {
    this.wiped = false,
    this.remainingAttempts = 0,
  });

  final String message;
  final bool wiped;
  final int remainingAttempts;

  @override
  String toString() => 'OfflineRecoveryException: $message';
}

/// Manages hardware-backed Keystore / Secure Enclave offline reboot recovery of
/// the active 12-hour DEK (`TECHNICAL_SPEC.md` §7.3–7.4).
///
/// Security properties enforced here:
/// 1. Plaintext DEK is never written anywhere on disk; only the PIN-sealed
///    AES-256-GCM blob inside Android Keystore / iOS Secure Enclave is saved.
/// 2. Lease `expiresAt` is bound inside GCM AAD AND checked against monotonic
///    `lastVerifiedAt` (rejects clock rollback > 5 minutes offline).
/// 3. Consecutive failed PIN attempts are tracked (`maxOfflinePinAttempts = 5`);
///    exceeding the threshold automatically destroys the Keystore slot.
/// 4. [wipeAll] instantaneously destroys all Keystore material and zeroes RAM
///    on logout, lease expiry, or Kill-Switch (`DEVICE_REVOKED`).
class KeystoreDekManager {
  KeystoreDekManager({
    required SecureKeyValueStore store,
    required RamKeyHolder ramKeyHolder,
    DateTime Function()? now,
    this.pbkdf2Iterations = EnvelopeCrypto.pinPbkdf2Iterations,
    // ignore: prefer_initializing_formals
  })  : _store = store,
        // ignore: prefer_initializing_formals
        _ramKeyHolder = ramKeyHolder,
        _now = now ?? _utcNow;

  static const int maxOfflinePinAttempts = 5;
  static const Duration maxClockRollbackTolerance = Duration(minutes: 5);

  static const String _slotKey = 'pasalx.keystore.offline_dek_slot.v1';
  static const String _envelopeKey = 'pasalx.keystore.server_envelope.v1';
  static const String _attemptsKey = 'pasalx.keystore.offline_pin_attempts.v1';

  static DateTime _utcNow() => DateTime.now().toUtc();

  final SecureKeyValueStore _store;
  final RamKeyHolder _ramKeyHolder;
  final DateTime Function() _now;
  final int pbkdf2Iterations;

  /// Seals the current unlocked DEK under [pin] and stores it inside the
  /// hardware Keystore slot for offline reboot recovery within the remaining
  /// 12-hour TTL. Also saves the 64-byte server lease envelope bytes if supplied.
  Future<void> provisionOfflineRecoverySlot({
    required ActiveLeaseSession session,
    required Uint8List dekBytes,
    required String pin,
    Uint8List? serverEnvelope,
  }) async {
    if (dekBytes.length != RamKeyHolder.dekLengthBytes) {
      throw const OfflineRecoveryException('DEK must be 32 bytes');
    }
    if (serverEnvelope != null &&
        serverEnvelope.length != EnvelopeCrypto.serverEnvelopeSize) {
      throw const OfflineRecoveryException(
        'Server lease envelope must be 64 bytes',
      );
    }
    final now = _now();
    const maxAllowedSpan =
        Duration(hours: 12, seconds: 60); // 12h lease + 60s skew
    if (!now.isBefore(session.expiresAt)) {
      throw const OfflineRecoveryException('Cannot store expired lease slot');
    }
    if (session.expiresAt.difference(now) > maxAllowedSpan ||
        session.expiresAt.difference(session.issuedAt) > maxAllowedSpan) {
      throw const OfflineRecoveryException(
        'Lease TTL exceeds 12-hour security ceiling',
      );
    }
    if (!EnvelopeCrypto.isValidPin(pin)) {
      throw const OfflineRecoveryException('Offline unlock requires 6-digit PIN');
    }

    final sealed = await EnvelopeCrypto.sealDekWithPin(
      dek: dekBytes,
      pin: pin,
      userId: session.userId,
      deviceId: session.deviceId,
      leaseId: session.leaseId,
      expiresAt: session.expiresAt,
      iterations: pbkdf2Iterations,
    );

    final record = <String, dynamic>{
      'v': 1,
      'user_id': session.userId,
      'username': session.username,
      'role': session.role,
      'device_id': session.deviceId,
      'device_code': session.deviceCode,
      'lease_id': session.leaseId,
      'issued_at': session.issuedAt.toUtc().toIso8601String(),
      'expires_at': session.expiresAt.toUtc().toIso8601String(),
      'last_verified_at': now.toUtc().toIso8601String(),
      'blob': sealed.toJson(),
    };

    // Reset attempt counter before writing slot so partial write never opens unguarded.
    await _store.write(_attemptsKey, '0');
    await _store.write(_slotKey, jsonEncode(record));
    if (serverEnvelope != null) {
      await _store.write(_envelopeKey, base64Encode(serverEnvelope));
    }
  }

  /// Inspects whether a recoverable offline Keystore slot currently exists and
  /// whether its 12-hour hardware TTL is still valid. Automatically wipes expired
  /// or tampered slots instead of retaining stale cryptographic material.
  Future<OfflineRecoveryStatus> inspectSlot() async {
    final raw = await _store.read(_slotKey);
    if (raw == null || raw.isEmpty) {
      return const OfflineRecoveryStatus(hasSlot: false);
    }

    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final issuedAt = DateTime.parse(map['issued_at'] as String).toUtc();
      final expiresAt = DateTime.parse(map['expires_at'] as String).toUtc();
      final lastVerified =
          DateTime.parse(map['last_verified_at'] as String).toUtc();
      final attempts = await _readValidatedAttempts();
      final now = _now();
      final ceilingExceeded = expiresAt.difference(issuedAt) >
          RamKeyHolder.maxLeaseDuration + const Duration(seconds: 60);
      final rolledBack =
          now.isBefore(lastVerified.subtract(maxClockRollbackTolerance));
      final expired = !now.isBefore(expiresAt) || ceilingExceeded;
      final exhausted = attempts == null || attempts >= maxOfflinePinAttempts;

      if (expired || rolledBack || exhausted) {
        await wipeAll();
        return const OfflineRecoveryStatus(hasSlot: false);
      }

      return OfflineRecoveryStatus(
        hasSlot: true,
        username: map['username'] as String?,
        role: map['role'] as String?,
        deviceCode: map['device_code'] as String?,
        expiresAt: expiresAt,
        remainingAttempts: maxOfflinePinAttempts - attempts,
        isExpired: false,
      );
    } catch (_) {
      await wipeAll();
      return const OfflineRecoveryStatus(hasSlot: false);
    }
  }

  /// Unwraps the DEK from the hardware Keystore slot using [pin] after an offline
  /// reboot and injects it directly into [RamKeyHolder].
  ///
  /// Enforces remaining 12-hour TTL, rejects clock rollback, and wipes the
  /// Keystore slot automatically if expired or after [maxOfflinePinAttempts]
  /// incorrect 6-digit PIN attempts.
  Future<ActiveLeaseSession> recoverDekWithPin(String pin) async {
    final raw = await _store.read(_slotKey);
    if (raw == null || raw.isEmpty) {
      throw const OfflineRecoveryException('No offline recovery slot present');
    }

    late final String userId;
    late final String username;
    late final String role;
    late final String deviceId;
    late final String deviceCode;
    late final String leaseId;
    late final DateTime issuedAt;
    late final DateTime expiresAt;
    late final DateTime lastVerified;
    late final PinSealedDekBlob blob;
    late final Map<String, dynamic> map;

    try {
      map = jsonDecode(raw) as Map<String, dynamic>;
      userId = map['user_id'] as String;
      username = map['username'] as String;
      role = map['role'] as String;
      deviceId = map['device_id'] as String;
      deviceCode = map['device_code'] as String;
      leaseId = map['lease_id'] as String;
      issuedAt = DateTime.parse(map['issued_at'] as String).toUtc();
      expiresAt = DateTime.parse(map['expires_at'] as String).toUtc();
      lastVerified =
          DateTime.parse(map['last_verified_at'] as String).toUtc();
      blob = PinSealedDekBlob.fromJson(map['blob'] as Map<String, dynamic>);
    } catch (_) {
      await wipeAll();
      throw const OfflineRecoveryException(
        'Corrupted Keystore slot destroyed',
        wiped: true,
      );
    }

    final now = _now();
    if (!now.isBefore(expiresAt) ||
        expiresAt.difference(issuedAt) >
            RamKeyHolder.maxLeaseDuration + const Duration(seconds: 60)) {
      await wipeAll();
      throw const OfflineRecoveryException(
        '12-hour offline lease expired; login online to continue',
        wiped: true,
      );
    }
    if (now.isBefore(lastVerified.subtract(maxClockRollbackTolerance))) {
      await wipeAll();
      throw const OfflineRecoveryException(
        'Device clock tampering detected; Keystore slot wiped',
        wiped: true,
      );
    }

    final priorAttempts = await _readValidatedAttempts();
    if (priorAttempts == null || priorAttempts >= maxOfflinePinAttempts) {
      await wipeAll();
      throw const OfflineRecoveryException(
        'Too many failed PIN attempts or corrupted counter; Keystore slot wiped',
        wiped: true,
      );
    }

    // Reject non-6-digit input without consuming hardware PIN attempts.
    if (!EnvelopeCrypto.isValidPin(pin)) {
      throw OfflineRecoveryException(
        'Offline unlock requires 6-digit PIN',
        remainingAttempts: maxOfflinePinAttempts - priorAttempts,
      );
    }

    Uint8List? recoveredDek;
    try {
      recoveredDek = await EnvelopeCrypto.unsealDekWithPin(
        blob: blob,
        pin: pin,
        userId: userId,
        deviceId: deviceId,
        leaseId: leaseId,
        expiresAt: expiresAt,
      );

      final session = ActiveLeaseSession(
        userId: userId,
        username: username,
        role: role,
        deviceId: deviceId,
        deviceCode: deviceCode,
        leaseId: leaseId,
        issuedAt: issuedAt,
        expiresAt: expiresAt,
      );

      // Update monotonic last_verified_at and reset failed attempt counter.
      map['last_verified_at'] = now.toUtc().toIso8601String();
      await _store.write(_slotKey, jsonEncode(map));
      await _store.write(_attemptsKey, '0');

      _ramKeyHolder.unlock(dekBytes: recoveredDek, session: session);
      return session;
    } on EnvelopeException {
      final nextAttempts = priorAttempts + 1;
      if (nextAttempts >= maxOfflinePinAttempts) {
        await wipeAll();
        throw const OfflineRecoveryException(
          'Too many failed PIN attempts; Keystore slot wiped',
          wiped: true,
          remainingAttempts: 0,
        );
      }
      await _store.write(_attemptsKey, nextAttempts.toString());
      final left = maxOfflinePinAttempts - nextAttempts;
      throw OfflineRecoveryException(
        'Invalid PIN ($left attempts remaining)',
        remainingAttempts: left,
      );
    } finally {
      RamKeyHolder.zeroBuffer(recoveredDek);
    }
  }

  /// Reads the persisted 64-byte server lease envelope if stored on device.
  Future<Uint8List?> readServerEnvelope() async {
    final encoded = await _store.read(_envelopeKey);
    if (encoded == null || encoded.isEmpty) return null;
    return Uint8List.fromList(base64Decode(encoded));
  }

  /// Destroys all Keystore recovery material AND zeroes volatile RAM DEK.
  /// Called on logout, lease expiry, or Kill-Switch (`DEVICE_REVOKED`).
  Future<void> wipeAll() async {
    _ramKeyHolder.wipe();
    await _store.delete(_slotKey);
    await _store.delete(_envelopeKey);
    await _store.delete(_attemptsKey);
  }

  /// Returns validated attempt count in `[0, maxOfflinePinAttempts]`, or `null`
  /// if missing, negative, or corrupted (fail-closed).
  Future<int?> _readValidatedAttempts() async {
    final raw = await _store.read(_attemptsKey);
    if (raw == null) return null;
    final parsed = int.tryParse(raw.trim());
    if (parsed == null || parsed < 0) return null;
    return parsed;
  }
}

/// In-memory [SecureKeyValueStore] strictly for isolated unit tests.
class InMemorySecureKeyValueStore implements SecureKeyValueStore {
  final Map<String, String> _data = {};

  Map<String, String> get debugSnapshot => Map.unmodifiable(_data);

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }
}

