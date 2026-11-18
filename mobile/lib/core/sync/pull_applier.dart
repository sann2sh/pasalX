import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../network/sync_models.dart';

/// Applies delta changes returned by `GET /api/sync/pull` into the local
/// SQLCipher Drift database inside a single ACID transaction.
abstract final class PullApplier {
  static const String cursorMetadataKey = 'last_pull_cursor';

  /// Reads the last saved microsecond cursor from `sync_metadata`, if any.
  static Future<DateTime?> readCursor(AppDatabase db) async {
    final raw = await db.getMetadata(cursorMetadataKey);
    if (raw == null || raw.trim().isEmpty) return null;
    return DateTime.tryParse(raw.trim())?.toUtc();
  }

  /// Upserts all rows from [pull] in strict foreign-key dependency order and
  /// advances [cursorMetadataKey] to [pull.serverTime] atomically.
  static Future<void> apply(AppDatabase db, SyncPullResult pull) async {
    final c = pull.changes;

    await db.transaction(() async {
      await db.customStatement('PRAGMA defer_foreign_keys = ON;');

      if (c.totalRecordCount > 0) {
        for (final st in c.stores) {
          await db.into(db.stores).insertOnConflictUpdate(
                StoresCompanion.insert(
                  id: st.id,
                  name: st.name,
                  panNumber: Value(st.panNumber),
                  phone: Value(st.phone),
                  address: Value(st.address),
                  status: Value(st.status),
                  updatedAt: _dtVal(st.updatedAt),
                ),
              );
        }

        for (final m in c.storeMembers) {
          await db.into(db.storeMembers).insertOnConflictUpdate(
                StoreMembersCompanion.insert(
                  id: m.id,
                  userId: m.userId,
                  name: m.name,
                  username: m.username,
                  role: m.role,
                  status: Value(m.status),
                  updatedAt: _dtVal(m.updatedAt),
                ),
              );
          await db.into(db.users).insertOnConflictUpdate(
                UsersCompanion.insert(
                  id: m.userId,
                  name: m.name,
                  username: m.username,
                  role: m.role,
                  isActive: Value(m.status == 'ACTIVE'),
                  updatedAt: _dtVal(m.updatedAt),
                ),
              );
        }

        await _ensureReferencedUsers(db, c);

        for (final s in c.suppliers) {
          await db.into(db.suppliers).insertOnConflictUpdate(
                SuppliersCompanion.insert(
                  id: s.id,
                  name: s.name,
                  phone: Value(s.phone),
                  panVat: Value(s.panVat),
                  address: Value(s.address),
                  totalPurchased: Value(s.totalPurchasedPaisa),
                  totalPaid: Value(s.totalPaidPaisa),
                  balanceDue: Value(s.balanceDuePaisa),
                  createdAt: _dtVal(s.createdAt),
                  updatedAt: _dtVal(s.updatedAt),
                  deletedAt: Value(s.deletedAt),
                ),
              );
        }

        for (final inv in c.purchaseInvoices) {
          await db.into(db.purchaseInvoices).insertOnConflictUpdate(
                PurchaseInvoicesCompanion.insert(
                  id: inv.id,
                  supplierId: inv.supplierId,
                  invoiceNo: inv.invoiceNo,
                  invoiceDate: inv.invoiceDate,
                  totalAmount: inv.totalAmountPaisa,
                  paidAmount: Value(inv.paidAmountPaisa),
                  dueAmount: inv.dueAmountPaisa,
                  status: Value(inv.status),
                  notes: Value(inv.notes),
                  createdByUserId: Value(inv.createdByUserId),
                  createdAt: _dtVal(inv.createdAt),
                  updatedAt: _dtVal(inv.updatedAt),
                ),
              );
        }

        for (final p in c.products) {
          await db.into(db.products).insertOnConflictUpdate(
                ProductsCompanion.insert(
                  id: p.id,
                  name: p.name,
                  brand: p.brand,
                  category: p.category,
                  isGeneric: Value(p.isGeneric),
                  photoUrl: Value(p.photoUrl),
                  createdAt: _dtVal(p.createdAt),
                  updatedAt: _dtVal(p.updatedAt),
                  deletedAt: Value(p.deletedAt),
                ),
              );
        }

        for (final v in c.productVariants) {
          await db.into(db.productVariants).insertOnConflictUpdate(
                ProductVariantsCompanion.insert(
                  id: v.id,
                  productId: v.productId,
                  variantName: v.variantName,
                  sizeVolume: Value(v.sizeVolume),
                  colorHex: Value(v.colorHex),
                  attributes: Value(v.attributesJson),
                  isActive: Value(v.isActive),
                  createdAt: _dtVal(v.createdAt),
                  updatedAt: _dtVal(v.updatedAt),
                  deletedAt: Value(v.deletedAt),
                ),
              );
        }

        for (final b in c.batches) {
          await db.into(db.batches).insertOnConflictUpdate(
                BatchesCompanion.insert(
                  id: b.id,
                  variantId: b.variantId,
                  supplierId: Value(b.supplierId),
                  purchaseInvoiceId: Value(b.purchaseInvoiceId),
                  batchCode: b.batchCode,
                  stickerBarcode: b.stickerBarcode,
                  costPrice: Value(b.costPricePaisa),
                  sellingPrice: b.sellingPricePaisa,
                  stockQuantity: Value(b.stockQuantity),
                  expiryDate: b.expiryDate,
                  createdAt: _dtVal(b.createdAt),
                  updatedAt: _dtVal(b.updatedAt),
                  deletedAt: Value(b.deletedAt),
                ),
              );
        }

        for (final pii in c.purchaseInvoiceItems) {
          await db.into(db.purchaseInvoiceItems).insertOnConflictUpdate(
                PurchaseInvoiceItemsCompanion.insert(
                  id: pii.id,
                  purchaseInvoiceId: pii.purchaseInvoiceId,
                  variantId: pii.variantId,
                  batchId: Value(pii.batchId),
                  productName: pii.productName,
                  variantName: pii.variantName,
                  quantityReceived: pii.quantityReceived,
                  unitCostPrice: Value(pii.unitCostPricePaisa),
                  unitSellingPrice: pii.unitSellingPricePaisa,
                  totalCost: Value(pii.totalCostPaisa),
                  batchCode: Value(pii.batchCode),
                  expiryDate: pii.expiryDate,
                  createdAt: _dtVal(pii.createdAt),
                  updatedAt: _dtVal(pii.updatedAt),
                ),
              );
        }

        for (final sp in c.supplierPayments) {
          await db.into(db.supplierPayments).insertOnConflictUpdate(
                SupplierPaymentsCompanion.insert(
                  id: sp.id,
                  supplierId: sp.supplierId,
                  purchaseInvoiceId: Value(sp.purchaseInvoiceId),
                  amount: sp.amountPaisa,
                  paymentMethod: sp.paymentMethod,
                  referenceNo: Value(sp.referenceNo),
                  createdByUserId: Value(sp.createdByUserId),
                  createdAt: _dtVal(sp.createdAt),
                  updatedAt: _dtVal(sp.updatedAt),
                ),
              );
        }

        for (final cust in c.customers) {
          await db.into(db.customers).insertOnConflictUpdate(
                CustomersCompanion.insert(
                  id: cust.id,
                  name: cust.name,
                  phone: cust.phone,
                  address: Value(cust.address),
                  creditLimit: Value(cust.creditLimitPaisa ?? 1000000),
                  currentBalanceDue: Value(cust.currentBalanceDuePaisa),
                  favoriteShadeNotes: Value(cust.favoriteShadeNotes),
                  createdAt: _dtVal(cust.createdAt),
                  updatedAt: _dtVal(cust.updatedAt),
                  deletedAt: Value(cust.deletedAt),
                ),
              );
        }

        for (final shade in c.customerShadeProfiles) {
          await db.into(db.customerShadeProfiles).insertOnConflictUpdate(
                CustomerShadeProfilesCompanion.insert(
                  id: shade.id,
                  customerId: shade.customerId,
                  productName: shade.productName,
                  brand: shade.brand,
                  shadeVariant: shade.shadeVariant,
                  notes: Value(shade.notes),
                  createdAt: _dtVal(shade.createdAt),
                  updatedAt: _dtVal(shade.updatedAt),
                ),
              );
        }

        for (final txRow in c.customerTransactions) {
          await db.into(db.customerTransactions).insertOnConflictUpdate(
                CustomerTransactionsCompanion.insert(
                  id: txRow.id,
                  customerId: txRow.customerId,
                  type: txRow.type,
                  amount: txRow.amountPaisa,
                  balanceAfter: txRow.balanceAfterPaisa,
                  referenceBillNo: Value(txRow.referenceBillNo),
                  paymentMethod: Value(txRow.paymentMethod),
                  notes: Value(txRow.notes),
                  createdByUserId: Value(txRow.createdByUserId),
                  createdAt: _dtVal(txRow.createdAt),
                  updatedAt: _dtVal(txRow.updatedAt),
                ),
              );
        }

        for (final rs in c.registerShifts) {
          await db.into(db.registerShifts).insertOnConflictUpdate(
                RegisterShiftsCompanion.insert(
                  id: rs.id,
                  openedByUserId: rs.openedByUserId,
                  closedByUserId: Value(rs.closedByUserId),
                  openedAt: _dtVal(rs.openedAt),
                  closedAt: Value(rs.closedAt),
                  openingFloat: rs.openingFloatPaisa,
                  cashSales: Value(rs.cashSalesPaisa),
                  digitalSales: Value(rs.digitalSalesPaisa),
                  khataCashRepayments: Value(rs.khataCashRepaymentsPaisa),
                  cashExpenses: Value(rs.cashExpensesPaisa),
                  expectedCash: rs.expectedCashPaisa,
                  actualCashCounted: Value(rs.actualCashCountedPaisa),
                  discrepancy: Value(rs.discrepancyPaisa),
                  cashWithdrawnDeposit: Value(rs.cashWithdrawnDepositPaisa),
                  retainedNextDayFloat: Value(rs.retainedNextDayFloatPaisa),
                  status: Value(rs.status),
                  notes: Value(rs.notes),
                  createdAt: _dtVal(rs.createdAt),
                  updatedAt: _dtVal(rs.updatedAt),
                ),
              );
        }

        for (final ss in c.staffShiftSessions) {
          await db.into(db.staffShiftSessions).insertOnConflictUpdate(
                StaffShiftSessionsCompanion.insert(
                  id: ss.id,
                  registerShiftId: ss.registerShiftId,
                  userId: ss.userId,
                  deviceCode: ss.deviceCode,
                  punchedInAt: _dtVal(ss.punchedInAt),
                  punchedOutAt: Value(ss.punchedOutAt),
                  lastSyncedAt: _dtVal(ss.lastSyncedAt),
                  status: Value(ss.status),
                  forceClosedByUserId: Value(ss.forceClosedByUserId),
                  updatedAt: _dtVal(ss.updatedAt),
                ),
              );
        }

        for (final order in c.saleOrders) {
          await db.into(db.saleOrders).insertOnConflictUpdate(
                SaleOrdersCompanion.insert(
                  id: order.id,
                  billNo: order.billNo,
                  customerId: Value(order.customerId),
                  customerName: Value(order.customerName),
                  customerPhone: Value(order.customerPhone),
                  cashierUserId: order.cashierUserId,
                  cashierName: order.cashierName,
                  shiftId: Value(order.shiftId),
                  subtotal: order.subtotalPaisa,
                  discountAmount: Value(order.discountAmountPaisa),
                  totalAmount: order.totalAmountPaisa,
                  costTotal: Value(order.costTotalPaisa),
                  netProfit: Value(order.netProfitPaisa),
                  paymentMode: order.paymentMode,
                  syncStatus: const Value('SYNCED'),
                  createdAt: _dtVal(order.createdAt),
                  updatedAt: _dtVal(order.updatedAt),
                ),
              );
        }

        for (final item in c.saleItems) {
          await db.into(db.saleItems).insertOnConflictUpdate(
                SaleItemsCompanion.insert(
                  id: item.id,
                  saleOrderId: item.saleOrderId,
                  batchId: item.batchId,
                  productName: item.productName,
                  variantName: item.variantName,
                  quantity: item.quantity,
                  costPrice: Value(item.costPricePaisa),
                  sellingPrice: item.sellingPricePaisa,
                  totalPrice: item.totalPricePaisa,
                ),
              );
        }

        for (final pay in c.salePayments) {
          await db.into(db.salePayments).insertOnConflictUpdate(
                SalePaymentsCompanion.insert(
                  id: pay.id,
                  saleOrderId: pay.saleOrderId,
                  method: pay.method,
                  amount: pay.amountPaisa,
                  transactionRef: Value(pay.transactionRef),
                ),
              );
        }

        for (final mv in c.stockMovements) {
          await db.into(db.stockMovements).insertOnConflictUpdate(
                StockMovementsCompanion.insert(
                  id: mv.id,
                  batchId: mv.batchId,
                  movementType: mv.movementType,
                  quantity: mv.quantity,
                  referenceId: Value(mv.referenceId),
                  reason: Value(mv.reason),
                  staffName: mv.staffName,
                  createdAt: _dtVal(mv.createdAt),
                  updatedAt: _dtVal(mv.updatedAt),
                ),
              );
        }

        for (final exp in c.expenses) {
          await db.into(db.expenses).insertOnConflictUpdate(
                ExpensesCompanion.insert(
                  id: exp.id,
                  category: exp.category,
                  title: exp.title,
                  amount: exp.amountPaisa,
                  paymentMethod: exp.paymentMethod,
                  paidTo: Value(exp.paidTo),
                  shiftId: Value(exp.shiftId),
                  createdByUserId: exp.createdByUserId,
                  createdAt: _dtVal(exp.createdAt),
                  updatedAt: _dtVal(exp.updatedAt),
                ),
              );
        }

        for (final audit in c.inventorySyncAudit) {
          await db.into(db.inventorySyncAudit).insertOnConflictUpdate(
                InventorySyncAuditCompanion.insert(
                  id: audit.id,
                  batchId: audit.batchId,
                  deviceCode: audit.deviceCode,
                  operation: audit.operation,
                  quantityChange: audit.quantityChange,
                  preSyncQty: Value(audit.preSyncQty),
                  postSyncQty: Value(audit.postSyncQty),
                  isDiscrepancy: Value(audit.isDiscrepancy),
                  referenceId: Value(audit.referenceId),
                  stockMovementId: Value(audit.stockMovementId),
                  createdAt: _dtVal(audit.createdAt),
                  updatedAt: _dtVal(audit.updatedAt),
                ),
              );
        }
      }

      await db.setMetadata(
        cursorMetadataKey,
        pull.serverTime.toUtc().toIso8601String(),
      );
    });
  }

  /// Ensures placeholder rows exist in `users` for any user UUIDs referenced by
  /// pulled records (e.g. another cashier's shift or sale), satisfying SQLite
  /// `PRAGMA foreign_keys = ON` without overwriting full profile rows.
  static Future<void> _ensureReferencedUsers(
    AppDatabase db,
    SyncPullChanges c,
  ) async {
    final userNames = <String, String>{};
    void addUser(String? id, [String? hintName]) {
      if (id == null || id.trim().isEmpty) return;
      final cleanId = id.trim();
      final hint = hintName?.trim();
      if (hint != null && hint.isNotEmpty) {
        userNames[cleanId] = hint;
      } else {
        userNames.putIfAbsent(cleanId, () => 'Shop Staff');
      }
    }

    for (final order in c.saleOrders) {
      addUser(order.cashierUserId, order.cashierName);
    }
    for (final rs in c.registerShifts) {
      addUser(rs.openedByUserId);
      addUser(rs.closedByUserId);
    }
    for (final ss in c.staffShiftSessions) {
      addUser(ss.userId);
      addUser(ss.forceClosedByUserId);
    }
    for (final tx in c.customerTransactions) {
      addUser(tx.createdByUserId);
    }
    for (final inv in c.purchaseInvoices) {
      addUser(inv.createdByUserId);
    }
    for (final sp in c.supplierPayments) {
      addUser(sp.createdByUserId);
    }
    for (final exp in c.expenses) {
      addUser(exp.createdByUserId);
    }

    for (final entry in userNames.entries) {
      await db.into(db.users).insert(
            UsersCompanion.insert(
              id: entry.key,
              name: entry.value,
              username: 'user_${entry.key}',
              role: 'STAFF',
              isActive: const Value(true),
            ),
            mode: InsertMode.insertOrIgnore,
          );
    }
  }

  static Value<DateTime> _dtVal(DateTime? dt) =>
      dt == null ? const Value.absent() : Value(dt.toUtc());
}

