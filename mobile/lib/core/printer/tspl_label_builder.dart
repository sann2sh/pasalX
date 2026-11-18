import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../database/money.dart';
import 'printer_config.dart';
import 'printer_encoding.dart';

/// Supported dual-column 62x20mm sticker layouts for Xlab 365T.
enum TsplLabelStyle {
  /// Full-width 1D Code 128 barcode (Subset C auto-compressed for digits).
  barcode128,

  /// Side-by-side price/expiry on left and 2D QR code on right.
  qrSideBySide,
}

/// Calibrated physical dot boundaries (203 DPI = 8 dots/mm) for 62x20mm
/// dual-column sticker rolls per `PRINTER_INTEGRATION_GUIDE.md` §2 & §7.
abstract final class TsplGeometry {
  static const int dpi = 203;
  static const int dotsPerMm = 8;

  static const int rollWidthMm = 62;
  static const int rollWidthDots = 496;
  static const int stickerHeightMm = 20;
  static const int stickerHeightDots = 160;
  static const int rowGapMm = 2;
  static const int rowGapDots = 16;

  /// Sticker 1 (Left Column) hard X limits: `[0, 215]`.
  static const int col1MinX = 0;
  static const int col1MaxX = 215;

  /// Inter-column gap: `215..238` (23 dots = 2.875 mm).
  static const int colPitch = 238;

  /// Sticker 2 (Right Column) hard X limits: `[238, 460]`.
  static const int col2MinX = 238;
  static const int col2MaxX = 460;

  /// Safe vertical printable boundaries: `[5, 120]`.
  static const int minY = 5;
  static const int maxY = 120;

  /// TSPL built-in Font `"1"` character cell size (`8x12` dots).
  static const int font1CharWidth = 8;
  static const int font1CharHeight = 12;
}

/// Fitted Code 128 barcode metrics guaranteed to stay inside column limits.
@immutable
class TsplBarcodeFit {
  const TsplBarcodeFit({
    required this.modules,
    required this.narrow,
    required this.widthDots,
    required this.isAllDigitSubsetC,
  });

  final int modules;
  final int narrow;
  final int widthDots;
  final bool isAllDigitSubsetC;
}

/// Domain payload for a single batch thermal sticker label.
@immutable
class BatchLabelData {
  const BatchLabelData({
    required this.productName,
    required this.variantName,
    required this.stickerBarcode,
    required this.sellingPricePaisa,
    required this.expiryDate,
    this.batchCode,
  });

  final String productName;
  final String variantName;
  final String stickerBarcode;
  final int sellingPricePaisa;
  final DateTime expiryDate;
  final String? batchCode;
}

/// Builds TSPL command payloads for 62x20mm dual-column sticker rolls on the
/// Xlab 365T / XP-365B printer (`203 DPI`).
class TsplLabelBuilder {
  const TsplLabelBuilder({
    this.density = 13,
    this.speed = 4,
  });

  /// Vendor firmware switch command (`1F 1B 1F 02 20 30 0D 0A`).
  static Uint8List get modeSwitchCommand => XlabProtocol.modeSwitchToLabel;

  final int density;
  final int speed;

  static final RegExp _allDigitsRegex = RegExp(r'^\d+$');

  /// Computes Code 128 module count and selects the widest `narrow` (`3`, `2`,
  /// or `1`) whose rendered width fits inside `[colOriginX, colMaxX]`.
  static TsplBarcodeFit fitBarcode(
    String rawBarcode, {
    int colOriginX = TsplGeometry.col1MinX,
    int colMaxX = TsplGeometry.col1MaxX,
  }) {
    final code = _sanitizeBarcodeValue(rawBarcode);
    final availableWidth = colMaxX - colOriginX;
    if (availableWidth <= 0) {
      throw PrinterPayloadException(
        'Invalid column bounds [$colOriginX, $colMaxX]',
      );
    }

    final isDigits = _allDigitsRegex.hasMatch(code);
    final int modules;
    if (isDigits) {
      if (code.length.isEven) {
        // Pure Code 128 Subset C: 37 overhead + 11 per 2-digit pair.
        modules = 37 + 11 * (code.length ~/ 2);
      } else {
        // Odd digit count switches the trailing digit to Subset B (+22) or uses
        // pure Subset B (smaller for 1-digit codes).
        final subsetB = 37 + 11 * code.length;
        final subsetCB = 37 + 11 * (code.length ~/ 2) + 22;
        modules = math.min(subsetB, subsetCB);
      }
    } else {
      // Code 128 Subset A/B conservative bound: 37 overhead + 11 per char.
      modules = 37 + 11 * code.length;
    }

    for (final narrow in const <int>[3, 2, 1]) {
      final width = modules * narrow;
      if (width <= availableWidth) {
        return TsplBarcodeFit(
          modules: modules,
          narrow: narrow,
          widthDots: width,
          isAllDigitSubsetC: isDigits,
        );
      }
    }

    throw PrinterPayloadException(
      'Barcode "$code" ($modules modules) exceeds column width '
      '$availableWidth dots even at narrow=1',
    );
  }

  /// Encodes a list of distinct or mixed [labels] into paired 2-column rows
  /// (`Column 1: X=0..215`, `Column 2: X=238..460`).
  Uint8List buildLabels(
    List<BatchLabelData> labels, {
    TsplLabelStyle style = TsplLabelStyle.barcode128,
  }) {
    if (labels.isEmpty) {
      throw const PrinterPayloadException('Cannot print an empty label list');
    }

    final sb = StringBuffer();
    _writeJobHeader(sb);

    for (var i = 0; i < labels.length; i += 2) {
      final left = labels[i];
      final right = (i + 1 < labels.length) ? labels[i + 1] : null;
      _writeRow(sb, left: left, right: right, copies: 1, style: style);
    }

    return Uint8List.fromList(ascii.encode(sb.toString()));
  }

  /// Encodes [quantity] identical copies of [label] efficiently using paired
  /// dual-column `PRINT` counts (e.g. `quantity=5` emits 2 full dual rows
  /// via `PRINT 2,1` plus 1 single left-column row via `PRINT 1,1`).
  Uint8List buildBatchCopies(
    BatchLabelData label, {
    required int quantity,
    TsplLabelStyle style = TsplLabelStyle.barcode128,
  }) {
    if (quantity <= 0) {
      throw PrinterPayloadException(
        'Label quantity must be positive, got $quantity',
      );
    }

    final sb = StringBuffer();
    _writeJobHeader(sb);

    final fullPairs = quantity ~/ 2;
    if (fullPairs > 0) {
      _writeRow(
        sb,
        left: label,
        right: label,
        copies: fullPairs,
        style: style,
      );
    }
    if (quantity.isOdd) {
      _writeRow(
        sb,
        left: label,
        right: null,
        copies: 1,
        style: style,
      );
    }

    return Uint8List.fromList(ascii.encode(sb.toString()));
  }

  /// Returns TSPL media gap sensor calibration command for 62x20mm rolls.
  Uint8List buildCalibrationCommand() {
    final cmd = 'SIZE ${TsplGeometry.rollWidthMm} mm,${TsplGeometry.stickerHeightMm} mm\r\n'
        'GAP ${TsplGeometry.rowGapMm} mm,0 mm\r\n'
        'GAPDETECT\r\n';
    return Uint8List.fromList(ascii.encode(cmd));
  }

  void _writeJobHeader(StringBuffer sb) {
    final safeDensity = density.clamp(1, 15);
    final safeSpeed = speed.clamp(1, 5);
    sb
      ..write('SIZE ${TsplGeometry.rollWidthMm} mm,${TsplGeometry.stickerHeightMm} mm\r\n')
      ..write('GAP ${TsplGeometry.rowGapMm} mm,0 mm\r\n')
      ..write('DIRECTION 0,0\r\n')
      ..write('DENSITY $safeDensity\r\n')
      ..write('SPEED $safeSpeed\r\n');
  }

  void _writeRow(
    StringBuffer sb, {
    required BatchLabelData left,
    required BatchLabelData? right,
    required int copies,
    required TsplLabelStyle style,
  }) {
    sb.write('CLS\r\n');
    _writeStickerColumn(
      sb,
      label: left,
      colOriginX: TsplGeometry.col1MinX,
      colMaxX: TsplGeometry.col1MaxX,
      style: style,
    );
    if (right != null) {
      _writeStickerColumn(
        sb,
        label: right,
        colOriginX: TsplGeometry.col2MinX,
        colMaxX: TsplGeometry.col2MaxX,
        style: style,
      );
    }
    sb.write('PRINT $copies,1\r\n');
  }

  void _writeStickerColumn(
    StringBuffer sb, {
    required BatchLabelData label,
    required int colOriginX,
    required int colMaxX,
    required TsplLabelStyle style,
  }) {
    if (label.sellingPricePaisa < 0 ||
        label.sellingPricePaisa > MoneyUtils.maxDecimal12_2Paisa) {
      throw PrinterPayloadException(
        'Selling price out of range for ${label.productName}',
      );
    }
    if (label.productName.trim().isEmpty) {
      throw const PrinterPayloadException('Product name must not be empty');
    }

    final barcode = _sanitizeBarcodeValue(label.stickerBarcode);
    final textX = colOriginX + 3;
    final maxCharsFull = (colMaxX - textX) ~/ TsplGeometry.font1CharWidth;

    final rawCleanProduct = _cleanText(label.productName);
    final productLine = _fitText(
      rawCleanProduct.isEmpty ? 'Item #$barcode' : rawCleanProduct,
      maxCharsFull,
    );
    final variantRaw = _cleanText(label.variantName);
    final batchRaw = _cleanText(label.batchCode ?? '');
    final secondaryText = variantRaw.isNotEmpty
        ? variantRaw
        : (batchRaw.isNotEmpty ? 'Lot: $batchRaw' : '');
    final variantLine = _fitText(secondaryText, maxCharsFull);

    final priceCompact = _formatCompactPrice(label.sellingPricePaisa);
    final expiryText = _formatExpiry(label.expiryDate);

    // Note TSPL Rule #1: zero spaces after commas in TEXT/BARCODE/QRCODE.
    _writeTsplText(sb, textX, 6, productLine);
    if (variantLine.isNotEmpty) {
      _writeTsplText(sb, textX, 20, variantLine);
    }

    switch (style) {
      case TsplLabelStyle.barcode128:
        final fullMeta = '$priceCompact Exp:$expiryText';
        final String metaLine;
        if (fullMeta.length <= maxCharsFull) {
          metaLine = fullMeta;
        } else {
          final shortExp =
              'E:${label.expiryDate.month.toString().padLeft(2, '0')}/${(label.expiryDate.year % 100).toString().padLeft(2, '0')}';
          final maxPriceChars = maxCharsFull - shortExp.length - 1;
          metaLine = maxPriceChars > 0
              ? '${_fitText(priceCompact, maxPriceChars)} $shortExp'
              : _fitText(shortExp, maxCharsFull);
        }
        _writeTsplText(sb, textX, 34, metaLine);

        final fit = fitBarcode(
          barcode,
          colOriginX: colOriginX,
          colMaxX: colMaxX,
        );
        // Y=50 + height 40 + ~16 HRI = 106 <= 120 safe vertical limit.
        // Narrow == wide strictly per TSPL Code 128 ratio 1:1 rule.
        sb.write(
          'BARCODE $colOriginX,50,"128",40,1,0,${fit.narrow},${fit.narrow},"$barcode"\r\n',
        );

      case TsplLabelStyle.qrSideBySide:
        // Left sub-zone ends before QR at colOriginX + 108 (max 12 chars in Font 1).
        final qrX = colOriginX + 108;
        final maxCharsLeft =
            ((qrX - 4) - textX) ~/ TsplGeometry.font1CharWidth;
        _writeTsplText(sb, textX, 38, _fitText(priceCompact, maxCharsLeft));
        _writeTsplText(sb, textX, 56, _fitText('Exp:$expiryText', maxCharsLeft));
        _writeTsplText(sb, textX, 74, _fitText(barcode, maxCharsLeft));

        // 9-parameter QRCODE format per PRINTER_INTEGRATION_GUIDE.md §3.3 & §8.
        // Placed at Y=36 so all QR versions remain strictly <= TsplGeometry.maxY (120):
        // - <=17 chars (V1, 21x21): cellWidth=4 -> 84 dots -> Y_end=120
        // - 18..32 chars (V2, 25x25): cellWidth=3 -> 75 dots -> Y_end=111
        // - 33..53 chars (V3, 29x29): cellWidth=2 -> 58 dots -> Y_end=94
        if (barcode.length > 53) {
          throw PrinterPayloadException(
            'QR barcode "$barcode" exceeds 53-char label capacity',
          );
        }
        final cellWidth = barcode.length <= 17
            ? 4
            : (barcode.length <= 32 ? 3 : 2);
        sb.write(
          'QRCODE $qrX,36,L,$cellWidth,A,0,M2,S7,"$barcode"\r\n',
        );
    }
  }

  void _writeTsplText(StringBuffer sb, int x, int y, String text) {
    sb.write('TEXT $x,$y,"1",0,1,1,"$text"\r\n');
  }

  String _formatCompactPrice(int paisa) {
    return 'Rs.${ThermalText.formatAmount(paisa, showDecimals: false)}';
  }

  String _formatExpiry(DateTime dt) {
    final month = dt.month.toString().padLeft(2, '0');
    final year = dt.year.toString().padLeft(4, '0');
    return '$month/$year';
  }

  String _fitText(String text, int maxChars) {
    return ThermalText.truncate(text, maxChars);
  }

  String _cleanText(String value) {
    // Disallow raw double quotes inside TSPL "..." string literals.
    return ThermalText.sanitizeAscii(value, allowDoubleQuotes: false);
  }

  static String _sanitizeBarcodeValue(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw const PrinterPayloadException('Sticker barcode must not be empty');
    }
    for (final rune in trimmed.runes) {
      // Barcodes must be exact printable ASCII without quotes, backslashes, or
      // tildes (which TSPL interprets as escape/FNC1 control prefixes).
      if (rune < 0x20 ||
          rune >= 0x7E ||
          rune == 0x22 ||
          rune == 0x5C) {
        throw PrinterPayloadException(
          'Sticker barcode "$trimmed" contains unsupported character',
        );
      }
    }
    return trimmed;
  }
}
