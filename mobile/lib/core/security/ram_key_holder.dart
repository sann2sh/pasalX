import 'dart:async';
import 'package:flutter/foundation.dart';

/// Session identity metadata associated with an active in-memory DEK lease.
@immutable
class ActiveLeaseSession {
  const ActiveLeaseSession({
    required this.userId,
    required this.username,
    required this.role,
    required this.deviceId,
    required this.deviceCode,
    required this.leaseId,
    required this.issuedAt,
    required this.expiresAt,
  });

  final String userId;
  final String username;
  final String role;
  final String deviceId;
  final String deviceCode;
  final String leaseId;
  final DateTime issuedAt;
  final DateTime expiresAt;
}

/// Volatile RAM-only holder for the active 256-bit SQLCipher Data Encryption Key (DEK).
///
/// The plaintext DEK is NEVER persisted to flash storage, preferences, or logs.
/// On lease expiration, logout, or remote Kill-Switch (`DEVICE_REVOKED`),
/// [wipe] overwrites the byte buffer with `0x00` and notifies listeners so open
/// SQLite connections close immediately.
class RamKeyHolder extends ChangeNotifier {
  RamKeyHolder({DateTime Function()? now}) : _now = now ?? _utcNow;

  static const int dekLengthBytes = 32;
  static const Duration maxLeaseDuration = Duration(hours: 12);

  static DateTime _utcNow() => DateTime.now().toUtc();

  final DateTime Function() _now;
  final List<VoidCallback> _lockCallbacks = <VoidCallback>[];
  Uint8List? _dek;
  ActiveLeaseSession? _session;
  Timer? _expiryTimer;
  bool _disposed = false;
  bool _scheduledNotify = false;

  /// Registers a callback invoked immediately whenever the RAM key is wiped
  /// or this holder is disposed (even during ProviderScope teardown).
  void addLockListener(VoidCallback listener) {
    if (_disposed) return;
    _lockCallbacks.add(listener);
  }

  /// Removes a previously registered lock listener.
  void removeLockListener(VoidCallback listener) {
    _lockCallbacks.remove(listener);
  }

  /// Current active lease metadata if unlocked and not expired.
  ActiveLeaseSession? get session => isUnlocked ? _session : null;

  /// Whether a valid 256-bit DEK is present in RAM and within its 12h lease TTL.
  ///
  /// If the lease deadline has passed (e.g., while suspended in OS sleep), this
  /// immediately zeroes `_dek`, closes registered database handles, and schedules
  /// a microtask UI notification without mutating widget trees mid-build.
  bool get isUnlocked {
    final dek = _dek;
    final sess = _session;
    if (dek == null || sess == null || dek.length != dekLengthBytes) {
      return false;
    }
    if (_now().isBefore(sess.expiresAt)) {
      return true;
    }
    _wipeOnPassiveExpiry();
    return false;
  }

  /// Actively verifies the lease clock (e.g., on app resume from OS sleep) and
  /// triggers full [wipe] + synchronous notifications if expired.
  bool enforceLeaseValidity() {
    final dek = _dek;
    final sess = _session;
    if (dek == null || sess == null || dek.length != dekLengthBytes) {
      return false;
    }
    if (_now().isBefore(sess.expiresAt)) {
      return true;
    }
    wipe();
    return false;
  }

  void _wipeOnPassiveExpiry() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    zeroBuffer(_dek);
    _dek = null;
    _session = null;
    _runLockCallbacks();
    if (!_disposed && !_scheduledNotify) {
      _scheduledNotify = true;
      scheduleMicrotask(() {
        _scheduledNotify = false;
        if (!_disposed) {
          notifyListeners();
        }
      });
    }
  }

  void _runLockCallbacks() {
    if (_lockCallbacks.isEmpty) return;
    for (final cb in List<VoidCallback>.from(_lockCallbacks)) {
      cb();
    }
  }

  /// Stores a defensive copy of [dekBytes] in RAM and records [session].
  ///
  /// The caller's [dekBytes] should be zeroed by the caller right after calling
  /// this method. Rejects expired leases or leases exceeding 12 hours + 60s skew.
  void unlock({
    required Uint8List dekBytes,
    required ActiveLeaseSession session,
  }) {
    if (dekBytes.length != dekLengthBytes) {
      throw ArgumentError.value(
        dekBytes.length,
        'dekBytes.length',
        'SQLCipher DEK must be exactly $dekLengthBytes bytes (256 bits)',
      );
    }
    final now = _now();
    if (!now.isBefore(session.expiresAt)) {
      throw StateError('Cannot unlock RAM key holder with an expired lease');
    }
    if (session.expiresAt.difference(now) >
        maxLeaseDuration + const Duration(seconds: 60)) {
      throw StateError('Lease TTL exceeds 12-hour security ceiling');
    }

    _expiryTimer?.cancel();
    zeroBuffer(_dek);
    _dek = Uint8List.fromList(dekBytes);
    _session = session;
    final remaining = session.expiresAt.difference(now);
    _expiryTimer = Timer(remaining, wipe);
    notifyListeners();
  }

  /// Enforces lease TTL and executes [action] with a freshly formatted SQLCipher
  /// raw hex key literal (`x'<64 hex chars>'`).
  ///
  /// Does not cache the formatted string on [RamKeyHolder]. Throws [StateError]
  /// and wipes memory if the lease has expired.
  T withSqlCipherRawKey<T>(T Function(String sqlCipherKeyLiteral) action) {
    final dek = _dek;
    final sess = _session;
    if (dek == null || sess == null) {
      throw StateError('Database is locked: no DEK loaded in RAM');
    }
    if (!_now().isBefore(sess.expiresAt)) {
      wipe();
      throw StateError('12-hour lease expired: DEK wiped from RAM');
    }
    final buf = StringBuffer("x'");
    for (var i = 0; i < dek.length; i++) {
      buf.write(dek[i].toRadixString(16).padLeft(2, '0'));
    }
    buf.write("'");
    return action(buf.toString());
  }

  /// Returns a defensive copy of the raw 32-byte DEK while unlocked.
  /// Callers MUST call [zeroBuffer] on the returned buffer when finished.
  Uint8List copyDekBytes() {
    if (!isUnlocked) {
      if (_dek != null) {
        wipe();
      }
      throw StateError('Database is locked or lease expired');
    }
    return Uint8List.fromList(_dek!);
  }

  /// Zeroes the in-memory DEK buffer (`0x00`), clears metadata, closes
  /// registered database locks synchronously, and notifies UI listeners.
  void wipe() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    final hadState = _dek != null || _session != null;
    zeroBuffer(_dek);
    _dek = null;
    _session = null;
    _runLockCallbacks();
    if (hadState && !_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    zeroBuffer(_dek);
    _dek = null;
    _session = null;
    _runLockCallbacks();
    _lockCallbacks.clear();
    super.dispose();
  }

  /// Overwrites [buffer] in place with zeros (best-effort memory sanitization).
  static void zeroBuffer(Uint8List? buffer) {
    if (buffer == null) return;
    buffer.fillRange(0, buffer.length, 0);
  }
}

