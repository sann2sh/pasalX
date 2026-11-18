import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pasalx_mobile/core/printer/printer.dart';

void main() {
  group('EscPosReceiptBuilder (80mm PAN-only)', () {
    test('mode switch and cut commands match exact vendor hex sequences', () {
      expect(
        EscPosReceiptBuilder.modeSwitchCommand,
        equals(const <int>[0x1F, 0x1B, 0x1F, 0x02, 0x20, 0x31, 0x0D, 0x0A]),
      );
      expect(
        EscPosReceiptBuilder.cutCommand,
        equals(const <int>[0x1D, 0x56, 0x41, 0x00]),
      );
    });

    test('builds PAN-only 80mm receipt without VAT and ends with cut command', () {
      const builder = EscPosReceiptBuilder(
        config: PrinterConfig(
          storeName: 'Perla Cosmetics',
          storeAddress: 'New Road, Kathmandu',
          storePhone: '01-5551234',
          storePan: '601234567',
        ),
      );

      final bytes = builder.build(
        ReceiptPrintData(
          billNo: '01-0042',
          printedAt: DateTime(2026, 11, 15, 10, 30),
          cashierName: 'Sunita Shrestha',
          customerName: 'Sita Sharma',
          customerPhone: '9841000001',
          items: const <ReceiptLineItem>[
            ReceiptLineItem(
              productName: 'Fit Me Matte Foundation',
              variantName: '#128 Warm Nude',
              quantity: 2,
              unitPricePaisa: 135000,
              lineTotalPaisa: 270000,
            ),
            ReceiptLineItem(
              productName: 'Hair Rubbers',
              variantName: 'Standard',
              quantity: 1,
              unitPricePaisa: 5000,
              lineTotalPaisa: 5000,
            ),
          ],
          subtotalPaisa: 275000,
          discountPaisa: 15000,
          totalPaisa: 260000,
          paymentMode: 'SPLIT',
          payments: const <ReceiptPaymentLine>[
            ReceiptPaymentLine(method: 'CASH', amountPaisa: 200000),
            ReceiptPaymentLine(
              method: 'FONEPAY_QR',
              amountPaisa: 60000,
              reference: 'FP-998811',
            ),
          ],
          cashTenderedPaisa: 200000,
          changeDuePaisa: 0,
        ),
      );

      // Starts with ESC @ (1B 40)
      expect(bytes.sublist(0, 2), equals(const <int>[0x1B, 0x40]));
      // Ends with ESC d 4 + GS V A 0 (1B 64 04 1D 56 41 00)
      expect(
        bytes.sublist(bytes.length - 7),
        equals(const <int>[0x1B, 0x64, 0x04, 0x1D, 0x56, 0x41, 0x00]),
      );

      final text = latin1.decode(bytes);
      expect(text, contains('Perla Cosmetics'));
      expect(text, contains('PAN: 601234567'));
      expect(text, contains('RETAIL BILL'));
      expect(text, contains('Bill: 01-0042'));
      expect(text, contains('2026-11-15 10:30'));
      expect(text, contains('Cashier: Sunita Shrestha'));
      expect(text, contains('Customer: Sita Sharma (9841000001)'));
      expect(text, contains('Fit Me Matte Foundation - #128 Warm Nude'));
      expect(text, contains('2 x 1,350.00'));
      expect(text, contains('2,700.00'));
      // "Standard" variant label is omitted for clean generic item lines.
      expect(text, contains('Hair Rubbers'));
      expect(text, isNot(contains('Hair Rubbers - Standard')));
      expect(text, contains('Subtotal'));
      expect(text, contains('Discount'));
      expect(text, contains('-Rs. 150.00'));
      expect(text, contains('NET TOTAL'));
      expect(text, contains('Rs. 2,600.00'));
      expect(text, contains('Split Payment'));
      expect(text, contains('Ref: FP-998811'));
      expect(text, contains('CHANGE DUE'));

      // Strictly PAN-only non-VAT per TECHNICAL_SPEC.md §3.4 & §9.7.
      expect(text.toUpperCase(), isNot(contains('VAT')));
      expect(text, isNot(contains('13%')));
    });

    test('encodes static Fonepay QR via GS ( k command and optional drawer kick', () {
      const builder = EscPosReceiptBuilder();
      const qr = 'fonepay://pay?pa=pasal@nabil&am=1350.00';

      final bytes = builder.build(
        ReceiptPrintData(
          billNo: '02-0007',
          printedAt: DateTime(2026, 11, 15, 14, 5),
          cashierName: 'Asha',
          items: const <ReceiptLineItem>[
            ReceiptLineItem(
              productName: "L'Oréal Paris Glycolic-Bright Cleanser 100ml",
              variantName: '100ml',
              quantity: 1,
              unitPricePaisa: 135000,
              lineTotalPaisa: 135000,
            ),
          ],
          subtotalPaisa: 135000,
          discountPaisa: 0,
          totalPaisa: 135000,
          paymentMode: 'FONEPAY_QR',
          staticQrPayload: qr,
          openCashDrawer: true,
        ),
      );

      final qrBytes = utf8.encode(qr);
      final storeLen = qrBytes.length + 3;
      final expectedStorePrefix = <int>[
        0x1D,
        0x28,
        0x6B,
        storeLen & 0xFF,
        (storeLen >> 8) & 0xFF,
        0x31,
        0x50,
        0x30,
        ...qrBytes,
      ];

      expect(_indexOfSublist(bytes, expectedStorePrefix), isNonNegative);
      // QR print command 1D 28 6B 03 00 31 51 30
      expect(
        _indexOfSublist(
          bytes,
          const <int>[0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30],
        ),
        isNonNegative,
      );
      // Cut followed by cash drawer kick 1B 70 00 19 FA
      expect(
        bytes.sublist(bytes.length - 9),
        equals(const <int>[
          0x1D, 0x56, 0x41, 0x00,
          0x1B, 0x70, 0x00, 0x19, 0xFA,
        ]),
      );
    });

    test('wraps long lines within 48 columns and handles large totals cleanly', () {
      const builder = EscPosReceiptBuilder();
      final bytes = builder.build(
        ReceiptPrintData(
          billNo: '01-0099',
          printedAt: DateTime(2026, 11, 15, 18, 0),
          cashierName: 'Owner',
          items: const <ReceiptLineItem>[
            ReceiptLineItem(
              productName:
                  "L'Oréal Paris Revitalift 1.5% Hyaluronic Acid Serum",
              variantName: '30ml Glass Dropper Edition',
              quantity: 50,
              unitPricePaisa: 200000,
              lineTotalPaisa: 10000000,
            ),
          ],
          subtotalPaisa: 10000000,
          discountPaisa: 0,
          totalPaisa: 10000000,
          paymentMode: 'CASH',
        ),
      );

      final text = latin1.decode(bytes);
      expect(text, contains("L'Oreal Paris Revitalift 1.5% Hyaluronic Acid"));
      expect(text, contains('NET TOTAL'));
      expect(text, contains('Rs. 100,000.00'));
    });

    test('normalizes pre-prefixed PAN and renders Khata balance due', () {
      const builder = EscPosReceiptBuilder(
        config: PrinterConfig(storePan: 'PAN: 601234567'),
      );
      final bytes = builder.build(
        ReceiptPrintData(
          billNo: '01-0100',
          printedAt: DateTime(2026, 11, 15, 19, 0),
          cashierName: 'Sunita',
          customerName: 'Maya',
          items: const <ReceiptLineItem>[
            ReceiptLineItem(
              productName: 'Rosehip Facial Oil',
              variantName: '30ml',
              quantity: 1,
              unitPricePaisa: 120000,
              lineTotalPaisa: 120000,
            ),
          ],
          subtotalPaisa: 120000,
          discountPaisa: 0,
          totalPaisa: 120000,
          paymentMode: 'KHATA_CREDIT',
          khataBalanceAfterPaisa: 450000,
        ),
      );
      final text = latin1.decode(bytes);
      expect(text, contains('PAN: 601234567'));
      expect(text, isNot(contains('PAN: PAN:')));
      expect(text, contains('Payment: Customer Khata'));
      expect(text, contains('Khata Balance Due'));
      expect(text, contains('Rs. 4,500.00'));
    });

    test('rejects invalid empty or negative payloads', () {
      const builder = EscPosReceiptBuilder();
      expect(
        () => builder.build(
          ReceiptPrintData(
            billNo: '01-0001',
            printedAt: DateTime(2026, 11, 15),
            cashierName: 'Staff',
            items: const <ReceiptLineItem>[],
            subtotalPaisa: 0,
            discountPaisa: 0,
            totalPaisa: 0,
            paymentMode: 'CASH',
          ),
        ),
        throwsA(isA<PrinterPayloadException>()),
      );

      expect(
        () => builder.build(
          ReceiptPrintData(
            billNo: '01-0001',
            printedAt: DateTime(2026, 11, 15),
            cashierName: 'Staff',
            items: const <ReceiptLineItem>[
              ReceiptLineItem(
                productName: 'Lipstick',
                variantName: 'Red',
                quantity: 0,
                unitPricePaisa: 50000,
                lineTotalPaisa: 0,
              ),
            ],
            subtotalPaisa: 0,
            discountPaisa: 0,
            totalPaisa: 0,
            paymentMode: 'CASH',
          ),
        ),
        throwsA(isA<PrinterPayloadException>()),
      );

      // Mismatched subtotal - discount != total
      expect(
        () => builder.build(
          ReceiptPrintData(
            billNo: '01-0002',
            printedAt: DateTime(2026, 11, 15),
            cashierName: 'Staff',
            items: const <ReceiptLineItem>[
              ReceiptLineItem(
                productName: 'Lipstick',
                variantName: 'Red',
                quantity: 1,
                unitPricePaisa: 50000,
                lineTotalPaisa: 50000,
              ),
            ],
            subtotalPaisa: 50000,
            discountPaisa: 5000,
            totalPaisa: 50000,
            paymentMode: 'CASH',
          ),
        ),
        throwsA(isA<PrinterPayloadException>()),
      );

      // Negative tender line
      expect(
        () => builder.build(
          ReceiptPrintData(
            billNo: '01-0003',
            printedAt: DateTime(2026, 11, 15),
            cashierName: 'Staff',
            items: const <ReceiptLineItem>[
              ReceiptLineItem(
                productName: 'Lipstick',
                variantName: 'Red',
                quantity: 1,
                unitPricePaisa: 50000,
                lineTotalPaisa: 50000,
              ),
            ],
            subtotalPaisa: 50000,
            discountPaisa: 0,
            totalPaisa: 50000,
            paymentMode: 'CASH',
            payments: const <ReceiptPaymentLine>[
              ReceiptPaymentLine(method: 'CASH', amountPaisa: -100),
            ],
          ),
        ),
        throwsA(isA<PrinterPayloadException>()),
      );
    });

    test('handles pure Nepali product name fallback without blank line', () {
      const builder = EscPosReceiptBuilder();
      final bytes = builder.build(
        ReceiptPrintData(
          billNo: '01-0101',
          printedAt: DateTime(2026, 11, 15, 20, 0),
          cashierName: 'Sunita',
          items: const <ReceiptLineItem>[
            ReceiptLineItem(
              productName: 'लालीगुँरास क्रिम',
              variantName: 'Standard',
              quantity: 1,
              unitPricePaisa: 50000,
              lineTotalPaisa: 50000,
            ),
          ],
          subtotalPaisa: 50000,
          discountPaisa: 0,
          totalPaisa: 50000,
          paymentMode: 'CASH',
        ),
      );
      final text = latin1.decode(bytes);
      expect(text, contains('\nItem\n  1 x 500.00'));
    });
  });
}

int _indexOfSublist(Uint8List haystack, List<int> needle) {
  if (needle.isEmpty || needle.length > haystack.length) return -1;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var matched = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return i;
  }
  return -1;
}
