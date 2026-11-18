/// Machine-readable exception emitted by [PasalApiClient] mirroring
/// `server/internal/auth/service.go` and `server/internal/sync/types.go`.
class ApiException implements Exception {
  const ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.retryAfterSeconds,
  });

  final int statusCode;
  final String code;
  final String message;
  final int? retryAfterSeconds;

  bool get isDeviceRevoked => code == 'DEVICE_REVOKED';

  bool get isAuthInvalidated =>
      code == 'DEVICE_REVOKED' ||
      code == 'SESSION_ENDED' ||
      code == 'TOKEN_EXPIRED' ||
      code == 'TOKEN_INVALID' ||
      code == 'TOKEN_MISSING' ||
      code == 'DEVICE_NOT_ACTIVE' ||
      code == 'DEVICE_NOT_REGISTERED' ||
      code == 'USER_DISABLED';

  bool get isPermanentSyncRejection =>
      statusCode == 400 ||
      statusCode == 403 ||
      statusCode == 409 ||
      statusCode == 413 ||
      statusCode == 422;

  bool get isRetryable =>
      statusCode == 0 || statusCode == 408 || statusCode == 429 || statusCode >= 500;

  @override
  String toString() => 'ApiException($statusCode, $code): $message';
}

