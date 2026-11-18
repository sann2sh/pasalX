import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pasalx_mobile/core/database/app_database.dart';
import 'package:pasalx_mobile/core/printer/esc_pos_receipt_builder.dart';
import 'package:pasalx_mobile/core/printer/printer_config.dart';
import 'package:pasalx_mobile/core/printer/printer_providers.dart';
import 'package:pasalx_mobile/core/printer/tspl_label_builder.dart';
import 'package:pasalx_mobile/core/printer/xlab_365t_driver.dart';
import 'package:pasalx_mobile/core/providers/foundation_providers.dart';
import 'package:pasalx_mobile/core/security/keystore_dek_manager.dart';
import 'package:pasalx_mobile/core/security/ram_key_holder.dart';
import 'package:pasalx_mobile/core/theme/app_theme.dart';
import 'package:pasalx_mobile/core/theme/pasal_widgets.dart';
import 'package:pasalx_mobile/features/pos/data/pos_repository.dart';
import 'package:pasalx_mobile/features/pos/presentation/khata_ledger_screen.dart';
import 'package:pasalx_mobile/features/settings/presentation/backup_settings_screen.dart';
import 'package:pasalx_mobile/features/settings/presentation/printer_settings_screen.dart';
import 'package:pasalx_mobile/features/settings/presentation/settings_screen.dart';
import 'package:uuid/uuid.dart';

class _FixedDbNotifier extends ActiveDatabaseNotifier {
  _FixedDbNotifier(this._db);
  final AppDatabase _db;

  @override
  AppDatabase? build() => _db;
}

class _InMemoryStore implements SecureKeyValueStore {
  final Map<String, String> _map = <String, String>{};

  @override
  Future<void> delete(String key) async => _map.remove(key);

  @override
  Future<String?> read(String key) async => _map[key];

  @override
  Future<void> write(String key, String value) async => _map[key] = value;
}

class _FakePrinterDriver extends Xlab365tDriver {
  _FakePrinterDriver({this.online = true});

  bool online;
  PrinterMode? switchedTo;
  int receiptCount = 0;
  int labelCount = 0;

  @override
  Future<PrinterStatus> probeStatus({
    PrinterMode mode = PrinterMode.receipt,
  }) async {
    if (!online) {
      throw const PrinterConnectionException('Offline');
    }
    return PrinterStatus(
      mode: mode,
      isOnline: true,
      isReady: true,
      coverOpen: false,
      paperOut: false,
      hasError: false,
      rawBytes: const <int>[0x12],
      message: 'Printer ready',
    );
  }

  @override
  Future<void> switchMode(PrinterMode mode) async {
    if (!online) throw const PrinterConnectionException('Offline');
    switchedTo = mode;
  }

  @override
  Future<Uint8List> printReceipt(
    ReceiptPrintData data, {
    bool? autoSwitch,
  }) async {
    if (!online) throw const PrinterConnectionException('Offline');
    receiptCount++;
    return Uint8List(0);
  }

  @override
  Future<Uint8List> printBatchCopies(
    BatchLabelData label, {
    required int quantity,
    TsplLabelStyle style = TsplLabelStyle.barcode128,
    int density = 13,
    int speed = 4,
    bool? autoSwitch,
  }) async {
    if (!online) throw const PrinterConnectionException('Offline');
    labelCount += quantity;
    return Uint8List(0);
  }
}

Future<void> _unmountWidgetTree(WidgetTester tester, AppDatabase db) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 10));
}

void main() {
  const uuid = Uuid();

  late AppDatabase db;
  late RamKeyHolder keyHolder;
  late String ownerId;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    ownerId = uuid.v4();
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: ownerId,
            username: 'owner',
            name: 'Sunita Owner',
            role: 'OWNER',
            pinHash: const Value('hash'),
          ),
        );
    final now = DateTime.now().toUtc();
    keyHolder = RamKeyHolder()
      ..unlock(
        dekBytes: Uint8List.fromList(List<int>.filled(32, 1)),
        session: ActiveLeaseSession(
          leaseId: uuid.v4(),
          userId: ownerId,
          username: 'owner',
          role: 'OWNER',
          deviceId: uuid.v4(),
          deviceCode: '01',
          issuedAt: now,
          expiresAt: now.add(const Duration(hours: 12)),
        ),
      );
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets(
      'PrinterSettingsScreen switches mode, warns on mode mismatch, and shows Red Error when offline',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final driver = _FakePrinterDriver(online: true);
    final alertCtrl = PasalAlertController();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeDatabaseProvider.overrideWith(() => _FixedDbNotifier(db)),
          ramKeyHolderProvider.overrideWith((ref) => keyHolder),
          xlabPrinterDriverProvider.overrideWithValue(driver),
          pasalAlertProvider.overrideWith((ref) => alertCtrl),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const PrinterSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Tapping Test Label while in Receipt Mode triggers Yellow Warning
    await tester.scrollUntilVisible(
      find.text('Test Label'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Test Label'));
    await tester.pumpAndSettle();
    expect(alertCtrl.current?.severity, PasalAlertSeverity.warning);
    expect(driver.labelCount, 2);

    // Switch to Label Mode
    await tester.scrollUntilVisible(
      find.text('Label Mode (Barcode Stickers)'),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Label Mode (Barcode Stickers)'));
    await tester.pumpAndSettle();
    expect(driver.switchedTo, PrinterMode.label);

    // Offline printer shows Red Error on Check Printer Status
    driver.online = false;
    await tester.drag(find.byType(ListView), const Offset(0, 500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check Printer Status'));
    await tester.pumpAndSettle();
    expect(alertCtrl.current?.severity, PasalAlertSeverity.error);
    expect(find.text('OFFLINE'), findsOneWidget);

    await _unmountWidgetTree(tester, db);
  });

  testWidgets(
      'BackupSettingsScreen renders pending outbox in plain language without technical jargon',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await db.into(db.syncOutbox).insert(
          SyncOutboxCompanion.insert(
            id: uuid.v4(),
            targetTable: 'sale_orders',
            recordId: uuid.v4(),
            operation: 'INSERT',
            payloadJson: jsonEncode({'bill_no': 'BL-001'}),
          ),
        );

    final mockClient = MockClient((req) async {
      return http.Response(jsonEncode({'applied': []}), 200);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeDatabaseProvider.overrideWith(() => _FixedDbNotifier(db)),
          ramKeyHolderProvider.overrideWith((ref) => keyHolder),
          secureKeyValueStoreProvider.overrideWithValue(_InMemoryStore()),
          httpClientFactoryProvider.overrideWithValue(() => mockClient),
          connectivityStreamProvider
              .overrideWithValue(Stream.value([ConnectivityResult.none])),
          connectivityCheckProvider
              .overrideWithValue(() async => [ConnectivityResult.none]),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const BackupSettingsScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('1 PENDING'), findsOneWidget);
    expect(find.textContaining('Sales Bill'), findsOneWidget);
    expect(find.textContaining('SQLite'), findsNothing);
    expect(find.textContaining('AES'), findsNothing);
    expect(find.text('Backup & Sync Now'), findsOneWidget);

    await _unmountWidgetTree(tester, db);
  });

  testWidgets(
      'KhataLedgerScreen displays customer shades, due balance & records Cash repayment',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final posRepo = PosRepository(db: db);
    final cust = await posRepo.createCustomer(
      name: 'Sita Sharma',
      phone: '9841234567',
      creditLimitPaisa: 1000000,
      favoriteShadeNotes: 'Fit Me #128',
      role: 'OWNER',
    );
    await db.into(db.customerTransactions).insert(
          CustomerTransactionsCompanion.insert(
            id: uuid.v4(),
            customerId: cust.id,
            type: 'DEBIT_PURCHASE',
            amount: 245000,
            balanceAfter: 245000,
          ),
        );
    await (db.update(db.customers)..where((t) => t.id.equals(cust.id))).write(
      const CustomersCompanion(currentBalanceDue: Value(245000)),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeDatabaseProvider.overrideWith(() => _FixedDbNotifier(db)),
          ramKeyHolderProvider.overrideWith((ref) => keyHolder),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const KhataLedgerScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Sita Sharma'), findsWidgets);
    expect(find.text('Fit Me #128'), findsOneWidget);
    expect(find.text('Rs. 2,450'), findsOneWidget);

    await tester.tap(find.text('Receive Payment'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text('Confirm Payment'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('Rs. 0'), findsOneWidget);

    await _unmountWidgetTree(tester, db);
  });

  testWidgets(
      'SettingsScreen hides Owner sections for STAFF and contains zero AES/DEK/SQLCipher/SSE jargon',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final now = DateTime.now().toUtc();
    keyHolder.unlock(
      dekBytes: Uint8List.fromList(List<int>.filled(32, 2)),
      session: ActiveLeaseSession(
        leaseId: uuid.v4(),
        userId: uuid.v4(),
        username: 'ram',
        role: 'STAFF',
        deviceId: uuid.v4(),
        deviceCode: '02',
        issuedAt: now,
        expiresAt: now.add(const Duration(hours: 12)),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeDatabaseProvider.overrideWith(() => _FixedDbNotifier(db)),
          ramKeyHolderProvider.overrideWith((ref) => keyHolder),
          secureKeyValueStoreProvider.overrideWithValue(_InMemoryStore()),
          connectivityStreamProvider
              .overrideWithValue(Stream.value([ConnectivityResult.none])),
          connectivityCheckProvider
              .overrideWithValue(() async => [ConnectivityResult.none]),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Printer Settings'), findsOneWidget);
    expect(find.text('Backup & Sync'), findsOneWidget);
    expect(find.text('Customer Khata Book'), findsOneWidget);
    expect(find.text('Suppliers & Bills'), findsNothing);
    expect(find.text('STAFF PHONE ACCESS'), findsNothing);
    expect(find.textContaining('AES'), findsNothing);
    expect(find.textContaining('DEK'), findsNothing);
    expect(find.textContaining('SQLCipher'), findsNothing);
    expect(find.textContaining('SSE'), findsNothing);

    await _unmountWidgetTree(tester, db);
  });
}
