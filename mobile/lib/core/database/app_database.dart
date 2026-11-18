import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'money.dart';
import 'tables.dart';

part 'app_database.g.dart';

/// Encrypted local Drift database mirroring PostgreSQL tables + `sync_outbox`
/// (`TECHNICAL_SPEC.md` §4 & server migrations `000001`–`000004`).
@DriftDatabase(
  tables: [
    Users,
    Customers,
    CustomerShadeProfiles,
    CustomerTransactions,
    Suppliers,
    PurchaseInvoices,
    PurchaseInvoiceItems,
    SupplierPayments,
    Products,
    ProductVariants,
    Batches,
    StockMovements,
    RegisterShifts,
    SaleOrders,
    SaleItems,
    SalePayments,
    StaffShiftSessions,
    Expenses,
    InventorySyncAudit,
    SyncOutbox,
    SyncMetadata,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  final List<VoidCallback> _onCloseCallbacks = <VoidCallback>[];
  bool _isClosed = false;

  /// Registers a callback invoked once when [close] is called.
  void addOnClose(VoidCallback callback) {
    if (_isClosed) {
      callback();
      return;
    }
    _onCloseCallbacks.add(callback);
  }

  @override
  Future<void> close() async {
    if (!_isClosed) {
      _isClosed = true;
      final callbacks = List<VoidCallback>.from(_onCloseCallbacks);
      _onCloseCallbacks.clear();
      for (final cb in callbacks) {
        cb();
      }
    }
    await super.close();
  }

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
          await _createIndexes();
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON;');
        },
      );

  Future<void> _createIndexes() async {
    const indexStatements = <String>[
      'CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);',
      'CREATE INDEX IF NOT EXISTS idx_customers_phone ON customers(phone);',
      'CREATE INDEX IF NOT EXISTS idx_customer_shades_cust ON customer_shade_profiles(customer_id);',
      'CREATE INDEX IF NOT EXISTS idx_customer_tx_cust ON customer_transactions(customer_id);',
      'CREATE INDEX IF NOT EXISTS idx_purchase_invoices_supplier ON purchase_invoices(supplier_id);',
      'CREATE INDEX IF NOT EXISTS idx_products_category ON products(category);',
      'CREATE INDEX IF NOT EXISTS idx_products_brand ON products(brand);',
      'CREATE INDEX IF NOT EXISTS idx_variants_product ON product_variants(product_id);',
      'CREATE INDEX IF NOT EXISTS idx_batches_barcode ON batches(sticker_barcode);',
      'CREATE INDEX IF NOT EXISTS idx_batches_expiry ON batches(expiry_date);',
      'CREATE INDEX IF NOT EXISTS idx_batches_variant ON batches(variant_id);',
      'CREATE INDEX IF NOT EXISTS idx_movements_batch ON stock_movements(batch_id);',
      'CREATE INDEX IF NOT EXISTS idx_sales_date ON sale_orders(created_at);',
      'CREATE INDEX IF NOT EXISTS idx_sales_sync ON sale_orders(sync_status);',
      'CREATE INDEX IF NOT EXISTS idx_sales_bill_no ON sale_orders(bill_no);',
      'CREATE INDEX IF NOT EXISTS idx_sale_items_order ON sale_items(sale_order_id);',
      'CREATE INDEX IF NOT EXISTS idx_sale_payments_order ON sale_payments(sale_order_id);',
      'CREATE INDEX IF NOT EXISTS idx_register_shifts_status ON register_shifts(status);',
      'CREATE INDEX IF NOT EXISTS idx_shift_sessions_shift ON staff_shift_sessions(register_shift_id);',
      'CREATE INDEX IF NOT EXISTS idx_shift_sessions_user ON staff_shift_sessions(user_id);',
      'CREATE INDEX IF NOT EXISTS idx_shift_sessions_status ON staff_shift_sessions(status);',
      'CREATE INDEX IF NOT EXISTS idx_expenses_shift ON expenses(shift_id);',
      'CREATE INDEX IF NOT EXISTS idx_sync_audit_batch ON inventory_sync_audit(batch_id);',
      'CREATE INDEX IF NOT EXISTS idx_sync_audit_discrepancy ON inventory_sync_audit(is_discrepancy);',
      'CREATE INDEX IF NOT EXISTS idx_outbox_status ON sync_outbox(status);',
      'CREATE INDEX IF NOT EXISTS idx_outbox_created ON sync_outbox(created_at);',
    ];
    for (final sql in indexStatements) {
      await customStatement(sql);
    }
  }

  /// Queries active `PRAGMA cipher_version;` from the underlying engine.
  Future<String?> readCipherVersion() async {
    final rows = await customSelect('PRAGMA cipher_version;').get();
    if (rows.isEmpty) return null;
    final val = rows.first.data.values.first;
    final str = val?.toString().trim();
    return (str == null || str.isEmpty) ? null : str;
  }

  /// Returns all user table names present in the SQLite schema.
  Future<List<String>> listTableNames() async {
    final rows = await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name ASC;",
    ).get();
    return rows.map((r) => r.read<String>('name')).toList();
  }

  /// Enqueues an offline mutation into `sync_outbox` for atomic push sync.
  Future<void> enqueueOutboxMutation({
    required String mutationId,
    required String targetTable,
    required String recordId,
    required String operation,
    required String payloadJson,
    DateTime? clientUpdatedAt,
    DateTime? createdAt,
  }) async {
    await into(syncOutbox).insert(
      SyncOutboxCompanion.insert(
        id: mutationId,
        targetTable: targetTable,
        recordId: recordId,
        operation: operation,
        payloadJson: payloadJson,
        clientUpdatedAt: Value(clientUpdatedAt?.toUtc()),
        createdAt: createdAt == null
            ? const Value.absent()
            : Value(createdAt.toUtc()),
      ),
    );
  }

  /// Fetches up to [limit] (`<= 50`) pending mutations ordered strictly FIFO
  /// by monotonic SQLite `rowid` insertion order (immune to clock skew).
  Future<List<SyncOutboxRow>> fetchPendingOutbox({int limit = 50}) {
    final query = select(syncOutbox)
      ..where((t) => t.status.equals('PENDING'))
      ..orderBy([
        (t) => OrderingTerm(expression: const CustomExpression<int>('rowid')),
      ])
      ..limit(limit);
    return query.get();
  }

  /// Reactive pending outbox count for the shell status indicator.
  Stream<int> watchPendingOutboxCount() {
    final countExp = syncOutbox.id.count();
    final query = selectOnly(syncOutbox)
      ..addColumns([countExp])
      ..where(syncOutbox.status.isIn(['PENDING', 'SYNCING']));
    return query.watchSingle().map((row) => row.read(countExp) ?? 0);
  }

  /// Resets any leftover `'SYNCING'` rows (e.g. after crash/kill mid-flight)
  /// back to `'PENDING'` so zero mutations are stranded.
  Future<int> resetStaleSyncingOutbox() {
    return (update(syncOutbox)..where((t) => t.status.equals('SYNCING'))).write(
      const SyncOutboxCompanion(status: Value('PENDING')),
    );
  }

  /// Marks outbox mutations `'SYNCING'` before HTTP dispatch.
  Future<int> markOutboxSyncing(List<String> ids) {
    if (ids.isEmpty) return Future.value(0);
    return (update(syncOutbox)..where((t) => t.id.isIn(ids))).write(
      const SyncOutboxCompanion(status: Value('SYNCING')),
    );
  }

  /// Reverts `'SYNCING'` mutations back to `'PENDING'` without incrementing
  /// `retry_count` (used before single-item poison-pill isolation).
  Future<int> revertOutboxSyncingToPending(List<String> ids) {
    if (ids.isEmpty) return Future.value(0);
    return (update(syncOutbox)..where((t) => t.id.isIn(ids))).write(
      const SyncOutboxCompanion(status: Value('PENDING')),
    );
  }

  /// Marks outbox mutations `'SYNCED'` with [syncedAt] timestamp.
  Future<int> markOutboxSynced(List<String> ids, {DateTime? syncedAt}) {
    if (ids.isEmpty) return Future.value(0);
    return (update(syncOutbox)..where((t) => t.id.isIn(ids))).write(
      SyncOutboxCompanion(
        status: const Value('SYNCED'),
        syncedAt: Value((syncedAt ?? DateTime.now()).toUtc()),
        errorMessage: const Value(null),
      ),
    );
  }

  /// Records a failed sync attempt. Transient errors return rows to `'PENDING'`,
  /// while permanent `4xx` rejections transition to `'FAILED'`.
  Future<void> markOutboxAttemptFailed(
    List<String> ids,
    String errorMessage, {
    bool permanent = false,
  }) async {
    if (ids.isEmpty) return;
    final status = permanent ? 'FAILED' : 'PENDING';
    await customStatement(
      'UPDATE sync_outbox '
      'SET status = ?, retry_count = retry_count + 1, error_message = ? '
      'WHERE id IN (${List.filled(ids.length, '?').join(', ')})',
      <Object?>[status, errorMessage, ...ids],
    );
  }

  /// Marks pushed `sale_orders` as `'SYNCED'` locally after server acceptance.
  Future<int> markSaleOrdersSynced(List<String> saleOrderIds) {
    if (saleOrderIds.isEmpty) return Future.value(0);
    return (update(saleOrders)..where((t) => t.id.isIn(saleOrderIds))).write(
      const SaleOrdersCompanion(syncStatus: Value('SYNCED')),
    );
  }

  /// Upserts the currently authenticated user so local FK references succeed
  /// immediately offline and online.
  Future<void> upsertAuthenticatedUser({
    required String id,
    required String name,
    required String username,
    required String role,
  }) async {
    final now = DateTime.now().toUtc();
    await into(users).insertOnConflictUpdate(
      UsersCompanion.insert(
        id: id,
        name: name,
        username: username,
        role: role,
        isActive: const Value(true),
        updatedAt: Value(now),
        deletedAt: const Value(null),
      ),
    );
  }

  /// Fetches the active open Single-Galla register shift, if one exists.
  Future<RegisterShiftRow?> fetchOpenRegisterShift() {
    final query = select(registerShifts)
      ..where((t) => t.status.equals('OPEN'))
      ..orderBy([(t) => OrderingTerm.desc(t.openedAt)])
      ..limit(1);
    return query.getSingleOrNull();
  }

  /// Streams the active open Single-Galla register shift.
  Stream<RegisterShiftRow?> watchOpenRegisterShift() {
    final query = select(registerShifts)
      ..where((t) => t.status.equals('OPEN'))
      ..orderBy([(t) => OrderingTerm.desc(t.openedAt)])
      ..limit(1);
    return query.watchSingleOrNull();
  }

  /// Fetches the active staff punch-in session for this user & terminal on [registerShiftId].
  Future<StaffShiftSessionRow?> fetchActiveStaffSession({
    required String registerShiftId,
    required String userId,
    required String deviceCode,
  }) {
    final query = select(staffShiftSessions)
      ..where(
        (t) =>
            t.registerShiftId.equals(registerShiftId) &
            t.userId.equals(userId) &
            t.deviceCode.equals(deviceCode) &
            t.status.equals('ACTIVE'),
      )
      ..orderBy([(t) => OrderingTerm.desc(t.punchedInAt)])
      ..limit(1);
    return query.getSingleOrNull();
  }

  /// Opens a new Single-Galla [RegisterShifts] record with [openingFloatPaisa]
  /// AND punches the current staff terminal into [StaffShiftSessions], enqueueing
  /// both FIFO mutations into `sync_outbox` inside one SQLite ACID transaction.
  Future<({RegisterShiftRow shift, StaffShiftSessionRow session})>
      openRegisterShiftAndPunchIn({
    required String userId,
    required String deviceCode,
    required int openingFloatPaisa,
    String? notes,
  }) async {
    if (openingFloatPaisa < 0 ||
        openingFloatPaisa > MoneyUtils.maxDecimal10_2Paisa) {
      throw ArgumentError.value(
        openingFloatPaisa,
        'openingFloatPaisa',
        'Opening float must fit non-negative DECIMAL(10,2)',
      );
    }

    const uuid = Uuid();
    final shiftId = uuid.v4();
    final sessionId = uuid.v4();
    final shiftMutId = uuid.v4();
    final sessionMutId = uuid.v4();
    final now = DateTime.now().toUtc();
    final normalizedNotes =
        (notes != null && notes.trim().isNotEmpty) ? notes.trim() : null;

    return transaction(() async {
      await into(registerShifts).insert(
        RegisterShiftsCompanion.insert(
          id: shiftId,
          openedByUserId: userId,
          openedAt: Value(now),
          openingFloat: openingFloatPaisa,
          expectedCash: openingFloatPaisa,
          status: const Value('OPEN'),
          notes: Value(normalizedNotes),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );

      final shiftPayload = <String, dynamic>{
        'id': shiftId,
        'opened_by_user_id': userId,
        'opened_at': now.toIso8601String(),
        'opening_float': MoneyUtils.toDecimalString(openingFloatPaisa),
        'cash_sales': '0.00',
        'digital_sales': '0.00',
        'khata_cash_repayments': '0.00',
        'cash_expenses': '0.00',
        'expected_cash': MoneyUtils.toDecimalString(openingFloatPaisa),
        'cash_withdrawn_deposit': '0.00',
        'retained_next_day_float': '0.00',
        'status': 'OPEN',
        if (normalizedNotes != null) 'notes': normalizedNotes,
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      };

      await enqueueOutboxMutation(
        mutationId: shiftMutId,
        targetTable: 'register_shifts',
        recordId: shiftId,
        operation: 'INSERT',
        payloadJson: jsonEncode(shiftPayload),
        clientUpdatedAt: now,
        createdAt: now,
      );

      await into(staffShiftSessions).insert(
        StaffShiftSessionsCompanion.insert(
          id: sessionId,
          registerShiftId: shiftId,
          userId: userId,
          deviceCode: deviceCode,
          punchedInAt: Value(now),
          lastSyncedAt: Value(now),
          status: const Value('ACTIVE'),
          updatedAt: Value(now),
        ),
      );

      final sessionPayload = <String, dynamic>{
        'id': sessionId,
        'register_shift_id': shiftId,
        'user_id': userId,
        'device_code': deviceCode,
        'punched_in_at': now.toIso8601String(),
        'last_synced_at': now.toIso8601String(),
        'status': 'ACTIVE',
        'updated_at': now.toIso8601String(),
      };

      await enqueueOutboxMutation(
        mutationId: sessionMutId,
        targetTable: 'staff_shift_sessions',
        recordId: sessionId,
        operation: 'INSERT',
        payloadJson: jsonEncode(sessionPayload),
        clientUpdatedAt: now,
        createdAt: now,
      );

      final shift = await (select(registerShifts)
            ..where((t) => t.id.equals(shiftId)))
          .getSingle();
      final session = await (select(staffShiftSessions)
            ..where((t) => t.id.equals(sessionId)))
          .getSingle();
      return (shift: shift, session: session);
    });
  }

  /// Punches the current staff phone into an already-open shop [registerShiftId]
  /// without creating a duplicate `register_shifts` row (`Single-Galla`).
  Future<StaffShiftSessionRow> punchInToExistingShift({
    required String registerShiftId,
    required String userId,
    required String deviceCode,
  }) async {
    const uuid = Uuid();
    final sessionId = uuid.v4();
    final mutId = uuid.v4();
    final now = DateTime.now().toUtc();

    return transaction(() async {
      await into(staffShiftSessions).insert(
        StaffShiftSessionsCompanion.insert(
          id: sessionId,
          registerShiftId: registerShiftId,
          userId: userId,
          deviceCode: deviceCode,
          punchedInAt: Value(now),
          lastSyncedAt: Value(now),
          status: const Value('ACTIVE'),
          updatedAt: Value(now),
        ),
      );

      final sessionPayload = <String, dynamic>{
        'id': sessionId,
        'register_shift_id': registerShiftId,
        'user_id': userId,
        'device_code': deviceCode,
        'punched_in_at': now.toIso8601String(),
        'last_synced_at': now.toIso8601String(),
        'status': 'ACTIVE',
        'updated_at': now.toIso8601String(),
      };

      await enqueueOutboxMutation(
        mutationId: mutId,
        targetTable: 'staff_shift_sessions',
        recordId: sessionId,
        operation: 'INSERT',
        payloadJson: jsonEncode(sessionPayload),
        clientUpdatedAt: now,
        createdAt: now,
      );

      return (select(staffShiftSessions)..where((t) => t.id.equals(sessionId)))
          .getSingle();
    });
  }

  /// Reads/writes metadata values like `last_pull_cursor` inside encrypted SQLite.
  Future<String?> getMetadata(String key) async {
    final row = await (select(syncMetadata)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setMetadata(String key, String value) async {
    await into(syncMetadata).insertOnConflictUpdate(
      SyncMetadataCompanion.insert(
        key: key,
        value: value,
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  Future<void> deleteMetadata(String key) async {
    await (delete(syncMetadata)..where((t) => t.key.equals(key))).go();
  }

  /// Enforces `TECHNICAL_SPEC.md` §7.5 role privacy on a shared shop terminal:
  /// - Downgrade (`OWNER -> MANAGER/STAFF`, `MANAGER -> STAFF`) scrubs masked
  ///   cost/profit/supplier columns & tables inside local SQLite.
  /// - Upgrade (`STAFF -> MANAGER/OWNER`, `MANAGER -> OWNER`) resets the pull
  ///   cursor so unmasked wholesale costs & supplier ledger re-sync cleanly.
  Future<void> enforceRolePrivacy(String currentRole) async {
    final normalized = currentRole.trim().toUpperCase();
    final previousRole = (await getMetadata('last_synced_role'))?.toUpperCase();
    final prevRank = _roleRank(previousRole);
    final currRank = _roleRank(normalized);

    await transaction(() async {
      await customStatement('PRAGMA defer_foreign_keys = ON;');

      if (normalized != 'OWNER') {
        await update(batches).write(const BatchesCompanion(costPrice: Value(null)));
        await update(saleOrders).write(
          const SaleOrdersCompanion(
            costTotal: Value(null),
            netProfit: Value(null),
          ),
        );
        await update(saleItems).write(const SaleItemsCompanion(costPrice: Value(null)));
        await update(purchaseInvoiceItems).write(
          const PurchaseInvoiceItemsCompanion(
            unitCostPrice: Value(null),
            totalCost: Value(null),
          ),
        );
      }

      if (normalized == 'STAFF') {
        await update(batches).write(
          const BatchesCompanion(
            supplierId: Value(null),
            purchaseInvoiceId: Value(null),
          ),
        );
        await delete(inventorySyncAudit).go();
        await delete(supplierPayments).go();
        await delete(purchaseInvoiceItems).go();
        await delete(purchaseInvoices).go();
        await delete(suppliers).go();
      }

      if (previousRole != null && currRank > prevRank) {
        await deleteMetadata('last_pull_cursor');
      }

      await setMetadata('last_synced_role', normalized);
    });
  }

  static int _roleRank(String? role) {
    switch (role) {
      case 'OWNER':
        return 3;
      case 'MANAGER':
        return 2;
      case 'STAFF':
        return 1;
      default:
        return 0;
    }
  }

  /// Watches chronological sale orders with their frozen line items and payments.
  Stream<List<SaleOrderBundle>> watchSaleOrderBundles({
    DateTime? from,
    DateTime? to,
  }) {
    final query = select(saleOrders)
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
    if (from != null) {
      query.where((t) => t.createdAt.isBiggerOrEqualValue(from.toUtc()));
    }
    if (to != null) {
      query.where((t) => t.createdAt.isSmallerThanValue(to.toUtc()));
    }
    return query.watch().asyncMap((orders) async {
      if (orders.isEmpty) return const <SaleOrderBundle>[];
      final orderIds = orders.map((o) => o.id).toList(growable: false);
      final items = await (select(saleItems)
            ..where((t) => t.saleOrderId.isIn(orderIds)))
          .get();
      final payments = await (select(salePayments)
            ..where((t) => t.saleOrderId.isIn(orderIds)))
          .get();

      final itemsByOrder = <String, List<SaleItemRow>>{};
      for (final item in items) {
        itemsByOrder.putIfAbsent(item.saleOrderId, () => <SaleItemRow>[]).add(item);
      }
      final paymentsByOrder = <String, List<SalePaymentRow>>{};
      for (final payment in payments) {
        paymentsByOrder
            .putIfAbsent(payment.saleOrderId, () => <SalePaymentRow>[])
            .add(payment);
      }

      return orders
          .map(
            (o) => SaleOrderBundle(
              order: o,
              items: itemsByOrder[o.id] ?? const <SaleItemRow>[],
              payments: paymentsByOrder[o.id] ?? const <SalePaymentRow>[],
            ),
          )
          .toList(growable: false);
    });
  }

  /// Fetches a single sale order with line items, payments, and linked customer.
  Future<SaleDetailBundle?> fetchSaleDetailBundle(String saleOrderId) async {
    final order = await (select(saleOrders)
          ..where((t) => t.id.equals(saleOrderId)))
        .getSingleOrNull();
    if (order == null) return null;

    final items = await (select(saleItems)
          ..where((t) => t.saleOrderId.equals(saleOrderId)))
        .get();
    final payments = await (select(salePayments)
          ..where((t) => t.saleOrderId.equals(saleOrderId)))
        .get();
    final customer = order.customerId == null
        ? null
        : await (select(customers)
              ..where((t) => t.id.equals(order.customerId!)))
            .getSingleOrNull();

    return SaleDetailBundle(
      order: order,
      items: items,
      payments: payments,
      customer: customer,
    );
  }

  /// Watches a single sale order detail bundle reactively.
  Stream<SaleDetailBundle?> watchSaleDetailBundle(String saleOrderId) {
    return (select(saleOrders)..where((t) => t.id.equals(saleOrderId)))
        .watchSingleOrNull()
        .asyncMap((order) {
      if (order == null) return Future<SaleDetailBundle?>.value(null);
      return fetchSaleDetailBundle(order.id);
    });
  }

  /// Watches chronological purchase invoices with supplier & item rollups.
  Stream<List<PurchaseInvoiceBundle>> watchPurchaseInvoiceBundles() {
    final query = select(purchaseInvoices)
      ..orderBy([
        (t) => OrderingTerm.desc(t.invoiceDate),
        (t) => OrderingTerm.desc(t.createdAt),
      ]);
    return query.watch().asyncMap((invoices) async {
      if (invoices.isEmpty) return const <PurchaseInvoiceBundle>[];
      final supplierIds =
          invoices.map((i) => i.supplierId).toSet().toList(growable: false);
      final invoiceIds = invoices.map((i) => i.id).toList(growable: false);

      final supplierRows = await (select(suppliers)
            ..where((t) => t.id.isIn(supplierIds)))
          .get();
      final supplierMap = {for (final s in supplierRows) s.id: s};

      final itemRows = await (select(purchaseInvoiceItems)
            ..where((t) => t.purchaseInvoiceId.isIn(invoiceIds)))
          .get();
      final countByInvoice = <String, int>{};
      final qtyByInvoice = <String, int>{};
      for (final item in itemRows) {
        countByInvoice[item.purchaseInvoiceId] =
            (countByInvoice[item.purchaseInvoiceId] ?? 0) + 1;
        qtyByInvoice[item.purchaseInvoiceId] =
            (qtyByInvoice[item.purchaseInvoiceId] ?? 0) + item.quantityReceived;
      }

      return invoices
          .map(
            (inv) => PurchaseInvoiceBundle(
              invoice: inv,
              supplier: supplierMap[inv.supplierId],
              productCount: countByInvoice[inv.id] ?? 0,
              totalQuantity: qtyByInvoice[inv.id] ?? 0,
            ),
          )
          .toList(growable: false);
    });
  }

  /// Fetches a single purchase invoice with supplier, inward items, and batches.
  Future<PurchaseDetailBundle?> fetchPurchaseDetailBundle(
    String purchaseInvoiceId,
  ) async {
    final invoice = await (select(purchaseInvoices)
          ..where((t) => t.id.equals(purchaseInvoiceId)))
        .getSingleOrNull();
    if (invoice == null) return null;

    final supplier = await (select(suppliers)
          ..where((t) => t.id.equals(invoice.supplierId)))
        .getSingleOrNull();
    final items = await (select(purchaseInvoiceItems)
          ..where((t) => t.purchaseInvoiceId.equals(purchaseInvoiceId)))
        .get();
    final batchIds = items
        .map((i) => i.batchId)
        .whereType<String>()
        .toSet()
        .toList(growable: false);
    final batchRows = batchIds.isEmpty
        ? const <BatchRow>[]
        : await (select(batches)..where((t) => t.id.isIn(batchIds))).get();
    final openSupplierInvoices = await (select(purchaseInvoices)
          ..where(
            (t) =>
                t.supplierId.equals(invoice.supplierId) &
                t.dueAmount.isBiggerThanValue(0),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.invoiceDate)]))
        .get();

    return PurchaseDetailBundle(
      invoice: invoice,
      supplier: supplier,
      items: items,
      batches: batchRows,
      openSupplierInvoices: openSupplierInvoices,
    );
  }

  /// Watches a single purchase invoice detail bundle reactively.
  Stream<PurchaseDetailBundle?> watchPurchaseDetailBundle(
    String purchaseInvoiceId,
  ) {
    return (select(purchaseInvoices)
          ..where((t) => t.id.equals(purchaseInvoiceId)))
        .watchSingleOrNull()
        .asyncMap((inv) {
      if (inv == null) return Future<PurchaseDetailBundle?>.value(null);
      return fetchPurchaseDetailBundle(inv.id);
    });
  }

  /// Watches pending/failed outbox rows for Backup & Sync status screen.
  Stream<List<SyncOutboxRow>> watchPendingSyncOutboxRows() {
    return (select(syncOutbox)
          ..where((t) => t.status.isIn(['PENDING', 'SYNCING', 'FAILED']))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch();
  }

  /// Watches stock movements across all batches of [productId].
  Stream<List<StockMovementRow>> watchProductMovements(String productId) {
    return (select(productVariants)
          ..where((t) => t.productId.equals(productId)))
        .watch()
        .asyncMap((variants) async {
      if (variants.isEmpty) return const <StockMovementRow>[];
      final variantIds = variants.map((v) => v.id).toList(growable: false);
      final productBatches = await (select(batches)
            ..where((t) => t.variantId.isIn(variantIds)))
          .get();
      if (productBatches.isEmpty) return const <StockMovementRow>[];
      final batchIds = productBatches.map((b) => b.id).toList(growable: false);
      return (select(stockMovements)
            ..where((t) => t.batchId.isIn(batchIds))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();
    });
  }
}

/// Summary bundle for a sale order with line items & payment legs.
@immutable
class SaleOrderBundle {
  const SaleOrderBundle({
    required this.order,
    required this.items,
    required this.payments,
  });

  final SaleOrderRow order;
  final List<SaleItemRow> items;
  final List<SalePaymentRow> payments;

  int get totalItemQuantity =>
      items.fold<int>(0, (sum, item) => sum + item.quantity);
}

/// Full sale detail bundle for [SaleDetailScreen].
@immutable
class SaleDetailBundle {
  const SaleDetailBundle({
    required this.order,
    required this.items,
    required this.payments,
    required this.customer,
  });

  final SaleOrderRow order;
  final List<SaleItemRow> items;
  final List<SalePaymentRow> payments;
  final CustomerRow? customer;
}

/// Summary bundle for a purchase invoice row in History.
@immutable
class PurchaseInvoiceBundle {
  const PurchaseInvoiceBundle({
    required this.invoice,
    required this.supplier,
    required this.productCount,
    required this.totalQuantity,
  });

  final PurchaseInvoiceRow invoice;
  final SupplierRow? supplier;
  final int productCount;
  final int totalQuantity;
}

/// Full purchase invoice detail bundle for [PurchaseDetailScreen].
@immutable
class PurchaseDetailBundle {
  const PurchaseDetailBundle({
    required this.invoice,
    required this.supplier,
    required this.items,
    required this.batches,
    required this.openSupplierInvoices,
  });

  final PurchaseInvoiceRow invoice;
  final SupplierRow? supplier;
  final List<PurchaseInvoiceItemRow> items;
  final List<BatchRow> batches;
  final List<PurchaseInvoiceRow> openSupplierInvoices;
}

