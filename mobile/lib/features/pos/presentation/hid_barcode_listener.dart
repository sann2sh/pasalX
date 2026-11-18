import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Passive USB/Bluetooth HID barcode scanner listener.
///
/// Captures rapid printable keystrokes ending with Enter/Return when no
/// [EditableText] field currently holds input focus, and dispatches the
/// trimmed barcode string via [onBarcodeScanned].
class HidBarcodeListener extends StatefulWidget {
  const HidBarcodeListener({
    super.key,
    required this.onBarcodeScanned,
    required this.child,
    this.minLength = 4,
    this.interKeyTimeout = const Duration(milliseconds: 120),
  });

  final ValueChanged<String> onBarcodeScanned;
  final Widget child;
  final int minLength;
  final Duration interKeyTimeout;

  @override
  State<HidBarcodeListener> createState() => _HidBarcodeListenerState();
}

class _HidBarcodeListenerState extends State<HidBarcodeListener> {
  final StringBuffer _buffer = StringBuffer();
  DateTime? _lastKeyAt;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  bool _isTextInputFocused() {
    final focus = FocusManager.instance.primaryFocus;
    final ctx = focus?.context;
    if (ctx == null) return false;
    if (ctx.widget is EditableText) return true;
    return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (!mounted) return false;
    if (!TickerMode.of(context)) {
      _buffer.clear();
      _lastKeyAt = null;
      return false;
    }
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      _buffer.clear();
      _lastKeyAt = null;
      return false;
    }
    if (event is! KeyDownEvent) return false;
    if (_isTextInputFocused()) {
      _buffer.clear();
      _lastKeyAt = null;
      return false;
    }

    final now = DateTime.now();
    if (_lastKeyAt != null &&
        now.difference(_lastKeyAt!) > widget.interKeyTimeout) {
      _buffer.clear();
    }
    _lastKeyAt = now;

    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final scanned = _buffer.toString().trim();
      _buffer.clear();
      _lastKeyAt = null;
      if (scanned.length >= widget.minLength) {
        widget.onBarcodeScanned(scanned);
        return true;
      }
      return false;
    }

    final rawChar = event.character;
    final ch = (rawChar != null && rawChar.length == 1)
        ? rawChar
        : (event.logicalKey.keyLabel.length == 1
            ? event.logicalKey.keyLabel
            : null);
    if (ch != null) {
      final code = ch.codeUnitAt(0);
      if (code >= 0x20 && code <= 0x7E) {
        _buffer.write(ch);
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
