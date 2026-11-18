import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pasalx_mobile/core/printer/printer.dart';

void main() {
  group('Xlab365tDriver raw TCP loopback', () {
    late ServerSocket server;
    late List<({DateTime receivedAt, List<int> bytes})> receivedConnections;
    late StreamSubscription<Socket> acceptSub;
    Completer<void>? connectionWaiter;
    int targetConnectionCount = 0;

    Future<void> waitForConnections(int count) async {
      if (receivedConnections.length >= count) return;
      targetConnectionCount = count;
      connectionWaiter = Completer<void>();
      await connectionWaiter!.future.timeout(const Duration(seconds: 2));
    }

    setUp(() async {
      receivedConnections = <({DateTime receivedAt, List<int> bytes})>[];
      connectionWaiter = null;
      targetConnectionCount = 0;
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      acceptSub = server.listen((socket) {
        final chunks = <int>[];
        socket.listen(
          chunks.addAll,
          onDone: () {
            receivedConnections.add((
              receivedAt: DateTime.now(),
              bytes: chunks,
            ));
            socket.close();
            if (connectionWaiter != null &&
                !connectionWaiter!.isCompleted &&
                receivedConnections.length >= targetConnectionCount) {
              connectionWaiter!.complete();
            }
          },
        );
      });
    });

    tearDown(() async {
      await acceptSub.cancel();
      await server.close();
    });

    test('default PrinterConfig targets 192.168.1.100:9100 with 1.5s delay', () {
      const cfg = PrinterConfig();
      expect(cfg.host, '192.168.1.100');
      expect(cfg.port, 9100);
      expect(cfg.modeSwitchDelay, const Duration(milliseconds: 1500));
      expect(cfg.autoSwitchMode, isTrue);
    });

    test(
      'printReceipt switches to ESC/POS mode (1F 1B 1F 02 20 31 0D 0A), '
      'waits >= 1.5s, and transmits receipt ending with 1D 56 41 00',
      () async {
        final driver = Xlab365tDriver(
          config: PrinterConfig(
            host: InternetAddress.loopbackIPv4.address,
            port: server.port,
            storePan: '601234567',
          ),
        );

        final sentPayload = await driver.printReceipt(
          ReceiptPrintData(
            billNo: '01-0042',
            printedAt: DateTime(2026, 11, 15, 11, 15),
            cashierName: 'Sunita',
            items: const <ReceiptLineItem>[
              ReceiptLineItem(
                productName: 'Fit Me Foundation',
                variantName: '#128 Warm Nude',
                quantity: 1,
                unitPricePaisa: 135000,
                lineTotalPaisa: 135000,
              ),
            ],
            subtotalPaisa: 135000,
            discountPaisa: 0,
            totalPaisa: 135000,
            paymentMode: 'CASH',
            cashTenderedPaisa: 150000,
            changeDuePaisa: 15000,
          ),
        );

        await waitForConnections(2);
        expect(receivedConnections.length, 2);

        // Connection 1: exact ESC/POS mode switch command
        expect(
          receivedConnections[0].bytes,
          equals(const <int>[0x1F, 0x1B, 0x1F, 0x02, 0x20, 0x31, 0x0D, 0x0A]),
        );

        // At least 1450ms elapsed between mode switch and payload dispatch
        // (spec requires 1500ms delay; allow tiny clock scheduling jitter).
        final gap = receivedConnections[1]
            .receivedAt
            .difference(receivedConnections[0].receivedAt);
        expect(gap, greaterThanOrEqualTo(const Duration(milliseconds: 1450)));

        // Connection 2: full receipt bytes ending in 1D 56 41 00
        expect(receivedConnections[1].bytes, equals(sentPayload));
        expect(
          receivedConnections[1].bytes.sublist(
            receivedConnections[1].bytes.length - 4,
          ),
          equals(const <int>[0x1D, 0x56, 0x41, 0x00]),
        );
      },
    );

    test(
      'printLabels switches to TSPL mode (1F 1B 1F 02 20 30 0D 0A), '
      'invokes 1.5s delay guard, and dispatches dual-column TSPL',
      () async {
        final recordedDelays = <Duration>[];
        final driver = Xlab365tDriver(
          config: PrinterConfig(
            host: InternetAddress.loopbackIPv4.address,
            port: server.port,
          ),
          delay: (duration) async {
            recordedDelays.add(duration);
          },
        );

        await driver.printBatchCopies(
          BatchLabelData(
            productName: 'Maybelline Fit Me',
            variantName: '#128 Warm Nude',
            stickerBarcode: '100024',
            sellingPricePaisa: 135000,
            expiryDate: DateTime(2026, 5, 31),
          ),
          quantity: 2,
        );

        expect(recordedDelays, equals(<Duration>[const Duration(milliseconds: 1500)]));
        await waitForConnections(2);
        expect(receivedConnections.length, 2);
        expect(
          receivedConnections[0].bytes,
          equals(const <int>[0x1F, 0x1B, 0x1F, 0x02, 0x20, 0x30, 0x0D, 0x0A]),
        );
        final tspl = ascii.decode(receivedConnections[1].bytes);
        expect(tspl, contains('BARCODE 0,50,"128",40,1,0,3,3,"100024"'));
        expect(tspl, contains('BARCODE 238,50,"128",40,1,0,3,3,"100024"'));
      },
    );

    test('serializes concurrent print jobs without interleaving TCP frames', () async {
      final driver = Xlab365tDriver(
        config: PrinterConfig(
          host: InternetAddress.loopbackIPv4.address,
          port: server.port,
          modeSwitchDelay: const Duration(milliseconds: 20),
        ),
      );

      final receiptFuture = driver.printReceipt(
        ReceiptPrintData(
          billNo: '01-0001',
          printedAt: DateTime(2026, 11, 15, 12, 0),
          cashierName: 'Staff A',
          items: const <ReceiptLineItem>[
            ReceiptLineItem(
              productName: 'Lip Gloss',
              variantName: 'Clear',
              quantity: 1,
              unitPricePaisa: 45000,
              lineTotalPaisa: 45000,
            ),
          ],
          subtotalPaisa: 45000,
          discountPaisa: 0,
          totalPaisa: 45000,
          paymentMode: 'CASH',
        ),
      );

      final labelFuture = driver.printLabels(
        <BatchLabelData>[
          BatchLabelData(
            productName: 'Lip Gloss',
            variantName: 'Clear',
            stickerBarcode: '100001',
            sellingPricePaisa: 45000,
            expiryDate: DateTime(2027, 1, 1),
          ),
        ],
      );

      await Future.wait(<Future<void>>[receiptFuture, labelFuture]);
      await waitForConnections(4);

      // Job 1 (receipt): conn 0 = switch(0x31), conn 1 = receipt payload
      // Job 2 (label):   conn 2 = switch(0x30), conn 3 = TSPL payload
      expect(receivedConnections.length, 4);
      expect(
        receivedConnections[0].bytes,
        equals(XlabProtocol.modeSwitchToReceipt),
      );
      expect(
        latin1.decode(receivedConnections[1].bytes),
        contains('Bill: 01-0001'),
      );
      expect(
        receivedConnections[2].bytes,
        equals(XlabProtocol.modeSwitchToLabel),
      );
      expect(
        ascii.decode(receivedConnections[3].bytes),
        contains('SIZE 62 mm,20 mm'),
      );
    });

    test('testConnection succeeds on reachable socket and fails cleanly on closed port', () async {
      final okDriver = Xlab365tDriver(
        config: PrinterConfig(
          host: InternetAddress.loopbackIPv4.address,
          port: server.port,
        ),
      );
      final latency = await okDriver.testConnection();
      expect(latency, greaterThanOrEqualTo(Duration.zero));

      // Grab an unused ephemeral port by binding & closing.
      final tempServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = tempServer.port;
      await tempServer.close();

      final failDriver = Xlab365tDriver(
        config: PrinterConfig(
          host: InternetAddress.loopbackIPv4.address,
          port: deadPort,
          connectTimeout: const Duration(milliseconds: 500),
        ),
      );

      await expectLater(
        failDriver.testConnection(),
        throwsA(isA<PrinterConnectionException>()),
      );

      final badEndpointDriver = Xlab365tDriver(
        config: const PrinterConfig(host: ' ', port: 9100),
      );
      await expectLater(
        badEndpointDriver.testConnection(),
        throwsA(isA<PrinterConnectionException>()),
      );
    });

    test('probeStatus decodes TSPL and ESC/POS responses over TCP', () async {
      // Dedicated responder server for interactive status queries.
      final statusServer =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var tsplResponseByte = 0x00;
      var escPosBytes = <int>[0x12, 0x00]; // online, no error

      final sub = statusServer.listen((socket) {
        final buf = <int>[];
        socket.listen((chunk) {
          buf.addAll(chunk);
          while (buf.length >= 3) {
            final cmd = buf.sublist(0, 3);
            buf.removeRange(0, 3);
            if (_listEquals(cmd, XlabProtocol.tsplStatusQuery)) {
              socket.add(<int>[tsplResponseByte]);
            } else if (_listEquals(cmd, XlabProtocol.escPosStatusQuery1)) {
              socket.add(<int>[escPosBytes[0]]);
            } else if (_listEquals(cmd, XlabProtocol.escPosStatusQuery2)) {
              socket.add(<int>[escPosBytes[1]]);
            }
          }
        });
      });

      addTearDown(() async {
        await sub.cancel();
        await statusServer.close();
      });

      final driver = Xlab365tDriver(
        config: PrinterConfig(
          host: InternetAddress.loopbackIPv4.address,
          port: statusServer.port,
        ),
      );

      // 1. TSPL Ready (0x00)
      final labelOk = await driver.probeStatus(mode: PrinterMode.label);
      expect(labelOk.isReady, isTrue);
      expect(labelOk.coverOpen, isFalse);
      expect(labelOk.paperOut, isFalse);

      // 2. TSPL Cover Open + Out of Paper (0x01 | 0x04 = 0x05)
      tsplResponseByte = 0x05;
      final labelErr = await driver.probeStatus(mode: PrinterMode.label);
      expect(labelErr.isReady, isFalse);
      expect(labelErr.coverOpen, isTrue);
      expect(labelErr.paperOut, isTrue);
      expect(labelErr.hasError, isTrue);

      // 3. ESC/POS Ready
      final receiptOk = await driver.probeStatus(mode: PrinterMode.receipt);
      expect(receiptOk.isReady, isTrue);
      expect(receiptOk.isOnline, isTrue);

      // 4. ESC/POS Offline + Cover Open + Paper Out
      escPosBytes = <int>[0x08, 0x24];
      final receiptErr = await driver.probeStatus(mode: PrinterMode.receipt);
      expect(receiptErr.isReady, isFalse);
      expect(receiptErr.isOnline, isFalse);
      expect(receiptErr.coverOpen, isTrue);
      expect(receiptErr.paperOut, isTrue);
    });

    test('Riverpod providers expose default config and update endpoint cleanly', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(printerConfigProvider).host, '192.168.1.100');
      expect(container.read(printerConfigProvider).port, 9100);
      expect(container.read(xlabPrinterDriverProvider).config.port, 9100);

      container
          .read(printerConfigProvider.notifier)
          .setEndpoint(host: ' 192.168.1.150 ', port: 9100);

      expect(container.read(xlabPrinterDriverProvider).config.host, '192.168.1.150');
      expect(
        identical(
          container.read(printerJobQueueProvider),
          container.read(printerJobQueueProvider),
        ),
        isTrue,
      );
    });

    test('probeStatus throws PrinterConnectionException on timeout', () async {
      final silentServer =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sub = silentServer.listen((_) {});
      addTearDown(() async {
        await sub.cancel();
        await silentServer.close();
      });

      final driver = Xlab365tDriver(
        config: PrinterConfig(
          host: InternetAddress.loopbackIPv4.address,
          port: silentServer.port,
          ioTimeout: const Duration(milliseconds: 150),
        ),
      );
      await expectLater(
        driver.probeStatus(mode: PrinterMode.label),
        throwsA(isA<PrinterConnectionException>()),
      );
    });

    test('autoSwitch=false skips mode switch and calibrateLabels dispatches GAPDETECT', () async {
      final driver = Xlab365tDriver(
        config: PrinterConfig(
          host: InternetAddress.loopbackIPv4.address,
          port: server.port,
          modeSwitchDelay: Duration.zero,
        ),
      );

      await driver.printLabels(
        <BatchLabelData>[
          BatchLabelData(
            productName: 'Toner',
            variantName: '200ml',
            stickerBarcode: '100888',
            sellingPricePaisa: 95000,
            expiryDate: DateTime(2027, 4, 1),
          ),
        ],
        autoSwitch: false,
      );
      await waitForConnections(1);
      expect(receivedConnections.length, 1);
      expect(ascii.decode(receivedConnections[0].bytes), contains('SIZE 62 mm,20 mm'));

      await driver.calibrateLabels(autoSwitch: true);
      await waitForConnections(3);
      expect(receivedConnections.length, 3);
      expect(receivedConnections[1].bytes, equals(XlabProtocol.modeSwitchToLabel));
      expect(ascii.decode(receivedConnections[2].bytes), contains('GAPDETECT'));
    });
  });
}

bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
