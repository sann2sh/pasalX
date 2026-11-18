import 'package:drift/drift.dart';

/// 1. USERS (`users`)
@DataClassName('UserRow')
class Users extends Table {
  @override
  String get tableName => 'users';

  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get username => text().unique()();
  TextColumn get passwordHash => text().nullable()();
  TextColumn get pinHash => text().nullable()();
  TextColumn get phone => text().nullable()();
  TextColumn get role => text()(); // 'OWNER', 'MANAGER', 'STAFF'
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 2. CUSTOMERS & KHATA (`customers`)
@DataClassName('CustomerRow')
class Customers extends Table {
  @override
  String get tableName => 'customers';

  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get phone => text().unique()();
  TextColumn get address => text().nullable()();
  IntColumn get creditLimit => integer().withDefault(const Constant(1000000))();
  IntColumn get currentBalanceDue => integer().withDefault(const Constant(0))();
  TextColumn get favoriteShadeNotes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get clientUpdatedAt => dateTime().nullable()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// `customer_shade_profiles`
@DataClassName('CustomerShadeProfileRow')
class CustomerShadeProfiles extends Table {
  @override
  String get tableName => 'customer_shade_profiles';

  TextColumn get id => text()();
  TextColumn get customerId =>
      text().references(Customers, #id, onDelete: KeyAction.cascade)();
  TextColumn get productName => text()();
  TextColumn get brand => text()();
  TextColumn get shadeVariant => text()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get clientUpdatedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// `customer_transactions`
@DataClassName('CustomerTransactionRow')
class CustomerTransactions extends Table {
  @override
  String get tableName => 'customer_transactions';

  TextColumn get id => text()();
  TextColumn get customerId =>
      text().references(Customers, #id, onDelete: KeyAction.restrict)();
  TextColumn get type => text()(); // 'DEBIT_PURCHASE', 'CREDIT_REPAYMENT'
  IntColumn get amount => integer()(); // paisa
  IntColumn get balanceAfter => integer()(); // paisa
  TextColumn get referenceBillNo => text().nullable()();
  TextColumn get paymentMethod => text().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get createdByUserId =>
      text().nullable().references(Users, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 3. SUPPLIERS & PROCUREMENT (`suppliers`)
@DataClassName('SupplierRow')
class Suppliers extends Table {
  @override
  String get tableName => 'suppliers';

  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get phone => text().nullable()();
  TextColumn get panVat => text().nullable()();
  TextColumn get address => text().nullable()();
  IntColumn get totalPurchased => integer().withDefault(const Constant(0))();
  IntColumn get totalPaid => integer().withDefault(const Constant(0))();
  IntColumn get balanceDue => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get clientUpdatedAt => dateTime().nullable()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// `purchase_invoices`
@DataClassName('PurchaseInvoiceRow')
class PurchaseInvoices extends Table {
  @override
  String get tableName => 'purchase_invoices';

  TextColumn get id => text()();
  TextColumn get supplierId =>
      text().references(Suppliers, #id, onDelete: KeyAction.restrict)();
  TextColumn get invoiceNo => text()();
  TextColumn get invoiceDate => text()(); // ISO YYYY-MM-DD
  IntColumn get totalAmount => integer()(); // paisa
  IntColumn get paidAmount => integer().withDefault(const Constant(0))();
  IntColumn get dueAmount => integer()(); // paisa
  TextColumn get status => text().withDefault(const Constant('UNPAID'))();
  TextColumn get notes => text().nullable()();
  TextColumn get createdByUserId =>
      text().nullable().references(Users, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 4. PRODUCT CATALOG & 3-TIER INVENTORY (`products`)
@DataClassName('ProductRow')
class Products extends Table {
  @override
  String get tableName => 'products';

  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get brand => text()();
  TextColumn get category => text()();
  BoolColumn get isGeneric => boolean().withDefault(const Constant(false))();
  TextColumn get photoUrl => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get clientUpdatedAt => dateTime().nullable()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// `product_variants`
@DataClassName('ProductVariantRow')
class ProductVariants extends Table {
  @override
  String get tableName => 'product_variants';

  TextColumn get id => text()();
  TextColumn get productId =>
      text().references(Products, #id, onDelete: KeyAction.cascade)();
  TextColumn get variantName => text()();
  TextColumn get sizeVolume => text().nullable()();
  TextColumn get colorHex => text().nullable()();
  TextColumn get attributes => text().withDefault(const Constant('{}'))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get clientUpdatedAt => dateTime().nullable()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// `batches` (Tier 3: Cost, MRP, Lot Stock & Expiry)
/// Note: `supplierId`, `purchaseInvoiceId`, and `costPrice` are nullable
/// on mobile so `STAFF` and `MANAGER` pulls enforce server RBAC masking cleanly.
@DataClassName('BatchRow')
class Batches extends Table {
  @override
  String get tableName => 'batches';

  TextColumn get id => text()();
  TextColumn get variantId =>
      text().references(ProductVariants, #id, onDelete: KeyAction.cascade)();
  TextColumn get supplierId => text().nullable().references(Suppliers, #id)();
  TextColumn get purchaseInvoiceId =>
      text().nullable().references(PurchaseInvoices, #id)();
  TextColumn get batchCode => text()();
  TextColumn get stickerBarcode => text().unique()();
  IntColumn get costPrice => integer().nullable()(); // paisa (OWNER only)
  IntColumn get sellingPrice => integer()(); // paisa
  IntColumn get stockQuantity => integer().withDefault(const Constant(0))();
  TextColumn get expiryDate => text()(); // ISO YYYY-MM-DD
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get clientUpdatedAt => dateTime().nullable()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// `purchase_invoice_items`
@DataClassName('PurchaseInvoiceItemRow')
class PurchaseInvoiceItems extends Table {
  @override
  String get tableName => 'purchase_invoice_items';

  TextColumn get id => text()();
  TextColumn get purchaseInvoiceId =>
      text().references(PurchaseInvoices, #id, onDelete: KeyAction.cascade)();
  TextColumn get variantId =>
      text().references(ProductVariants, #id)();
  TextColumn get batchId => text().nullable().references(Batches, #id)();
  TextColumn get productName => text()();
  TextColumn get variantName => text()();
  IntColumn get quantityReceived => integer()();
  IntColumn get unitCostPrice => integer().nullable()(); // paisa (OWNER only)
  IntColumn get unitSellingPrice => integer()(); // paisa
  IntColumn get totalCost => integer().nullable()(); // paisa (OWNER only)
  TextColumn get batchCode => text().nullable()();
  TextColumn get expiryDate => text()(); // ISO YYYY-MM-DD
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// `supplier_payments`
@DataClassName('SupplierPaymentRow')
class SupplierPayments extends Table {
  @override
  String get tableName => 'supplier_payments';

  TextColumn get id => text()();
  TextColumn get supplierId => text().references(Suppliers, #id)();
  TextColumn get purchaseInvoiceId =>
      text().nullable().references(PurchaseInvoices, #id)();
  IntColumn get amount => integer()(); // paisa
  TextColumn get paymentMethod => text()();
  TextColumn get referenceNo => text().nullable()();
  TextColumn get createdByUserId =>
      text().nullable().references(Users, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// `stock_movements`
@DataClassName('StockMovementRow')
class StockMovements extends Table {
  @override
  String get tableName => 'stock_movements';

  TextColumn get id => text()();
  TextColumn get batchId => text().references(Batches, #id)();
  TextColumn get movementType => text()();
  IntColumn get quantity => integer()(); // signed delta
  TextColumn get referenceId => text().nullable()();
  TextColumn get reason => text().nullable()();
  TextColumn get staffName => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 5. CASH REGISTER SHIFTS (SINGLE GALLA) (`register_shifts`)
@DataClassName('RegisterShiftRow')
class RegisterShifts extends Table {
  @override
  String get tableName => 'register_shifts';

  TextColumn get id => text()();
  @ReferenceName('openedRegisterShifts')
  TextColumn get openedByUserId => text().references(Users, #id)();
  @ReferenceName('closedRegisterShifts')
  TextColumn get closedByUserId => text().nullable().references(Users, #id)();
  DateTimeColumn get openedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get closedAt => dateTime().nullable()();
  IntColumn get openingFloat => integer()(); // paisa
  IntColumn get cashSales => integer().withDefault(const Constant(0))();
  IntColumn get digitalSales => integer().withDefault(const Constant(0))();
  IntColumn get khataCashRepayments =>
      integer().withDefault(const Constant(0))();
  IntColumn get cashExpenses => integer().withDefault(const Constant(0))();
  IntColumn get expectedCash => integer()(); // paisa
  IntColumn get actualCashCounted => integer().nullable()();
  IntColumn get discrepancy => integer().nullable()();
  IntColumn get cashWithdrawnDeposit =>
      integer().withDefault(const Constant(0))();
  IntColumn get retainedNextDayFloat =>
      integer().withDefault(const Constant(0))();
  TextColumn get status => text().withDefault(const Constant('OPEN'))();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 6. SALES, LINE ITEMS & PAYMENTS (`sale_orders`)
@DataClassName('SaleOrderRow')
class SaleOrders extends Table {
  @override
  String get tableName => 'sale_orders';

  TextColumn get id => text()();
  TextColumn get billNo => text().unique()();
  TextColumn get customerId => text().nullable().references(Customers, #id)();
  TextColumn get customerName => text().nullable()();
  TextColumn get customerPhone => text().nullable()();
  TextColumn get cashierUserId => text().references(Users, #id)();
  TextColumn get cashierName => text()();
  TextColumn get shiftId =>
      text().nullable().references(RegisterShifts, #id)();
  IntColumn get subtotal => integer()(); // paisa
  IntColumn get discountAmount => integer().withDefault(const Constant(0))();
  IntColumn get totalAmount => integer()(); // paisa
  IntColumn get costTotal => integer().nullable()(); // OWNER only
  IntColumn get netProfit => integer().nullable()(); // OWNER only
  TextColumn get paymentMode => text()();
  TextColumn get syncStatus => text().withDefault(const Constant('PENDING'))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// `sale_items`
@DataClassName('SaleItemRow')
class SaleItems extends Table {
  @override
  String get tableName => 'sale_items';

  TextColumn get id => text()();
  TextColumn get saleOrderId =>
      text().references(SaleOrders, #id, onDelete: KeyAction.cascade)();
  TextColumn get batchId => text().references(Batches, #id)();
  TextColumn get productName => text()();
  TextColumn get variantName => text()();
  IntColumn get quantity => integer()();
  IntColumn get costPrice => integer().nullable()(); // OWNER only
  IntColumn get sellingPrice => integer()(); // paisa
  IntColumn get totalPrice => integer()(); // paisa

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// `sale_payments`
@DataClassName('SalePaymentRow')
class SalePayments extends Table {
  @override
  String get tableName => 'sale_payments';

  TextColumn get id => text()();
  TextColumn get saleOrderId =>
      text().references(SaleOrders, #id, onDelete: KeyAction.cascade)();
  TextColumn get method => text()();
  IntColumn get amount => integer()(); // paisa
  TextColumn get transactionRef => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// `staff_shift_sessions`
@DataClassName('StaffShiftSessionRow')
class StaffShiftSessions extends Table {
  @override
  String get tableName => 'staff_shift_sessions';

  TextColumn get id => text()();
  TextColumn get registerShiftId => text().references(RegisterShifts, #id)();
  @ReferenceName('staffSessions')
  TextColumn get userId => text().references(Users, #id)();
  TextColumn get deviceCode => text()();
  DateTimeColumn get punchedInAt =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get punchedOutAt => dateTime().nullable()();
  DateTimeColumn get lastSyncedAt =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get status => text().withDefault(const Constant('ACTIVE'))();
  @ReferenceName('forceClosedSessions')
  TextColumn get forceClosedByUserId =>
      text().nullable().references(Users, #id)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// `expenses`
@DataClassName('ExpenseRow')
class Expenses extends Table {
  @override
  String get tableName => 'expenses';

  TextColumn get id => text()();
  TextColumn get category => text()();
  TextColumn get title => text()();
  IntColumn get amount => integer()(); // paisa
  TextColumn get paymentMethod => text()();
  TextColumn get paidTo => text().nullable()();
  TextColumn get shiftId =>
      text().nullable().references(RegisterShifts, #id)();
  TextColumn get createdByUserId => text().references(Users, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// `inventory_sync_audit` (pulled for OWNER/MANAGER discrepancy review)
@DataClassName('InventorySyncAuditRow')
class InventorySyncAudit extends Table {
  @override
  String get tableName => 'inventory_sync_audit';

  TextColumn get id => text()();
  TextColumn get batchId => text().references(Batches, #id)();
  TextColumn get deviceCode => text()();
  TextColumn get operation => text()();
  IntColumn get quantityChange => integer()();
  IntColumn get preSyncQty => integer().nullable()();
  IntColumn get postSyncQty => integer().nullable()();
  BoolColumn get isDiscrepancy =>
      boolean().withDefault(const Constant(false))();
  TextColumn get referenceId => text().nullable()();
  TextColumn get stockMovementId =>
      text().nullable().unique().references(StockMovements, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 7. OFFLINE SYNC OUTBOX (MOBILE CLIENT ONLY) (`sync_outbox`)
@DataClassName('SyncOutboxRow')
class SyncOutbox extends Table {
  @override
  String get tableName => 'sync_outbox';

  TextColumn get id => text()();
  TextColumn get targetTable => text().named('table_name')();
  TextColumn get recordId => text()();
  TextColumn get operation => text()(); // 'INSERT', 'UPDATE', 'DELETE'
  TextColumn get payloadJson => text()();
  TextColumn get status => text().withDefault(const Constant('PENDING'))();
  TextColumn get errorMessage => text().nullable()();
  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get clientUpdatedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get syncedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Local encrypted non-secret sync cursor & monotonic bill sequence store (`sync_metadata`).
@DataClassName('SyncMetadataRow')
class SyncMetadata extends Table {
  @override
  String get tableName => 'sync_metadata';

  TextColumn get key => text()();
  TextColumn get value => text()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// 8. SYNCED STORE PROFILE (`stores`, server-authoritative via `GET /api/sync/pull`).
@DataClassName('StoreRow')
class Stores extends Table {
  @override
  String get tableName => 'stores';

  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get panNumber => text().nullable()();
  TextColumn get phone => text().nullable()();
  TextColumn get address => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('ACTIVE'))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 9. SYNCED STORE MEMBERS (`store_members`, server-authoritative via `GET /api/sync/pull`).
@DataClassName('StoreMemberRow')
class StoreMembers extends Table {
  @override
  String get tableName => 'store_members';

  TextColumn get id => text()();
  TextColumn get userId => text().unique()();
  TextColumn get name => text()();
  TextColumn get username => text()();
  TextColumn get role => text()(); // 'OWNER', 'MANAGER', 'STAFF'
  TextColumn get status => text().withDefault(const Constant('ACTIVE'))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
