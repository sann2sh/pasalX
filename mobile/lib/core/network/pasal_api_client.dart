import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_config.dart';
import 'api_exceptions.dart';
import 'auth_models.dart';
import 'sync_models.dart';

/// HTTP client for all Step 3 Auth & Step 4 Sync Go backend endpoints.
///
/// Automatically inspects every error response (including `WWW-Authenticate`
/// headers on `401`) and invokes [onDeviceRevoked] immediately if the server
/// reports `DEVICE_REVOKED`.
class PasalApiClient {
  PasalApiClient({
    ApiConfig? config,
    ApiConfig Function()? getConfig,
    http.Client? httpClient,
    this.onDeviceRevoked,
  })  : _getConfig = getConfig ??
            (() => config ?? (throw ArgumentError('config or getConfig required'))),
        _client = httpClient ?? http.Client();

  final ApiConfig Function() _getConfig;
  final http.Client _client;

  ApiConfig get config => _getConfig();

  /// Callback invoked synchronously when any HTTP response returns `401 DEVICE_REVOKED`.
  FutureOr<void> Function(String message)? onDeviceRevoked;

  /// Enrolls a shop terminal (`POST /api/auth/devices/register`, OWNER credentials required).
  Future<RegisteredDevice> registerDevice({
    required String ownerUsername,
    required String ownerPassword,
    required String deviceName,
    String platform = 'ANDROID',
  }) async {
    final json = await _sendJson(
      method: 'POST',
      path: '/api/auth/devices/register',
      body: <String, dynamic>{
        'owner_username': ownerUsername.trim(),
        'owner_password': ownerPassword,
        'device_name': deviceName.trim(),
        'platform': platform.toUpperCase().trim(),
      },
    );
    return RegisteredDevice.fromJson(json['device'] as Map<String, dynamic>);
  }

  /// Authenticates a staff member or owner with either [pin] (6 digits) or [password].
  Future<AuthLoginResponse> login({
    required String username,
    required String deviceId,
    String? pin,
    String? password,
  }) async {
    final trimmedUser = username.trim();
    if (trimmedUser.isEmpty) {
      throw const ApiException(
        statusCode: 400,
        code: 'BAD_REQUEST',
        message: 'Username is required.',
      );
    }
    final hasPin = pin != null && pin.isNotEmpty;
    final hasPassword = password != null && password.isNotEmpty;
    if (hasPin == hasPassword) {
      throw const ApiException(
        statusCode: 400,
        code: 'BAD_REQUEST',
        message: 'Provide either a 6-digit PIN or password.',
      );
    }
    final body = <String, dynamic>{
      'username': trimmedUser,
      'device_id': deviceId.trim(),
      if (hasPin) 'pin': pin else 'password': password,
    };
    final json = await _sendJson(
      method: 'POST',
      path: '/api/auth/login',
      body: body,
    );
    return AuthLoginResponse.fromJson(json);
  }

  /// Re-issues JWT & wrapped DEK under the active 12h lease without extending TTL.
  Future<AuthLoginResponse> refresh({required String accessToken}) async {
    final json = await _sendJson(
      method: 'POST',
      path: '/api/auth/refresh',
      accessToken: accessToken,
    );
    return AuthLoginResponse.fromJson(json);
  }

  /// Ends the active server lease (`POST /api/auth/logout`).
  Future<void> logout({required String accessToken}) async {
    await _sendJson(
      method: 'POST',
      path: '/api/auth/logout',
      accessToken: accessToken,
    );
  }

  /// Lightweight kill-switch & lease check (`GET /api/auth/heartbeat`).
  Future<HeartbeatResponse> heartbeat({required String accessToken}) async {
    final json = await _sendJson(
      method: 'GET',
      path: '/api/auth/heartbeat',
      accessToken: accessToken,
    );
    return HeartbeatResponse.fromJson(json);
  }

  /// Lists registered devices (OWNER only, `GET /api/auth/devices`).
  Future<List<RegisteredDevice>> listDevices({required String accessToken}) async {
    final json = await _sendJson(
      method: 'GET',
      path: '/api/auth/devices',
      accessToken: accessToken,
    );
    final raw = json['devices'] as List<dynamic>? ?? const [];
    return raw
        .map((e) => RegisteredDevice.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Remote Kill-Switch (OWNER only, `POST /api/auth/revoke`).
  Future<RegisteredDevice> revokeDevice({
    required String accessToken,
    String? deviceId,
    String? deviceCode,
    required String reason,
  }) async {
    final body = <String, dynamic>{
      'reason': reason,
      if (deviceId != null && deviceId.trim().isNotEmpty)
        'device_id': deviceId.trim(),
      if (deviceCode != null && deviceCode.trim().isNotEmpty)
        'device_code': deviceCode.trim(),
    };
    final json = await _sendJson(
      method: 'POST',
      path: '/api/auth/revoke',
      accessToken: accessToken,
      body: body,
    );
    return RegisteredDevice.fromJson(json['device'] as Map<String, dynamic>);
  }

  /// Pushes up to 50 idempotent outbox mutations (`POST /api/sync/push`).
  Future<SyncPushResult> pushMutations({
    required String accessToken,
    required List<OutboxMutationPayload> mutations,
  }) async {
    final json = await _sendJson(
      method: 'POST',
      path: '/api/sync/push',
      accessToken: accessToken,
      body: <String, dynamic>{
        'mutations': mutations.map((m) => m.toJson()).toList(),
      },
    );
    return SyncPushResult.fromJson(json);
  }

  /// Pulls microsecond cursor changes (`GET /api/sync/pull`).
  Future<SyncPullResult> pullChanges({
    required String accessToken,
    DateTime? since,
    int limit = 500,
  }) async {
    final query = <String, String>{
      'limit': limit.toString(),
      if (since != null) 'since': since.toUtc().toIso8601String(),
    };
    final json = await _sendJson(
      method: 'GET',
      path: '/api/sync/pull',
      queryParameters: query,
      accessToken: accessToken,
    );
    return SyncPullResult.fromJson(json);
  }

  Future<Map<String, dynamic>> _sendJson({
    required String method,
    required String path,
    Map<String, String>? queryParameters,
    String? accessToken,
    Map<String, dynamic>? body,
  }) async {
    final uri = config.resolve(path, queryParameters);
    final headers = <String, String>{
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
      if (accessToken != null && accessToken.isNotEmpty)
        'Authorization': 'Bearer $accessToken',
    };

    late final http.Response response;
    try {
      final Future<http.Response> requestFuture;
      switch (method) {
        case 'GET':
          requestFuture = _client.get(uri, headers: headers);
          break;
        case 'POST':
          requestFuture = _client.post(
            uri,
            headers: headers,
            body: body == null ? null : jsonEncode(body),
          );
          break;
        default:
          throw ArgumentError.value(method, 'method', 'Unsupported HTTP method');
      }
      response = await requestFuture.timeout(config.requestTimeout);
    } on TimeoutException catch (e) {
      throw ApiException(
        statusCode: 0,
        code: 'TIMEOUT',
        message: 'Server request timed out: ${e.message ?? path}',
      );
    } on SocketException catch (e) {
      throw ApiException(
        statusCode: 0,
        code: 'NETWORK_ERROR',
        message: 'Network unreachable: ${e.message}',
      );
    } on http.ClientException catch (e) {
      throw ApiException(
        statusCode: 0,
        code: 'NETWORK_ERROR',
        message: 'HTTP connection failed: ${e.message}',
      );
    }

    final decoded = _decodeJsonMap(response.body);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded ?? <String, dynamic>{};
    }

    final apiErr = parseApiError(
      statusCode: response.statusCode,
      headers: response.headers,
      decodedBody: decoded,
      rawBody: response.body,
    );
    if (apiErr.isDeviceRevoked && onDeviceRevoked != null) {
      await onDeviceRevoked!(apiErr.message);
    }
    throw apiErr;
  }

  /// Parses Go error payloads and `WWW-Authenticate: Bearer error="DEVICE_REVOKED"`.
  static ApiException parseApiError({
    required int statusCode,
    required Map<String, String> headers,
    Map<String, dynamic>? decodedBody,
    String rawBody = '',
  }) {
    String? code = decodedBody?['error'] as String?;
    String? message = decodedBody?['message'] as String?;

    final wwwAuth = headers['www-authenticate'] ?? headers['WWW-Authenticate'];
    if ((code == null || code.isEmpty) && wwwAuth != null) {
      final match = RegExp(r'error="([^"]+)"').firstMatch(wwwAuth);
      if (match != null) {
        code = match.group(1);
      }
    }

    final retryAfterRaw = headers['retry-after'] ?? headers['Retry-After'];
    final retryAfter = retryAfterRaw == null ? null : int.tryParse(retryAfterRaw);

    return ApiException(
      statusCode: statusCode,
      code: (code != null && code.isNotEmpty) ? code : 'HTTP_$statusCode',
      message: (message != null && message.isNotEmpty)
          ? message
          : (rawBody.trim().isNotEmpty ? rawBody.trim() : 'HTTP $statusCode'),
      retryAfterSeconds: retryAfter,
    );
  }

  static Map<String, dynamic>? _decodeJsonMap(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return null;
    try {
      final parsed = jsonDecode(trimmed);
      if (parsed is Map<String, dynamic>) {
        return parsed;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
