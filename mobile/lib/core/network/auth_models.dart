import 'dart:convert';

import 'package:flutter/foundation.dart';

/// User profile returned by `POST /api/auth/login` or `/api/auth/refresh`.
@immutable
class AuthUser {
  const AuthUser({
    required this.id,
    required this.name,
    required this.username,
    required this.role,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      id: json['id'] as String,
      name: json['name'] as String,
      username: json['username'] as String,
      role: json['role'] as String,
    );
  }

  final String id;
  final String name;
  final String username;
  final String role;
}

/// Device registration metadata returned by Go `/api/auth/devices*`.
@immutable
class RegisteredDevice {
  const RegisteredDevice({
    required this.id,
    required this.code,
    required this.name,
    required this.platform,
    required this.status,
    this.currentUserId,
    this.currentUserName,
    this.leaseExpiresAt,
    this.revokedAt,
    this.revocationReason,
  });

  factory RegisteredDevice.fromJson(Map<String, dynamic> json) {
    return RegisteredDevice(
      id: json['id'] as String,
      code: json['code'] as String,
      name: json['name'] as String,
      platform: json['platform'] as String,
      status: json['status'] as String,
      currentUserId: json['current_user_id'] as String?,
      currentUserName: json['current_user_name'] as String?,
      leaseExpiresAt: _parseNullableDateTime(json['lease_expires_at']),
      revokedAt: _parseNullableDateTime(json['revoked_at']),
      revocationReason: json['revocation_reason'] as String?,
    );
  }

  final String id;
  final String code;
  final String name;
  final String platform;
  final String status;
  final String? currentUserId;
  final String? currentUserName;
  final DateTime? leaseExpiresAt;
  final DateTime? revokedAt;
  final String? revocationReason;
}

/// 12-hour cryptographic KEK + 64-byte `PX\x01\x00` DEK envelope issued by Go.
@immutable
class AuthLeasePayload {
  const AuthLeasePayload({
    required this.leaseId,
    required this.issuedAt,
    required this.expiresAt,
    required this.expiresUnix,
    required this.ttlSeconds,
    required this.kekBytes,
    required this.envelopeBytes,
    required this.envelopeVersion,
  });

  factory AuthLeasePayload.fromJson(Map<String, dynamic> json) {
    return AuthLeasePayload(
      leaseId: json['lease_id'] as String,
      issuedAt: DateTime.parse(json['issued_at'] as String).toUtc(),
      expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
      expiresUnix: (json['expires_unix'] as num).toInt(),
      ttlSeconds: (json['ttl_seconds'] as num).toInt(),
      kekBytes: Uint8List.fromList(base64Decode(json['kek_b64'] as String)),
      envelopeBytes:
          Uint8List.fromList(base64Decode(json['envelope_b64'] as String)),
      envelopeVersion: (json['envelope_version'] as num).toInt(),
    );
  }

  final String leaseId;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final int expiresUnix;
  final int ttlSeconds;
  final Uint8List kekBytes;
  final Uint8List envelopeBytes;
  final int envelopeVersion;
}

/// Response from `POST /api/auth/login` or `POST /api/auth/refresh`.
@immutable
class AuthLoginResponse {
  const AuthLoginResponse({
    required this.accessToken,
    required this.tokenType,
    required this.expiresAt,
    required this.user,
    required this.device,
    required this.lease,
  });

  factory AuthLoginResponse.fromJson(Map<String, dynamic> json) {
    return AuthLoginResponse(
      accessToken: json['access_token'] as String,
      tokenType: json['token_type'] as String? ?? 'Bearer',
      expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
      user: AuthUser.fromJson(json['user'] as Map<String, dynamic>),
      device: RegisteredDevice.fromJson(json['device'] as Map<String, dynamic>),
      lease: AuthLeasePayload.fromJson(json['lease'] as Map<String, dynamic>),
    );
  }

  final String accessToken;
  final String tokenType;
  final DateTime expiresAt;
  final AuthUser user;
  final RegisteredDevice device;
  final AuthLeasePayload lease;
}

/// Response from `GET /api/auth/heartbeat`.
@immutable
class HeartbeatResponse {
  const HeartbeatResponse({
    required this.status,
    required this.deviceCode,
    required this.role,
    required this.leaseExpiresAt,
    required this.serverTime,
  });

  factory HeartbeatResponse.fromJson(Map<String, dynamic> json) {
    return HeartbeatResponse(
      status: json['status'] as String,
      deviceCode: json['device_code'] as String,
      role: json['role'] as String,
      leaseExpiresAt:
          DateTime.parse(json['lease_expires_at'] as String).toUtc(),
      serverTime: DateTime.parse(json['server_time'] as String).toUtc(),
    );
  }

  final String status;
  final String deviceCode;
  final String role;
  final DateTime leaseExpiresAt;
  final DateTime serverTime;
}

DateTime? _parseNullableDateTime(Object? raw) {
  if (raw == null) return null;
  final text = raw.toString().trim();
  if (text.isEmpty) return null;
  return DateTime.parse(text).toUtc();
}
