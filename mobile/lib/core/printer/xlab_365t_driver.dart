import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'esc_pos_receipt_builder.dart';
import 'printer_config.dart';
import 'printer_encoding.dart';
import 'tspl_label_builder.dart';

typedef DelayCallback = Future<void> Function(Duration duration);

/// Serializes raw TCP 9100 print/switch jobs across driver rebuilds so
/// concurrent callers or config updates never interleave wire bytes.
class PrinterJobQueue {
  Future<void> _serialQueue = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _serialQueue = _serialQueue.then((_) async {
      try {
        final result = await action();
        if (!completer.isCompleted) {
          completer.complete(result);
        }
      } catch (e, st) {
        if (!completer.isCompleted) {
          completer.completeError(e, st);
        }
      }
    });
    return completer.future;
  }
}

/// Raw TCP Port 9100 (`dart:io` Socket) driver for the Xlab 365T / XP-365B
/// dual-mode thermal printer (`192.168.1.100:9100`).
class Xlab365tDriver {
  Xlab365tDriver({
    this.config = const PrinterConfig(),
    DelayCallback? delay,
    PrinterJobQueue? queue,
  })  : _delay = delay ?? Future<void>.delayed,
        _queue = queue ?? PrinterJobQueue();

  final PrinterConfig config;
  final DelayCallback _delay;
  final PrinterJobQueue _queue;

  /// Switches firmware parser mode over TCP 9100 and waits
  /// [PrinterConfig.modeSwitchDelay] (`1.5s` default) before returning.
  Future<void> switchMode(PrinterMode mode) {
    return _synchronized(() => _switchModeLocked(mode));
  }

  /// Sends raw pre-built bytes over a fresh TCP 9100 connection.
  Future<void> sendRaw(List<int> bytes) {
    return _synchronized(() => _sendBytesLocked(bytes));
  }

  /// Builds and prints an 80mm PAN-only ESC/POS receipt.
  ///
  /// When [autoSwitch] (or [PrinterConfig.autoSwitchMode]) is true, sends the
  /// Receipt mode switch command (`1F 1B 1F 02 20 31 0D 0A`), waits the 1.5s
  /// parser initialization delay, and dispatches the receipt bytes.
  Future<Uint8List> printReceipt(
    ReceiptPrintData data, {
    bool? autoSwitch,
  }) async {
    final builder = EscPosReceiptBuilder(config: config);
    final payload = builder.build(data);
    final shouldSwitch = autoSwitch ?? config.autoSwitchMode;

    await _synchronized(() async {
      if (shouldSwitch) {
        await _switchModeLocked(PrinterMode.receipt);
      }
      await _sendBytesLocked(payload);
    });
    return payload;
  }

  /// Builds and prints an 80mm End-of-Day Z-Report summary.
  Future<Uint8List> printZReport(
    ZReportPrintData data, {
    bool? autoSwitch,
  }) async {
    final builder = EscPosReceiptBuilder(config: config);
    final payload = builder.buildZReport(data);
    final shouldSwitch = autoSwitch ?? config.autoSwitchMode;

    await _synchronized(() async {
      if (shouldSwitch) {
        await _switchModeLocked(PrinterMode.receipt);
      }
      await _sendBytesLocked(payload);
    });
    return payload;
  }

  /// Builds and prints a list of 62x20mm dual-column TSPL barcode stickers.
  Future<Uint8List> printLabels(
    List<BatchLabelData> labels, {
    TsplLabelStyle style = TsplLabelStyle.barcode128,
    int density = 13,
    int speed = 4,
    bool? autoSwitch,
  }) async {
    final builder = TsplLabelBuilder(density: density, speed: speed);
    final payload = builder.buildLabels(labels, style: style);
    final shouldSwitch = autoSwitch ?? config.autoSwitchMode;

    await _synchronized(() async {
      if (shouldSwitch) {
        await _switchModeLocked(PrinterMode.label);
      }
      await _sendBytesLocked(payload);
    });
    return payload;
  }

  /// Builds and prints [quantity] copies of a single batch sticker on 62x20mm
  /// dual-column media.
  Future<Uint8List> printBatchCopies(
    BatchLabelData label, {
    required int quantity,
    TsplLabelStyle style = TsplLabelStyle.barcode128,
    int density = 13,
    int speed = 4,
    bool? autoSwitch,
  }) async {
    final builder = TsplLabelBuilder(density: density, speed: speed);
    final payload = builder.buildBatchCopies(
      label,
      quantity: quantity,
      style: style,
    );
    final shouldSwitch = autoSwitch ?? config.autoSwitchMode;

    await _synchronized(() async {
      if (shouldSwitch) {
        await _switchModeLocked(PrinterMode.label);
      }
      await _sendBytesLocked(payload);
    });
    return payload;
  }

  /// Triggers TSPL gap sensor calibration (`GAPDETECT`) for 62x20mm rolls.
  Future<void> calibrateLabels({bool? autoSwitch}) {
    final payload = const TsplLabelBuilder().buildCalibrationCommand();
    final shouldSwitch = autoSwitch ?? config.autoSwitchMode;

    return _synchronized(() async {
      if (shouldSwitch) {
        await _switchModeLocked(PrinterMode.label);
      }
      await _sendBytesLocked(payload);
    });
  }

  /// Verifies raw TCP reachability to [PrinterConfig.host]:[PrinterConfig.port]
  /// and returns connection latency on success.
  Future<Duration> testConnection() {
    return _synchronized(() async {
      final sw = Stopwatch()..start();
      final socket = await _connect();
      final sub = socket.listen((_) {}, onError: (_) {}, cancelOnError: true);
      try {
        await socket.close().timeout(config.ioTimeout);
      } on TimeoutException catch (e) {
        throw PrinterConnectionException(
          'Timed out closing test connection to ${config.host}:${config.port}',
          e,
        );
      } on SocketException catch (e) {
        throw PrinterConnectionException(
          'Socket error during test connection to ${config.host}:${config.port}',
          e,
        );
      } on OSError catch (e) {
        throw PrinterConnectionException(
          'OS error during test connection to ${config.host}:${config.port}',
          e,
        );
      } finally {
        await sub.cancel();
        socket.destroy();
      }
      sw.stop();
      return sw.elapsed;
    });
  }

  /// Queries real-time printer status using ESC/POS `DLE EOT` (`0x10 0x04`)
  /// or TSPL `<ESC>!?` (`0x1B 0x21 0x3F`) without triggering a mode switch.
  Future<PrinterStatus> probeStatus({
    PrinterMode mode = PrinterMode.receipt,
  }) {
    return _synchronized(() async {
      final socket = await _connect();
      final reader = _SocketByteReader(socket);
      try {
        switch (mode) {
          case PrinterMode.label:
            socket.add(XlabProtocol.tsplStatusQuery);
            await socket.flush().timeout(config.ioTimeout);
            final bytes = await reader.readExact(1, config.ioTimeout);
            return _parseTsplStatus(bytes[0]);

          case PrinterMode.receipt:
            socket.add(XlabProtocol.escPosStatusQuery1);
            await socket.flush().timeout(config.ioTimeout);
            final b1 = (await reader.readExact(1, config.ioTimeout))[0];

            socket.add(XlabProtocol.escPosStatusQuery2);
            await socket.flush().timeout(config.ioTimeout);
            final b2 = (await reader.readExact(1, config.ioTimeout))[0];
            return _parseEscPosStatus(b1, b2);
        }
      } on PrinterException {
        rethrow;
      } on TimeoutException catch (e) {
        throw PrinterConnectionException(
          'Timed out waiting for printer status from ${config.host}:${config.port}',
          e,
        );
      } on SocketException catch (e) {
        throw PrinterConnectionException(
          'Socket error probing printer status at ${config.host}:${config.port}',
          e,
        );
      } on OSError catch (e) {
        throw PrinterConnectionException(
          'OS error probing printer status at ${config.host}:${config.port}',
          e,
        );
      } on StateError catch (e) {
        throw PrinterConnectionException(
          'Stream error probing printer status at ${config.host}:${config.port}',
          e,
        );
      } finally {
        await reader.dispose();
        socket.destroy();
      }
    });
  }

  Future<void> _switchModeLocked(PrinterMode mode) async {
    final cmd = switch (mode) {
      PrinterMode.receipt => XlabProtocol.modeSwitchToReceipt,
      PrinterMode.label => XlabProtocol.modeSwitchToLabel,
    };
    await _sendBytesLocked(cmd);
    if (config.modeSwitchDelay > Duration.zero) {
      await _delay(config.modeSwitchDelay);
    }
  }

  Future<void> _sendBytesLocked(List<int> bytes) async {
    final socket = await _connect();
    // Drain inbound stream so async TCP RSTs cannot surface as uncaught zone
    // errors and sockets do not linger in FIN_WAIT_2 / CLOSE_WAIT.
    final sub = socket.listen((_) {}, onError: (_) {}, cancelOnError: true);
    try {
      socket.add(bytes);
      await socket.flush().timeout(config.ioTimeout);
      await socket.close().timeout(config.ioTimeout);
    } on TimeoutException catch (e) {
      throw PrinterConnectionException(
        'Timed out sending ${bytes.length} bytes to ${config.host}:${config.port}',
        e,
      );
    } on SocketException catch (e) {
      throw PrinterConnectionException(
        'Failed sending ${bytes.length} bytes to ${config.host}:${config.port}',
        e,
      );
    } on OSError catch (e) {
      throw PrinterConnectionException(
        'OS error sending ${bytes.length} bytes to ${config.host}:${config.port}',
        e,
      );
    } on StateError catch (e) {
      throw PrinterConnectionException(
        'Socket closed while sending ${bytes.length} bytes to ${config.host}:${config.port}',
        e,
      );
    } finally {
      await sub.cancel();
      socket.destroy();
    }
  }

  Future<Socket> _connect() async {
    final host = config.host.trim();
    if (host.isEmpty || config.port <= 0 || config.port > 65535) {
      throw PrinterConnectionException(
        'Invalid printer endpoint ${config.host}:${config.port}',
      );
    }
    try {
      return await Socket.connect(
        host,
        config.port,
        timeout: config.connectTimeout,
      );
    } on TimeoutException catch (e) {
      throw PrinterConnectionException(
        'Connection timeout to $host:${config.port}',
        e,
      );
    } on SocketException catch (e) {
      throw PrinterConnectionException(
        'Unable to connect to printer at $host:${config.port}',
        e,
      );
    } on OSError catch (e) {
      throw PrinterConnectionException(
        'OS error connecting to printer at $host:${config.port}',
        e,
      );
    }
  }

  Future<T> _synchronized<T>(Future<T> Function() action) => _queue.run(action);

  PrinterStatus _parseTsplStatus(int statusByte) {
    final coverOpen = (statusByte & 0x01) != 0;
    final paperJam = (statusByte & 0x02) != 0;
    final paperOut = (statusByte & 0x04) != 0;
    final ribbonOut = (statusByte & 0x08) != 0;
    final paused = (statusByte & 0x10) != 0;
    final printing = (statusByte & 0x20) != 0;
    final otherError = (statusByte & 0x80) != 0;
    final hasError = coverOpen || paperJam || paperOut || ribbonOut || otherError;
    final isReady = statusByte == 0x00;

    final reasons = <String>[
      if (coverOpen) 'Cover Open',
      if (paperJam) 'Paper Jam',
      if (paperOut) 'Out of Paper',
      if (ribbonOut) 'Ribbon Out',
      if (paused) 'Paused',
      if (printing) 'Printing',
      if (otherError) 'Hardware Error',
    ];

    return PrinterStatus(
      mode: PrinterMode.label,
      isOnline: !hasError,
      isReady: isReady,
      coverOpen: coverOpen,
      paperOut: paperOut,
      hasError: hasError,
      rawBytes: <int>[statusByte],
      message: isReady
          ? 'Label Mode Ready'
          : 'Label Mode: ${reasons.join(', ')}',
    );
  }

  PrinterStatus _parseEscPosStatus(int b1, int b2) {
    final offline = (b1 & 0x08) != 0;
    final coverOpen = (b2 & 0x04) != 0;
    final paperOut = (b2 & 0x20) != 0;
    final hasError = (b2 & 0x40) != 0 || coverOpen || paperOut;
    final isReady = !offline && !hasError;

    final reasons = <String>[
      if (offline) 'Offline',
      if (coverOpen) 'Cover Open',
      if (paperOut) 'Out of Paper',
      if ((b2 & 0x40) != 0) 'Printer Error',
    ];

    return PrinterStatus(
      mode: PrinterMode.receipt,
      isOnline: !offline,
      isReady: isReady,
      coverOpen: coverOpen,
      paperOut: paperOut,
      hasError: hasError,
      rawBytes: <int>[b1, b2],
      message: isReady
          ? 'Receipt Mode Ready'
          : 'Receipt Mode: ${reasons.join(', ')}',
    );
  }
}

/// Buffers incoming TCP chunks from a single-subscription [Socket] stream
/// so sequential status queries can read exact byte counts safely.
class _SocketByteReader {
  _SocketByteReader(Socket socket) {
    _sub = socket.listen(
      (chunk) {
        _buffer.addAll(chunk);
        _drainWaiter();
      },
      onError: (Object error, StackTrace stackTrace) {
        _error = error;
        _stackTrace = stackTrace;
        _failWaiter(error, stackTrace);
      },
      onDone: () {
        _done = true;
        _drainWaiter();
      },
      cancelOnError: true,
    );
  }

  final List<int> _buffer = <int>[];
  late final StreamSubscription<Uint8List> _sub;

  Completer<void>? _waiter;
  int _waitTarget = 0;
  Object? _error;
  StackTrace? _stackTrace;
  bool _done = false;

  Future<List<int>> readExact(int count, Duration timeout) async {
    while (_buffer.length < count) {
      if (_error != null) {
        Error.throwWithStackTrace(_error!, _stackTrace ?? StackTrace.current);
      }
      if (_done) {
        throw const PrinterConnectionException(
          'Printer closed socket before returning full status response',
        );
      }
      _waitTarget = count;
      final waiter = Completer<void>();
      _waiter = waiter;
      try {
        await waiter.future.timeout(timeout);
      } finally {
        if (identical(_waiter, waiter)) {
          _waiter = null;
        }
      }
    }
    final result = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return result;
  }

  void _drainWaiter() {
    final waiter = _waiter;
    if (waiter == null || waiter.isCompleted) return;
    if (_buffer.length >= _waitTarget) {
      _waiter = null;
      waiter.complete();
    } else if (_done) {
      _waiter = null;
      waiter.completeError(
        const PrinterConnectionException(
          'Printer closed socket before returning full status response',
        ),
      );
    }
  }

  void _failWaiter(Object error, StackTrace st) {
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) {
      _waiter = null;
      waiter.completeError(error, st);
    }
  }

  Future<void> dispose() => _sub.cancel();
}
