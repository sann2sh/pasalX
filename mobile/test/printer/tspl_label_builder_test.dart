import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pasalx_mobile/core/printer/printer.dart';

void main() {
  group('TsplLabelBuilder (62x20mm dual-column)', () {
    test('mode switch command matches exact vendor hex sequence', () {
      expect(
        TsplLabelBuilder.modeSwitchCommand,
        equals(const <int>[0x1F, 0x1B, 0x1F, 0x02, 0x20, 0x30, 0x0D, 0x0A]),
      );
    });

    test('Code 128 Subset C width math and auto-scaling stay inside X=0..215', () {
      // 6-digit numeric: 37 + 11*3 = 70 modules; narrow=3 => 210 <= 215.
      final fit6 = TsplLabelBuilder.fitBarcode('123456');
      expect(fit6.isAllDigitSubsetC, isTrue);
      expect(fit6.modules, 70);
      expect(fit6.narrow, 3);
      expect(fit6.widthDots, 210);
      expect(fit6.widthDots, lessThanOrEqualTo(TsplGeometry.col1MaxX));

      // 4-digit numeric: 37 + 11*2 = 59 modules; narrow=3 => 177 <= 215.
      final fit4 = TsplLabelBuilder.fitBarcode('1001');
      expect(fit4.modules, 59);
      expect(fit4.narrow, 3);
      expect(fit4.widthDots, 177);

      // 8-digit numeric: 37 + 11*4 = 81 modules; narrow=3 (243) exceeds 215,
      // so it auto-scales down to narrow=2 => 162 <= 215.
      final fit8 = TsplLabelBuilder.fitBarcode('12345678');
      expect(fit8.modules, 81);
      expect(fit8.narrow, 2);
      expect(fit8.widthDots, 162);

      // Alphanumeric PRL-10024 (9 chars): Subset B = 37 + 99 = 136 modules;
      // auto-scales to narrow=1 => 136 <= 215.
      final fitAlpha = TsplLabelBuilder.fitBarcode('PRL-10024');
      expect(fitAlpha.isAllDigitSubsetC, isFalse);
      expect(fitAlpha.modules, 136);
      expect(fitAlpha.narrow, 1);
      expect(fitAlpha.widthDots, 136);

      // Oversized alphanumeric (>16 chars) fails cleanly instead of overflowing.
      expect(
        () => TsplLabelBuilder.fitBarcode('ABCDEFGHIJKLMNOPQ'),
        throwsA(isA<PrinterPayloadException>()),
      );
    });

    test('renders dual-column stickers strictly within X=0..215 and X=238..460', () {
      const builder = TsplLabelBuilder();
      final bytes = builder.buildLabels(
        <BatchLabelData>[
          BatchLabelData(
            productName: 'Fit Me Matte + Poreless Foundation 30ml',
            variantName: '#128 Warm Nude',
            stickerBarcode: '100024',
            sellingPricePaisa: 135000,
            expiryDate: DateTime(2026, 5, 31),
          ),
          BatchLabelData(
            productName: 'La Roche-Posay Anthelios Invisible Fluid "SPF 50"',
            variantName: '50ml SPF 50+',
            stickerBarcode: '100025',
            sellingPricePaisa: 285000,
            expiryDate: DateTime(2027, 12, 1),
          ),
        ],
      );

      final tspl = ascii.decode(bytes);
      expect(tspl, startsWith('SIZE 62 mm,20 mm\r\nGAP 2 mm,0 mm\r\n'));
      expect(tspl, contains('DIRECTION 0,0\r\nDENSITY 13\r\nSPEED 4\r\nCLS\r\n'));
      expect(tspl, endsWith('PRINT 1,1\r\n'));
      expect(tspl, contains('Rs.1,350 Exp:05/2026'));
      expect(tspl, contains('Rs.2,850 Exp:12/2027'));
      expect(tspl, contains('#128 Warm Nude'));
      // Embedded double quote sanitized to single quote so TSPL parser won't break.
      expect(tspl, isNot(contains('""SPF 50""')));

      _assertAllCommandsWithinColumnBounds(tspl);
    });

    test('buildBatchCopies pairs odd quantities efficiently', () {
      const builder = TsplLabelBuilder();
      final label = BatchLabelData(
        productName: 'Maybelline SuperStay Vinyl Ink',
        variantName: '#35 Cheeky',
        stickerBarcode: '100421',
        sellingPricePaisa: 165000,
        expiryDate: DateTime(2027, 8, 15),
      );

      final tspl = ascii.decode(builder.buildBatchCopies(label, quantity: 5));

      // 5 labels = 2 dual-column rows (`PRINT 2,1`) + 1 left-column row (`PRINT 1,1`).
      expect(tspl, contains('PRINT 2,1\r\n'));
      expect(tspl, contains('PRINT 1,1\r\n'));

      final barcodeLines = tspl
          .split('\r\n')
          .where((l) => l.startsWith('BARCODE '))
          .toList();
      // Row 1 has 2 BARCODE commands (X=0, X=238); Row 2 has 1 BARCODE command (X=0).
      expect(barcodeLines.length, 3);
      expect(barcodeLines[0], startsWith('BARCODE 0,50,"128",40,1,0,3,3,"100421"'));
      expect(barcodeLines[1], startsWith('BARCODE 238,50,"128",40,1,0,3,3,"100421"'));
      expect(barcodeLines[2], startsWith('BARCODE 0,50,"128",40,1,0,3,3,"100421"'));

      _assertAllCommandsWithinColumnBounds(tspl);
    });

    test('qrSideBySide emits 9-parameter QRCODE within hard bounds', () {
      const builder = TsplLabelBuilder();
      final tspl = ascii.decode(
        builder.buildLabels(
          <BatchLabelData>[
            BatchLabelData(
              productName: 'Ceramide Repair Serum',
              variantName: '30ml',
              stickerBarcode: '100999',
              sellingPricePaisa: 190000,
              expiryDate: DateTime(2027, 3, 1),
            ),
            BatchLabelData(
              productName: 'Ceramide Repair Serum',
              variantName: '30ml',
              stickerBarcode: '101000',
              sellingPricePaisa: 190000,
              expiryDate: DateTime(2027, 3, 1),
            ),
          ],
          style: TsplLabelStyle.qrSideBySide,
        ),
      );

      expect(tspl, contains('QRCODE 108,36,L,4,A,0,M2,S7,"100999"'));
      expect(tspl, contains('QRCODE 346,36,L,4,A,0,M2,S7,"101000"'));
      _assertAllCommandsWithinColumnBounds(tspl);
    });

    test('calibration command emits GAPDETECT for 62x20mm roll', () {
      const builder = TsplLabelBuilder();
      final cmd = ascii.decode(builder.buildCalibrationCommand());
      expect(
        cmd,
        equals('SIZE 62 mm,20 mm\r\nGAP 2 mm,0 mm\r\nGAPDETECT\r\n'),
      );
    });

    test('rejects backslash/tilde/non-ASCII barcodes and handles Nepali & high-price labels', () {
      const builder = TsplLabelBuilder();
      expect(
        () => TsplLabelBuilder.fitBarcode('100\u0967'),
        throwsA(isA<PrinterPayloadException>()),
      );
      expect(
        () => TsplLabelBuilder.fitBarcode('100"24'),
        throwsA(isA<PrinterPayloadException>()),
      );
      expect(
        () => TsplLabelBuilder.fitBarcode(r'100\24'),
        throwsA(isA<PrinterPayloadException>()),
      );
      expect(
        () => TsplLabelBuilder.fitBarcode('100~1'),
        throwsA(isA<PrinterPayloadException>()),
      );

      // Nepali-only product name + trailing backslash in variant + high price
      // preserves expiry and sanitizes trailing backslash cleanly.
      final specialTspl = ascii.decode(
        builder.buildLabels(
          <BatchLabelData>[
            BatchLabelData(
              productName: 'लालीगुँरास क्रिम',
              variantName: r'Shade #1\',
              stickerBarcode: '100777',
              sellingPricePaisa: 9999999950, // Rs. 99,999,999.50 (>26 chars w/ Exp)
              expiryDate: DateTime(2027, 6, 1),
            ),
          ],
        ),
      );
      expect(specialTspl, contains('"Item #100777"'));
      expect(specialTspl, contains('"Shade #1/"'));
      expect(specialTspl, contains('E:06/27'));
      _assertAllCommandsWithinColumnBounds(specialTspl);

      final single = ascii.decode(
        builder.buildBatchCopies(
          BatchLabelData(
            productName: 'Single Lip Balm',
            variantName: 'Honey',
            stickerBarcode: '100777',
            sellingPricePaisa: 35000,
            expiryDate: DateTime(2027, 6, 1),
          ),
          quantity: 1,
        ),
      );
      expect(single, contains('PRINT 1,1\r\n'));
      expect(single, contains('BARCODE 0,50,'));
      expect(single, isNot(contains('BARCODE 238,')));
      _assertAllCommandsWithinColumnBounds(single);
    });
  });
}

void _assertAllCommandsWithinColumnBounds(String tspl) {
  final lines = tspl.split('\r\n').where((l) => l.isNotEmpty);
  final textRegex = RegExp(r'^TEXT (\d+),(\d+),"1",0,1,1,"([^"]*)"$');
  final barcodeRegex = RegExp(
    r'^BARCODE (\d+),(\d+),"128",(\d+),(\d+),0,(\d+),(\d+),"([^"]*)"$',
  );
  final qrRegex = RegExp(
    r'^QRCODE (\d+),(\d+),[LMQH],(\d+),A,0,M2,S7,"([^"]*)"$',
  );

  for (final line in lines) {
    if (line.startsWith('TEXT ') ||
        line.startsWith('BARCODE ') ||
        line.startsWith('QRCODE ')) {
      // TSPL Rule #1: zero spaces after commas inside parameter list.
      expect(line, isNot(contains(', ')), reason: 'Space after comma in: $line');
    }

    final textMatch = textRegex.firstMatch(line);
    if (textMatch != null) {
      final x = int.parse(textMatch.group(1)!);
      final y = int.parse(textMatch.group(2)!);
      final content = textMatch.group(3)!;
      final xEnd = x + content.length * TsplGeometry.font1CharWidth;
      expect(y, greaterThanOrEqualTo(TsplGeometry.minY));
      expect(y + TsplGeometry.font1CharHeight, lessThanOrEqualTo(TsplGeometry.maxY));
      _assertInColumn(x, xEnd, line);
      continue;
    }

    final barcodeMatch = barcodeRegex.firstMatch(line);
    if (barcodeMatch != null) {
      final x = int.parse(barcodeMatch.group(1)!);
      final y = int.parse(barcodeMatch.group(2)!);
      final height = int.parse(barcodeMatch.group(3)!);
      final hri = int.parse(barcodeMatch.group(4)!);
      final narrow = int.parse(barcodeMatch.group(5)!);
      final wide = int.parse(barcodeMatch.group(6)!);
      final code = barcodeMatch.group(7)!;

      // TSPL Rule #2: narrow == wide for Code 128.
      expect(narrow, equals(wide), reason: 'Code 128 ratio must be 1:1 in $line');

      final fit = TsplLabelBuilder.fitBarcode(
        code,
        colOriginX: x < TsplGeometry.col2MinX
            ? TsplGeometry.col1MinX
            : TsplGeometry.col2MinX,
        colMaxX: x < TsplGeometry.col2MinX
            ? TsplGeometry.col1MaxX
            : TsplGeometry.col2MaxX,
      );
      expect(narrow, equals(fit.narrow));
      _assertInColumn(x, x + fit.widthDots, line);

      final yEnd = y + height + (hri > 0 ? 16 : 0);
      expect(y, greaterThanOrEqualTo(TsplGeometry.minY));
      expect(yEnd, lessThanOrEqualTo(TsplGeometry.maxY));
      continue;
    }

    final qrMatch = qrRegex.firstMatch(line);
    if (qrMatch != null) {
      final x = int.parse(qrMatch.group(1)!);
      final y = int.parse(qrMatch.group(2)!);
      final cellWidth = int.parse(qrMatch.group(3)!);
      final qrData = qrMatch.group(4)!;
      final modules = qrData.length <= 17 ? 21 : (qrData.length <= 32 ? 25 : 29);
      final estimatedQrDots = modules * cellWidth;
      _assertInColumn(x, x + estimatedQrDots, line);
      expect(y, greaterThanOrEqualTo(TsplGeometry.minY));
      expect(y + estimatedQrDots, lessThanOrEqualTo(TsplGeometry.maxY));
    }
  }
}

void _assertInColumn(int xStart, int xEnd, String line) {
  if (xStart < TsplGeometry.col2MinX) {
    expect(xStart, greaterThanOrEqualTo(TsplGeometry.col1MinX), reason: line);
    expect(xEnd, lessThanOrEqualTo(TsplGeometry.col1MaxX), reason: line);
  } else {
    expect(xStart, greaterThanOrEqualTo(TsplGeometry.col2MinX), reason: line);
    expect(xEnd, lessThanOrEqualTo(TsplGeometry.col2MaxX), reason: line);
  }
}
