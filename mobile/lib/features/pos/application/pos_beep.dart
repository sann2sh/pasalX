import 'package:flutter/services.dart';

/// Plays a short standard POS scanner beep via Android's native ToneGenerator.
abstract final class PosBeep {
  static const MethodChannel _channel = MethodChannel('com.pasalx.pos/beep');

  static Future<void> playSuccess() async {
    try {
      await _channel.invokeMethod<void>('beep');
    } on MissingPluginException {
      // Safe no-op in widget tests and non-Android hosts.
    } catch (_) {
      // Never block POS scanning if audio hardware is muted or unavailable.
    }
  }
}

