import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../network/api_config.dart';
import '../network/pasal_api_client.dart';

/// Parsed payload for a Go `/api/sync/events` `DATA_CHANGED` SSE ping.
@immutable
class SseDataChangedEvent {
  const SseDataChangedEvent({
    required this.originDeviceCode,
    required this.serverTime,
    this.hasDiscrepancy = false,
  });

  factory SseDataChangedEvent.fromJson(Map<String, dynamic> json) {
    return SseDataChangedEvent(
      originDeviceCode: json['origin_device_code'] as String? ?? '',
      serverTime: json['server_time'] != null
          ? DateTime.parse(json['server_time'] as String).toUtc()
          : DateTime.now().toUtc(),
      hasDiscrepancy: json['has_discrepancy'] as bool? ?? false,
    );
  }

  final String originDeviceCode;
  final DateTime serverTime;
  final bool hasDiscrepancy;
}

/// Real-time Server-Sent Events listener targeting `GET /api/sync/events`.
///
/// Handles Go backend events (`server/internal/sync/handler.go`):
/// - `event: CONNECTED` -> marks live stream connected & resets backoff,
/// - `event: DATA_CHANGED` -> invokes [onDataChanged] for `< 1s` delta pull,
/// - `event: DEVICE_REVOKED` (or HTTP 401 `DEVICE_REVOKED`) -> invokes [onDeviceRevoked],
/// - `event: SESSION_EXPIRED` -> invokes [onSessionExpired],
/// - `: keepalive` -> keeps TCP stream alive silently.
class SseSyncClient {
  SseSyncClient({
    required ApiConfig Function() getConfig,
    required String? Function() getAccessToken,
    http.Client Function()? clientFactory,
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
    this.onConnectedChanged,
    this.onDataChanged,
    this.onDeviceRevoked,
    this.onSessionExpired,
    // ignore: prefer_initializing_formals
  })  : _getConfig = getConfig,
        // ignore: prefer_initializing_formals
        _getAccessToken = getAccessToken,
        _clientFactory = clientFactory ?? http.Client.new;

  final ApiConfig Function() _getConfig;
  final String? Function() _getAccessToken;
  final http.Client Function() _clientFactory;
  final Duration initialBackoff;
  final Duration maxBackoff;

  void Function(bool connected)? onConnectedChanged;
  FutureOr<void> Function(SseDataChangedEvent event)? onDataChanged;
  FutureOr<void> Function(String reason)? onDeviceRevoked;
  FutureOr<void> Function()? onSessionExpired;

  bool _running = false;
  bool _suppressDisconnectNotify = false;
  int _generation = 0;
  http.Client? _activeHttpClient;
  Completer<void>? _waitInterrupt;
  Timer? _backoffTimer;

  bool get isRunning => _running;

  /// Starts the persistent background SSE loop with exponential backoff reconnect.
  void start() {
    if (_running) return;
    _suppressDisconnectNotify = false;
    _running = true;
    final gen = ++_generation;
    unawaited(_runLoop(gen));
  }

  /// Interrupts any pending backoff sleep and reconnects immediately (e.g., on Wi-Fi recovery).
  void reconnectNow() {
    if (!_running) return;
    _backoffTimer?.cancel();
    _backoffTimer = null;
    _activeHttpClient?.close();
    _activeHttpClient = null;
    final w = _waitInterrupt;
    if (w != null && !w.isCompleted) {
      w.complete();
    }
  }

  /// Stops listening and closes any live SSE socket cleanly.
  Future<void> stop({bool notify = true}) async {
    _suppressDisconnectNotify = !notify;
    _running = false;
    _generation++;
    _backoffTimer?.cancel();
    _backoffTimer = null;
    _activeHttpClient?.close();
    _activeHttpClient = null;
    final w = _waitInterrupt;
    if (w != null && !w.isCompleted) {
      w.complete();
    }
    if (notify) {
      onConnectedChanged?.call(false);
    }
  }

  Future<void> _runLoop(int gen) async {
    var backoffMs = initialBackoff.inMilliseconds.clamp(50, 30000);
    final maxMs = max(backoffMs, maxBackoff.inMilliseconds);

    while (_running && gen == _generation) {
      final token = _getAccessToken();
      if (token == null || token.isEmpty) {
        break;
      }

      var resetBackoff = false;
      try {
        resetBackoff = await _connectOnce(gen, token);
      } on _FatalSseStopException {
        break;
      } catch (_) {
        // Transient stream drop or network outage -> retry with exponential backoff.
      } finally {
        if (!_suppressDisconnectNotify && gen == _generation) {
          onConnectedChanged?.call(false);
        }
        _activeHttpClient?.close();
        _activeHttpClient = null;
      }

      if (!_running || gen != _generation) break;
      if (resetBackoff) {
        backoffMs = initialBackoff.inMilliseconds.clamp(50, 30000);
      }

      final interrupt = Completer<void>();
      _waitInterrupt = interrupt;
      _backoffTimer = Timer(Duration(milliseconds: backoffMs), () {
        if (!interrupt.isCompleted) {
          interrupt.complete();
        }
      });
      await interrupt.future;
      _backoffTimer?.cancel();
      _backoffTimer = null;
      if (identical(_waitInterrupt, interrupt)) {
        _waitInterrupt = null;
      }
      backoffMs = min(backoffMs * 2, maxMs);
    }
  }

  /// Opens one SSE connection and processes frames until closed or aborted.
  /// Returns `true` if `CONNECTED` was observed (so backoff resets cleanly).
  Future<bool> _connectOnce(int gen, String token) async {
    final config = _getConfig();
    final uri = config.resolve('/api/sync/events');
    final client = _clientFactory();
    _activeHttpClient = client;

    final req = http.Request('GET', uri)
      ..headers['Accept'] = 'text/event-stream'
      ..headers['Cache-Control'] = 'no-cache'
      ..headers['Authorization'] = 'Bearer $token';

    final streamed = await client.send(req).timeout(config.sseConnectTimeout);

    if (streamed.statusCode != 200) {
      final rawBody = await streamed.stream.bytesToString();
      Map<String, dynamic>? decoded;
      try {
        final obj = jsonDecode(rawBody);
        if (obj is Map<String, dynamic>) decoded = obj;
      } catch (_) {}

      final err = PasalApiClient.parseApiError(
        statusCode: streamed.statusCode,
        headers: streamed.headers,
        decodedBody: decoded,
        rawBody: rawBody,
      );

      if (err.isDeviceRevoked) {
        _running = false;
        if (onDeviceRevoked != null) {
          await onDeviceRevoked!(err.message);
        }
        throw const _FatalSseStopException();
      }
      if (err.isAuthInvalidated) {
        _running = false;
        if (onSessionExpired != null) {
          await onSessionExpired!();
        }
        throw const _FatalSseStopException();
      }
      throw err;
    }

    var connectedObserved = false;
    var currentEvent = '';
    final dataLines = <String>[];

    Future<void> dispatchFrame() async {
      if (currentEvent.isEmpty && dataLines.isEmpty) {
        return;
      }
      final ev = currentEvent.isEmpty ? 'message' : currentEvent;
      final data = dataLines.join('\n');
      currentEvent = '';
      dataLines.clear();

      if (!_running || gen != _generation) return;

      switch (ev) {
        case 'CONNECTED':
          connectedObserved = true;
          onConnectedChanged?.call(true);
          break;
        case 'DATA_CHANGED':
          SseDataChangedEvent parsed = SseDataChangedEvent(
            originDeviceCode: '',
            serverTime: DateTime.now().toUtc(),
          );
          if (data.trim().isNotEmpty) {
            try {
              parsed = SseDataChangedEvent.fromJson(
                jsonDecode(data) as Map<String, dynamic>,
              );
            } catch (_) {}
          }
          if (onDataChanged != null) {
            await onDataChanged!(parsed);
          }
          break;
        case 'DEVICE_REVOKED':
          String reason = 'Device revoked by store owner.';
          if (data.trim().isNotEmpty) {
            try {
              final map = jsonDecode(data) as Map<String, dynamic>;
              final msg = (map['message'] ?? map['reason'] ?? '').toString().trim();
              if (msg.isNotEmpty) reason = msg;
            } catch (_) {}
          }
          _running = false;
          if (onDeviceRevoked != null) {
            await onDeviceRevoked!(reason);
          }
          throw const _FatalSseStopException();
        case 'SESSION_EXPIRED':
          _running = false;
          if (onSessionExpired != null) {
            await onSessionExpired!();
          }
          throw const _FatalSseStopException();
        default:
          break;
      }
    }

    final lines = streamed.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      if (!_running || gen != _generation) break;
      if (line.isEmpty) {
        await dispatchFrame();
        continue;
      }
      if (line.startsWith(':')) {
        // SSE comment / keepalive ping.
        continue;
      }
      if (line.startsWith('event:')) {
        currentEvent = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        var val = line.substring(5);
        if (val.startsWith(' ')) val = val.substring(1);
        dataLines.add(val);
      }
    }
    if (currentEvent.isNotEmpty || dataLines.isNotEmpty) {
      await dispatchFrame();
    }
    return connectedObserved;
  }
}

class _FatalSseStopException implements Exception {
  const _FatalSseStopException();
}
