import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../database/money.dart';
import 'printer_config.dart';
import 'printer_encoding.dart';

/// Single line item on an 80mm PAN-only retail receipt.
@immutable
class ReceiptLineItem {
  const ReceiptLineItem({
    required this.productName,
    required this.variantName,
    required this.quantity,
    required this.unitPricePaisa,
    required this.lineTotalPaisa,
  });

  final String productName;
  final String variantName;
  final int quantity;
  final int unitPricePaisa;
  final int lineTotalPaisa;
}

/// Payment tender entry on a retail receipt (supports split tender).
@immutable
class ReceiptPaymentLine {
  const ReceiptPaymentLine({
    required this.method,
    required this.amountPaisa,
    this.reference,
  });

  /// E.g., `CASH`, `FONEPAY_QR`, `CARD`, `KHATA_CREDIT`.
  final String method;
  final int amountPaisa;
  final String? reference;
}

/// Complete domain payload required to print an 80mm PAN-only receipt.
@immutable
class ReceiptPrintData {
  const ReceiptPrintData({
    required this.billNo,
    required this.printedAt,
    required this.cashierName,
    required this.items,
    required this.subtotalPaisa,
    required this.discountPaisa,
    required this.totalPaisa,
    required this.paymentMode,
    this.payments = const <ReceiptPaymentLine>[],
    this.customerName,
    this.customerPhone,
    this.cashTenderedPaisa,
    this.changeDuePaisa,
    this.khataBalanceAfterPaisa,
    this.staticQrPayload,
    this.staticQrLabel = 'Scan to Pay (Fonepay QR)',
    this.storeName,
    this.storeAddress,
    this.storePhone,
    this.storePan,
    this.footerNote,
    this.openCashDrawer = false,
  });

  final String billNo;
  final DateTime printedAt;
  final String cashierName;
  final List<ReceiptLineItem> items;
  final int subtotalPaisa;
  final int discountPaisa;
  final int totalPaisa;
  final String paymentMode;
  final List<ReceiptPaymentLine> payments;
  final String? customerName;
  final String? customerPhone;
  final int? cashTenderedPaisa;
  final int? changeDuePaisa;
  final int? khataBalanceAfterPaisa;
  final String? staticQrPayload;
  final String staticQrLabel;
  final String? storeName;
  final String? storeAddress;
  final String? storePhone;
  final String? storePan;
  final String? footerNote;
  final bool openCashDrawer;
}

/// Complete domain payload required to print an 80mm End-of-Day Z-Report summary.
@immutable
class ZReportPrintData {
  const ZReportPrintData({
    required this.shiftId,
    required this.openedAt,
    required this.closedAt,
    required this.closedByName,
    required this.openingFloatPaisa,
    required this.cashSalesPaisa,
    required this.digitalSalesPaisa,
    required this.khataCashRepaymentsPaisa,
    required this.cashExpensesPaisa,
    required this.expectedCashPaisa,
    required this.actualCashCountedPaisa,
    required this.discrepancyPaisa,
    required this.cashWithdrawnDepositPaisa,
    required this.retainedNextDayFloatPaisa,
    this.notes,
    this.storeName,
    this.storePan,
  });

  final String shiftId;
  final DateTime openedAt;
  final DateTime closedAt;
  final String closedByName;
  final int openingFloatPaisa;
  final int cashSalesPaisa;
  final int digitalSalesPaisa;
  final int khataCashRepaymentsPaisa;
  final int cashExpensesPaisa;
  final int expectedCashPaisa;
  final int actualCashCountedPaisa;
  final int discrepancyPaisa;
  final int cashWithdrawnDepositPaisa;
  final int retainedNextDayFloatPaisa;
  final String? notes;
  final String? storeName;
  final String? storePan;
}

/// Builds 80mm PAN-only (non-VAT) ESC/POS byte payloads for the Xlab 365T.
class EscPosReceiptBuilder {
  const EscPosReceiptBuilder({
    this.config = const PrinterConfig(),
    this.lineWidth = defaultLineWidth,
  });

  /// 80mm roll (576 printable dots) in Font A (12x24 dots) = 48 columns.
  static const int defaultLineWidth = 48;

  /// Vendor firmware switch command (`1F 1B 1F 02 20 31 0D 0A`).
  static Uint8List get modeSwitchCommand => XlabProtocol.modeSwitchToReceipt;

  /// Feed and partial cut command (`1D 56 41 00`).
  static Uint8List get cutCommand => XlabProtocol.escPosCutCommand;

  static final DateFormat _dateFormat = DateFormat('yyyy-MM-dd HH:mm');

  final PrinterConfig config;
  final int lineWidth;

  /// Encodes [data] into a complete ESC/POS receipt byte buffer ending in
  /// `1D 56 41 00` (feed and cut).
  Uint8List build(ReceiptPrintData data) {
    _validate(data);

    final out = BytesBuilder(copy: false);

    // Initialize printer & select left margin/default line spacing.
    out.add(const <int>[0x1B, 0x40]); // ESC @

    // --- Store Header (Centered, PAN-only) ---
    final storeName = _clean(data.storeName ?? config.storeName);
    final storeAddress = _clean(data.storeAddress ?? config.storeAddress);
    final storePhone = _clean(data.storePhone ?? config.storePhone);
    final storePan = _clean(data.storePan ?? config.storePan);

    _setAlign(out, _Align.center);
    _setBold(out, true);
    _setTextSize(out, 0x11); // 2x width & height (24 cols max)
    for (final line in _wrapText(
      storeName.isEmpty ? 'Pasal Cosmetics' : storeName,
      lineWidth ~/ 2,
    )) {
      _writeLine(out, line);
    }
    _setTextSize(out, 0x00);
    _setBold(out, false);

    if (storeAddress.isNotEmpty) {
      for (final line in _wrapText(storeAddress, lineWidth)) {
        _writeLine(out, line);
      }
    }
    if (storePhone.isNotEmpty) {
      _writeLine(out, 'Tel: $storePhone');
    }
    if (storePan.isNotEmpty) {
      final panLine = RegExp(r'^pan\s*:?', caseSensitive: false).hasMatch(storePan)
          ? storePan.replaceFirst(RegExp(r'^pan\s*:?\s*', caseSensitive: false), 'PAN: ')
          : 'PAN: $storePan';
      _writeLine(out, panLine);
    }
    _writeLine(out, 'RETAIL BILL');
    _writeDivider(out, '=');

    // --- Bill Metadata ---
    _setAlign(out, _Align.left);
    _writePair(
      out,
      'Bill: ${_clean(data.billNo)}',
      _dateFormat.format(data.printedAt),
    );
    _writeLine(out, 'Cashier: ${_clean(data.cashierName)}');

    final custName = _clean(data.customerName ?? '');
    final custPhone = _clean(data.customerPhone ?? '');
    if (custName.isNotEmpty || custPhone.isNotEmpty) {
      final customerLabel = [
        if (custName.isNotEmpty) custName,
        if (custPhone.isNotEmpty) '($custPhone)',
      ].join(' ');
      for (final line in _wrapText('Customer: $customerLabel', lineWidth)) {
        _writeLine(out, line);
      }
    }

    _writeDivider(out, '-');
    _setBold(out, true);
    _writePair(out, 'Item / Qty x Rate', 'Amount (Rs)');
    _setBold(out, false);
    _writeDivider(out, '-');

    // --- Itemized Table ---
    for (final item in data.items) {
      final rawProd = _clean(item.productName);
      final prod = rawProd.isEmpty ? 'Item' : rawProd;
      final variant = _clean(item.variantName);
      final title = (variant.isNotEmpty && variant.toLowerCase() != 'standard')
          ? '$prod - $variant'
          : prod;
      for (final line in _wrapText(title, lineWidth)) {
        _writeLine(out, line);
      }
      final unitAmt = ThermalText.formatAmount(item.unitPricePaisa);
      final lineAmt = ThermalText.formatAmount(item.lineTotalPaisa);
      _writePair(out, '  ${item.quantity} x $unitAmt', lineAmt);
    }

    _writeDivider(out, '-');

    // --- Totals (PAN-Only, Strictly Non-VAT) ---
    _writePair(
      out,
      'Subtotal',
      MoneyUtils.formatRs(data.subtotalPaisa, alwaysShowDecimals: true),
    );
    if (data.discountPaisa > 0) {
      _writePair(
        out,
        'Discount',
        '-${MoneyUtils.formatRs(data.discountPaisa, alwaysShowDecimals: true)}',
      );
    }

    _writeDivider(out, '=');
    final netStr = MoneyUtils.formatRs(data.totalPaisa, alwaysShowDecimals: true);
    const totalLabel = 'NET TOTAL';
    _setBold(out, true);
    if (totalLabel.length + 1 + netStr.length <= lineWidth ~/ 2) {
      _setTextSize(out, 0x11); // Double width & height when it fits 24 cols
      _writePair(out, totalLabel, netStr, width: lineWidth ~/ 2);
    } else {
      _setTextSize(out, 0x01); // Double height only for very large totals
      _writePair(out, totalLabel, netStr, width: lineWidth);
    }
    _setTextSize(out, 0x00);
    _setBold(out, false);
    _writeDivider(out, '=');

    // --- Payment Breakdown ---
    _writeLine(out, 'Payment: ${_formatMethodLabel(data.paymentMode)}');
    for (final payment in data.payments) {
      final label = '  ${_formatMethodLabel(payment.method)}';
      final amt = MoneyUtils.formatRs(
        payment.amountPaisa,
        alwaysShowDecimals: true,
      );
      _writePair(out, label, amt);
      final ref = _clean(payment.reference ?? '');
      if (ref.isNotEmpty) {
        _writeLine(out, '    Ref: $ref');
      }
    }

    if (data.cashTenderedPaisa != null) {
      _writePair(
        out,
        'Cash Tendered',
        MoneyUtils.formatRs(data.cashTenderedPaisa!, alwaysShowDecimals: true),
      );
    }
    if (data.changeDuePaisa != null) {
      _setBold(out, true);
      _writePair(
        out,
        'CHANGE DUE',
        MoneyUtils.formatRs(data.changeDuePaisa!, alwaysShowDecimals: true),
      );
      _setBold(out, false);
    }
    if (data.khataBalanceAfterPaisa != null) {
      _writePair(
        out,
        'Khata Balance Due',
        MoneyUtils.formatRs(
          data.khataBalanceAfterPaisa!,
          alwaysShowDecimals: true,
        ),
      );
    }

    // --- Optional Static Fonepay QR ---
    final qrPayload = (data.staticQrPayload ?? '').trim();
    if (qrPayload.isNotEmpty) {
      _writeLine(out, '');
      _setAlign(out, _Align.center);
      _writeLine(out, _clean(data.staticQrLabel));
      _writeQrCode(out, qrPayload);
    }

    // --- Footer & Feed/Cut (`1D 56 41 00`) ---
    final footer = _clean(data.footerNote ?? config.receiptFooter);
    if (footer.isNotEmpty) {
      _writeLine(out, '');
      _setAlign(out, _Align.center);
      for (final line in _wrapText(footer, lineWidth)) {
        _writeLine(out, line);
      }
    }

    out.add(const <int>[0x1B, 0x64, 0x04]); // ESC d 4 (feed 4 lines before cut)
    out.add(XlabProtocol.escPosCutCommand); // 1D 56 41 00

    if (data.openCashDrawer) {
      out.add(XlabProtocol.escPosCashDrawerKick);
    }

    return out.toBytes();
  }

  void _validate(ReceiptPrintData data) {
    if (lineWidth < 24) {
      throw PrinterPayloadException('lineWidth must be >= 24, got $lineWidth');
    }
    if (_clean(data.billNo).isEmpty) {
      throw const PrinterPayloadException('billNo must not be empty');
    }
    if (data.items.isEmpty) {
      throw const PrinterPayloadException('Receipt must have at least 1 item');
    }
    for (final item in data.items) {
      if (item.productName.trim().isEmpty) {
        throw const PrinterPayloadException('Item productName must not be empty');
      }
      if (item.quantity <= 0) {
        throw PrinterPayloadException(
          'Invalid quantity ${item.quantity} for ${item.productName}',
        );
      }
      if (item.unitPricePaisa < 0 ||
          item.lineTotalPaisa < 0 ||
          item.unitPricePaisa > MoneyUtils.maxDecimal12_2Paisa ||
          item.lineTotalPaisa > MoneyUtils.maxDecimal12_2Paisa) {
        throw PrinterPayloadException(
          'Invalid price bounds for ${item.productName}',
        );
      }
    }
    if (data.subtotalPaisa < 0 ||
        data.discountPaisa < 0 ||
        data.totalPaisa < 0 ||
        data.subtotalPaisa > MoneyUtils.maxDecimal12_2Paisa ||
        data.discountPaisa > MoneyUtils.maxDecimal12_2Paisa ||
        data.totalPaisa > MoneyUtils.maxDecimal12_2Paisa) {
      throw const PrinterPayloadException(
        'Receipt totals out of valid range',
      );
    }
    if (data.subtotalPaisa - data.discountPaisa != data.totalPaisa) {
      throw PrinterPayloadException(
        'Receipt total mismatch: ${data.subtotalPaisa} - ${data.discountPaisa} != ${data.totalPaisa}',
      );
    }
    for (final payment in data.payments) {
      if (payment.amountPaisa < 0 ||
          payment.amountPaisa > MoneyUtils.maxDecimal12_2Paisa) {
        throw PrinterPayloadException(
          'Invalid payment amount ${payment.amountPaisa} for ${payment.method}',
        );
      }
    }
    if ((data.cashTenderedPaisa ?? 0) < 0 || (data.changeDuePaisa ?? 0) < 0) {
      throw const PrinterPayloadException(
        'Cash tendered and change due cannot be negative',
      );
    }
  }

  void _setAlign(BytesBuilder out, _Align align) {
    out.add(<int>[0x1B, 0x61, align.code]);
  }

  void _setBold(BytesBuilder out, bool enabled) {
    out.add(<int>[0x1B, 0x45, enabled ? 0x01 : 0x00]);
  }

  void _setTextSize(BytesBuilder out, int sizeByte) {
    out.add(<int>[0x1D, 0x21, sizeByte]);
  }

  void _writeLine(BytesBuilder out, String text) {
    out.add(ascii.encode(text));
    out.addByte(0x0A); // LF
  }

  void _writeDivider(BytesBuilder out, String ch) {
    _writeLine(out, ch * lineWidth);
  }

  void _writePair(BytesBuilder out, String left, String right, {int? width}) {
    final w = width ?? lineWidth;
    if (left.length + 1 + right.length <= w) {
      final spaces = w - left.length - right.length;
      _writeLine(out, '$left${' ' * spaces}$right');
      return;
    }
    for (final line in _wrapText(left, w)) {
      _writeLine(out, line);
    }
    if (right.length > w) {
      for (final line in _wrapText(right, w)) {
        _writeLine(out, line);
      }
      return;
    }
    final pad = w - right.length;
    _writeLine(out, '${' ' * pad}$right');
  }

  void _writeQrCode(BytesBuilder out, String payload) {
    final payloadBytes = utf8.encode(payload);
    final storeLen = payloadBytes.length + 3;
    if (storeLen > 7092) {
      throw const PrinterPayloadException('QR payload exceeds ESC/POS limit');
    }
    final pL = storeLen & 0xFF;
    final pH = (storeLen >> 8) & 0xFF;

    // 1. Select Model 2
    out.add(const <int>[0x1D, 0x28, 0x6B, 0x04, 0x00, 0x31, 0x41, 0x32, 0x00]);
    // 2. Module size = 6 dots
    out.add(const <int>[0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x43, 0x06]);
    // 3. Error correction level L (48 = 0x30)
    out.add(const <int>[0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x45, 0x30]);
    // 4. Store data in symbol buffer
    out.add(<int>[0x1D, 0x28, 0x6B, pL, pH, 0x31, 0x50, 0x30]);
    out.add(payloadBytes);
    // 5. Print stored symbol
    out.add(const <int>[0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30]);
    out.addByte(0x0A);
  }

  List<String> _wrapText(String text, int maxCols) {
    if (text.isEmpty) return const <String>[''];
    if (text.length <= maxCols) return <String>[text];

    final lines = <String>[];
    var current = StringBuffer();
    for (final word in text.split(' ')) {
      if (word.isEmpty) continue;
      if (word.length > maxCols) {
        if (current.isNotEmpty) {
          lines.add(current.toString());
          current = StringBuffer();
        }
        for (var i = 0; i < word.length; i += maxCols) {
          final end = (i + maxCols < word.length) ? i + maxCols : word.length;
          lines.add(word.substring(i, end));
        }
        continue;
      }
      if (current.isEmpty) {
        current.write(word);
      } else if (current.length + 1 + word.length <= maxCols) {
        current.write(' $word');
      } else {
        lines.add(current.toString());
        current = StringBuffer()..write(word);
      }
    }
    if (current.isNotEmpty) {
      lines.add(current.toString());
    }
    return lines;
  }

  String _formatMethodLabel(String method) {
    return switch (method.trim().toUpperCase()) {
      'CASH' => 'Cash',
      'FONEPAY_QR' => 'Fonepay QR',
      'CARD' => 'Card',
      'KHATA_CREDIT' => 'Customer Khata',
      'SPLIT' => 'Split Payment',
      _ => _clean(method),
    };
  }

  String _clean(String value) =>
      ThermalText.sanitizeAscii(value, allowDoubleQuotes: true);

  /// Encodes an 80mm End-of-Day Z-Report summary ending in `1D 56 41 00`.
  Uint8List buildZReport(ZReportPrintData data) {
    final out = BytesBuilder(copy: false);
    out.add(const <int>[0x1B, 0x40]); // ESC @

    final storeName = _clean(data.storeName ?? config.storeName);
    final storePan = _clean(data.storePan ?? config.storePan);

    _setAlign(out, _Align.center);
    _setBold(out, true);
    _setTextSize(out, 0x11);
    for (final line in _wrapText(
      storeName.isEmpty ? 'Pasal Cosmetics' : storeName,
      lineWidth ~/ 2,
    )) {
      _writeLine(out, line);
    }
    _setTextSize(out, 0x00);
    if (storePan.isNotEmpty) {
      _writeLine(out, 'PAN: $storePan');
    }
    _writeLine(out, 'END-OF-DAY Z-REPORT');
    _setBold(out, false);
    _writeDivider(out, '=');

    _setAlign(out, _Align.left);
    _writePair(out, 'Shift:', _clean(data.shiftId.substring(0, data.shiftId.length >= 8 ? 8 : data.shiftId.length)));
    _writePair(out, 'Opened:', _dateFormat.format(data.openedAt.toLocal()));
    _writePair(out, 'Closed:', _dateFormat.format(data.closedAt.toLocal()));
    _writePair(out, 'Settled By:', _clean(data.closedByName));
    _writeDivider(out, '-');

    _writePair(out, 'Opening Float', MoneyUtils.formatRs(data.openingFloatPaisa));
    _writePair(out, 'Cash Sales', MoneyUtils.formatRs(data.cashSalesPaisa));
    _writePair(
      out,
      'Khata Cash Repaid',
      MoneyUtils.formatRs(data.khataCashRepaymentsPaisa),
    );
    _writePair(
      out,
      'Cash Expenses',
      '-${MoneyUtils.formatRs(data.cashExpensesPaisa)}',
    );
    _writeDivider(out, '-');

    _setBold(out, true);
    _writePair(out, 'EXPECTED CASH', MoneyUtils.formatRs(data.expectedCashPaisa));
    _writePair(
      out,
      'ACTUAL COUNTED',
      MoneyUtils.formatRs(data.actualCashCountedPaisa),
    );
    final discSign = data.discrepancyPaisa > 0 ? '+' : '';
    _writePair(
      out,
      'DISCREPANCY',
      '$discSign${MoneyUtils.formatRs(data.discrepancyPaisa)}',
    );
    _setBold(out, false);
    _writeDivider(out, '-');

    _writePair(
      out,
      'Digital Sales (QR/Card)',
      MoneyUtils.formatRs(data.digitalSalesPaisa),
    );
    _writePair(
      out,
      'Bank Drop / Deposit',
      MoneyUtils.formatRs(data.cashWithdrawnDepositPaisa),
    );
    _setBold(out, true);
    _writePair(
      out,
      'NEXT-DAY FLOAT',
      MoneyUtils.formatRs(data.retainedNextDayFloatPaisa),
    );
    _setBold(out, false);

    if (data.notes != null && data.notes!.trim().isNotEmpty) {
      _writeDivider(out, '-');
      for (final line in _wrapText('Notes: ${_clean(data.notes!.trim())}', lineWidth)) {
        _writeLine(out, line);
      }
    }

    _writeDivider(out, '=');
    _setAlign(out, _Align.center);
    _writeLine(out, '*** Z-REPORT VERIFIED ***');
    out.add(const <int>[0x0A, 0x0A, 0x0A]);
    out.add(cutCommand);
    return out.toBytes();
  }
}

enum _Align {
  left(0x00),
  center(0x01);

  const _Align(this.code);
  final int code;
}
