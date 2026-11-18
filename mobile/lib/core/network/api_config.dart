import 'package:flutter/foundation.dart';

/// Configuration for the PasalX Cloud Sync & Auth Go API.
@immutable
class ApiConfig {
  const ApiConfig({
    this.baseUrl = defaultBaseUrl,
    this.requestTimeout = const Duration(seconds: 10),
    this.sseConnectTimeout = const Duration(seconds: 15),
  });

  /// Default API base URL (localhost for desktop/loopback; configurable to
  /// `http://10.0.2.2:8080` or the shop's GCP Cloud Run / VM HTTPS endpoint).
  static const String defaultBaseUrl = 'http://127.0.0.1:8080';

  final String baseUrl;
  final Duration requestTimeout;
  final Duration sseConnectTimeout;

  Uri resolve(String path, [Map<String, String>? queryParameters]) {
    final trimmedBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$trimmedBase$normalizedPath');
    if (queryParameters == null || queryParameters.isEmpty) {
      return uri;
    }
    return uri.replace(queryParameters: queryParameters);
  }

  ApiConfig copyWith({
    String? baseUrl,
    Duration? requestTimeout,
    Duration? sseConnectTimeout,
  }) {
    return ApiConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      requestTimeout: requestTimeout ?? this.requestTimeout,
      sseConnectTimeout: sseConnectTimeout ?? this.sseConnectTimeout,
    );
  }
}

