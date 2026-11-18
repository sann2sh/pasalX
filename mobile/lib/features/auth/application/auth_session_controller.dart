import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../core/database/app_database.dart';
import '../../../core/network/api_config.dart';
import '../../../core/network/api_exceptions.dart';
import '../../../core/network/pasal_api_client.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../../core/security/device_credentials_store.dart';
import '../../../core/security/envelope_crypto.dart';
import '../../../core/security/keystore_dek_manager.dart';
import '../../../core/security/kill_switch_service.dart';
import '../../../core/security/ram_key_holder.dart';
import '../../../core/sync/sse_sync_client.dart';
import '../../../core/sync/sync_outbox_worker.dart';

enum AuthGateStage {
  initializing,
  unregistered,
  locked,
  shiftOpenRequired,
  ready,
  revoked,
}

@immutable
class AuthSessionState {
  const AuthSessionState({
    this.stage = AuthGateStage.initializing,
    this.serverUrl = ApiConfig.defaultBaseUrl,
    this.enrolledDevice,
    this.offlineRecovery = const OfflineRecoveryStatus(hasSlot: false),
    this.session,
    this.displayName,
    this.activeShift,
    this.activeStaffSession,
    this.busy = false,
    this.errorMessage,
    this.revocationReason,
  });

  final AuthGateStage stage;
  final String serverUrl;
  final EnrolledDeviceInfo? enrolledDevice;
  final OfflineRecoveryStatus offlineRecovery;
  final ActiveLeaseSession? session;
  final String? displayName;
  final RegisterShiftRow? activeShift;
  final StaffShiftSessionRow? activeStaffSession;
  final bool busy;
  final String? errorMessage;
  final String? revocationReason;

  bool get isReady => stage == AuthGateStage.ready;

  AuthSessionState copyWith({
    AuthGateStage? stage,
    String? serverUrl,
    EnrolledDeviceInfo? enrolledDevice,
    bool clearEnrolledDevice = false,
    OfflineRecoveryStatus? offlineRecovery,
    ActiveLeaseSession? session,
    bool clearSession = false,
    String? displayName,
    bool clearDisplayName = false,
    RegisterShiftRow? activeShift,
    bool clearActiveShift = false,
    StaffShiftSessionRow? activeStaffSession,
    bool clearActiveStaffSession = false,
    bool? busy,
    String? errorMessage,
    bool clearError = false,
    String? revocationReason,
    bool clearRevocationReason = false,
  }) {
    return AuthSessionState(
      stage: stage ?? this.stage,
      serverUrl: serverUrl ?? this.serverUrl,
      enrolledDevice: clearEnrolledDevice
          ? null
          : (enrolledDevice ?? this.enrolledDevice),
      offlineRecovery: offlineRecovery ?? this.offlineRecovery,
      session: clearSession ? null : (session ?? this.session),
      displayName: clearDisplayName ? null : (displayName ?? this.displayName),
      activeShift: clearActiveShift ? null : (activeShift ?? this.activeShift),
      activeStaffSession: clearActiveStaffSession
          ? null
          : (activeStaffSession ?? this.activeStaffSession),
      busy: busy ?? this.busy,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      revocationReason: clearRevocationReason
          ? null
          : (revocationReason ?? this.revocationReason),
    );
  }
}

/// Coordinates Step 7 authentication, 12-hour DEK unwrap & offline PIN
/// Keystore recovery, Single-Galla shift opening, background sync/SSE startup,
/// and instant Kill-Switch wipe lockouts.
class AuthSessionController extends ChangeNotifier {
  AuthSessionController({
    required Ref ref,
    Future<void> Function()? deleteLocalDatabaseFiles,
    // ignore: prefer_initializing_formals
  })  : _ref = ref,
        // ignore: prefer_initializing_formals
        _deleteLocalDatabaseFiles = deleteLocalDatabaseFiles {
    _cachedRamKeyHolder = _ref.read(ramKeyHolderProvider);
    _cachedKillSwitch = _ref.read(killSwitchServiceProvider);
    _cachedRamKeyHolder.addLockListener(_onRamKeyLocked);
    _cachedKillSwitch.addRevocationListener(_onRevocationExecuted);
  }

  final Ref _ref;
  final Future<void> Function()? _deleteLocalDatabaseFiles;
  late final RamKeyHolder _cachedRamKeyHolder;
  late final KillSwitchService _cachedKillSwitch;

  AuthSessionState _state = const AuthSessionState();
  AuthSessionState get state => _state;

  bool _initialized = false;
  Future<void>? _initFuture;
  bool _disposed = false;
  int _authEpoch = 0;

  PasalApiClient get _api => _ref.read(pasalApiClientProvider);
  RamKeyHolder get _ramKeyHolder => _ref.read(ramKeyHolderProvider);
  KeystoreDekManager get _keystore => _ref.read(keystoreDekManagerProvider);
  DeviceCredentialsStore get _creds =>
      _ref.read(deviceCredentialsStoreProvider);
  SyncOutboxWorker get _syncWorker => _ref.read(syncOutboxWorkerProvider);
  SseSyncClient get _sseClient => _ref.read(sseSyncClientProvider);
  DatabaseOpener get _openDatabase => _ref.read(databaseOpenerProvider);

  Future<void> initialize() {
    if (_initialized) return Future.value();
    _initFuture ??= _runInitialize();
    return _initFuture!;
  }

  Future<void> _runInitialize() async {
    try {
      String serverUrl = _ref.read(apiConfigProvider).baseUrl;
      try {
        final savedUrl = await _creds.readServerUrl();
        if (savedUrl != null && savedUrl.isNotEmpty) {
          serverUrl = savedUrl;
          _ref.read(apiConfigProvider.notifier).setBaseUrl(savedUrl);
        }
      } on MissingPluginException {
        // Test environment without secure storage plugin.
      } on PlatformException {
        // Fallback cleanly to default URL.
      }

      EnrolledDeviceInfo? device;
      OfflineRecoveryStatus offlineStatus =
          const OfflineRecoveryStatus(hasSlot: false);
      try {
        device = await _creds.readDevice();
        if (device != null && device.isRevoked) {
          await _keystore.wipeAll();
          await _creds.clearSession();
          _setState(
            _state.copyWith(
              stage: AuthGateStage.revoked,
              serverUrl: serverUrl,
              enrolledDevice: device,
              offlineRecovery: const OfflineRecoveryStatus(hasSlot: false),
              revocationReason:
                  device.revocationMessage ?? 'Device revoked by store owner.',
            ),
          );
          _initialized = true;
          return;
        }
        offlineStatus = await _keystore.inspectSlot();
      } on MissingPluginException {
        device = null;
      } on PlatformException {
        device = null;
      }

      _setState(
        _state.copyWith(
          stage: device == null
              ? AuthGateStage.unregistered
              : AuthGateStage.locked,
          serverUrl: serverUrl,
          enrolledDevice: device,
          clearEnrolledDevice: device == null,
          offlineRecovery: offlineStatus,
          clearError: true,
        ),
      );
      _initialized = true;
    } catch (e) {
      _setState(
        _state.copyWith(
          stage: AuthGateStage.unregistered,
          errorMessage: 'Initialization warning: $e',
        ),
      );
      _initialized = true;
    }
  }

  Future<void> _onRevocationExecuted(String reason) async {
    if (_disposed) return;
    _authEpoch++;
    final device = await _creds.readDevice();
    _setState(
      _state.copyWith(
        stage: AuthGateStage.revoked,
        enrolledDevice: device,
        offlineRecovery: const OfflineRecoveryStatus(hasSlot: false),
        clearSession: true,
        clearDisplayName: true,
        clearActiveShift: true,
        clearActiveStaffSession: true,
        busy: false,
        revocationReason: reason,
      ),
    );
  }

  void _onRamKeyLocked() {
    if (_disposed || _cachedRamKeyHolder.isDisposed) return;
    if (_cachedKillSwitch.isRevoking) return;
    if (_state.stage == AuthGateStage.shiftOpenRequired ||
        _state.stage == AuthGateStage.ready) {
      final epoch = _authEpoch;
      unawaited(_handleUnexpectedLock(expectedEpoch: epoch));
    }
  }

  Future<void> _handleUnexpectedLock({int? expectedEpoch}) async {
    if (_disposed || _cachedRamKeyHolder.isDisposed) return;
    if (expectedEpoch != null && expectedEpoch != _authEpoch) return;
    if (_ramKeyHolder.isUnlocked) return;

    await _sseClient.stop();
    await _syncWorker.stop();
    if (_disposed ||
        _ramKeyHolder.isUnlocked ||
        (expectedEpoch != null && expectedEpoch != _authEpoch)) {
      return;
    }

    _ref.read(activeAccessTokenProvider.notifier).setToken(null);
    if (_disposed ||
        _state.stage == AuthGateStage.revoked ||
        _cachedKillSwitch.isRevoking) {
      return;
    }

    final device = await _creds.readDevice();
    if (_disposed ||
        _ramKeyHolder.isUnlocked ||
        (expectedEpoch != null && expectedEpoch != _authEpoch) ||
        _state.stage == AuthGateStage.revoked ||
        _cachedKillSwitch.isRevoking) {
      return;
    }
    if (device != null && device.isRevoked) {
      _setState(
        _state.copyWith(
          stage: AuthGateStage.revoked,
          enrolledDevice: device,
          offlineRecovery: const OfflineRecoveryStatus(hasSlot: false),
          clearSession: true,
          clearDisplayName: true,
          clearActiveShift: true,
          clearActiveStaffSession: true,
          busy: false,
          revocationReason:
              device.revocationMessage ?? 'This device was revoked by owner.',
        ),
      );
      return;
    }

    final slot = await _keystore.inspectSlot();
    if (_disposed ||
        _ramKeyHolder.isUnlocked ||
        (expectedEpoch != null && expectedEpoch != _authEpoch) ||
        _state.stage == AuthGateStage.revoked ||
        _cachedKillSwitch.isRevoking) {
      return;
    }
    _setState(
      _state.copyWith(
        stage: device == null ? AuthGateStage.unregistered : AuthGateStage.locked,
        enrolledDevice: device,
        offlineRecovery: slot,
        clearSession: true,
        clearDisplayName: true,
        clearActiveShift: true,
        clearActiveStaffSession: true,
        busy: false,
        errorMessage: 'Session locked or 12-hour lease expired.',
      ),
    );
  }

  Future<void> updateServerUrl(String url) async {
    final trimmed = url.trim();
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null ||
        !(parsed.isScheme('http') || parsed.isScheme('https')) ||
        parsed.host.isEmpty) {
      _setState(
        _state.copyWith(
          errorMessage: 'Enter a valid http:// or https:// server address.',
        ),
      );
      return;
    }
    _ref.read(apiConfigProvider.notifier).setBaseUrl(trimmed);
    await _creds.saveServerUrl(trimmed);
    _setState(_state.copyWith(serverUrl: trimmed, clearError: true));
  }

  /// Registers this terminal (`01`, `02`, ...) using OWNER credentials.
  Future<bool> registerTerminal({
    required String ownerUsername,
    required String ownerPassword,
    required String deviceName,
    String platform = 'ANDROID',
    String? serverUrl,
  }) async {
    if (_state.busy) return false;
    if (deviceName.trim().isEmpty ||
        ownerUsername.trim().isEmpty ||
        ownerPassword.isEmpty) {
      _setState(
        _state.copyWith(
          errorMessage:
              'Terminal name, owner username, and owner password are required.',
        ),
      );
      return false;
    }

    _setState(_state.copyWith(busy: true, clearError: true));

    try {
      if (serverUrl != null && serverUrl.trim().isNotEmpty) {
        await updateServerUrl(serverUrl);
        if (_state.errorMessage != null) {
          _setState(_state.copyWith(busy: false));
          return false;
        }
      }

      final previousDevice = await _creds.readDevice();
      final reg = await _api.registerDevice(
        ownerUsername: ownerUsername,
        ownerPassword: ownerPassword,
        deviceName: deviceName,
        platform: platform,
      );

      // New device ID receives a distinct DEK: wipe stale vault/keystore material.
      if (previousDevice != null && previousDevice.deviceId != reg.id) {
        await _keystore.wipeAll();
        await _creds.clearSession();
        await _purgeLocalDbFiles();
      } else {
        await _keystore.wipeAll();
        await _creds.clearSession();
      }

      final enrolled = EnrolledDeviceInfo(
        deviceId: reg.id,
        deviceCode: reg.code,
        deviceName: reg.name,
        platform: reg.platform,
        isRevoked: false,
      );
      await _creds.saveDevice(enrolled);

      _setState(
        _state.copyWith(
          stage: AuthGateStage.locked,
          enrolledDevice: enrolled,
          offlineRecovery: const OfflineRecoveryStatus(hasSlot: false),
          busy: false,
          clearError: true,
          clearRevocationReason: true,
        ),
      );
      return true;
    } on ApiException catch (e) {
      _setState(_state.copyWith(busy: false, errorMessage: e.message));
      return false;
    } catch (e) {
      _setState(
        _state.copyWith(busy: false, errorMessage: 'Registration failed: $e'),
      );
      return false;
    }
  }

  /// Online login (`POST /api/auth/login`), unwraps 64-byte `PX\x01\x00`
  /// envelope into volatile RAM, opens SQLCipher DB, and optionally provisions
  /// the hardware Keystore offline recovery slot when logging in with a 6-digit PIN.
  Future<bool> loginOnline({
    required String username,
    String? pin,
    String? password,
  }) async {
    if (_state.busy) return false;
    final device = _state.enrolledDevice ?? await _creds.readDevice();
    if (device == null) {
      _setState(
        _state.copyWith(
          stage: AuthGateStage.unregistered,
          errorMessage: 'Register this terminal before signing in.',
        ),
      );
      return false;
    }
    if (device.isRevoked) {
      _setState(
        _state.copyWith(
          stage: AuthGateStage.revoked,
          revocationReason:
              device.revocationMessage ?? 'This device has been revoked.',
        ),
      );
      return false;
    }

    _authEpoch++;
    _setState(_state.copyWith(busy: true, clearError: true));

    Uint8List? dekBytes;
    Uint8List? kekBytes;
    try {
      final res = await _api.login(
        username: username,
        deviceId: device.deviceId,
        pin: pin,
        password: password,
      );
      kekBytes = res.lease.kekBytes;

      dekBytes = await EnvelopeCrypto.unwrapServerEnvelope(
        kek: kekBytes,
        envelope: res.lease.envelopeBytes,
        deviceId: res.device.id,
        leaseId: res.lease.leaseId,
        expiresAt: res.lease.expiresAt,
      );
      RamKeyHolder.zeroBuffer(kekBytes);
      kekBytes = null;

      final session = ActiveLeaseSession(
        userId: res.user.id,
        username: res.user.username,
        role: res.user.role,
        deviceId: res.device.id,
        deviceCode: res.device.code,
        leaseId: res.lease.leaseId,
        issuedAt: res.lease.issuedAt,
        expiresAt: res.lease.expiresAt,
      );

      _ramKeyHolder.unlock(dekBytes: dekBytes, session: session);

      if (pin != null && EnvelopeCrypto.isValidPin(pin)) {
        await _keystore.provisionOfflineRecoverySlot(
          session: session,
          dekBytes: dekBytes,
          pin: pin,
          serverEnvelope: res.lease.envelopeBytes,
        );
      } else {
        // Password-only login must never leave a prior staff member's PIN slot behind.
        await _keystore.clearOfflineSlot();
      }
      RamKeyHolder.zeroBuffer(dekBytes);
      dekBytes = null;

      await _creds.saveSession(
        PersistedAuthSession(
          accessToken: res.accessToken,
          userId: res.user.id,
          username: res.user.username,
          displayName: res.user.name,
          role: res.user.role,
          deviceId: res.device.id,
          deviceCode: res.device.code,
          leaseId: res.lease.leaseId,
          expiresAt: res.lease.expiresAt,
        ),
      );
      _ref.read(activeAccessTokenProvider.notifier).setToken(res.accessToken);

      final db = await _openDatabase(_ramKeyHolder);
      _ref.read(activeDatabaseProvider.notifier).setDatabase(db);
      await db.upsertAuthenticatedUser(
        id: res.user.id,
        name: res.user.name,
        username: res.user.username,
        role: res.user.role,
      );
      await db.enforceRolePrivacy(res.user.role);

      await _syncWorker.start(runInitialSync: false);
      await _syncWorker.pullNow();

      // Kill-switch could have triggered mid-pull if revoked asynchronously.
      if (!_ramKeyHolder.isUnlocked) {
        return false;
      }

      _sseClient.start();
      await _evaluateShiftAndTransition(
        db: db,
        session: session,
        displayName: res.user.name,
      );
      return true;
    } on ApiException catch (e) {
      await _cleanupFailedUnlock(wipePersistedMaterials: e.isDeviceRevoked);
      if (e.isDeviceRevoked) {
        await _ref
            .read(killSwitchServiceProvider)
            .executeRevocation(reason: e.message);
      } else {
        _setState(_state.copyWith(busy: false, errorMessage: e.message));
      }
      return false;
    } catch (e) {
      await _cleanupFailedUnlock(wipePersistedMaterials: true);
      _setState(
        _state.copyWith(busy: false, errorMessage: 'Login failed: $e'),
      );
      return false;
    } finally {
      RamKeyHolder.zeroBuffer(kekBytes);
      RamKeyHolder.zeroBuffer(dekBytes);
    }
  }

  /// Offline reboot recovery via hardware Keystore PIN slot (`TECHNICAL_SPEC.md` §7.3).
  Future<bool> unlockOfflineWithPin(String pin) async {
    if (_state.busy) return false;
    final device = _state.enrolledDevice ?? await _creds.readDevice();
    if (device == null || device.isRevoked) {
      await _handleUnexpectedLock();
      return false;
    }

    _authEpoch++;
    _setState(_state.copyWith(busy: true, clearError: true));

    try {
      final session = await _keystore.recoverDekWithPin(pin);
      final persisted = await _creds.readSession();
      if (persisted != null &&
          persisted.leaseId == session.leaseId &&
          DateTime.now().toUtc().isBefore(persisted.expiresAt)) {
        _ref
            .read(activeAccessTokenProvider.notifier)
            .setToken(persisted.accessToken);
      }

      final db = await _openDatabase(_ramKeyHolder);
      _ref.read(activeDatabaseProvider.notifier).setDatabase(db);
      final resolvedName = persisted?.displayName ?? session.username;
      await db.upsertAuthenticatedUser(
        id: session.userId,
        name: resolvedName,
        username: session.username,
        role: session.role,
      );
      await db.enforceRolePrivacy(session.role);

      await _syncWorker.start(runInitialSync: false);
      if (_ref.read(activeAccessTokenProvider) != null) {
        _sseClient.start();
      }

      await _evaluateShiftAndTransition(
        db: db,
        session: session,
        displayName: resolvedName,
      );
      return true;
    } on OfflineRecoveryException catch (e) {
      await _cleanupFailedUnlock();
      final refreshedSlot = await _keystore.inspectSlot();
      _setState(
        _state.copyWith(
          busy: false,
          offlineRecovery: refreshedSlot,
          errorMessage: e.message,
        ),
      );
      return false;
    } catch (e) {
      await _cleanupFailedUnlock();
      final refreshedSlot = await _keystore.inspectSlot();
      _setState(
        _state.copyWith(
          busy: false,
          offlineRecovery: refreshedSlot,
          errorMessage: 'Offline unlock failed: $e',
        ),
      );
      return false;
    }
  }

  Future<void> _evaluateShiftAndTransition({
    required AppDatabase db,
    required ActiveLeaseSession session,
    required String displayName,
  }) async {
    final openShift = await db.fetchOpenRegisterShift();
    StaffShiftSessionRow? staffSess;
    if (openShift != null) {
      staffSess = await db.fetchActiveStaffSession(
        registerShiftId: openShift.id,
        userId: session.userId,
        deviceCode: session.deviceCode,
      );
    }

    final slot = await _keystore.inspectSlot();
    final alreadyReady = openShift != null && staffSess != null;

    _setState(
      _state.copyWith(
        stage: alreadyReady
            ? AuthGateStage.ready
            : AuthGateStage.shiftOpenRequired,
        offlineRecovery: slot,
        session: session,
        displayName: displayName,
        activeShift: openShift,
        clearActiveShift: openShift == null,
        activeStaffSession: staffSess,
        clearActiveStaffSession: staffSess == null,
        busy: false,
        clearError: true,
      ),
    );
  }

  /// Opens a brand-new Single-Galla morning register shift with [openingFloatPaisa]
  /// and punches this staff phone into `staff_shift_sessions`.
  Future<bool> openNewShiftWithFloat({
    required int openingFloatPaisa,
    String? notes,
  }) async {
    if (_state.busy) return false;
    final db = _ref.read(activeDatabaseProvider);
    final session = _ramKeyHolder.session;
    if (db == null || session == null) {
      await _handleUnexpectedLock();
      return false;
    }

    _setState(_state.copyWith(busy: true, clearError: true));
    try {
      // Single-Galla guard: check if another phone synced an OPEN shift meanwhile.
      final existing = await db.fetchOpenRegisterShift();
      if (existing != null) {
        final staffSess = await db.fetchActiveStaffSession(
              registerShiftId: existing.id,
              userId: session.userId,
              deviceCode: session.deviceCode,
            ) ??
            await db.punchInToExistingShift(
              registerShiftId: existing.id,
              userId: session.userId,
              deviceCode: session.deviceCode,
            );
        _setState(
          _state.copyWith(
            stage: AuthGateStage.ready,
            activeShift: existing,
            activeStaffSession: staffSess,
            busy: false,
            clearError: true,
          ),
        );
        _syncWorker.scheduleImmediateSync();
        return true;
      }

      final created = await db.openRegisterShiftAndPunchIn(
        userId: session.userId,
        deviceCode: session.deviceCode,
        openingFloatPaisa: openingFloatPaisa,
        notes: notes,
      );

      _setState(
        _state.copyWith(
          stage: AuthGateStage.ready,
          activeShift: created.shift,
          activeStaffSession: created.session,
          busy: false,
          clearError: true,
        ),
      );
      _syncWorker.scheduleImmediateSync();
      return true;
    } catch (e) {
      _setState(
        _state.copyWith(
          busy: false,
          errorMessage: 'Failed to open register: $e',
        ),
      );
      return false;
    }
  }

  /// Punches this phone into the active shop Single-Galla shift (`Phone 02`+).
  Future<bool> joinExistingOpenShift() async {
    if (_state.busy) return false;
    final db = _ref.read(activeDatabaseProvider);
    final session = _ramKeyHolder.session;
    final shift = _state.activeShift ?? await db?.fetchOpenRegisterShift();
    if (db == null || session == null || shift == null) {
      _setState(
        _state.copyWith(errorMessage: 'No active open register found.'),
      );
      return false;
    }

    _setState(_state.copyWith(busy: true, clearError: true));
    try {
      final staffSess = await db.fetchActiveStaffSession(
            registerShiftId: shift.id,
            userId: session.userId,
            deviceCode: session.deviceCode,
          ) ??
          await db.punchInToExistingShift(
            registerShiftId: shift.id,
            userId: session.userId,
            deviceCode: session.deviceCode,
          );

      _setState(
        _state.copyWith(
          stage: AuthGateStage.ready,
          activeShift: shift,
          activeStaffSession: staffSess,
          busy: false,
          clearError: true,
        ),
      );
      _syncWorker.scheduleImmediateSync();
      return true;
    } catch (e) {
      _setState(
        _state.copyWith(
          busy: false,
          errorMessage: 'Failed to punch in: $e',
        ),
      );
      return false;
    }
  }

  /// Clears cached [activeShift] and [activeStaffSession] right after Z-Report
  /// settles so POS bills / Khata repayments never attach to a CLOSED shift.
  void onShiftClosed(String closedShiftId) {
    if (_state.activeShift?.id != closedShiftId) return;
    _setState(
      _state.copyWith(
        clearActiveShift: true,
        clearActiveStaffSession: true,
      ),
    );
  }

  /// Routes an unlocked user cleanly back to the Opening Float screen when no
  /// register shift is currently open (e.g. immediately after Z-Report close).
  void requestNewShiftOpen() {
    if (_ramKeyHolder.session == null) return;
    _setState(
      _state.copyWith(
        stage: AuthGateStage.shiftOpenRequired,
        clearActiveShift: true,
        clearActiveStaffSession: true,
        clearError: true,
      ),
    );
  }

  /// Clean manual logout: ends server lease best-effort, stops sync/SSE,
  /// zeroes RAM DEK & deletes offline PIN slot, keeping device registration.
  Future<void> logout() async {
    _authEpoch++;
    final token = _ref.read(activeAccessTokenProvider);
    await _sseClient.stop();
    await _syncWorker.stop();

    if (token != null && token.isNotEmpty) {
      try {
        await _api.logout(accessToken: token);
      } catch (_) {
        // Offline logout must still wipe local RAM & Keystore cleanly.
      }
    }

    _ref.read(activeAccessTokenProvider.notifier).setToken(null);
    await _creds.clearSession();
    await _keystore.wipeAll();

    final device = await _creds.readDevice();
    _setState(
      _state.copyWith(
        stage: device == null
            ? AuthGateStage.unregistered
            : (device.isRevoked
                ? AuthGateStage.revoked
                : AuthGateStage.locked),
        enrolledDevice: device,
        offlineRecovery: const OfflineRecoveryStatus(hasSlot: false),
        clearSession: true,
        clearDisplayName: true,
        clearActiveShift: true,
        clearActiveStaffSession: true,
        busy: false,
        clearError: true,
      ),
    );
  }

  /// Clears a revoked terminal record so the Owner can re-enroll this device.
  Future<void> resetRevokedEnrollment() async {
    _authEpoch++;
    await _sseClient.stop();
    await _syncWorker.stop();
    _ref.read(activeAccessTokenProvider.notifier).setToken(null);
    await _keystore.wipeAll();
    await _creds.clearSession();
    await _creds.clearDevice();
    await _purgeLocalDbFiles();

    _setState(
      _state.copyWith(
        stage: AuthGateStage.unregistered,
        clearEnrolledDevice: true,
        offlineRecovery: const OfflineRecoveryStatus(hasSlot: false),
        clearSession: true,
        clearDisplayName: true,
        clearActiveShift: true,
        clearActiveStaffSession: true,
        busy: false,
        clearError: true,
        clearRevocationReason: true,
      ),
    );
  }

  /// Test helper or post-enrollment shortcut to re-check current revocation state.
  Future<void> handleExternalKillSwitch(String reason) async {
    await _ref.read(killSwitchServiceProvider).executeRevocation(reason: reason);
    await _handleUnexpectedLock();
  }

  Future<void> _cleanupFailedUnlock({bool wipePersistedMaterials = false}) async {
    await _sseClient.stop();
    await _syncWorker.stop();
    _ref.read(activeAccessTokenProvider.notifier).setToken(null);
    _ramKeyHolder.wipe();
    if (wipePersistedMaterials) {
      await _keystore.wipeAll();
      await _creds.clearSession();
    }
  }

  Future<void> _purgeLocalDbFiles() async {
    if (_deleteLocalDatabaseFiles != null) {
      await _deleteLocalDatabaseFiles();
      return;
    }
    try {
      final dbFile =
          await _ref.read(sqlCipherDatabaseFactoryProvider).resolveDatabaseFile();
      for (final path in <String>[
        dbFile.path,
        '${dbFile.path}-wal',
        '${dbFile.path}-shm',
      ]) {
        final f = File(path);
        if (f.existsSync()) {
          await f.delete();
        }
      }
    } catch (_) {
      // Best-effort cleanup of old device-bound encrypted database.
    }
  }

  void _setState(AuthSessionState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cachedRamKeyHolder.removeLockListener(_onRamKeyLocked);
    _cachedKillSwitch.removeRevocationListener(_onRevocationExecuted);
    super.dispose();
  }
}

final authSessionControllerProvider =
    ChangeNotifierProvider<AuthSessionController>((ref) {
  return AuthSessionController(ref: ref);
});
