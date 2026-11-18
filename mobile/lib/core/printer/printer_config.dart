import 'package:flutter/foundation.dart';

/// Operating parser mode of the Xlab 365T / XP-365B dual-mode thermal printer.
enum PrinterMode {
  /// Bill / receipt parser mode (`ESC/POS`, vendor mode byte `0x31`).
  receipt,

  /// Barcode / sticker label parser mode (`TSPL`, vendor mode byte `0x30`).
  label,
}

/// Network and hardware configuration for the Xlab 365T printer over TCP 9100.
@immutable
class PrinterConfig {
  const PrinterConfig({
    this.host = defaultHost,
    this.port = defaultPort,
    this.connectTimeout = const Duration(seconds: 3),
    this.ioTimeout = const Duration(seconds: 5),
    this.modeSwitchDelay = defaultModeSwitchDelay,
    this.autoSwitchMode = true,
    this.preferredMode = PrinterMode.receipt,
    this.storeName = 'Pasal Cosmetics',
    this.storeAddress = '',
    this.storePhone = '',
    this.storePan = '',
    this.receiptFooter = 'Thank you! No refund on opened cosmetics.',
  });

  static const String defaultHost = '192.168.1.100';
  static const int defaultPort = 9100;

  /// Required 1.5s firmware parser reinitialization pause after mode switching
  /// per `TECHNICAL_SPEC.md` §3.2 and `PRINTER_INTEGRATION_GUIDE.md` §1.3.
  static const Duration defaultModeSwitchDelay = Duration(milliseconds: 1500);

  final String host;
  final int port;
  final Duration connectTimeout;
  final Duration ioTimeout;
  final Duration modeSwitchDelay;
  final bool autoSwitchMode;
  final PrinterMode preferredMode;
  final String storeName;
  final String storeAddress;
  final String storePhone;
  final String storePan;
  final String receiptFooter;

  PrinterConfig copyWith({
    String? host,
    int? port,
    Duration? connectTimeout,
    Duration? ioTimeout,
    Duration? modeSwitchDelay,
    bool? autoSwitchMode,
    PrinterMode? preferredMode,
    String? storeName,
    String? storeAddress,
    String? storePhone,
    String? storePan,
    String? receiptFooter,
  }) {
    return PrinterConfig(
      host: host ?? this.host,
      port: port ?? this.port,
      connectTimeout: connectTimeout ?? this.connectTimeout,
      ioTimeout: ioTimeout ?? this.ioTimeout,
      modeSwitchDelay: modeSwitchDelay ?? this.modeSwitchDelay,
      autoSwitchMode: autoSwitchMode ?? this.autoSwitchMode,
      preferredMode: preferredMode ?? this.preferredMode,
      storeName: storeName ?? this.storeName,
      storeAddress: storeAddress ?? this.storeAddress,
      storePhone: storePhone ?? this.storePhone,
      storePan: storePan ?? this.storePan,
      receiptFooter: receiptFooter ?? this.receiptFooter,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'host': host,
        'port': port,
        'auto_switch_mode': autoSwitchMode,
        'preferred_mode': preferredMode.name,
        'store_name': storeName,
        'store_address': storeAddress,
        'store_phone': storePhone,
        'store_pan': storePan,
        'receipt_footer': receiptFooter,
      };

  static PrinterConfig fromJson(Map<String, dynamic> json) {
    final host = (json['host'] as String?)?.trim();
    final port = (json['port'] as num?)?.toInt();
    final rawMode = (json['preferred_mode'] as String?)?.trim().toLowerCase();
    return PrinterConfig(
      host: (host != null && host.isNotEmpty) ? host : defaultHost,
      port: (port != null && port > 0 && port <= 65535) ? port : defaultPort,
      autoSwitchMode: json['auto_switch_mode'] as bool? ?? true,
      preferredMode:
          rawMode == 'label' ? PrinterMode.label : PrinterMode.receipt,
      storeName: (json['store_name'] as String?) ?? 'Pasal Cosmetics',
      storeAddress: (json['store_address'] as String?) ?? '',
      storePhone: (json['store_phone'] as String?) ?? '',
      storePan: (json['store_pan'] as String?) ?? '',
      receiptFooter: (json['receipt_footer'] as String?) ??
          'Thank you! No refund on opened cosmetics.',
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PrinterConfig &&
        other.host == host &&
        other.port == port &&
        other.connectTimeout == connectTimeout &&
        other.ioTimeout == ioTimeout &&
        other.modeSwitchDelay == modeSwitchDelay &&
        other.autoSwitchMode == autoSwitchMode &&
        other.preferredMode == preferredMode &&
        other.storeName == storeName &&
        other.storeAddress == storeAddress &&
        other.storePhone == storePhone &&
        other.storePan == storePan &&
        other.receiptFooter == receiptFooter;
  }

  @override
  int get hashCode => Object.hash(
        host,
        port,
        connectTimeout,
        ioTimeout,
        modeSwitchDelay,
        autoSwitchMode,
        preferredMode,
        storeName,
        storeAddress,
        storePhone,
        storePan,
        receiptFooter,
      );
}

/// Real-time status snapshot returned by [Xlab365tDriver.probeStatus].
@immutable
class PrinterStatus {
  const PrinterStatus({
    required this.mode,
    required this.isOnline,
    required this.isReady,
    required this.coverOpen,
    required this.paperOut,
    required this.hasError,
    required this.rawBytes,
    required this.message,
  });

  final PrinterMode mode;
  final bool isOnline;
  final bool isReady;
  final bool coverOpen;
  final bool paperOut;
  final bool hasError;
  final List<int> rawBytes;
  final String message;
}

/// Base exception for thermal printer protocol and transport errors.
sealed class PrinterException implements Exception {
  const PrinterException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      cause == null ? '$runtimeType: $message' : '$runtimeType: $message ($cause)';
}

/// Raised when TCP socket connection or I/O to `host:9100` fails or times out.
final class PrinterConnectionException extends PrinterException {
  const PrinterConnectionException(super.message, [super.cause]);
}

/// Raised when payload parameters violate physical hardware boundaries
/// (e.g. a barcode exceeding sticker column dot limits `X=0..215`).
final class PrinterPayloadException extends PrinterException {
  const PrinterPayloadException(super.message, [super.cause]);
}

