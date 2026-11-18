import 'dart:async';

import 'package:flutter/foundation.dart';

import 'device_credentials_store.dart';
import 'keystore_dek_manager.dart';

/// Instant remote Kill-Switch coordinator (`TECHNICAL_SPEC.md` §7.4, Task 7.4).
///
/// Triggered synchronously whenever:
/// 1. Any API call receives `HTTP 401 DEVICE_REVOKED`,
/// 2. Live SSE stream receives `event: DEVICE_REVOKED`, or
/// 3. High-priority push (FCM) delivers a revocation directive.
///
/// Execution guarantees:
/// - Stops active SSE/sync background loops immediately,
/// - Zeroes plaintext DEK in RAM (`RamKeyHolder.wipe()`),
/// - Auto-closes encrypted SQLite (`ActiveDatabaseNotifier` lock listener),
/// - Deletes Keystore offline recovery slot (`KeystoreDekManager.wipeAll()`),
/// - Wipes saved JWT bearer token & marks terminal `REVOKED`,
/// - Invokes registered lock/exit callbacks immediately.
class KillSwitchService {
  KillSwitchService({
    required KeystoreDekManager keystoreDekManager,
    required DeviceCredentialsStore credentialsStore,
    VoidCallback? onWillExecute,
    FutureOr<void> Function(String reason)? onRevokedUiLock,
    // ignore: prefer_initializing_formals
  })  : _keystoreDekManager = keystoreDekManager,
        // ignore: prefer_initializing_formals
        _credentialsStore = credentialsStore,
        // ignore: prefer_initializing_formals
        _onWillExecute = onWillExecute,
        // ignore: prefer_initializing_formals
        _onRevokedUiLock = onRevokedUiLock;

  final KeystoreDekManager _keystoreDekManager;
  final DeviceCredentialsStore _credentialsStore;
  final VoidCallback? _onWillExecute;
  final FutureOr<void> Function(String reason)? _onRevokedUiLock;
  final List<FutureOr<void> Function(String reason)> _listeners =
      <FutureOr<void> Function(String reason)>[];

  Future<void>? _inFlight;
  bool _revoking = false;

  bool get isRevoking => _revoking || _inFlight != null;

  void addRevocationListener(FutureOr<void> Function(String reason) listener) {
    _listeners.add(listener);
  }

  void removeRevocationListener(
    FutureOr<void> Function(String reason) listener,
  ) {
    _listeners.remove(listener);
  }

  Future<void> executeRevocation({
    String reason = 'This device has been revoked by the owner.',
  }) {
    final existing = _inFlight;
    if (existing != null) return existing;

    _revoking = true;
    final future = _runRevocation(reason);
    _inFlight = future.whenComplete(() {
      _revoking = false;
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    });
    return _inFlight!;
  }

  Future<void> _runRevocation(String reason) async {
    // 1. Stop sync workers / SSE immediately before asynchronous I/O.
    _onWillExecute?.call();

    // 2. Zero RAM DEK + delete Keystore/Secure Enclave slot & envelope.
    //    `RamKeyHolder.wipe()` fires synchronously inside `wipeAll()`, closing SQLite.
    await _keystoreDekManager.wipeAll();

    // 3. Delete active JWT session & mark terminal revoked.
    await _credentialsStore.clearSession();
    await _credentialsStore.markDeviceRevoked(message: reason);

    // 4. Force auth/router gate to lock onto Login screen with revocation alert.
    if (_onRevokedUiLock != null) {
      await _onRevokedUiLock(reason);
    }
    for (final listener in List.of(_listeners)) {
      await listener(reason);
    }
  }

  /// Entrypoint for FCM / high-priority remote push kill-switch payloads.
  /// Returns `true` if the payload matched a device revocation command.
  Future<bool> handlePushNotificationPayload(
    Map<String, dynamic> data, {
    String? currentDeviceId,
    String? currentDeviceCode,
  }) async {
    final eventType =
        (data['event'] ?? data['type'] ?? data['error'] ?? '').toString().trim().toUpperCase();
    if (eventType != 'DEVICE_REVOKED' && eventType != 'KILL_SWITCH') {
      return false;
    }

    final targetId = (data['device_id'] ?? '').toString().trim();
    final targetCode = (data['device_code'] ?? '').toString().trim();
    if (currentDeviceId != null &&
        targetId.isNotEmpty &&
        targetId != currentDeviceId) {
      return false;
    }
    if (currentDeviceCode != null &&
        targetCode.isNotEmpty &&
        targetCode != currentDeviceCode) {
      return false;
    }

    final reason = (data['reason'] ?? data['message'] ?? '').toString().trim();
    await executeRevocation(
      reason: reason.isNotEmpty
          ? reason
          : 'Remote Kill-Switch triggered by store owner.',
    );
    return true;
  }
}
