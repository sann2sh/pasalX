import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pasalx_mobile/core/database/app_database.dart';
import 'package:pasalx_mobile/core/network/api_config.dart';
import 'package:pasalx_mobile/core/network/pasal_api_client.dart';
import 'package:pasalx_mobile/core/network/sync_models.dart';
import 'package:pasalx_mobile/core/sync/pull_applier.dart';
import 'package:pasalx_mobile/core/sync/sse_sync_client.dart';
import 'package:pasalx_mobile/core/sync/sync_outbox_worker.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('PullApplier & Drift outbox lifecycle', () {
    test('applies 18 pull tables in FK order with stub users and exact paisa',
        () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final pullJson = <String, dynamic>{
        'server_time': '2026-11-16T06:00:00.123456Z',
        'since': '1970-01-01T00:00:00Z',
        'has_more': false,
        'role': 'STAFF',
        'changes': <String, dynamic>{
          'products': [
            {
              'id': 'prod-1',
              'name': 'Fit Me Matte Foundation',
              'brand': 'Maybelline',
              'category': 'Makeup - Face',
              'is_generic': false,
              'created_at': '2026-11-16T05:00:00Z',
              'updated_at': '2026-11-16T05:00:00Z',
            },
          ],
          'product_variants': [
            {
              'id': 'var-1',
              'product_id': 'prod-1',
              'variant_name': '#128 Warm Nude',
              'size_volume': '30ml',
              'color_hex': '#E0B083',
              'attributes': {'finish': 'matte'},
              'is_active': true,
              'created_at': '2026-11-16T05:00:00Z',
              'updated_at': '2026-11-16T05:00:00Z',
            },
          ],
          'batches': [
            {
              'id': 'batch-1',
              'variant_id': 'var-1',
              'batch_code': 'LOT-A1',
              'sticker_barcode': '100001',
              'selling_price': 1350.50,
              'stock_quantity': 12,
              'expiry_date': '2028-06-01',
              'created_at': '2026-11-16T05:00:00Z',
              'updated_at': '2026-11-16T05:00:00Z',
            },
          ],
          'customers': [
            {
              'id': 'cust-1',
              'name': 'Asha Gurung',
              'phone': '9841000001',
              'credit_limit': 10000.00,
              'current_balance_due': 450.25,
              'favorite_shade_notes': 'Fit Me 128',
              'updated_at': '2026-11-16T05:10:00Z',
            },
          ],
          'customer_shade_profiles': [
            {
              'id': 'shade-1',
              'customer_id': 'cust-1',
              'product_name': 'Fit Me',
              'brand': 'Maybelline',
              'shade_variant': '#128 Warm Nude',
              'updated_at': '2026-11-16T05:10:00Z',
            },
          ],
          'customer_transactions': [
            {
              'id': 'ctx-1',
              'customer_id': 'cust-1',
              'type': 'DEBIT_PURCHASE',
              'amount': 450.25,
              'balance_after': 450.25,
              'created_by_user_id': 'other-owner-uuid',
              'updated_at': '2026-11-16T05:10:00Z',
            },
          ],
          'suppliers': [],
          'purchase_invoices': [],
          'purchase_invoice_items': [],
          'supplier_payments': [],
          'register_shifts': [
            {
              'id': 'shift-1',
              'opened_by_user_id': 'other-owner-uuid',
              'opened_at': '2026-11-16T04:00:00Z',
              'opening_float': 5000.00,
              'cash_sales': 1350.50,
              'digital_sales': 0.00,
              'khata_cash_repayments': 0.00,
              'cash_expenses': 0.00,
              'expected_cash': 6350.50,
              'cash_withdrawn_deposit': 0.00,
              'retained_next_day_float': 0.00,
              'status': 'OPEN',
              'updated_at': '2026-11-16T05:15:00Z',
            },
          ],
          'staff_shift_sessions': [
            {
              'id': 'ssess-1',
              'register_shift_id': 'shift-1',
              'user_id': 'other-owner-uuid',
              'device_code': '01',
              'status': 'ACTIVE',
              'updated_at': '2026-11-16T05:15:00Z',
            },
          ],
          'sale_orders': [
            {
              'id': 'sale-1',
              'bill_no': '01-0001',
              'customer_id': 'cust-1',
              'cashier_user_id': 'other-staff-uuid',
              'cashier_name': 'Sita Rai',
              'shift_id': 'shift-1',
              'subtotal': 1350.50,
              'discount_amount': 0.00,
              'total_amount': 1350.50,
              'payment_mode': 'CASH',
              'sync_status': 'SYNCED',
              'updated_at': '2026-11-16T05:20:00Z',
            },
          ],
          'sale_items': [
            {
              'id': 'sitem-1',
              'sale_order_id': 'sale-1',
              'batch_id': 'batch-1',
              'product_name': 'Fit Me Matte Foundation',
              'variant_name': '#128 Warm Nude',
              'quantity': 1,
              'selling_price': 1350.50,
              'total_price': 1350.50,
            },
          ],
          'sale_payments': [
            {
              'id': 'spay-1',
              'sale_order_id': 'sale-1',
              'method': 'CASH',
              'amount': 1350.50,
            },
          ],
          'stock_movements': [
            {
              'id': 'mv-1',
              'batch_id': 'batch-1',
              'movement_type': 'SALE',
              'quantity': -1,
              'quantity_change': -1,
              'reference_id': '01-0001',
              'staff_name': 'Sita Rai',
              'updated_at': '2026-11-16T05:20:00Z',
            },
          ],
          'expenses': [
            {
              'id': 'exp-1',
              'category': 'TEA_PETTY',
              'title': 'Shop Milk Tea',
              'amount': 120.00,
              'payment_method': 'CASH',
              'shift_id': 'shift-1',
              'created_by_user_id': 'other-staff-uuid',
              'updated_at': '2026-11-16T06:00:00.123456Z',
            },
          ],
          'inventory_sync_audit': [],
        },
      };

      final pull = SyncPullResult.fromJson(pullJson);
      await PullApplier.apply(db, pull);

      final batch = await (db.select(db.batches)
            ..where((t) => t.id.equals('batch-1')))
          .getSingle();
      expect(batch.sellingPrice, 135050);
      expect(batch.costPrice, isNull);

      final openShift = await db.fetchOpenRegisterShift();
      expect(openShift, isNotNull);
      expect(openShift!.expectedCash, 635050);

      final cursor = await PullApplier.readCursor(db);
      expect(
        cursor?.microsecondsSinceEpoch,
        DateTime.parse('2026-11-16T06:00:00.123456Z').microsecondsSinceEpoch,
      );
    });
  });

  group('SyncOutboxWorker batching, connectivity & error isolation', () {
    test('chunks 55 mutations (50 + 5), auto-flushes on connectivity_plus, and paginates pull',
        () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      for (var i = 0; i < 55; i++) {
        await db.enqueueOutboxMutation(
          mutationId: 'mut-$i',
          targetTable: 'expenses',
          recordId: 'rec-$i',
          operation: 'INSERT',
          payloadJson: jsonEncode({'id': 'rec-$i', 'amount': '50.00'}),
        );
      }

      final pushedBatchSizes = <int>[];
      var pullCalls = 0;

      final mockHttp = MockClient((req) async {
        if (req.url.path == '/api/sync/push') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final muts = (body['mutations'] as List<dynamic>).cast<Map<String, dynamic>>();
          pushedBatchSizes.add(muts.length);
          return http.Response(
            jsonEncode({
              'server_time': '2026-11-16T06:05:00Z',
              'processed_count': muts.length,
              'applied_count': muts.length,
              'duplicate_count': 0,
              'results': muts
                  .map((m) => {
                        'id': m['id'],
                        'table_name': m['table_name'],
                        'record_id': m['record_id'],
                        'status': 'APPLIED',
                      })
                  .toList(),
              'discrepancies': [
                if (pushedBatchSizes.length == 1)
                  {
                    'audit_id': 'audit-1',
                    'batch_id': 'batch-1',
                    'device_code': '01',
                    'pre_sync_qty': 0,
                    'post_sync_qty': -1,
                    'quantity_change': -1,
                  }
              ],
            }),
            200,
          );
        }
        if (req.url.path == '/api/sync/pull') {
          pullCalls++;
          final page1 = pullCalls == 1;
          return http.Response(
            jsonEncode({
              'server_time': page1
                  ? '2026-11-16T06:05:01Z'
                  : '2026-11-16T06:05:02Z',
              'since': req.url.queryParameters['since'] ?? '1970-01-01T00:00:00Z',
              'has_more': page1,
              'role': 'OWNER',
              'changes': {
                'products': page1
                    ? [
                        {
                          'id': 'p-pulled',
                          'name': 'Hydro Boost',
                          'brand': 'Neutrogena',
                          'category': 'Skincare',
                          'is_generic': false,
                          'updated_at': '2026-11-16T06:05:01Z',
                        }
                      ]
                    : [],
                'product_variants': [],
                'batches': [],
                'customers': [],
                'customer_shade_profiles': [],
                'customer_transactions': [],
                'suppliers': [],
                'purchase_invoices': [],
                'purchase_invoice_items': [],
                'supplier_payments': [],
                'stock_movements': [],
                'sale_orders': [],
                'sale_items': [],
                'sale_payments': [],
                'register_shifts': [],
                'staff_shift_sessions': [],
                'expenses': [],
                'inventory_sync_audit': [],
              },
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });

      final connCtrl = StreamController<List<ConnectivityResult>>.broadcast();
      addTearDown(connCtrl.close);

      var reconnectedFired = false;
      final worker = SyncOutboxWorker(
        getDatabase: () => db,
        getAccessToken: () => 'jwt-token',
        apiClient: PasalApiClient(
          config: const ApiConfig(baseUrl: 'http://test.local'),
          httpClient: mockHttp,
        ),
        connectivityStream: connCtrl.stream,
        checkConnectivity: () async => [ConnectivityResult.none],
        periodicInterval: const Duration(minutes: 5),
        onOnlineReconnected: () => reconnectedFired = true,
      );
      addTearDown(worker.dispose);

      await worker.start(runInitialSync: true);
      expect(pushedBatchSizes, isEmpty);
      expect(worker.status.isOnline, isFalse);

      // Reconnect Wi-Fi -> auto flush!
      connCtrl.add([ConnectivityResult.wifi]);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(reconnectedFired, isTrue);
      expect(pushedBatchSizes, [50, 5]);
      expect(pullCalls, 2);
      expect(await db.fetchPendingOutbox(), isEmpty);
      expect(worker.status.discrepancies.length, 1);
      expect(worker.status.discrepancies.first.postSyncQty, -1);

      final pulledProduct = await (db.select(db.products)
            ..where((t) => t.id.equals('p-pulled')))
          .getSingleOrNull();
      expect(pulledProduct?.name, 'Hydro Boost');
    });

    test('isolates poison-pill 400 mutation while still syncing valid mutations & recovers stale SYNCING rows',
        () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      // Simulate one crashed-in-flight SYNCING valid row + one malformed row + one pending valid row.
      await db.into(db.syncOutbox).insert(
            SyncOutboxCompanion.insert(
              id: 'mut-stale',
              targetTable: 'expenses',
              recordId: 'e1',
              operation: 'INSERT',
              payloadJson: jsonEncode({'id': 'e1', 'amount': '10.00'}),
              status: const Value('SYNCING'),
            ),
          );
      await db.enqueueOutboxMutation(
        mutationId: 'mut-bad',
        targetTable: 'expenses',
        recordId: 'e-bad',
        operation: 'INSERT',
        payloadJson: jsonEncode({'id': 'e-bad', 'amount': '-5.00'}),
      );
      await db.enqueueOutboxMutation(
        mutationId: 'mut-good',
        targetTable: 'expenses',
        recordId: 'e2',
        operation: 'INSERT',
        payloadJson: jsonEncode({'id': 'e2', 'amount': '20.00'}),
      );

      final mockHttp = MockClient((req) async {
        if (req.url.path == '/api/sync/push') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final muts = (body['mutations'] as List<dynamic>).cast<Map<String, dynamic>>();
          final hasBad = muts.any((m) => m['id'] == 'mut-bad');
          if (hasBad) {
            return http.Response(
              jsonEncode({'error': 'BAD_REQUEST', 'message': 'amount <= 0'}),
              400,
            );
          }
          return http.Response(
            jsonEncode({
              'server_time': '2026-11-16T06:10:00Z',
              'processed_count': muts.length,
              'applied_count': muts.length,
              'duplicate_count': 0,
              'results': muts
                  .map((m) => {
                        'id': m['id'],
                        'table_name': m['table_name'],
                        'record_id': m['record_id'],
                        'status': 'APPLIED',
                      })
                  .toList(),
              'discrepancies': [],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'server_time': '2026-11-16T06:10:00Z',
            'since': '1970-01-01T00:00:00Z',
            'has_more': false,
            'role': 'STAFF',
            'changes': {},
          }),
          200,
        );
      });

      final worker = SyncOutboxWorker(
        getDatabase: () => db,
        getAccessToken: () => 'jwt',
        apiClient: PasalApiClient(
          config: const ApiConfig(baseUrl: 'http://test.local'),
          httpClient: mockHttp,
        ),
        connectivityStream: const Stream.empty(),
        checkConnectivity: () async => [ConnectivityResult.wifi],
      );
      addTearDown(worker.dispose);

      await worker.start(runInitialSync: false);
      await worker.syncNow();

      final rows = await (db.select(db.syncOutbox)
            ..orderBy([(t) => OrderingTerm(expression: const CustomExpression<int>('rowid'))]))
          .get();
      final byId = {for (final r in rows) r.id: r};

      expect(byId['mut-stale']?.status, 'SYNCED');
      expect(byId['mut-good']?.status, 'SYNCED');
      expect(byId['mut-bad']?.status, 'FAILED');
      expect(byId['mut-bad']?.retryCount, 1);
      expect(byId['mut-bad']?.errorMessage, contains('BAD_REQUEST'));
    });

    test('isolates corrupted outbox payload JSON without blocking valid outbox mutations',
        () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      await db.enqueueOutboxMutation(
        mutationId: 'mut-corrupt-json',
        targetTable: 'expenses',
        recordId: 'e-corrupt',
        operation: 'INSERT',
        payloadJson: '{not-valid-json',
      );
      await db.enqueueOutboxMutation(
        mutationId: 'mut-valid-after-corrupt',
        targetTable: 'expenses',
        recordId: 'e-valid',
        operation: 'INSERT',
        payloadJson: jsonEncode({'id': 'e-valid', 'amount': '25.00'}),
      );

      final mockHttp = MockClient((req) async {
        if (req.url.path == '/api/sync/push') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final muts =
              (body['mutations'] as List<dynamic>).cast<Map<String, dynamic>>();
          return http.Response(
            jsonEncode({
              'server_time': '2026-11-16T06:11:00Z',
              'processed_count': muts.length,
              'applied_count': muts.length,
              'duplicate_count': 0,
              'results': muts
                  .map((m) => {
                        'id': m['id'],
                        'table_name': m['table_name'],
                        'record_id': m['record_id'],
                        'status': 'APPLIED',
                      })
                  .toList(),
              'discrepancies': [],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'server_time': '2026-11-16T06:11:00Z',
            'since': '1970-01-01T00:00:00Z',
            'has_more': false,
            'role': 'STAFF',
            'changes': {},
          }),
          200,
        );
      });

      final worker = SyncOutboxWorker(
        getDatabase: () => db,
        getAccessToken: () => 'jwt',
        apiClient: PasalApiClient(
          config: const ApiConfig(baseUrl: 'http://test.local'),
          httpClient: mockHttp,
        ),
        connectivityStream: const Stream.empty(),
        checkConnectivity: () async => [ConnectivityResult.wifi],
      );
      addTearDown(worker.dispose);

      await worker.start(runInitialSync: false);
      await worker.syncNow();

      final rows = await db.select(db.syncOutbox).get();
      final byId = {for (final r in rows) r.id: r};
      expect(byId['mut-corrupt-json']?.status, 'FAILED');
      expect(byId['mut-valid-after-corrupt']?.status, 'SYNCED');
    });

    test('periodic 30s fallback timer triggers background sync automatically',
        () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      await db.enqueueOutboxMutation(
        mutationId: 'mut-timer',
        targetTable: 'expenses',
        recordId: 'e-timer',
        operation: 'INSERT',
        payloadJson: jsonEncode({'id': 'e-timer'}),
      );

      final mockHttp = MockClient((req) async {
        if (req.url.path == '/api/sync/push') {
          return http.Response(
            jsonEncode({
              'server_time': '2026-11-16T06:12:00Z',
              'processed_count': 1,
              'applied_count': 1,
              'duplicate_count': 0,
              'results': [
                {
                  'id': 'mut-timer',
                  'table_name': 'expenses',
                  'record_id': 'e-timer',
                  'status': 'APPLIED',
                }
              ],
              'discrepancies': [],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'server_time': '2026-11-16T06:12:00Z',
            'since': '1970-01-01T00:00:00Z',
            'has_more': false,
            'role': 'STAFF',
            'changes': {},
          }),
          200,
        );
      });

      final worker = SyncOutboxWorker(
        getDatabase: () => db,
        getAccessToken: () => 'jwt',
        apiClient: PasalApiClient(
          config: const ApiConfig(baseUrl: 'http://test.local'),
          httpClient: mockHttp,
        ),
        connectivityStream: const Stream.empty(),
        checkConnectivity: () async => [ConnectivityResult.wifi],
        periodicInterval: const Duration(milliseconds: 50),
      );
      addTearDown(worker.dispose);

      await worker.start(runInitialSync: false);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(await db.fetchPendingOutbox(), isEmpty);
    });
  });

  group('SseSyncClient loopback stream', () {
    test('receives CONNECTED, triggers pull on DATA_CHANGED < 1s, and triggers revoke on DEVICE_REVOKED',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      HttpResponse? activeSseRes;
      var pulledAfterSse = false;
      final connectedCompleter = Completer<void>();
      final pullCompleter = Completer<void>();
      final revokedCompleter = Completer<String>();

      server.listen((req) async {
        if (req.uri.path == '/api/sync/events') {
          req.response.statusCode = 200;
          req.response.headers.contentType =
              ContentType('text', 'event-stream');
          req.response.bufferOutput = false;
          activeSseRes = req.response;
          req.response.write(
            'event: CONNECTED\ndata: {"device_code":"01"}\n\n',
          );
          await req.response.flush();
        } else if (req.uri.path == '/api/sync/pull') {
          pulledAfterSse = true;
          if (!pullCompleter.isCompleted) pullCompleter.complete();
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'server_time': '2026-11-16T06:20:00Z',
              'since': '1970-01-01T00:00:00Z',
              'has_more': false,
              'role': 'STAFF',
              'changes': {},
            }));
          await req.response.close();
        }
      });

      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final config = ApiConfig(baseUrl: 'http://127.0.0.1:${server.port}');
      final worker = SyncOutboxWorker(
        getDatabase: () => db,
        getAccessToken: () => 'jwt',
        apiClient: PasalApiClient(config: config),
        connectivityStream: const Stream.empty(),
        checkConnectivity: () async => [ConnectivityResult.wifi],
      );
      addTearDown(worker.dispose);
      await worker.start(runInitialSync: false);

      final sse = SseSyncClient(
        getConfig: () => config,
        getAccessToken: () => 'jwt',
        initialBackoff: const Duration(milliseconds: 50),
        onConnectedChanged: (c) {
          worker.setSseConnected(c);
          if (c && !connectedCompleter.isCompleted) {
            connectedCompleter.complete();
          }
        },
        onDataChanged: (_) => worker.pullNow(),
        onDeviceRevoked: (reason) {
          if (!revokedCompleter.isCompleted) revokedCompleter.complete(reason);
        },
      );
      addTearDown(sse.stop);

      sse.start();
      await connectedCompleter.future.timeout(const Duration(seconds: 2));
      expect(worker.status.sseConnected, isTrue);

      // Push DATA_CHANGED over live TCP SSE stream -> verify immediate pull.
      final sw = Stopwatch()..start();
      activeSseRes!.write(
        'event: DATA_CHANGED\ndata: {"origin_device_code":"02","server_time":"2026-11-16T06:20:00Z"}\n\n',
      );
      await activeSseRes!.flush();
      await pullCompleter.future.timeout(const Duration(seconds: 2));
      sw.stop();

      expect(pulledAfterSse, isTrue);
      expect(sw.elapsedMilliseconds, lessThan(1000));

      // Push DEVICE_REVOKED over SSE -> immediate kill-switch callback.
      activeSseRes!.write(
        'event: DEVICE_REVOKED\ndata: {"error":"DEVICE_REVOKED","device_code":"01"}\n\n',
      );
      await activeSseRes!.flush();
      await activeSseRes!.close();

      await revokedCompleter.future.timeout(const Duration(seconds: 2));
      expect(sse.isRunning, isFalse);
    });
  });
}
