import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
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
  /// (using SQLite `rowid` as deterministic sub-microsecond tiebreaker).
  Future<List<SyncOutboxRow>> fetchPendingOutbox({int limit = 50}) {
    final query = select(syncOutbox)
      ..where((t) => t.status.equals('PENDING'))
      ..orderBy([
        (t) => OrderingTerm.asc(t.createdAt),
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
}

