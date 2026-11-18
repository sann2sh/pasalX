import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../network/auth_models.dart';
import 'keystore_dek_manager.dart';

/// Enrolled terminal metadata stored inside secure Keystore/Keychain storage.
@immutable
class EnrolledDeviceInfo {
  const EnrolledDeviceInfo({
    required this.deviceId,
    this.storeId,
    required this.deviceCode,
    required this.deviceName,
    required this.platform,
    this.lastUsername,
    this.isRevoked = false,
    this.revocationMessage,
  });

  factory EnrolledDeviceInfo.fromJson(Map<String, dynamic> json) {
    return EnrolledDeviceInfo(
      deviceId: json['device_id'] as String,
      storeId: json['store_id'] as String?,
      deviceCode: json['device_code'] as String,
      deviceName: json['device_name'] as String,
      platform: json['platform'] as String,
      lastUsername: json['last_username'] as String?,
      isRevoked: json['is_revoked'] as bool? ?? false,
      revocationMessage: json['revocation_message'] as String?,
    );
  }

  final String deviceId;
  final String? storeId;
  final String deviceCode;
  final String deviceName;
  final String platform;
  final String? lastUsername;
  final bool isRevoked;
  final String? revocationMessage;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'device_id': deviceId,
        if (storeId != null && storeId!.isNotEmpty) 'store_id': storeId,
        'device_code': deviceCode,
        'device_name': deviceName,
        'platform': platform,
        if (lastUsername != null && lastUsername!.isNotEmpty)
          'last_username': lastUsername,
        'is_revoked': isRevoked,
        if (revocationMessage != null) 'revocation_message': revocationMessage,
      };

  EnrolledDeviceInfo copyWith({
    String? storeId,
    String? lastUsername,
    bool? isRevoked,
    String? revocationMessage,
  }) {
    return EnrolledDeviceInfo(
      deviceId: deviceId,
      storeId: storeId ?? this.storeId,
      deviceCode: deviceCode,
      deviceName: deviceName,
      platform: platform,
      lastUsername: lastUsername ?? this.lastUsername,
      isRevoked: isRevoked ?? this.isRevoked,
      revocationMessage: revocationMessage ?? this.revocationMessage,
    );
  }
}

/// Persisted Account JWT session (`aud=pasalx-account`, short 15m TTL),
/// strictly separated from [PersistedAuthSession] (Device JWT).
@immutable
class PersistedAccountSession {
  const PersistedAccountSession({
    required this.accessToken,
    required this.userId,
    required this.name,
    required this.username,
    required this.expiresAt,
    this.membership,
  });

  factory PersistedAccountSession.fromJson(Map<String, dynamic> json) {
    return PersistedAccountSession(
      accessToken: json['access_token'] as String,
      userId: json['user_id'] as String,
      name: json['name'] as String,
      username: json['username'] as String,
      expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
      membership: json['membership'] == null
          ? null
          : StoreSummary.fromJson(json['membership'] as Map<String, dynamic>),
    );
  }

  final String accessToken;
  final String userId;
  final String name;
  final String username;
  final DateTime expiresAt;
  final StoreSummary? membership;

  bool get isExpired => !DateTime.now().toUtc().isBefore(expiresAt);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'access_token': accessToken,
        'user_id': userId,
        'name': name,
        'username': username,
        'expires_at': expiresAt.toUtc().toIso8601String(),
        if (membership != null) 'membership': membership!.toJson(),
      };
}

/// Persisted JWT access token + non-secret session metadata inside secure storage.
/// Plaintext DEK, KEK, PIN, and passwords are NEVER stored here.
@immutable
class PersistedAuthSession {
  const PersistedAuthSession({
    required this.accessToken,
    required this.userId,
    required this.username,
    required this.displayName,
    required this.role,
    required this.deviceId,
    required this.deviceCode,
    required this.leaseId,
    required this.expiresAt,
  });

  factory PersistedAuthSession.fromJson(Map<String, dynamic> json) {
    return PersistedAuthSession(
      accessToken: json['access_token'] as String,
      userId: json['user_id'] as String,
      username: json['username'] as String,
      displayName: json['display_name'] as String,
      role: json['role'] as String,
      deviceId: json['device_id'] as String,
      deviceCode: json['device_code'] as String,
      leaseId: json['lease_id'] as String,
      expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
    );
  }

  final String accessToken;
  final String userId;
  final String username;
  final String displayName;
  final String role;
  final String deviceId;
  final String deviceCode;
  final String leaseId;
  final DateTime expiresAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'access_token': accessToken,
        'user_id': userId,
        'username': username,
        'display_name': displayName,
        'role': role,
        'device_id': deviceId,
        'device_code': deviceCode,
        'lease_id': leaseId,
        'expires_at': expiresAt.toUtc().toIso8601String(),
      };
}

/// Hardware Keystore / Secure Storage persistence for terminal enrollment,
/// active JWT bearer token, and server base URL.
class DeviceCredentialsStore {
  DeviceCredentialsStore({required SecureKeyValueStore store})
      // ignore: prefer_initializing_formals
      : _store = store;

  static const String _deviceKey = 'pasalx.auth.enrolled_device.v1';
  static const String _sessionKey = 'pasalx.auth.session_token.v1';
  static const String _accountSessionKey = 'pasalx.auth.account_session.v1';
  static const String _pendingEnrollmentKey = 'pasalx.auth.pending_enrollment.v1';
  static const String _serverUrlKey = 'pasalx.auth.server_url.v1';

  final SecureKeyValueStore _store;

  Future<EnrolledDeviceInfo?> readDevice() async {
    final raw = await _store.read(_deviceKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return EnrolledDeviceInfo.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> saveDevice(EnrolledDeviceInfo device) async {
    await _store.write(_deviceKey, jsonEncode(device.toJson()));
  }

  Future<void> markDeviceRevoked({String? message}) async {
    final existing = await readDevice();
    if (existing != null) {
      await saveDevice(
        existing.copyWith(
          isRevoked: true,
          revocationMessage:
              message ?? 'This device has been revoked by the owner.',
        ),
      );
    }
  }

  Future<void> clearDevice() async {
    await _store.delete(_deviceKey);
  }

  Future<PersistedAuthSession?> readSession() async {
    final raw = await _store.read(_sessionKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return PersistedAuthSession.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      await clearSession();
      return null;
    }
  }

  Future<void> saveSession(PersistedAuthSession session) async {
    await _store.write(_sessionKey, jsonEncode(session.toJson()));
  }

  Future<void> clearSession() async {
    await _store.delete(_sessionKey);
  }

  Future<String?> readServerUrl() async {
    final raw = await _store.read(_serverUrlKey);
    if (raw == null || raw.trim().isEmpty) return null;
    return raw.trim();
  }

  Future<void> saveServerUrl(String url) async {
    await _store.write(_serverUrlKey, url.trim());
  }

  Future<PersistedAccountSession?> readAccountSession() async {
    final raw = await _store.read(_accountSessionKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final parsed = PersistedAccountSession.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (parsed.isExpired) {
        await clearAccountSession();
        return null;
      }
      return parsed;
    } catch (_) {
      await clearAccountSession();
      return null;
    }
  }

  Future<void> saveAccountSession(PersistedAccountSession session) async {
    await _store.write(_accountSessionKey, jsonEncode(session.toJson()));
  }

  Future<void> clearAccountSession() async {
    await _store.delete(_accountSessionKey);
  }

  Future<DeviceStatusResult?> readPendingEnrollment() async {
    final raw = await _store.read(_pendingEnrollmentKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return DeviceStatusResult.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      await clearPendingEnrollment();
      return null;
    }
  }

  Future<void> savePendingEnrollment(DeviceStatusResult status) async {
    await _store.write(_pendingEnrollmentKey, jsonEncode(status.toJson()));
  }

  Future<void> clearPendingEnrollment() async {
    await _store.delete(_pendingEnrollmentKey);
  }
}
