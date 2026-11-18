import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/money.dart';
import '../domain/supplier_models.dart';

/// Encrypted local repository for Supplier Ledger, Supplier Payments, and
/// Petty Cash Expenses (`suppliers`, `purchase_invoices`, `supplier_payments`,
/// `expenses`, `register_shifts`).
class SupplierRepository {
  SupplierRepository(this._db);

  final AppDatabase _db;
  static const Uuid _uuid = Uuid();

  static void _requireManagerOrOwner(String role, String action) {
    final normalized = role.trim().toUpperCase();
    if (normalized != 'OWNER' && normalized != 'MANAGER') {
      throw StateError('Permission denied ($normalized): $action requires OWNER or MANAGER.');
    }
  }

  /// Streams active suppliers ordered by highest payable due first, then name.
  Stream<List<SupplierRow>> watchSuppliers({String search = ''}) {
    final trimmed = search.trim().toLowerCase();
    final query = _db.select(_db.suppliers)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm.desc(t.balanceDue),
        (t) => OrderingTerm.asc(t.name),
      ]);
    return query.watch().map((rows) {
      if (trimmed.isEmpty) return rows;
      return rows.where((r) {
        return r.name.toLowerCase().contains(trimmed) ||
            (r.phone?.toLowerCase().contains(trimmed) ?? false) ||
            (r.panVat?.toLowerCase().contains(trimmed) ?? false);
      }).toList(growable: false);
    });
  }

  /// Loads supplier profile, purchase invoices, and payment history.
  Future<SupplierDetailBundle?> loadSupplierDetail(String supplierId) async {
    final supplier = await (_db.select(_db.suppliers)
          ..where((t) => t.id.equals(supplierId) & t.deletedAt.isNull()))
        .getSingleOrNull();
    if (supplier == null) return null;

    final invoices = await (_db.select(_db.purchaseInvoices)
          ..where((t) => t.supplierId.equals(supplierId))
          ..orderBy([
            (t) => OrderingTerm.desc(t.invoiceDate),
            (t) => OrderingTerm.desc(t.createdAt),
          ]))
        .get();

    final payments = await (_db.select(_db.supplierPayments)
          ..where((t) => t.supplierId.equals(supplierId))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();

    return SupplierDetailBundle(
      supplier: supplier,
      invoices: invoices,
      payments: payments,
    );
  }

  /// Creates or updates a supplier (MANAGER / OWNER only).
  Future<SupplierRow> saveSupplier({
    required String role,
    String? existingId,
    required String name,
    String? phone,
    String? panVat,
    String? address,
  }) async {
    _requireManagerOrOwner(role, 'Modify supplier');
    final cleanName = name.trim();
    if (cleanName.isEmpty) {
      throw ArgumentError('Supplier name is required.');
    }
    final cleanPhone = _nullIfEmpty(phone);
    final cleanPan = _nullIfEmpty(panVat);
    final cleanAddress = _nullIfEmpty(address);
    final now = DateTime.now().toUtc();
    final isInsert = existingId == null || existingId.trim().isEmpty;
    final id = isInsert ? _uuid.v4() : existingId.trim();
    final mutId = _uuid.v4();

    return _db.transaction(() async {
      late final SupplierRow saved;
      if (isInsert) {
        await _db.into(_db.suppliers).insert(
              SuppliersCompanion.insert(
                id: id,
                name: cleanName,
                phone: Value(cleanPhone),
                panVat: Value(cleanPan),
                address: Value(cleanAddress),
                totalPurchased: const Value(0),
                totalPaid: const Value(0),
                balanceDue: const Value(0),
                createdAt: Value(now),
                updatedAt: Value(now),
                clientUpdatedAt: Value(now),
              ),
            );
        saved = await (_db.select(_db.suppliers)
              ..where((t) => t.id.equals(id)))
            .getSingle();
      } else {
        final existing = await (_db.select(_db.suppliers)
              ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
            .getSingleOrNull();
        if (existing == null) {
          throw StateError('Supplier not found.');
        }
        await (_db.update(_db.suppliers)..where((t) => t.id.equals(id))).write(
          SuppliersCompanion(
            name: Value(cleanName),
            phone: Value(cleanPhone),
            panVat: Value(cleanPan),
            address: Value(cleanAddress),
            updatedAt: Value(now),
            clientUpdatedAt: Value(now),
          ),
        );
        saved = await (_db.select(_db.suppliers)
              ..where((t) => t.id.equals(id)))
            .getSingle();
      }

      final payload = <String, dynamic>{
        'id': saved.id,
        'name': saved.name,
        if (saved.phone != null) 'phone': saved.phone,
        if (saved.panVat != null) 'pan_vat': saved.panVat,
        if (saved.address != null) 'address': saved.address,
        'total_purchased': MoneyUtils.toDecimalString(saved.totalPurchased),
        'total_paid': MoneyUtils.toDecimalString(saved.totalPaid),
        'balance_due': MoneyUtils.toDecimalString(saved.balanceDue),
        'created_at': saved.createdAt.toUtc().toIso8601String(),
        'updated_at': now.toIso8601String(),
      };

      await _db.enqueueOutboxMutation(
        mutationId: mutId,
        targetTable: 'suppliers',
        recordId: saved.id,
        operation: isInsert ? 'INSERT' : 'UPDATE',
        payloadJson: jsonEncode(payload),
        clientUpdatedAt: now,
        createdAt: now,
      );

      return saved;
    });
  }

  /// Records a supplier bill payment (MANAGER / OWNER only), optionally tied
  /// to a specific [purchaseInvoiceId]. Updates local balances atomically and
  /// enqueues `supplier_payments` into `sync_outbox`.
  Future<SupplierPaymentRow> recordSupplierPayment({
    required String role,
    required String supplierId,
    String? purchaseInvoiceId,
    required int amountPaisa,
    required String paymentMethod,
    String? referenceNo,
    required String createdByUserId,
  }) async {
    _requireManagerOrOwner(role, 'Record supplier payment');
    if (amountPaisa <= 0 || amountPaisa > MoneyUtils.maxDecimal10_2Paisa) {
      throw ArgumentError('Payment amount must be greater than zero.');
    }
    if (!SupplierPaymentMethods.all.contains(paymentMethod)) {
      throw ArgumentError('Unsupported supplier payment method: $paymentMethod');
    }

    final cleanRef = _nullIfEmpty(referenceNo);
    final cleanInvId = _nullIfEmpty(purchaseInvoiceId);
    final now = DateTime.now().toUtc();
    final paymentId = _uuid.v4();
    final mutId = _uuid.v4();

    return _db.transaction(() async {
      final supplier = await (_db.select(_db.suppliers)
            ..where((t) => t.id.equals(supplierId) & t.deletedAt.isNull()))
          .getSingleOrNull();
      if (supplier == null) {
        throw StateError('Supplier not found.');
      }
      if (amountPaisa > supplier.balanceDue) {
        throw StateError(
          'Payment ${MoneyUtils.formatRs(amountPaisa)} exceeds supplier due '
          '${MoneyUtils.formatRs(supplier.balanceDue)}.',
        );
      }

      if (cleanInvId != null) {
        final inv = await (_db.select(_db.purchaseInvoices)
              ..where((t) => t.id.equals(cleanInvId)))
            .getSingleOrNull();
        if (inv == null || inv.supplierId != supplierId) {
          throw StateError('Purchase invoice not found for this supplier.');
        }
        if (amountPaisa > inv.dueAmount) {
          throw StateError(
            'Payment ${MoneyUtils.formatRs(amountPaisa)} exceeds invoice due '
            '${MoneyUtils.formatRs(inv.dueAmount)}.',
          );
        }
        final newPaid = inv.paidAmount + amountPaisa;
        final newDue = inv.dueAmount - amountPaisa;
        final newStatus = newDue <= 0 ? 'PAID' : 'PARTIAL';
        await (_db.update(_db.purchaseInvoices)
              ..where((t) => t.id.equals(cleanInvId)))
            .write(
          PurchaseInvoicesCompanion(
            paidAmount: Value(newPaid),
            dueAmount: Value(newDue),
            status: Value(newStatus),
            updatedAt: Value(now),
          ),
        );
      }

      await (_db.update(_db.suppliers)..where((t) => t.id.equals(supplierId)))
          .write(
        SuppliersCompanion(
          totalPaid: Value(supplier.totalPaid + amountPaisa),
          balanceDue: Value(supplier.balanceDue - amountPaisa),
          updatedAt: Value(now),
        ),
      );

      await _db.into(_db.supplierPayments).insert(
            SupplierPaymentsCompanion.insert(
              id: paymentId,
              supplierId: supplierId,
              purchaseInvoiceId: Value(cleanInvId),
              amount: amountPaisa,
              paymentMethod: paymentMethod,
              referenceNo: Value(cleanRef),
              createdByUserId: Value(createdByUserId),
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );

      final payload = <String, dynamic>{
        'id': paymentId,
        'supplier_id': supplierId,
        if (cleanInvId != null) 'purchase_invoice_id': cleanInvId,
        'amount': MoneyUtils.toDecimalString(amountPaisa),
        'payment_method': paymentMethod,
        if (cleanRef != null) 'reference_no': cleanRef,
        'created_by_user_id': createdByUserId,
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      };

      await _db.enqueueOutboxMutation(
        mutationId: mutId,
        targetTable: 'supplier_payments',
        recordId: paymentId,
        operation: 'INSERT',
        payloadJson: jsonEncode(payload),
        clientUpdatedAt: now,
        createdAt: now,
      );

      return (_db.select(_db.supplierPayments)
            ..where((t) => t.id.equals(paymentId)))
          .getSingle();
    });
  }

  /// Streams petty cash expenses for [shiftId] (or recent 50 if [shiftId] is null).
  Stream<List<ExpenseRow>> watchExpenses({String? shiftId}) {
    final query = _db.select(_db.expenses);
    if (shiftId != null) {
      query.where((t) => t.shiftId.equals(shiftId));
    }
    query
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
      ..limit(50);
    return query.watch();
  }

  /// Records a petty cash / shop expense (`expenses` INSERT + Single-Galla drawer
  /// deduction if `paymentMethod == 'CASH'` and an open shift is active).
  Future<ExpenseRow> recordPettyExpense({
    required String category,
    required String title,
    required int amountPaisa,
    required String paymentMethod,
    String? paidTo,
    String? shiftId,
    required String createdByUserId,
  }) async {
    final cleanCategory = category.trim();
    final cleanTitle = title.trim();
    if (cleanCategory.isEmpty || cleanTitle.isEmpty) {
      throw ArgumentError('Category and title are required.');
    }
    if (amountPaisa <= 0 || amountPaisa > MoneyUtils.maxDecimal10_2Paisa) {
      throw ArgumentError('Expense amount must be greater than zero.');
    }
    if (!ExpensePaymentMethods.all.contains(paymentMethod)) {
      throw ArgumentError('Unsupported expense method: $paymentMethod');
    }

    final cleanPaidTo = _nullIfEmpty(paidTo);
    final now = DateTime.now().toUtc();
    final expenseId = _uuid.v4();
    final mutId = _uuid.v4();

    return _db.transaction(() async {
      final resolvedShiftId = _nullIfEmpty(shiftId) ??
          (await _db.fetchOpenRegisterShift())?.id;

      await _db.into(_db.expenses).insert(
            ExpensesCompanion.insert(
              id: expenseId,
              category: cleanCategory,
              title: cleanTitle,
              amount: amountPaisa,
              paymentMethod: paymentMethod,
              paidTo: Value(cleanPaidTo),
              shiftId: Value(resolvedShiftId),
              createdByUserId: createdByUserId,
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );

      if (paymentMethod == ExpensePaymentMethods.cash &&
          resolvedShiftId != null) {
        final shift = await (_db.select(_db.registerShifts)
              ..where((t) => t.id.equals(resolvedShiftId)))
            .getSingleOrNull();
        if (shift != null && shift.status == 'OPEN') {
          await (_db.update(_db.registerShifts)
                ..where((t) => t.id.equals(resolvedShiftId)))
              .write(
            RegisterShiftsCompanion(
              cashExpenses: Value(shift.cashExpenses + amountPaisa),
              expectedCash: Value(shift.expectedCash - amountPaisa),
              updatedAt: Value(now),
            ),
          );
        }
      }

      final payload = <String, dynamic>{
        'id': expenseId,
        'category': cleanCategory,
        'title': cleanTitle,
        'amount': MoneyUtils.toDecimalString(amountPaisa),
        'payment_method': paymentMethod,
        if (cleanPaidTo != null) 'paid_to': cleanPaidTo,
        if (resolvedShiftId != null) 'shift_id': resolvedShiftId,
        'created_by_user_id': createdByUserId,
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      };

      await _db.enqueueOutboxMutation(
        mutationId: mutId,
        targetTable: 'expenses',
        recordId: expenseId,
        operation: 'INSERT',
        payloadJson: jsonEncode(payload),
        clientUpdatedAt: now,
        createdAt: now,
      );

      return (_db.select(_db.expenses)..where((t) => t.id.equals(expenseId)))
          .getSingle();
    });
  }

  static String? _nullIfEmpty(String? v) {
    final trimmed = v?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }
}

