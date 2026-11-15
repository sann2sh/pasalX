import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Cryptographic primitives mirroring the Go auth backend (`server/internal/auth/envelope.go`)
/// plus PIN-bound offline Keystore sealing (`TECHNICAL_SPEC.md` §7.2–7.3).
abstract final class EnvelopeCrypto {
  static const int dekSize = 32;
  static const int kekSize = 32;
  static const int serverEnvelopeSize = 64;
  static const int nonceSize = 12;
  static const int macSize = 16;
  static const int saltSize = 16;
  static const int pinPbkdf2Iterations = 100000;
  static const int minPbkdf2Iterations = 1000;
  static const int maxPbkdf2Iterations = 1000000;

  static const List<int> serverMagicHeader = [0x50, 0x58, 0x01, 0x00]; // PX\x01\x00
  static final AesGcm _aesGcm = AesGcm.with256bits();
  static final Random _secureRandom = Random.secure();

  /// Unwraps the 64-byte server key envelope using the 12-hour [kek] returned by
  /// `POST /api/auth/login` or `POST /api/auth/refresh`.
  ///
  /// Matches Go's `auth.IssueLease` / `auth.OpenEnvelope` layout:
  /// `[0:4] 'P' 'X' 0x01 0x00` | `[4:16] nonce` | `[16:48] ciphertext` | `[48:64] tag`
  /// with AAD = `header || "<device_id>|<lease_id>|<expires_unix>"`.
  static Future<Uint8List> unwrapServerEnvelope({
    required Uint8List kek,
    required Uint8List envelope,
    required String deviceId,
    required String leaseId,
    required DateTime expiresAt,
  }) async {
    if (kek.length != kekSize) {
      throw const EnvelopeException('KEK must be 32 bytes');
    }
    if (envelope.length != serverEnvelopeSize) {
      throw const EnvelopeException('Envelope must be 64 bytes');
    }
    for (var i = 0; i < 4; i++) {
      if (envelope[i] != serverMagicHeader[i]) {
        throw const EnvelopeException('Invalid envelope header magic');
      }
    }

    final nonce = envelope.sublist(4, 16);
    final cipherText = envelope.sublist(16, 48);
    final macBytes = envelope.sublist(48, 64);
    final aad = _serverEnvelopeAad(
      deviceId: deviceId,
      leaseId: leaseId,
      expiresAt: expiresAt,
    );

    try {
      final clear = await _aesGcm.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes)),
        secretKey: SecretKey(kek),
        aad: aad,
      );
      final out = Uint8List.fromList(clear);
      _zeroList(clear);
      if (out.length != dekSize) {
        out.fillRange(0, out.length, 0);
        throw const EnvelopeException('Unwrapped DEK length invalid');
      }
      return out;
    } on SecretBoxAuthenticationError {
      throw const EnvelopeException('Lease envelope authentication failed');
    }
  }

  /// Seals [dek] under a key derived from the staff member's 6-digit [pin] using
  /// PBKDF2-HMAC-SHA256 + HKDF-SHA256 domain separation and AES-256-GCM AAD binding
  /// to `[userId, deviceId, leaseId, expiresAt]`.
  static Future<PinSealedDekBlob> sealDekWithPin({
    required Uint8List dek,
    required String pin,
    required String userId,
    required String deviceId,
    required String leaseId,
    required DateTime expiresAt,
    int iterations = pinPbkdf2Iterations,
  }) async {
    if (dek.length != dekSize) {
      throw const EnvelopeException('DEK must be 32 bytes');
    }
    if (!isValidPin(pin)) {
      throw const EnvelopeException('PIN must be 6 digits');
    }
    if (iterations < minPbkdf2Iterations || iterations > maxPbkdf2Iterations) {
      throw const EnvelopeException('Invalid PBKDF2 iteration count');
    }

    final salt = randomBytes(saltSize);
    final nonce = randomBytes(nonceSize);
    final wrappingKey = await _derivePinWrappingKey(
      pin: pin,
      salt: salt,
      userId: userId,
      deviceId: deviceId,
      leaseId: leaseId,
      expiresAt: expiresAt,
      iterations: iterations,
    );

    try {
      final aad = _offlineAad(
        userId: userId,
        deviceId: deviceId,
        leaseId: leaseId,
        expiresAt: expiresAt,
      );
      final box = await _aesGcm.encrypt(
        dek,
        secretKey: wrappingKey,
        nonce: nonce,
        aad: aad,
      );
      return PinSealedDekBlob(
        saltBase64: base64Encode(salt),
        nonceBase64: base64Encode(box.nonce),
        cipherTextBase64: base64Encode(box.cipherText),
        macBase64: base64Encode(box.mac.bytes),
        iterations: iterations,
      );
    } finally {
      wrappingKey.destroy();
    }
  }

  /// Unseals [blob] back into a 32-byte DEK using the staff member's 6-digit [pin].
  /// Throws [EnvelopeException] on wrong PIN, tampering, or AAD mismatch.
  static Future<Uint8List> unsealDekWithPin({
    required PinSealedDekBlob blob,
    required String pin,
    required String userId,
    required String deviceId,
    required String leaseId,
    required DateTime expiresAt,
  }) async {
    if (!isValidPin(pin)) {
      throw const EnvelopeException('PIN must be 6 digits');
    }
    if (blob.iterations < minPbkdf2Iterations ||
        blob.iterations > maxPbkdf2Iterations) {
      throw const EnvelopeException('Invalid PBKDF2 iteration count');
    }

    final Uint8List salt;
    final Uint8List nonce;
    final Uint8List cipherText;
    final Uint8List macBytes;
    try {
      salt = base64Decode(blob.saltBase64);
      nonce = base64Decode(blob.nonceBase64);
      cipherText = base64Decode(blob.cipherTextBase64);
      macBytes = base64Decode(blob.macBase64);
    } on FormatException {
      throw const EnvelopeException('Malformed offline Keystore slot');
    }

    if (salt.length != saltSize ||
        nonce.length != nonceSize ||
        cipherText.length != dekSize ||
        macBytes.length != macSize) {
      throw const EnvelopeException('Malformed offline Keystore slot');
    }

    final wrappingKey = await _derivePinWrappingKey(
      pin: pin,
      salt: salt,
      userId: userId,
      deviceId: deviceId,
      leaseId: leaseId,
      expiresAt: expiresAt,
      iterations: blob.iterations,
    );

    try {
      final aad = _offlineAad(
        userId: userId,
        deviceId: deviceId,
        leaseId: leaseId,
        expiresAt: expiresAt,
      );
      final clear = await _aesGcm.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes)),
        secretKey: wrappingKey,
        aad: aad,
      );
      final out = Uint8List.fromList(clear);
      _zeroList(clear);
      if (out.length != dekSize) {
        out.fillRange(0, out.length, 0);
        throw const EnvelopeException('Recovered DEK length invalid');
      }
      return out;
    } on SecretBoxAuthenticationError {
      throw const EnvelopeException('Invalid offline PIN or tampered slot');
    } finally {
      wrappingKey.destroy();
    }
  }

  static bool isValidPin(String pin) {
    return RegExp(r'^\d{6}$').hasMatch(pin);
  }

  static Uint8List randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _secureRandom.nextInt(256);
    }
    return out;
  }

  static Future<SecretKeyData> _derivePinWrappingKey({
    required String pin,
    required List<int> salt,
    required String userId,
    required String deviceId,
    required String leaseId,
    required DateTime expiresAt,
    required int iterations,
  }) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    final baseKey = await pbkdf2.deriveKeyFromPassword(
      password: pin,
      nonce: salt,
    );
    try {
      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      final info = utf8.encode(
        'pasalx/offline-pin-wrap/v1|$userId|$deviceId|$leaseId|${_unixSeconds(expiresAt)}',
      );
      return await hkdf.deriveKey(
        secretKey: baseKey,
        nonce: salt,
        info: info,
      );
    } finally {
      baseKey.destroy();
    }
  }

  static List<int> _serverEnvelopeAad({
    required String deviceId,
    required String leaseId,
    required DateTime expiresAt,
  }) {
    final suffix = utf8.encode('$deviceId|$leaseId|${_unixSeconds(expiresAt)}');
    return <int>[...serverMagicHeader, ...suffix];
  }

  static List<int> _offlineAad({
    required String userId,
    required String deviceId,
    required String leaseId,
    required DateTime expiresAt,
  }) {
    return utf8.encode(
      'pasalx/offline-dek/v1|$userId|$deviceId|$leaseId|${_unixSeconds(expiresAt)}',
    );
  }

  static int _unixSeconds(DateTime dt) =>
      dt.toUtc().millisecondsSinceEpoch ~/ 1000;

  static void _zeroList(List<int> bytes) {
    if (bytes is Uint8List) {
      bytes.fillRange(0, bytes.length, 0);
      return;
    }
    try {
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = 0;
      }
    } on UnsupportedError {
      // Unmodifiable list view cannot be zeroed in place.
    }
  }
}

class PinSealedDekBlob {
  const PinSealedDekBlob({
    required this.saltBase64,
    required this.nonceBase64,
    required this.cipherTextBase64,
    required this.macBase64,
    required this.iterations,
  });

  factory PinSealedDekBlob.fromJson(Map<String, dynamic> json) {
    return PinSealedDekBlob(
      saltBase64: json['salt'] as String,
      nonceBase64: json['nonce'] as String,
      cipherTextBase64: json['ciphertext'] as String,
      macBase64: json['mac'] as String,
      iterations: (json['iterations'] as num).toInt(),
    );
  }

  final String saltBase64;
  final String nonceBase64;
  final String cipherTextBase64;
  final String macBase64;
  final int iterations;

  Map<String, dynamic> toJson() => {
        'salt': saltBase64,
        'nonce': nonceBase64,
        'ciphertext': cipherTextBase64,
        'mac': macBase64,
        'iterations': iterations,
      };
}

class EnvelopeException implements Exception {
  const EnvelopeException(this.message);
  final String message;

  @override
  String toString() => 'EnvelopeException: $message';
}

