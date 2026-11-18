import 'package:flutter/foundation.dart';

/// Configuration for the PasalX Cloud Sync & Auth Go API.
@immutable
class ApiConfig {
  const ApiConfig({
    this.baseUrl = defaultBaseUrl,
    this.requestTimeout = const Duration(seconds: 10),
    this.sseConnectTimeout = const Duration(seconds: 15),
  });

  /// Default API base URL configurable at build time via
  /// `--dart-define=PASALX_API_URL=...`, defaulting to the live production host.
  static const String defaultBaseUrl = String.fromEnvironment(
    'PASALX_API_URL',
    defaultValue: 'https://pasalx.skisub.com',
  );

  /// Validates [url] as an API base URL. In release builds (`kReleaseMode`),
  /// non-HTTPS URLs are rejected to prevent cleartext credential/data leakage.
  static bool isValidBaseUrl(String url, {bool? requireHttps}) {
    final trimmed = url.trim();
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null || parsed.host.isEmpty) {
      return false;
    }
    final enforceHttps = requireHttps ?? kReleaseMode;
    if (enforceHttps) {
      return parsed.isScheme('https');
    }
    return parsed.isScheme('http') || parsed.isScheme('https');
  }

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

