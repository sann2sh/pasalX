import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../core/database/app_database.dart';
import '../../../core/network/api_config.dart';
import '../../../core/network/api_exceptions.dart';
import '../../../core/network/auth_models.dart';
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
  accountAuthRequired,
  emailVerificationRequired,
  storeSetupRequired,
  deviceApprovalPending,
  deviceRejected,
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
    this.accountSession,
    this.pendingEmail,
    this.pendingEnrollment,
    this.displayName,
    this.activeShift,
    this.activeStaffSession,
    this.busy = false,
    this.errorMessage,
    this.infoMessage,
    this.revocationReason,
  });

  final AuthGateStage stage;
  final String serverUrl;
  final EnrolledDeviceInfo? enrolledDevice;
  final OfflineRecoveryStatus offlineRecovery;
  final ActiveLeaseSession? session;
  final PersistedAccountSession? accountSession;
  final String? pendingEmail;
  final DeviceStatusResult? pendingEnrollment;
  final String? displayName;
  final RegisterShiftRow? activeShift;
  final StaffShiftSessionRow? activeStaffSession;
  final bool busy;
  final String? errorMessage;
  final String? infoMessage;
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
    PersistedAccountSession? accountSession,
    bool clearAccountSession = false,
    String? pendingEmail,
    bool clearPendingEmail = false,
    DeviceStatusResult? pendingEnrollment,
    bool clearPendingEnrollment = false,
    String? displayName,
    bool clearDisplayName = false,
    RegisterShiftRow? activeShift,
    bool clearActiveShift = false,
    StaffShiftSessionRow? activeStaffSession,
    bool clearActiveStaffSession = false,
    bool? busy,
    String? errorMessage,
    bool clearError = false,
    String? infoMessage,
    bool clearInfo = false,
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
      accountSession: clearAccountSession
          ? null
          : (accountSession ?? this.accountSession),
      pendingEmail:
          clearPendingEmail ? null : (pendingEmail ?? this.pendingEmail),
      pendingEnrollment: clearPendingEnrollment
          ? null
          : (pendingEnrollment ?? this.pendingEnrollment),
      displayName: clearDisplayName ? null : (displayName ?? this.displayName),
      activeShift: clearActiveShift ? null : (activeShift ?? this.activeShift),
      activeStaffSession: clearActiveStaffSession
          ? null
          : (activeStaffSession ?? this.activeStaffSession),
      busy: busy ?? this.busy,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      infoMessage: clearInfo ? null : (infoMessage ?? this.infoMessage),
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
        if (savedUrl != null &&
            savedUrl.isNotEmpty &&
            ApiConfig.isValidBaseUrl(savedUrl)) {
          serverUrl = savedUrl;
          _ref.read(apiConfigProvider.notifier).setBaseUrl(savedUrl);
        }
      } on MissingPluginException {
        // Test environment without secure storage plugin.
      } on PlatformException {
        // Fallback cleanly to default URL.
      }

      EnrolledDeviceInfo? device;
      PersistedAccountSession? accountSess;
      DeviceStatusResult? pendingEnrollment;
      OfflineRecoveryStatus offlineStatus =
          const OfflineRecoveryStatus(hasSlot: false);
      try {
        device = await _creds.readDevice();
        if (device != null && device.isRevoked) {
          await _keystore.wipeAll();
          await _creds.clearSession();
          await _purgeLocalDbFiles();
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

        // M3 / Store-isolation guard: legacy enrollments lacking storeId or
        // sessions whose JWT `sid` mismatches the enrolled device's store_id
        // trigger a controlled wipe & re-enrollment instead of a crash.
        if (device != null) {
          final deviceStoreId = device.storeId?.trim();
          final persisted = await _creds.readSession();
          final tokenSid = persisted == null
              ? null
              : JwtPayloadHelper.readStoreId(persisted.accessToken);
          final legacyMissingStore =
              deviceStoreId == null || deviceStoreId.isEmpty;
          final tokenMismatch = persisted != null &&
              (tokenSid == null || tokenSid != deviceStoreId);
          if (legacyMissingStore || tokenMismatch) {
            await _wipeAllLocalStoreState(clearAccountSession: true);
            _setState(
              _state.copyWith(
                stage: AuthGateStage.accountAuthRequired,
                serverUrl: serverUrl,
                clearEnrolledDevice: true,
                offlineRecovery: const OfflineRecoveryStatus(hasSlot: false),
                infoMessage: legacyMissingStore
                    ? 'App updated for multi-store security. Please sign in to re-enroll this phone.'
                    : 'Store mismatch detected. Local data cleared for security.',
              ),
            );
            _initialized = true;
            return;
          }
          offlineStatus = await _keystore.inspectSlot();
          if (device.lastUsername == null || device.lastUsername!.isEmpty) {
            final acct = await _creds.readAccountSession();
            final fallbackUser =
                persisted?.username ?? offlineStatus.username ?? acct?.username;
            if (fallbackUser != null && fallbackUser.isNotEmpty) {
              device = device.copyWith(lastUsername: fallbackUser);
              await _creds.saveDevice(device);
            }
          }
        } else {
          accountSess = await _creds.readAccountSession();
          pendingEnrollment = await _creds.readPendingEnrollment();
        }
      } on MissingPluginException {
        device = null;
      } on PlatformException {
        device = null;
      }

      final AuthGateStage nextStage;
      if (device != null) {
        nextStage = AuthGateStage.locked;
      } else if (pendingEnrollment != null) {
        nextStage = pendingEnrollment.status == 'REJECTED'
            ? AuthGateStage.deviceRejected
            : AuthGateStage.deviceApprovalPending;
      } else if (accountSess != null && !accountSess.isExpired) {
        nextStage = AuthGateStage.storeSetupRequired;
      } else {
        nextStage = AuthGateStage.accountAuthRequired;
      }

      _setState(
        _state.copyWith(
          stage: nextStage,
          serverUrl: serverUrl,
          enrolledDevice: device,
          clearEnrolledDevice: device == null,
          accountSession: accountSess,
          clearAccountSession: accountSess == null,
          pendingEnrollment: pendingEnrollment,
          clearPendingEnrollment: pendingEnrollment == null,
          offlineRecovery: offlineStatus,
          clearError: true,
        ),
      );
      _initialized = true;
    } catch (e) {
      _setState(
        _state.copyWith(
          stage: AuthGateStage.accountAuthRequired,
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
    // Delete encrypted .db/.wal/.shm files immediately in the background (or
    // await directly when a test override avoids host path_provider I/O).
    final hasDirectPath = _deleteLocalDatabaseFiles != null ||
        _ref.read(sqlCipherDatabaseFactoryProvider).databaseFileOverride != null;
    if (hasDirectPath) {
      await _purgeLocalDbFiles();
    } else {
      unawaited(_purgeLocalDbFiles());
    }
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
        stage: device == null
            ? AuthGateStage.accountAuthRequired
            : AuthGateStage.locked,
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
    if (!ApiConfig.isValidBaseUrl(trimmed)) {
      _setState(
        _state.copyWith(
          errorMessage: kReleaseMode
              ? 'Release builds require a valid https:// server address.'
              : 'Enter a valid http:// or https:// server address.',
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
        storeId: reg.storeId,
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
          stage: AuthGateStage.accountAuthRequired,
          errorMessage: 'Sign in and enroll this terminal first.',
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

      // M3 store-isolation guard: verify JWT `sid` matches enrolled device storeId.
      final tokenSid = JwtPayloadHelper.readStoreId(res.accessToken);
      final expectedStoreId = device.storeId ?? res.device.storeId;
      if (tokenSid == null ||
          expectedStoreId == null ||
          expectedStoreId.isEmpty ||
          tokenSid != expectedStoreId) {
        await _wipeAllLocalStoreState(clearAccountSession: true);
        _setState(
          _state.copyWith(
            stage: AuthGateStage.accountAuthRequired,
            clearEnrolledDevice: true,
            offlineRecovery: const OfflineRecoveryStatus(hasSlot: false),
            clearSession: true,
            busy: false,
            errorMessage:
                'Store mismatch detected on login. Local data wiped for security.',
          ),
        );
        return false;
      }

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

      if (res.user.username.isNotEmpty &&
          device.lastUsername != res.user.username) {
        final updatedDevice = device.copyWith(lastUsername: res.user.username);
        await _creds.saveDevice(updatedDevice);
        _setState(_state.copyWith(enrolledDevice: updatedDevice));
      }

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
            ? AuthGateStage.accountAuthRequired
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

  /// Clears a revoked terminal record so the user can re-enroll this device.
  Future<void> resetRevokedEnrollment() async {
    _authEpoch++;
    await _wipeAllLocalStoreState(clearAccountSession: true);

    _setState(
      _state.copyWith(
        stage: AuthGateStage.accountAuthRequired,
        clearEnrolledDevice: true,
        clearAccountSession: true,
        clearPendingEnrollment: true,
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

  // ------------------------------------------------------------------ Phase 2 Onboarding & Lifecycle

  Future<bool> signupAccount({
    required String name,
    required String email,
    required String password,
    required String username,
    required String pin,
  }) async {
    if (_state.busy) return false;
    _setState(_state.copyWith(busy: true, clearError: true, clearInfo: true));
    try {
      final res = await _api.signup(
        name: name,
        email: email,
        password: password,
        username: username,
        pin: pin,
      );
      _setState(
        _state.copyWith(
          stage: res.verificationRequired
              ? AuthGateStage.emailVerificationRequired
              : AuthGateStage.accountAuthRequired,
          pendingEmail: email.trim().toLowerCase(),
          busy: false,
          infoMessage: res.verificationRequired
              ? 'Verification code sent to ${email.trim()}.'
              : 'Account created. Please log in.',
        ),
      );
      return true;
    } on ApiException catch (e) {
      _setState(_state.copyWith(busy: false, errorMessage: e.message));
      return false;
    } catch (e) {
      _setState(_state.copyWith(busy: false, errorMessage: 'Sign up failed: $e'));
      return false;
    }
  }

  Future<bool> verifyEmailCode({
    required String email,
    required String code,
  }) async {
    if (_state.busy) return false;
    _setState(_state.copyWith(busy: true, clearError: true, clearInfo: true));
    try {
      await _api.verifyEmail(email: email, code: code);
      _setState(
        _state.copyWith(
          stage: AuthGateStage.accountAuthRequired,
          clearPendingEmail: true,
          busy: false,
          infoMessage: 'Email verified! Please log in to continue.',
        ),
      );
      return true;
    } on ApiException catch (e) {
      _setState(_state.copyWith(busy: false, errorMessage: e.message));
      return false;
    } catch (e) {
      _setState(
        _state.copyWith(busy: false, errorMessage: 'Verification failed: $e'),
      );
      return false;
    }
  }

  Future<bool> resendVerificationCode({required String email}) async {
    if (_state.busy) return false;
    _setState(_state.copyWith(busy: true, clearError: true));
    try {
      await _api.resendVerification(email: email);
      _setState(
        _state.copyWith(
          busy: false,
          infoMessage: 'A new verification code has been sent.',
        ),
      );
      return true;
    } on ApiException catch (e) {
      _setState(_state.copyWith(busy: false, errorMessage: e.message));
      return false;
    } catch (e) {
      _setState(_state.copyWith(busy: false, errorMessage: 'Resend failed: $e'));
      return false;
    }
  }

  Future<bool> loginAccount({
    required String email,
    required String password,
  }) async {
    if (_state.busy) return false;
    _setState(_state.copyWith(busy: true, clearError: true, clearInfo: true));
    try {
      final res = await _api.accountLogin(email: email, password: password);
      final acct = PersistedAccountSession(
        accessToken: res.accessToken,
        userId: res.user.id,
        name: res.user.name,
        username: res.user.username,
        expiresAt: res.expiresAt,
        membership: res.membership,
      );
      await _creds.saveAccountSession(acct);

      if (res.membership == null) {
        _setState(
          _state.copyWith(
            stage: AuthGateStage.storeSetupRequired,
            accountSession: acct,
            busy: false,
          ),
        );
        return true;
      }

      // User already belongs to a store: check if this device is already enrolled.
      final existingDevice = await _creds.readDevice();
      if (existingDevice != null &&
          existingDevice.storeId == res.membership!.storeId &&
          !existingDevice.isRevoked) {
        _setState(
          _state.copyWith(
            stage: AuthGateStage.locked,
            accountSession: acct,
            enrolledDevice: existingDevice,
            busy: false,
          ),
        );
        return true;
      }

      // Otherwise stay on storeSetupRequired where user can enroll this phone
      // into their existing store (or we show their store membership).
      _setState(
        _state.copyWith(
          stage: AuthGateStage.storeSetupRequired,
          accountSession: acct,
          busy: false,
        ),
      );
      return true;
    } on ApiException catch (e) {
      if (e.code == 'EMAIL_NOT_VERIFIED') {
        _setState(
          _state.copyWith(
            stage: AuthGateStage.emailVerificationRequired,
            pendingEmail: email.trim().toLowerCase(),
            busy: false,
            errorMessage: e.message,
          ),
        );
        return false;
      }
      _setState(_state.copyWith(busy: false, errorMessage: e.message));
      return false;
    } catch (e) {
      _setState(_state.copyWith(busy: false, errorMessage: 'Login failed: $e'));
      return false;
    }
  }

  Future<bool> forgotPassword({required String email}) async {
    if (_state.busy) return false;
    _setState(_state.copyWith(busy: true, clearError: true));
    try {
      await _api.forgotPassword(email: email);
      _setState(
        _state.copyWith(
          busy: false,
          pendingEmail: email.trim().toLowerCase(),
          infoMessage:
              'If an account exists for that email, a reset code has been sent.',
        ),
      );
      return true;
    } on ApiException catch (e) {
      _setState(_state.copyWith(busy: false, errorMessage: e.message));
      return false;
    } catch (e) {
      _setState(_state.copyWith(busy: false, errorMessage: 'Request failed: $e'));
      return false;
    }
  }

  Future<bool> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    if (_state.busy) return false;
    _setState(_state.copyWith(busy: true, clearError: true));
    try {
      await _api.resetPassword(
        email: email,
        code: code,
        newPassword: newPassword,
      );
      _setState(
        _state.copyWith(
          stage: AuthGateStage.accountAuthRequired,
          clearPendingEmail: true,
          busy: false,
          infoMessage: 'Password updated. Please log in with your new password.',
        ),
      );
      return true;
    } on ApiException catch (e) {
      _setState(_state.copyWith(busy: false, errorMessage: e.message));
      return false;
    } catch (e) {
      _setState(_state.copyWith(busy: false, errorMessage: 'Reset failed: $e'));
      return false;
    }
  }

  Future<bool> createStoreAndEnroll({
    required String storeName,
    String? panNumber,
    String? phone,
    String? address,
    required String deviceName,
    String platform = 'ANDROID',
  }) async {
    if (_state.busy) return false;
    final acct = _state.accountSession ?? await _creds.readAccountSession();
    if (acct == null || acct.isExpired) {
      _setState(
        _state.copyWith(
          stage: AuthGateStage.accountAuthRequired,
          errorMessage: 'Your account session expired. Please log in again.',
        ),
      );
      return false;
    }

    _authEpoch++;
    _setState(_state.copyWith(busy: true, clearError: true));
    Uint8List? dekBytes;
    Uint8List? kekBytes;
    try {
      final res = await _api.createStore(
        accountToken: acct.accessToken,
        storeName: storeName,
        panNumber: panNumber,
        phone: phone,
        address: address,
        deviceName: deviceName,
        platform: platform,
      );

      await _wipeAllLocalStoreState(clearAccountSession: false);

      final enrolled = EnrolledDeviceInfo(
        deviceId: res.device.id,
        storeId: res.store.id,
        deviceCode: res.device.code,
        deviceName: res.device.name,
        platform: res.device.platform,
        lastUsername: res.user.username,
        isRevoked: false,
      );
      await _creds.saveDevice(enrolled);

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
      _sseClient.start();

      _setState(
        _state.copyWith(
          enrolledDevice: enrolled,
          clearPendingEnrollment: true,
        ),
      );
      await _evaluateShiftAndTransition(
        db: db,
        session: session,
        displayName: res.user.name,
      );
      return true;
    } on ApiException catch (e) {
      await _cleanupFailedUnlock(wipePersistedMaterials: true);
      _setState(_state.copyWith(busy: false, errorMessage: e.message));
      return false;
    } catch (e) {
      await _cleanupFailedUnlock(wipePersistedMaterials: true);
      _setState(
        _state.copyWith(busy: false, errorMessage: 'Store creation failed: $e'),
      );
      return false;
    } finally {
      RamKeyHolder.zeroBuffer(kekBytes);
      RamKeyHolder.zeroBuffer(dekBytes);
    }
  }

  Future<bool> acceptInvitationCode({
    required String code,
    required String deviceName,
    String platform = 'ANDROID',
  }) async {
    if (_state.busy) return false;
    final acct = _state.accountSession ?? await _creds.readAccountSession();
    if (acct == null || acct.isExpired) {
      _setState(
        _state.copyWith(
          stage: AuthGateStage.accountAuthRequired,
          errorMessage: 'Your account session expired. Please log in again.',
        ),
      );
      return false;
    }

    _setState(_state.copyWith(busy: true, clearError: true));
    try {
      final status = await _api.acceptInvitation(
        accountToken: acct.accessToken,
        code: code,
        deviceName: deviceName,
        platform: platform,
      );
      await _creds.savePendingEnrollment(status);
      _setState(
        _state.copyWith(
          stage: AuthGateStage.deviceApprovalPending,
          pendingEnrollment: status,
          busy: false,
        ),
      );
      return true;
    } on ApiException catch (e) {
      _setState(_state.copyWith(busy: false, errorMessage: e.message));
      return false;
    } catch (e) {
      _setState(
        _state.copyWith(busy: false, errorMessage: 'Failed to join store: $e'),
      );
      return false;
    }
  }

  Future<bool> enrollExistingStoreDevice({
    required String deviceName,
    String platform = 'ANDROID',
  }) async {
    if (_state.busy) return false;
    final acct = _state.accountSession ?? await _creds.readAccountSession();
    if (acct == null || acct.isExpired) {
      _setState(
        _state.copyWith(
          stage: AuthGateStage.accountAuthRequired,
          errorMessage: 'Your account session expired. Please log in again.',
        ),
      );
      return false;
    }

    _setState(_state.copyWith(busy: true, clearError: true));
    try {
      final status = await _api.enrollDevice(
        accountToken: acct.accessToken,
        deviceName: deviceName,
        platform: platform,
      );
      if (status.status == 'ACTIVE' &&
          status.deviceCode != null &&
          status.deviceCode!.isNotEmpty) {
        final enrolled = EnrolledDeviceInfo(
          deviceId: status.deviceId,
          storeId: status.storeId,
          deviceCode: status.deviceCode!,
          deviceName: status.deviceName,
          platform: status.platform,
          lastUsername: acct.username,
        );
        await _creds.saveDevice(enrolled);
        await _creds.clearPendingEnrollment();
        _setState(
          _state.copyWith(
            stage: AuthGateStage.locked,
            enrolledDevice: enrolled,
            clearPendingEnrollment: true,
            busy: false,
          ),
        );
        return true;
      }

      await _creds.savePendingEnrollment(status);
      _setState(
        _state.copyWith(
          stage: AuthGateStage.deviceApprovalPending,
          pendingEnrollment: status,
          busy: false,
        ),
      );
      return true;
    } on ApiException catch (e) {
      _setState(_state.copyWith(busy: false, errorMessage: e.message));
      return false;
    } catch (e) {
      _setState(
        _state.copyWith(busy: false, errorMessage: 'Enrollment failed: $e'),
      );
      return false;
    }
  }

  Future<DeviceStatusResult?> checkPendingDeviceStatus() async {
    final pending =
        _state.pendingEnrollment ?? await _creds.readPendingEnrollment();
    final acct = _state.accountSession ?? await _creds.readAccountSession();
    if (pending == null || acct == null || acct.isExpired) {
      return null;
    }

    try {
      final updated = await _api.getMyDeviceStatus(
        accountToken: acct.accessToken,
        deviceId: pending.deviceId,
      );
      if (updated.status == 'ACTIVE' &&
          updated.deviceCode != null &&
          updated.deviceCode!.isNotEmpty) {
        final enrolled = EnrolledDeviceInfo(
          deviceId: updated.deviceId,
          storeId: updated.storeId,
          deviceCode: updated.deviceCode!,
          deviceName: updated.deviceName,
          platform: updated.platform,
          lastUsername: acct.username,
        );
        await _creds.saveDevice(enrolled);
        await _creds.clearPendingEnrollment();
        _setState(
          _state.copyWith(
            stage: AuthGateStage.locked,
            enrolledDevice: enrolled,
            clearPendingEnrollment: true,
            infoMessage: 'Device approved! Enter your username and 6-digit PIN.',
            clearError: true,
          ),
        );
      } else if (updated.status == 'REJECTED' || updated.status == 'REVOKED') {
        await _creds.savePendingEnrollment(updated);
        _setState(
          _state.copyWith(
            stage: AuthGateStage.deviceRejected,
            pendingEnrollment: updated,
            clearError: true,
          ),
        );
      } else {
        await _creds.savePendingEnrollment(updated);
        _setState(
          _state.copyWith(
            pendingEnrollment: updated,
            clearError: true,
          ),
        );
      }
      return updated;
    } on ApiException catch (e) {
      _setState(_state.copyWith(errorMessage: e.message));
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> cancelPendingEnrollment() async {
    await _creds.clearPendingEnrollment();
    final acct = _state.accountSession ?? await _creds.readAccountSession();
    _setState(
      _state.copyWith(
        stage: (acct != null && !acct.isExpired)
            ? AuthGateStage.storeSetupRequired
            : AuthGateStage.accountAuthRequired,
        clearPendingEnrollment: true,
        clearError: true,
      ),
    );
  }

  Future<void> signOutAccount() async {
    await _creds.clearAccountSession();
    await _creds.clearPendingEnrollment();
    _setState(
      _state.copyWith(
        stage: AuthGateStage.accountAuthRequired,
        clearAccountSession: true,
        clearPendingEnrollment: true,
        clearPendingEmail: true,
        clearError: true,
        clearInfo: true,
      ),
    );
  }

  /// Returns the number of local outbox mutations waiting to sync (`PENDING` or `FAILED`).
  Future<int> checkUnsyncedOutboxCount() async {
    final db = _ref.read(activeDatabaseProvider);
    if (db == null) return 0;
    return db.countUnsyncedOutboxMutations();
  }

  /// Safely leaves the current store (`Task 3.6`, `H4`):
  /// 1. Flushes outbox best-effort.
  /// 2. If unsynced mutations remain and [discardUnsynced] is false, returns
  ///    `unsyncedCount > 0` without leaving so UI can show the blocking dialog.
  /// 3. Calls `POST /api/stores/current/leave`.
  /// 4. Wipes local SQLCipher DB + WAL/SHM, Keystore, credentials, and RAM DEK.
  Future<({bool left, int unsyncedCount, String? error})> leaveStoreSafely({
    bool discardUnsynced = false,
  }) async {
    final token = _ref.read(activeAccessTokenProvider);
    if (token == null || token.isEmpty) {
      return (
        left: false,
        unsyncedCount: 0,
        error: 'You must be online and signed in to leave the store.',
      );
    }

    _setState(_state.copyWith(busy: true, clearError: true));
    try {
      await _syncWorker.syncNow().catchError((_) {});
      final db = _ref.read(activeDatabaseProvider);
      final unsynced = db == null ? 0 : await db.countUnsyncedOutboxMutations();
      if (unsynced > 0 && !discardUnsynced) {
        _setState(_state.copyWith(busy: false));
        return (left: false, unsyncedCount: unsynced, error: null);
      }

      await _api.leaveStore(
        accessToken: token,
        outboxEmpty: unsynced == 0,
        discardUnsynced: discardUnsynced,
      );

      await _wipeAllLocalStoreState(clearAccountSession: false);
      final acct = _state.accountSession ?? await _creds.readAccountSession();
      final nextAcct = acct == null
          ? null
          : PersistedAccountSession(
              accessToken: acct.accessToken,
              userId: acct.userId,
              name: acct.name,
              username: acct.username,
              expiresAt: acct.expiresAt,
              membership: null,
            );
      if (nextAcct != null) {
        await _creds.saveAccountSession(nextAcct);
      }

      _setState(
        _state.copyWith(
          stage: (nextAcct != null && !nextAcct.isExpired)
              ? AuthGateStage.storeSetupRequired
              : AuthGateStage.accountAuthRequired,
          clearEnrolledDevice: true,
          accountSession: nextAcct,
          clearAccountSession: nextAcct == null,
          offlineRecovery: const OfflineRecoveryStatus(hasSlot: false),
          clearSession: true,
          clearDisplayName: true,
          clearActiveShift: true,
          clearActiveStaffSession: true,
          busy: false,
          infoMessage: 'You have left the store and local data was wiped.',
        ),
      );
      return (left: true, unsyncedCount: 0, error: null);
    } on ApiException catch (e) {
      _setState(_state.copyWith(busy: false, errorMessage: e.message));
      return (left: false, unsyncedCount: 0, error: e.message);
    } catch (e) {
      final msg = 'Failed to leave store: $e';
      _setState(_state.copyWith(busy: false, errorMessage: msg));
      return (left: false, unsyncedCount: 0, error: msg);
    }
  }

  /// Permanently deletes the current user's account (`DELETE /api/account`, `H5`).
  /// If an Account JWT is not currently cached (or expired), authenticates first
  /// using [email] + [password] via `/api/auth/account-login`.
  Future<bool> deleteAccountWithPassword({
    required String email,
    required String password,
  }) async {
    if (_state.busy) return false;
    _setState(_state.copyWith(busy: true, clearError: true));
    try {
      var acct = _state.accountSession ?? await _creds.readAccountSession();
      if (acct == null || acct.isExpired) {
        final loginRes = await _api.accountLogin(
          email: email,
          password: password,
        );
        acct = PersistedAccountSession(
          accessToken: loginRes.accessToken,
          userId: loginRes.user.id,
          name: loginRes.user.name,
          username: loginRes.user.username,
          expiresAt: loginRes.expiresAt,
          membership: loginRes.membership,
        );
      }

      await _api.deleteAccount(
        accountToken: acct.accessToken,
        password: password,
      );

      await _wipeAllLocalStoreState(clearAccountSession: true);
      _setState(
        _state.copyWith(
          stage: AuthGateStage.accountAuthRequired,
          clearEnrolledDevice: true,
          clearAccountSession: true,
          clearPendingEnrollment: true,
          offlineRecovery: const OfflineRecoveryStatus(hasSlot: false),
          clearSession: true,
          clearDisplayName: true,
          clearActiveShift: true,
          clearActiveStaffSession: true,
          busy: false,
          infoMessage: 'Your account has been permanently deleted.',
        ),
      );
      return true;
    } on ApiException catch (e) {
      _setState(_state.copyWith(busy: false, errorMessage: e.message));
      return false;
    } catch (e) {
      _setState(
        _state.copyWith(busy: false, errorMessage: 'Account deletion failed: $e'),
      );
      return false;
    }
  }

  /// Wipes all local store data: stops SSE/sync, zeroes RAM DEK (closing SQLite),
  /// clears Keystore slot, clears credentials, and deletes `.db` + WAL/SHM files.
  Future<void> _wipeAllLocalStoreState({
    bool clearAccountSession = true,
  }) async {
    await _sseClient.stop();
    await _syncWorker.stop();
    _ref.read(activeAccessTokenProvider.notifier).setToken(null);
    final activeDb = _ref.read(activeDatabaseProvider);
    await _keystore.wipeAll();
    if (activeDb != null) {
      await activeDb.close();
    }
    await _creds.clearSession();
    await _creds.clearDevice();
    await _creds.clearPendingEnrollment();
    if (clearAccountSession) {
      await _creds.clearAccountSession();
    }
    await _purgeLocalDbFiles();
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
