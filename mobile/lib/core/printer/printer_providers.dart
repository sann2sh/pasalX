import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../providers/foundation_providers.dart';
import 'printer_config.dart';
import 'xlab_365t_driver.dart';

/// Holds the active Xlab 365T TCP 9100 printer configuration (`192.168.1.100:9100`)
/// and persists edits encrypted inside SQLCipher `sync_metadata`.
class PrinterConfigNotifier extends Notifier<PrinterConfig> {
  static const String _metaKey = 'printer_config_json';
  int _loadEpoch = 0;

  @override
  PrinterConfig build() {
    final db = ref.watch(activeDatabaseProvider);
    if (db != null) {
      final epoch = ++_loadEpoch;
      unawaited(_loadFromDb(db, epoch));
    }
    return const PrinterConfig();
  }

  Future<void> _loadFromDb(AppDatabase db, int epoch) async {
    try {
      final raw = await db.getMetadata(_metaKey);
      if (epoch != _loadEpoch || raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        state = PrinterConfig.fromJson(decoded);
      }
    } catch (_) {
      // Safe no-op if DB closes during teardown or JSON is corrupt.
    }
  }

  void updateConfig(PrinterConfig config) {
    _loadEpoch++;
    state = config;
    final db = ref.read(activeDatabaseProvider);
    if (db != null) {
      unawaited(
        db
            .setMetadata(_metaKey, jsonEncode(config.toJson()))
            .catchError((_) {}),
      );
    }
  }

  void setEndpoint({required String host, int port = PrinterConfig.defaultPort}) {
    updateConfig(state.copyWith(host: host.trim(), port: port));
  }
}

final printerConfigProvider =
    NotifierProvider<PrinterConfigNotifier, PrinterConfig>(
  PrinterConfigNotifier.new,
);

/// Shared TCP 9100 job queue preserved across [printerConfigProvider] updates.
final printerJobQueueProvider = Provider<PrinterJobQueue>((ref) {
  return PrinterJobQueue();
});

/// Active [Xlab365tDriver] bound to [printerConfigProvider].
final xlabPrinterDriverProvider = Provider<Xlab365tDriver>((ref) {
  final config = ref.watch(printerConfigProvider);
  final queue = ref.watch(printerJobQueueProvider);
  return Xlab365tDriver(config: config, queue: queue);
});
