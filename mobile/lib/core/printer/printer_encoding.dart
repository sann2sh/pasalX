import 'dart:typed_data';

import 'package:intl/intl.dart';

/// Shared Xlab 365T / XP-365B vendor commands and thermal ASCII helpers.
abstract final class XlabProtocol {
  /// Switch to Receipt / Bill Mode (ESC/POS): `1F 1B 1F 02 20 31 0D 0A`.
  static final Uint8List modeSwitchToReceipt = Uint8List.fromList(
    const <int>[0x1F, 0x1B, 0x1F, 0x02, 0x20, 0x31, 0x0D, 0x0A],
  );

  /// Switch to Label / Sticker Mode (TSPL): `1F 1B 1F 02 20 30 0D 0A`.
  static final Uint8List modeSwitchToLabel = Uint8List.fromList(
    const <int>[0x1F, 0x1B, 0x1F, 0x02, 0x20, 0x30, 0x0D, 0x0A],
  );

  /// ESC/POS real-time printer status query (`DLE EOT 1`).
  static final Uint8List escPosStatusQuery1 = Uint8List.fromList(
    const <int>[0x10, 0x04, 0x01],
  );

  /// ESC/POS real-time offline cause query (`DLE EOT 2`).
  static final Uint8List escPosStatusQuery2 = Uint8List.fromList(
    const <int>[0x10, 0x04, 0x02],
  );

  /// TSPL real-time status query (`<ESC>!?`).
  static final Uint8List tsplStatusQuery = Uint8List.fromList(
    const <int>[0x1B, 0x21, 0x3F],
  );

  /// ESC/POS feed and partial cut command (`GS V A 0`: `1D 56 41 00`).
  static final Uint8List escPosCutCommand = Uint8List.fromList(
    const <int>[0x1D, 0x56, 0x41, 0x00],
  );

  /// ESC/POS cash drawer kick pulse on pin 2 (`ESC p 0 25 250`).
  static final Uint8List escPosCashDrawerKick = Uint8List.fromList(
    const <int>[0x1B, 0x70, 0x00, 0x19, 0xFA],
  );
}

/// Normalizes text to printable 7-bit ASCII (`0x20..0x7E`) for thermal firmware.
abstract final class ThermalText {
  static final NumberFormat _wholeFormat = NumberFormat('#,##0', 'en_IN');

  static String sanitizeAscii(String input, {bool allowDoubleQuotes = true}) {
    final buf = StringBuffer();
    for (final rune in input.runes) {
      switch (rune) {
        case 0x2018 || 0x2019 || 0x2032: // curly single quotes / prime
          buf.write("'");
        case 0x201C || 0x201D || 0x2033: // curly double quotes
          buf.write(allowDoubleQuotes ? '"' : "'");
        case 0x2013 || 0x2014 || 0x2212: // en-dash, em-dash, minus
          buf.write('-');
        case 0x00D7: // multiplication sign
          buf.write('x');
        case 0x2192: // right arrow
          buf.write('->');
        case 0x00A0: // non-breaking space
          buf.write(' ');
        case 0x0022: // double quote
          buf.write(allowDoubleQuotes ? '"' : "'");
        case 0x005C: // backslash (escapes quotes in TSPL strings)
          buf.write('/');
        case >= 0x0966 && <= 0x096F: // Devanagari digits ०-९
          buf.writeCharCode(0x30 + (rune - 0x0966));
        case >= 0x00C0 && <= 0x00C5:
          buf.write('A');
        case 0x00C7:
          buf.write('C');
        case >= 0x00C8 && <= 0x00CB:
          buf.write('E');
        case >= 0x00CC && <= 0x00CF:
          buf.write('I');
        case 0x00D1:
          buf.write('N');
        case >= 0x00D2 && <= 0x00D6:
          buf.write('O');
        case >= 0x00D9 && <= 0x00DC:
          buf.write('U');
        case >= 0x00E0 && <= 0x00E5:
          buf.write('a');
        case 0x00E7:
          buf.write('c');
        case >= 0x00E8 && <= 0x00EB:
          buf.write('e');
        case >= 0x00EC && <= 0x00EF:
          buf.write('i');
        case 0x00F1:
          buf.write('n');
        case >= 0x00F2 && <= 0x00F6:
          buf.write('o');
        case >= 0x00F9 && <= 0x00FC:
          buf.write('u');
        default:
          if (rune >= 0x20 && rune <= 0x7E) {
            buf.writeCharCode(rune);
          } else if (rune == 0x09) {
            buf.write(' ');
          }
      }
    }
    return buf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Truncates [text] cleanly to at most [maxChars] characters.
  static String truncate(String text, int maxChars) {
    if (maxChars <= 0) return '';
    if (text.length <= maxChars) return text;
    if (maxChars <= 2) return text.substring(0, maxChars);
    return '${text.substring(0, maxChars - 2)}..';
  }

  /// Formats integer paisa as `1,350.00` (or `1,350` when [showDecimals] is false and frac == 0).
  static String formatAmount(int paisa, {bool showDecimals = true}) {
    final negative = paisa < 0;
    final abs = paisa.abs();
    final whole = abs ~/ 100;
    final frac = abs % 100;
    final wholeStr = _wholeFormat.format(whole);
    final formatted = (showDecimals || frac != 0)
        ? '$wholeStr.${frac.toString().padLeft(2, '0')}'
        : wholeStr;
    return negative ? '-$formatted' : formatted;
  }
}
