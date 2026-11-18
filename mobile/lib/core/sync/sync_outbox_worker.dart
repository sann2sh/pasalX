import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../database/app_database.dart';
import '../network/api_exceptions.dart';
import '../network/pasal_api_client.dart';
import '../network/sync_models.dart';
import 'pull_applier.dart';

enum SyncHealthState {
  idle,
  syncing,
  synced,
  offline,
  error,
  revoked,
}

@immutable
class SyncStatusSnapshot {
  const SyncStatusSnapshot({
    this.state = SyncHealthState.idle,
    this.pendingCount = 0,
    this.isOnline = true,
    this.sseConnected = false,
    this.lastSyncedAt,
    this.lastError,
    this.discrepancies = const <DiscrepancyAlert>[],
  });

  final SyncHealthState state;
  final int pendingCount;
  final bool isOnline;
  final bool sseConnected;
  final DateTime? lastSyncedAt;
  final String? lastError;
  final List<DiscrepancyAlert> discrepancies;

  SyncStatusSnapshot copyWith({
    SyncHealthState? state,
    int? pendingCount,
    bool? isOnline,
    bool? sseConnected,
    DateTime? lastSyncedAt,
    String? lastError,
    bool clearError = false,
    List<DiscrepancyAlert>? discrepancies,
  }) {
    return SyncStatusSnapshot(
      state: state ?? this.state,
      pendingCount: pendingCount ?? this.pendingCount,
      isOnline: isOnline ?? this.isOnline,
      sseConnected: sseConnected ?? this.sseConnected,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      lastError: clearError ? null : (lastError ?? this.lastError),
      discrepancies: discrepancies ?? this.discrepancies,
    );
  }
}

/// Coordinates offline-first batch `POST /api/sync/push` (`LIMIT 50`) and
/// delta `GET /api/sync/pull` triggers:
/// - Immediate debounced dispatch after local writes (~150 ms),
/// - `connectivity_plus` instant flush when Wi-Fi / mobile data returns,
/// - Periodic 30-second fallback timer,
/// - Live SSE `DATA_CHANGED` delta pulls,
/// - Immediate `401 DEVICE_REVOKED` Kill-Switch escalation.
class SyncOutboxWorker extends ChangeNotifier {
  SyncOutboxWorker({
    required AppDatabase? Function() getDatabase,
    required String? Function() getAccessToken,
    required PasalApiClient apiClient,
    Stream<List<ConnectivityResult>>? connectivityStream,
    Future<List<ConnectivityResult>> Function()? checkConnectivity,
    this.periodicInterval = const Duration(seconds: 30),
    this.immediateDebounce = const Duration(milliseconds: 150),
    this.onDeviceRevoked,
    this.onAuthInvalidated,
    this.onOnlineReconnected,
    // ignore: prefer_initializing_formals
  })  : _getDatabase = getDatabase,
        // ignore: prefer_initializing_formals
        _getAccessToken = getAccessToken,
        // ignore: prefer_initializing_formals
        _apiClient = apiClient,
        _connectivityStream =
            connectivityStream ?? Connectivity().onConnectivityChanged,
        _checkConnectivity =
            checkConnectivity ?? (() => Connectivity().checkConnectivity());

  static const int pushBatchLimit = 50;
  static const int pullPageLimit = 500;
  static const int maxPullPagesPerRun = 50;

  final AppDatabase? Function() _getDatabase;
  final String? Function() _getAccessToken;
  final PasalApiClient _apiClient;
  final Stream<List<ConnectivityResult>> _connectivityStream;
  final Future<List<ConnectivityResult>> Function() _checkConnectivity;
  final Duration periodicInterval;
  final Duration immediateDebounce;

  FutureOr<void> Function(String reason)? onDeviceRevoked;
  FutureOr<void> Function(ApiException error)? onAuthInvalidated;
  VoidCallback? onOnlineReconnected;

  SyncStatusSnapshot _status = const SyncStatusSnapshot();
  SyncStatusSnapshot get status => _status;

  Timer? _periodicTimer;
  Timer? _debounceTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  StreamSubscription<int>? _outboxCountSub;
  Future<void>? _activeRun;
  bool _running = false;
  bool _disposed = false;

  bool get isRunning => _running;

  /// Starts periodic 30s sync, `connectivity_plus` listener, and outbox badge stream.
  Future<void> start({bool runInitialSync = true}) async {
    if (_disposed || _running) return;
    _running = true;

    final db = _getDatabase();
    if (db != null) {
      await db.resetStaleSyncingOutbox();
      _bindOutboxCountStream(db);
    }

    try {
      final initialConn = await _checkConnectivity();
      _updateStatus(isOnline: hasNetworkTransport(initialConn));
    } catch (_) {
      // Some platforms/tests without platform channel fallback to true.
    }

    _connectivitySub = _connectivityStream.listen(
      _handleConnectivityChanged,
      onError: (_) {},
    );
    _periodicTimer = Timer.periodic(periodicInterval, (_) {
      unawaited(syncNow());
    });

    if (runInitialSync && _status.isOnline) {
      unawaited(syncNow());
    }
  }

  /// Stops timers and listeners safely (e.g. on logout or Kill-Switch wipe).
  Future<void> stop() async {
    _running = false;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _periodicTimer?.cancel();
    _periodicTimer = null;
    await _connectivitySub?.cancel();
    _connectivitySub = null;
    await _outboxCountSub?.cancel();
    _outboxCountSub = null;
    if (!_disposed && _status.state != SyncHealthState.revoked) {
      _updateStatus(
        state: SyncHealthState.idle,
        sseConnected: false,
        pendingCount: 0,
        discrepancies: const <DiscrepancyAlert>[],
      );
    }
  }

  void setSseConnected(bool connected) {
    if (_disposed || _status.sseConnected == connected) return;
    _updateStatus(sseConnected: connected);
  }

  void markRevoked(String reason) {
    _updateStatus(
      state: SyncHealthState.revoked,
      sseConnected: false,
      lastError: reason,
    );
  }

  /// Debounced trigger invoked right after checkout, intake, or shift open.
  void scheduleImmediateSync() {
    if (_disposed || !_running) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(immediateDebounce, () {
      unawaited(syncNow());
    });
  }

  /// Pushes all pending outbox batches (`LIMIT 50`), then pulls any delta changes.
  /// Concurrent invocations coalesce cleanly onto the in-flight serialized job.
  Future<void> syncNow() {
    return _enqueueSerialized(() async {
      await _pushAllPending();
      await _pullUntilCaughtUp();
    });
  }

  /// Executes an immediate delta pull (`GET /api/sync/pull`), e.g. on SSE `DATA_CHANGED`.
  Future<void> pullNow() {
    return _enqueueSerialized(() async {
      await _pullUntilCaughtUp();
    });
  }

  Future<void> _enqueueSerialized(Future<void> Function() task) async {
    if (_disposed) return;
    while (_activeRun != null) {
      await _activeRun;
      if (_disposed) return;
    }

    final completer = Completer<void>();
    _activeRun = completer.future;
    try {
      await task();
    } finally {
      _activeRun = null;
      completer.complete();
    }
  }

  void _bindOutboxCountStream(AppDatabase db) {
    _outboxCountSub?.cancel();
    _outboxCountSub = db.watchPendingOutboxCount().listen((count) {
      _updateStatus(pendingCount: count);
    });
  }

  void _handleConnectivityChanged(List<ConnectivityResult> results) {
    final online = hasNetworkTransport(results);
    final wasOffline = !_status.isOnline;
    _updateStatus(
      isOnline: online,
      state: online ? _status.state : SyncHealthState.offline,
    );
    if (online) {
      if (wasOffline) {
        onOnlineReconnected?.call();
      }
      if (_running) {
        unawaited(syncNow());
      }
    }
  }

  Future<void> _pushAllPending() async {
    final db = _getDatabase();
    final token = _getAccessToken();
    if (db == null) return;
    if (token == null || token.isEmpty) {
      if (_status.isOnline && _status.pendingCount > 0) {
        _updateStatus(
          state: SyncHealthState.error,
          lastError: 'Online sign-in required to sync pending records.',
        );
      }
      return;
    }

    while (!_disposed && _running) {
      final batch = await db.fetchPendingOutbox(limit: pushBatchLimit);
      if (batch.isEmpty) {
        if (_status.state == SyncHealthState.syncing) {
          _updateStatus(
            state: SyncHealthState.synced,
            lastSyncedAt: DateTime.now().toUtc(),
            clearError: true,
          );
        }
        return;
      }

      _updateStatus(state: SyncHealthState.syncing, clearError: true);
      final ids = batch.map((r) => r.id).toList();
      await db.markOutboxSyncing(ids);

      try {
        final mutations = batch.map(_rowToMutation).toList();
        final result = await _apiClient.pushMutations(
          accessToken: token,
          mutations: mutations,
        );
        await _handleBatchSuccess(db, batch, result);
      } on ApiException catch (e) {
        if (e.isDeviceRevoked) {
          await db.markOutboxAttemptFailed(ids, e.message);
          markRevoked(e.message);
          await _triggerRevocation(e.message);
          return;
        }
        if (e.isAuthInvalidated) {
          await db.markOutboxAttemptFailed(ids, e.message);
          _updateStatus(state: SyncHealthState.error, lastError: e.message);
          if (onAuthInvalidated != null) {
            await onAuthInvalidated!(e);
          }
          return;
        }
        if (e.isPermanentSyncRejection) {
          if (batch.length == 1) {
            await db.markOutboxAttemptFailed(
              ids,
              '${e.code}: ${e.message}',
              permanent: true,
            );
            _updateStatus(state: SyncHealthState.error, lastError: e.message);
            continue;
          }
          // Isolate permanent poison pill without blocking other valid queued sales.
          await db.revertOutboxSyncingToPending(ids);
          final aborted = await _pushIndividuallyToIsolateFailure(db, token, batch);
          if (aborted) return;
          continue;
        }

        // Transient network / timeout / 429 / 5xx: restore to PENDING and stop run.
        await db.markOutboxAttemptFailed(ids, e.message);
        _updateStatus(
          state: e.statusCode == 0 ? SyncHealthState.offline : SyncHealthState.error,
          isOnline: e.statusCode != 0,
          lastError: e.message,
        );
        return;
      } on FormatException catch (e) {
        if (batch.length == 1) {
          await db.markOutboxAttemptFailed(ids, e.message, permanent: true);
          _updateStatus(state: SyncHealthState.error, lastError: e.message);
          continue;
        }
        await db.revertOutboxSyncingToPending(ids);
        final aborted = await _pushIndividuallyToIsolateFailure(db, token, batch);
        if (aborted) return;
        continue;
      } catch (e) {
        await db.markOutboxAttemptFailed(ids, e.toString());
        _updateStatus(state: SyncHealthState.error, lastError: e.toString());
        return;
      }
    }
  }

  /// Replays a permanently rejected multi-item batch item-by-item so only the
  /// offending mutation moves to `'FAILED'` while valid sales still succeed.
  /// Returns `true` if sync should stop immediately (transient/auth failure).
  Future<bool> _pushIndividuallyToIsolateFailure(
    AppDatabase db,
    String token,
    List<SyncOutboxRow> batch,
  ) async {
    for (final row in batch) {
      if (_disposed || !_running) return true;
      final singleIds = <String>[row.id];
      await db.markOutboxSyncing(singleIds);
      try {
        final result = await _apiClient.pushMutations(
          accessToken: token,
          mutations: <OutboxMutationPayload>[_rowToMutation(row)],
        );
        await _handleBatchSuccess(db, <SyncOutboxRow>[row], result);
      } on FormatException catch (e) {
        await db.markOutboxAttemptFailed(singleIds, e.message, permanent: true);
        _updateStatus(state: SyncHealthState.error, lastError: e.message);
        continue;
      } on ApiException catch (e) {
        if (e.isDeviceRevoked) {
          await db.markOutboxAttemptFailed(singleIds, e.message);
          markRevoked(e.message);
          await _triggerRevocation(e.message);
          return true;
        }
        if (e.isAuthInvalidated) {
          await db.markOutboxAttemptFailed(singleIds, e.message);
          if (onAuthInvalidated != null) {
            await onAuthInvalidated!(e);
          }
          return true;
        }
        if (e.isPermanentSyncRejection) {
          await db.markOutboxAttemptFailed(
            singleIds,
            '${e.code}: ${e.message}',
            permanent: true,
          );
          _updateStatus(state: SyncHealthState.error, lastError: e.message);
          continue;
        }
        await db.markOutboxAttemptFailed(singleIds, e.message);
        _updateStatus(
          state: e.statusCode == 0 ? SyncHealthState.offline : SyncHealthState.error,
          isOnline: e.statusCode != 0,
          lastError: e.message,
        );
        return true;
      }
    }
    return false;
  }

  Future<void> _handleBatchSuccess(
    AppDatabase db,
    List<SyncOutboxRow> batch,
    SyncPushResult result,
  ) async {
    final ids = batch.map((r) => r.id).toList();
    await db.markOutboxSynced(ids, syncedAt: result.serverTime);

    final syncedSaleIds = batch
        .where((r) => r.targetTable == 'sale_orders')
        .map((r) => r.recordId)
        .toList();
    if (syncedSaleIds.isNotEmpty) {
      await db.markSaleOrdersSynced(syncedSaleIds);
    }

    if (result.discrepancies.isNotEmpty) {
      final merged = <DiscrepancyAlert>[
        ...result.discrepancies,
        ..._status.discrepancies,
      ];
      _updateStatus(
        discrepancies: merged.take(25).toList(),
      );
    }

    _updateStatus(
      state: SyncHealthState.synced,
      isOnline: true,
      lastSyncedAt: result.serverTime,
      clearError: true,
    );
  }

  Future<void> _pullUntilCaughtUp() async {
    final db = _getDatabase();
    final token = _getAccessToken();
    if (db == null || token == null || token.isEmpty) return;

    _updateStatus(state: SyncHealthState.syncing, clearError: true);

    for (var page = 0; page < maxPullPagesPerRun; page++) {
      if (_disposed || !_running) return;
      final since = await PullApplier.readCursor(db);

      try {
        final pull = await _apiClient.pullChanges(
          accessToken: token,
          since: since,
          limit: pullPageLimit,
        );
        await PullApplier.apply(db, pull);

        _updateStatus(
          state: SyncHealthState.synced,
          isOnline: true,
          lastSyncedAt: pull.serverTime,
          clearError: true,
        );

        if (!pull.hasMore) {
          return;
        }
        // Guard against stuck server cursor.
        if (since != null && !pull.serverTime.isAfter(since)) {
          return;
        }
      } on ApiException catch (e) {
        if (e.isDeviceRevoked) {
          markRevoked(e.message);
          await _triggerRevocation(e.message);
          return;
        }
        if (e.isAuthInvalidated) {
          _updateStatus(state: SyncHealthState.error, lastError: e.message);
          if (onAuthInvalidated != null) {
            await onAuthInvalidated!(e);
          }
          return;
        }
        _updateStatus(
          state: e.statusCode == 0 ? SyncHealthState.offline : SyncHealthState.error,
          isOnline: e.statusCode != 0,
          lastError: e.message,
        );
        return;
      } catch (e) {
        _updateStatus(state: SyncHealthState.error, lastError: e.toString());
        return;
      }
    }
  }

  Future<void> _triggerRevocation(String reason) async {
    await stop();
    if (onDeviceRevoked != null) {
      await onDeviceRevoked!(reason);
    }
  }

  OutboxMutationPayload _rowToMutation(SyncOutboxRow row) {
    final decoded = jsonDecode(row.payloadJson);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException(
        'Outbox payload for ${row.id} (${row.targetTable}) must be a JSON object',
      );
    }
    return OutboxMutationPayload(
      id: row.id,
      tableName: row.targetTable,
      recordId: row.recordId,
      operation: row.operation,
      clientUpdatedAt: row.clientUpdatedAt,
      payload: decoded,
    );
  }

  void _updateStatus({
    SyncHealthState? state,
    int? pendingCount,
    bool? isOnline,
    bool? sseConnected,
    DateTime? lastSyncedAt,
    String? lastError,
    bool clearError = false,
    List<DiscrepancyAlert>? discrepancies,
  }) {
    if (_disposed) return;
    _status = _status.copyWith(
      state: state,
      pendingCount: pendingCount,
      isOnline: isOnline,
      sseConnected: sseConnected,
      lastSyncedAt: lastSyncedAt,
      lastError: lastError,
      clearError: clearError,
      discrepancies: discrepancies,
    );
    notifyListeners();
  }

  static bool hasNetworkTransport(List<ConnectivityResult> results) {
    if (results.isEmpty) return false;
    return results.any((r) => r != ConnectivityResult.none);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
