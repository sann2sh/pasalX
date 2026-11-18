import 'package:intl/intl.dart';

/// Fixed-point paisa (1 NPR = 100 paisa) arithmetic & formatting utilities
/// matching Go's `sync.Money` (`int64` paisa/cents) to avoid floating-point drift.
abstract final class MoneyUtils {
  /// Maximum paisa fitting SQL `DECIMAL(10,2)` (`99,999,999.99`).
  static const int maxDecimal10_2Paisa = 9999999999;

  /// Maximum paisa fitting SQL `DECIMAL(12,2)` (`9,999,999,999.99`).
  static const int maxDecimal12_2Paisa = 999999999999;

  static final NumberFormat _wholeFormat = NumberFormat('#,##0', 'en_IN');

  /// Formats [paisa] for UI display (e.g. `135000` -> `Rs. 1,350`, or `Rs. 1,350.50`)
  /// using pure integer division/modulo without IEEE-754 floating-point conversion.
  static String formatRs(int paisa, {bool alwaysShowDecimals = false}) {
    final negative = paisa < 0;
    final abs = paisa.abs();
    final whole = abs ~/ 100;
    final frac = abs % 100;
    final wholeFormatted = _wholeFormat.format(whole);
    final formatted = (alwaysShowDecimals || frac != 0)
        ? '$wholeFormatted.${frac.toString().padLeft(2, '0')}'
        : wholeFormatted;
    return negative ? '-Rs. $formatted' : 'Rs. $formatted';
  }

  /// Formats [paisa] into exact 2-decimal API string (`135050` -> `"1350.50"`).
  static String toDecimalString(int paisa) {
    final negative = paisa < 0;
    final abs = paisa.abs();
    final whole = abs ~/ 100;
    final frac = (abs % 100).toString().padLeft(2, '0');
    return negative ? '-$whole.$frac' : '$whole.$frac';
  }

  /// Parses JSON numeric/string decimal (`1350`, `1350.5`, `"1350.50"`) into exact
  /// paisa without IEEE-754 rounding error or 64-bit integer overflow.
  /// Rejects more than 2 fractional digits and values exceeding `DECIMAL(12,2)`.
  static int parseToPaisa(Object raw) {
    final text = raw.toString().trim();
    if (text.isEmpty) {
      throw const FormatException('Empty money value');
    }
    final match = RegExp(r'^(-)?(\d+)(?:\.(\d+))?$').firstMatch(text);
    if (match == null) {
      throw FormatException('Invalid money format: $text');
    }
    final negative = match.group(1) != null;
    final wholeDigits = match.group(2)!.replaceFirst(RegExp(r'^0+'), '');
    if (wholeDigits.length > 10) {
      throw FormatException('Money value exceeds DECIMAL(12,2) range: $text');
    }
    final whole = wholeDigits.isEmpty ? 0 : int.parse(wholeDigits);
    final fracRaw = match.group(3) ?? '';
    if (fracRaw.length > 2) {
      final extra = fracRaw.substring(2);
      if (RegExp(r'[1-9]').hasMatch(extra)) {
        throw FormatException('Sub-paisa precision not allowed: $text');
      }
    }
    final fracPadded = fracRaw.padRight(2, '0').substring(0, 2);
    final total = whole * 100 + int.parse(fracPadded);
    if (total > maxDecimal12_2Paisa) {
      throw FormatException('Money value exceeds DECIMAL(12,2) range: $text');
    }
    return negative && total != 0 ? -total : total;
  }

  /// Parses nullable API money JSON value.
  static int? parseNullableToPaisa(Object? raw) {
    if (raw == null) return null;
    return parseToPaisa(raw);
  }

  /// Safely parses user-entered decimal rupees string to paisa, returning null
  /// on empty or malformed input.
  static int? tryParseToPaisa(String? raw) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    try {
      return parseToPaisa(trimmed);
    } on FormatException {
      return null;
    }
  }
}

