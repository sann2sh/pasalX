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
      role: (json['role'] as String?) ?? '',
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
    this.storeId,
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
      storeId: json['store_id'] as String?,
      code: (json['code'] as String?) ?? '',
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
  final String? storeId;
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

/// Response from `POST /api/auth/signup`.
@immutable
class SignupResult {
  const SignupResult({
    required this.user,
    required this.verificationRequired,
  });

  factory SignupResult.fromJson(Map<String, dynamic> json) {
    return SignupResult(
      user: AuthUser.fromJson(json['user'] as Map<String, dynamic>),
      verificationRequired: json['verification_required'] as bool? ?? true,
    );
  }

  final AuthUser user;
  final bool verificationRequired;
}

/// Active store membership summary returned inside [AccountLoginResult].
@immutable
class StoreSummary {
  const StoreSummary({
    required this.storeId,
    required this.storeName,
    required this.role,
    required this.storeStatus,
  });

  factory StoreSummary.fromJson(Map<String, dynamic> json) {
    return StoreSummary(
      storeId: json['store_id'] as String,
      storeName: json['store_name'] as String,
      role: json['role'] as String,
      storeStatus: json['store_status'] as String,
    );
  }

  final String storeId;
  final String storeName;
  final String role;
  final String storeStatus;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'store_id': storeId,
        'store_name': storeName,
        'role': role,
        'store_status': storeStatus,
      };
}

/// Response from `POST /api/auth/account-login` (Account JWT, `aud=pasalx-account`).
@immutable
class AccountLoginResult {
  const AccountLoginResult({
    required this.accessToken,
    required this.tokenType,
    required this.expiresAt,
    required this.user,
    this.membership,
  });

  factory AccountLoginResult.fromJson(Map<String, dynamic> json) {
    return AccountLoginResult(
      accessToken: json['access_token'] as String,
      tokenType: json['token_type'] as String? ?? 'Bearer',
      expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
      user: AuthUser.fromJson(json['user'] as Map<String, dynamic>),
      membership: json['membership'] == null
          ? null
          : StoreSummary.fromJson(json['membership'] as Map<String, dynamic>),
    );
  }

  final String accessToken;
  final String tokenType;
  final DateTime expiresAt;
  final AuthUser user;
  final StoreSummary? membership;
}

/// Store profile returned by `/api/stores/current` and `POST /api/stores`.
@immutable
class StoreInfo {
  const StoreInfo({
    required this.id,
    required this.name,
    this.panNumber,
    this.phone,
    this.address,
    required this.status,
    this.closedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  factory StoreInfo.fromJson(Map<String, dynamic> json) {
    return StoreInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      panNumber: json['pan_number'] as String?,
      phone: json['phone'] as String?,
      address: json['address'] as String?,
      status: json['status'] as String,
      closedAt: _parseNullableDateTime(json['closed_at']),
      createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updated_at'] as String).toUtc(),
    );
  }

  final String id;
  final String name;
  final String? panNumber;
  final String? phone;
  final String? address;
  final String status;
  final DateTime? closedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// Response from `POST /api/stores` (creates store + enrolls device `01` + issues lease).
@immutable
class CreateStoreResult {
  const CreateStoreResult({
    required this.store,
    required this.accessToken,
    required this.tokenType,
    required this.expiresAt,
    required this.user,
    required this.device,
    required this.lease,
  });

  factory CreateStoreResult.fromJson(Map<String, dynamic> json) {
    return CreateStoreResult(
      store: StoreInfo.fromJson(json['store'] as Map<String, dynamic>),
      accessToken: json['access_token'] as String,
      tokenType: json['token_type'] as String? ?? 'Bearer',
      expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
      user: AuthUser.fromJson(json['user'] as Map<String, dynamic>),
      device: RegisteredDevice.fromJson(json['device'] as Map<String, dynamic>),
      lease: AuthLeasePayload.fromJson(json['lease'] as Map<String, dynamic>),
    );
  }

  final StoreInfo store;
  final String accessToken;
  final String tokenType;
  final DateTime expiresAt;
  final AuthUser user;
  final RegisteredDevice device;
  final AuthLeasePayload lease;

  AuthLoginResponse toAuthLoginResponse() => AuthLoginResponse(
        accessToken: accessToken,
        tokenType: tokenType,
        expiresAt: expiresAt,
        user: user,
        device: device,
        lease: lease,
      );
}

/// Invitation metadata returned by `/api/stores/current/invitations`.
@immutable
class InvitationInfo {
  const InvitationInfo({
    required this.id,
    required this.storeId,
    required this.role,
    this.invitedEmail,
    required this.status,
    required this.expiresAt,
    required this.createdAt,
    this.code,
  });

  factory InvitationInfo.fromJson(Map<String, dynamic> json) {
    return InvitationInfo(
      id: json['id'] as String,
      storeId: json['store_id'] as String,
      role: json['role'] as String,
      invitedEmail: json['invited_email'] as String?,
      status: json['status'] as String,
      expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
      createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
      code: json['code'] as String?,
    );
  }

  final String id;
  final String storeId;
  final String role;
  final String? invitedEmail;
  final String status;
  final DateTime expiresAt;
  final DateTime createdAt;
  final String? code;
}

/// Pending/active/rejected device status returned by `acceptInvitation`,
/// `enrollDevice`, and `GET /api/devices/me/status`.
@immutable
class DeviceStatusResult {
  const DeviceStatusResult({
    required this.deviceId,
    this.deviceCode,
    required this.deviceName,
    required this.platform,
    required this.status,
    required this.storeId,
    required this.storeName,
    required this.role,
    this.revocationReason,
  });

  factory DeviceStatusResult.fromJson(Map<String, dynamic> json) {
    return DeviceStatusResult(
      deviceId: json['device_id'] as String,
      deviceCode: json['device_code'] as String?,
      deviceName: json['device_name'] as String,
      platform: json['platform'] as String,
      status: json['status'] as String,
      storeId: json['store_id'] as String,
      storeName: json['store_name'] as String,
      role: json['role'] as String,
      revocationReason: json['revocation_reason'] as String?,
    );
  }

  final String deviceId;
  final String? deviceCode;
  final String deviceName;
  final String platform;
  final String status;
  final String storeId;
  final String storeName;
  final String role;
  final String? revocationReason;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'device_id': deviceId,
        if (deviceCode != null) 'device_code': deviceCode,
        'device_name': deviceName,
        'platform': platform,
        'status': status,
        'store_id': storeId,
        'store_name': storeName,
        'role': role,
        if (revocationReason != null) 'revocation_reason': revocationReason,
      };
}

/// Team member returned by `GET /api/stores/current/members`.
@immutable
class MemberInfo {
  const MemberInfo({
    required this.userId,
    required this.name,
    required this.username,
    this.email,
    required this.role,
    required this.status,
    required this.joinedAt,
  });

  factory MemberInfo.fromJson(Map<String, dynamic> json) {
    return MemberInfo(
      userId: json['user_id'] as String,
      name: json['name'] as String,
      username: json['username'] as String,
      email: json['email'] as String?,
      role: json['role'] as String,
      status: json['status'] as String,
      joinedAt: DateTime.parse(json['joined_at'] as String).toUtc(),
    );
  }

  final String userId;
  final String name;
  final String username;
  final String? email;
  final String role;
  final String status;
  final DateTime joinedAt;
}

/// Decodes unverified JWT claims locally so the client can inspect `sid` / `aud`
/// for store-isolation mismatch checks (`M3`) without leaking secrets.
abstract final class JwtPayloadHelper {
  static Map<String, dynamic>? decodeClaims(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final normalized = base64Url.normalize(parts[1]);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final parsed = jsonDecode(decoded);
      if (parsed is Map<String, dynamic>) {
        return parsed;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static String? readStoreId(String jwt) {
    final claims = decodeClaims(jwt);
    final sid = claims?['sid'] as String?;
    if (sid == null || sid.trim().isEmpty) return null;
    return sid.trim();
  }
}
