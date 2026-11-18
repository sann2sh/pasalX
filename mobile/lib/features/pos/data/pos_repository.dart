import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/money.dart';
import '../../../core/printer/esc_pos_receipt_builder.dart';
import '../domain/pos_models.dart';

class PosValidationException implements Exception {
  const PosValidationException(this.message);
  final String message;

  @override
  String toString() => 'PosValidationException: $message';
}

/// Encrypted Drift repository for Step 9 POS Counter, FEFO & Expiry Checks,
/// Quick-Pad generic items, Customer Khata + Shade Profiles, and ACID Checkout.
class PosRepository {
  PosRepository({
    required this.db,
    this.onMutationCommitted,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AppDatabase db;
  final VoidCallback? onMutationCommitted;
  final DateTime Function() _clock;
  final Uuid _uuid = const Uuid();

  static bool _canViewCost(String? role) =>
      role?.trim().toUpperCase() == 'OWNER';

  static String _isoUtc(DateTime dt) => dt.toUtc().toIso8601String();

  PosScannedBatch _mapBatch({
    required ProductRow product,
    required ProductVariantRow variant,
    required BatchRow batch,
    required String? role,
  }) {
    return PosScannedBatch(
      batchId: batch.id,
      variantId: variant.id,
      productId: product.id,
      productName: product.name,
      brand: product.brand,
      category: product.category,
      isGeneric: product.isGeneric,
      variantName: variant.variantName,
      batchCode: batch.batchCode,
      stickerBarcode: batch.stickerBarcode,
      sellingPricePaisa: batch.sellingPrice,
      costPricePaisa: _canViewCost(role) ? batch.costPrice : null,
      stockQuantity: batch.stockQuantity,
      expiryDate:
          DateTime.tryParse(batch.expiryDate) ?? DateTime.utc(2099, 12, 31),
      colorHex: variant.colorHex,
      sizeVolume: variant.sizeVolume,
    );
  }

  /// Looks up a barcode in local encrypted SQLite and enforces:
  /// 1. Expired hard-block (`PosBatchScanStatus.expiredBlocked`)
  /// 2. FEFO older-batch soft warning (`PosBatchScanStatus.fefoOlderExists`)
  ///
  /// [inCartQtyByBatchId] accounts for units already in the active POS cart
  /// so FEFO won't keep nudging an older batch whose shelf units are already
  /// allocated in the current bill.
  Future<PosScanLookupResult> lookupByBarcode(
    String rawBarcode, {
    required String? role,
    Map<String, int> inCartQtyByBatchId = const <String, int>{},
  }) async {
    final code = rawBarcode.trim();
    if (code.isEmpty) return const PosScanLookupResult.notFound();

    final query = db.select(db.batches).join([
      innerJoin(
        db.productVariants,
        db.productVariants.id.equalsExp(db.batches.variantId),
      ),
      innerJoin(
        db.products,
        db.products.id.equalsExp(db.productVariants.productId),
      ),
    ])
      ..where(
        db.batches.stickerBarcode.equals(code) &
            db.batches.deletedAt.isNull() &
            db.productVariants.deletedAt.isNull() &
            db.products.deletedAt.isNull(),
      )
      ..limit(1);

    final row = await query.getSingleOrNull();
    if (row == null) {
      return const PosScanLookupResult.notFound();
    }

    final product = row.readTable(db.products);
    final variant = row.readTable(db.productVariants);
    final batch = row.readTable(db.batches);
    final scanned = _mapBatch(
      product: product,
      variant: variant,
      batch: batch,
      role: role,
    );

    final now = _clock();
    if (scanned.isExpiredAt(now)) {
      return PosScanLookupResult.expired(scanned);
    }

    // Check FEFO: does an older non-expired batch of this exact variant exist
    // with stock > 0?
    if (!scanned.isNonPerishable) {
      final siblingRows = await (db.select(db.batches)
            ..where(
              (b) =>
                  b.variantId.equals(variant.id) &
                  b.id.equals(batch.id).not() &
                  b.deletedAt.isNull() &
                  b.stockQuantity.isBiggerThanValue(0),
            )
            ..orderBy([(b) => OrderingTerm.asc(b.expiryDate)]))
          .get();

      for (final sibling in siblingRows) {
        final remainingSibling =
            sibling.stockQuantity - (inCartQtyByBatchId[sibling.id] ?? 0);
        if (remainingSibling <= 0) {
          continue;
        }
        final candidate = _mapBatch(
          product: product,
          variant: variant,
          batch: sibling,
          role: role,
        );
        if (candidate.isExpiredAt(now)) {
          continue;
        }
        final candidateDay = DateTime.utc(
          candidate.expiryDate.year,
          candidate.expiryDate.month,
          candidate.expiryDate.day,
        );
        final scannedDay = DateTime.utc(
          scanned.expiryDate.year,
          scanned.expiryDate.month,
          scanned.expiryDate.day,
        );
        if (candidateDay.isBefore(scannedDay)) {
          return PosScanLookupResult.fefoWarning(
            scanned: scanned,
            older: candidate,
          );
        }
        break;
      }
    }

    return PosScanLookupResult.ok(scanned);
  }

  /// Watches Generic / Quick-Pad items (up to 9 tiles for the 3x3 Quick-Pad).
  Stream<List<PosScannedBatch>> watchQuickPadItems({
    required String? role,
  }) {
    final query = db.select(db.products).join([
      innerJoin(
        db.productVariants,
        db.productVariants.productId.equalsExp(db.products.id),
      ),
      innerJoin(
        db.batches,
        db.batches.variantId.equalsExp(db.productVariants.id),
      ),
    ])
      ..where(
        (db.products.isGeneric.equals(true) |
                db.products.category.equals('Generic')) &
            db.products.deletedAt.isNull() &
            db.productVariants.deletedAt.isNull() &
            db.batches.deletedAt.isNull(),
      )
      ..orderBy([
        OrderingTerm.asc(db.products.name),
        OrderingTerm.asc(db.batches.expiryDate),
      ]);

    return query.watch().map((rows) {
      final now = _clock();
      final byProduct = <String, PosScannedBatch>{};
      for (final r in rows) {
        final product = r.readTable(db.products);
        if (byProduct.containsKey(product.id)) continue;
        final variant = r.readTable(db.productVariants);
        final batch = r.readTable(db.batches);
        final mapped = _mapBatch(
          product: product,
          variant: variant,
          batch: batch,
          role: role,
        );
        if (mapped.isExpiredAt(now)) continue;
        byProduct[product.id] = mapped;
        if (byProduct.length >= 9) break;
      }
      return byProduct.values.toList(growable: false);
    });
  }

  /// Searches sellable non-expired batches by product name, brand, shade, or
  /// sticker barcode for quick counter lookup.
  Future<List<PosScannedBatch>> searchSellableBatches(
    String queryText, {
    required String? role,
    int limit = 25,
  }) async {
    final needle = queryText.trim().toLowerCase();
    final rows = await (db.select(db.batches).join([
      innerJoin(
        db.productVariants,
        db.productVariants.id.equalsExp(db.batches.variantId),
      ),
      innerJoin(
        db.products,
        db.products.id.equalsExp(db.productVariants.productId),
      ),
    ])
          ..where(
            db.batches.deletedAt.isNull() &
                db.productVariants.deletedAt.isNull() &
                db.products.deletedAt.isNull(),
          )
          ..orderBy([
            OrderingTerm.asc(db.products.name),
            OrderingTerm.asc(db.batches.expiryDate),
          ]))
        .get();

    final now = _clock();
    final results = <PosScannedBatch>[];
    for (final row in rows) {
      final product = row.readTable(db.products);
      final variant = row.readTable(db.productVariants);
      final batch = row.readTable(db.batches);
      final mapped = _mapBatch(
        product: product,
        variant: variant,
        batch: batch,
        role: role,
      );
      if (mapped.isExpiredAt(now)) continue;

      if (needle.isNotEmpty) {
        final haystack =
            '${product.name} ${product.brand} ${variant.variantName} '
                    '${batch.stickerBarcode} ${batch.batchCode}'
                .toLowerCase();
        if (!haystack.contains(needle)) continue;
      }
      results.add(mapped);
      if (results.length >= limit) break;
    }
    return results;
  }

  /// Finds the earliest non-expired batch (FEFO) matching a saved
  /// [CustomerShadeProfileRow] so staff can tap "Add Previous Shade" into cart.
  Future<PosScannedBatch?> findBestBatchForShadeProfile(
    CustomerShadeProfileRow profile, {
    required String? role,
  }) async {
    final prodNeedle = profile.productName.trim().toLowerCase();
    final brandNeedle = profile.brand.trim().toLowerCase();
    final shadeNeedle = profile.shadeVariant.trim().toLowerCase();
    if (prodNeedle.isEmpty || shadeNeedle.isEmpty) return null;

    final rows = await (db.select(db.batches).join([
      innerJoin(
        db.productVariants,
        db.productVariants.id.equalsExp(db.batches.variantId),
      ),
      innerJoin(
        db.products,
        db.products.id.equalsExp(db.productVariants.productId),
      ),
    ])
          ..where(
            db.batches.deletedAt.isNull() &
                db.productVariants.deletedAt.isNull() &
                db.products.deletedAt.isNull(),
          )
          ..orderBy([OrderingTerm.asc(db.batches.expiryDate)]))
        .get();

    final now = _clock();
    PosScannedBatch? exactInStock;
    PosScannedBatch? exactOutOfStock;
    PosScannedBatch? partialInStock;
    PosScannedBatch? partialOutOfStock;

    for (final row in rows) {
      final product = row.readTable(db.products);
      final variant = row.readTable(db.productVariants);
      final batch = row.readTable(db.batches);
      final mapped = _mapBatch(
        product: product,
        variant: variant,
        batch: batch,
        role: role,
      );
      if (mapped.isExpiredAt(now)) continue;

      final pName = product.name.trim().toLowerCase();
      final pBrand = product.brand.trim().toLowerCase();
      final vName = variant.variantName.trim().toLowerCase();

      final exactProd = pName == prodNeedle;
      final exactShade = vName == shadeNeedle;
      final brandOk = brandNeedle.isEmpty ||
          brandNeedle == 'general' ||
          pBrand == brandNeedle ||
          pBrand.contains(brandNeedle);

      if (exactProd && exactShade && brandOk) {
        if (mapped.stockQuantity > 0) {
          exactInStock ??= mapped;
        } else {
          exactOutOfStock ??= mapped;
        }
        continue;
      }

      final prodMatch = pName.contains(prodNeedle) || prodNeedle.contains(pName);
      final shadeMatch =
          vName.contains(shadeNeedle) || shadeNeedle.contains(vName);
      if (!prodMatch || !shadeMatch || !brandOk) continue;

      if (mapped.stockQuantity > 0) {
        partialInStock ??= mapped;
      } else {
        partialOutOfStock ??= mapped;
      }
    }
    return exactInStock ?? exactOutOfStock ?? partialInStock ?? partialOutOfStock;
  }

  /// Watches customers filtered by name or phone (sub-second local SQLite).
  Stream<List<CustomerRow>> watchCustomers({String query = ''}) {
    final needle = query.trim().toLowerCase();
    return (db.select(db.customers)
          ..where((c) => c.deletedAt.isNull())
          ..orderBy([(c) => OrderingTerm.asc(c.name)]))
        .watch()
        .map((rows) {
      if (needle.isEmpty) return rows;
      return rows
          .where(
            (c) =>
                c.name.toLowerCase().contains(needle) ||
                c.phone.toLowerCase().contains(needle),
          )
          .toList(growable: false);
    });
  }

  /// Loads full customer bundle (profile, shade history, Khata ledger).
  Future<CustomerProfileBundle?> loadCustomerBundle(String customerId) async {
    final customer = await (db.select(db.customers)
          ..where((c) => c.id.equals(customerId) & c.deletedAt.isNull()))
        .getSingleOrNull();
    if (customer == null) return null;

    final shades = await (db.select(db.customerShadeProfiles)
          ..where((s) => s.customerId.equals(customerId))
          ..orderBy([(s) => OrderingTerm.desc(s.createdAt)]))
        .get();

    final txns = await (db.select(db.customerTransactions)
          ..where((t) => t.customerId.equals(customerId))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(30))
        .get();

    return CustomerProfileBundle(
      customer: customer,
      shades: shades,
      recentTransactions: txns,
    );
  }

  /// Creates a new Khata customer in encrypted SQLite and queues `sync_outbox`.
  Future<CustomerRow> createCustomer({
    required String name,
    required String phone,
    String? address,
    int creditLimitPaisa = 1000000, // Rs. 10,000 default
    String? favoriteShadeNotes,
    required String? role,
  }) async {
    final cleanName = name.trim();
    final cleanPhone = phone.trim();
    if (cleanName.isEmpty || cleanPhone.isEmpty) {
      throw const PosValidationException(
        'Customer name and phone number are required.',
      );
    }
    if (creditLimitPaisa < 0 ||
        creditLimitPaisa > MoneyUtils.maxDecimal10_2Paisa) {
      throw const PosValidationException(
        'Credit limit must be between Rs. 0 and Rs. 9,99,99,999.99.',
      );
    }

    final existing = await (db.select(db.customers)
          ..where((c) => c.phone.equals(cleanPhone)))
        .getSingleOrNull();
    if (existing != null) {
      throw const PosValidationException(
        'A customer with this phone number already exists.',
      );
    }

    final now = _clock().toUtc();
    final id = _uuid.v4();
    final cleanAddress =
        (address?.trim().isEmpty ?? true) ? null : address!.trim();
    final cleanNotes = (favoriteShadeNotes?.trim().isEmpty ?? true)
        ? null
        : favoriteShadeNotes!.trim();
    final allowLimit = role == 'OWNER' || role == 'MANAGER';
    final effectiveLimit = allowLimit ? creditLimitPaisa : 1000000;

    final created = await db.transaction(() async {
      await db.into(db.customers).insert(
            CustomersCompanion.insert(
              id: id,
              name: cleanName,
              phone: cleanPhone,
              address: Value(cleanAddress),
              creditLimit: Value(effectiveLimit),
              currentBalanceDue: const Value(0),
              favoriteShadeNotes: Value(cleanNotes),
              createdAt: Value(now),
              updatedAt: Value(now),
              clientUpdatedAt: Value(now),
            ),
          );

      final payload = <String, dynamic>{
        'id': id,
        'name': cleanName,
        'phone': cleanPhone,
        if (cleanAddress != null) 'address': cleanAddress,
        if (allowLimit)
          'credit_limit': MoneyUtils.toDecimalString(effectiveLimit),
        'current_balance_due': '0.00',
        if (cleanNotes != null) 'favorite_shade_notes': cleanNotes,
        'created_at': _isoUtc(now),
        'updated_at': _isoUtc(now),
      };

      await db.enqueueOutboxMutation(
        mutationId: _uuid.v4(),
        targetTable: 'customers',
        recordId: id,
        operation: 'INSERT',
        payloadJson: jsonEncode(payload),
        clientUpdatedAt: now,
      );

      return (db.select(db.customers)..where((c) => c.id.equals(id)))
          .getSingle();
    });

    onMutationCommitted?.call();
    return created;
  }

  /// Adds a customer shade profile (`customer_shade_profiles`) for future lookup.
  Future<CustomerShadeProfileRow> addCustomerShadeProfile({
    required String customerId,
    required String productName,
    required String brand,
    required String shadeVariant,
    String? notes,
  }) async {
    final cleanProd = productName.trim();
    final cleanBrand = brand.trim();
    final cleanShade = shadeVariant.trim();
    if (cleanProd.isEmpty || cleanShade.isEmpty) {
      throw const PosValidationException(
        'Product name and shade/variant are required.',
      );
    }

    final now = _clock().toUtc();
    final id = _uuid.v4();
    final cleanNotes = (notes?.trim().isEmpty ?? true) ? null : notes!.trim();

    final row = await db.transaction(() async {
      await db.into(db.customerShadeProfiles).insert(
            CustomerShadeProfilesCompanion.insert(
              id: id,
              customerId: customerId,
              productName: cleanProd,
              brand: cleanBrand.isEmpty ? 'General' : cleanBrand,
              shadeVariant: cleanShade,
              notes: Value(cleanNotes),
              createdAt: Value(now),
              updatedAt: Value(now),
              clientUpdatedAt: Value(now),
            ),
          );

      final payload = <String, dynamic>{
        'id': id,
        'customer_id': customerId,
        'product_name': cleanProd,
        'brand': cleanBrand.isEmpty ? 'General' : cleanBrand,
        'shade_variant': cleanShade,
        if (cleanNotes != null) 'notes': cleanNotes,
        'created_at': _isoUtc(now),
        'updated_at': _isoUtc(now),
      };

      await db.enqueueOutboxMutation(
        mutationId: _uuid.v4(),
        targetTable: 'customer_shade_profiles',
        recordId: id,
        operation: 'INSERT',
        payloadJson: jsonEncode(payload),
        clientUpdatedAt: now,
      );

      return (db.select(db.customerShadeProfiles)
            ..where((s) => s.id.equals(id)))
          .getSingle();
    });

    onMutationCommitted?.call();
    return row;
  }

  /// Records a Khata customer repayment (`CREDIT_REPAYMENT`) via `CASH` or
  /// `FONEPAY_QR`, decrementing `current_balance_due`, incrementing the active
  /// register shift if paid in cash, and queuing `sync_outbox`.
  Future<CustomerTransactionRow> recordKhataRepayment({
    required String customerId,
    required int amountPaisa,
    required String paymentMethod, // 'CASH' or 'FONEPAY_QR'
    required String userId,
    String? shiftId,
    String? notes,
  }) async {
    if (amountPaisa <= 0 || amountPaisa > MoneyUtils.maxDecimal10_2Paisa) {
      throw const PosValidationException(
        'Repayment amount must be greater than Rs. 0.',
      );
    }
    if (paymentMethod != 'CASH' && paymentMethod != 'FONEPAY_QR') {
      throw const PosValidationException(
        'Repayment method must be CASH or FONEPAY_QR.',
      );
    }

    final now = _clock().toUtc();
    final txnId = _uuid.v4();
    final cleanNotes = (notes?.trim().isEmpty ?? true) ? null : notes!.trim();
    final explicitShift = shiftId == null
        ? null
        : await (db.select(db.registerShifts)
              ..where((s) => s.id.equals(shiftId) & s.status.equals('OPEN')))
            .getSingleOrNull();
    final effectiveShiftId =
        explicitShift?.id ?? (await db.fetchOpenRegisterShift())?.id;

    final created = await db.transaction(() async {
      final customer = await (db.select(db.customers)
            ..where((c) => c.id.equals(customerId) & c.deletedAt.isNull()))
          .getSingleOrNull();
      if (customer == null) {
        throw const PosValidationException('Customer not found.');
      }
      if (customer.currentBalanceDue <= 0) {
        throw const PosValidationException(
          'This customer has no outstanding Khata balance due.',
        );
      }
      if (amountPaisa > customer.currentBalanceDue) {
        throw PosValidationException(
          'Repayment cannot exceed current due '
          '(${MoneyUtils.formatRs(customer.currentBalanceDue)}).',
        );
      }

      final newBalance = customer.currentBalanceDue - amountPaisa;
      await db.into(db.customerTransactions).insert(
            CustomerTransactionsCompanion.insert(
              id: txnId,
              customerId: customerId,
              type: 'CREDIT_REPAYMENT',
              amount: amountPaisa,
              balanceAfter: newBalance,
              paymentMethod: Value(paymentMethod),
              notes: Value(cleanNotes),
              createdByUserId: Value(userId),
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );

      await (db.update(db.customers)..where((c) => c.id.equals(customerId)))
          .write(
        CustomersCompanion(
          currentBalanceDue: Value(newBalance),
          updatedAt: Value(now),
        ),
      );

      if (paymentMethod == 'CASH' && effectiveShiftId != null) {
        final shift = await (db.select(db.registerShifts)
              ..where((s) => s.id.equals(effectiveShiftId)))
            .getSingleOrNull();
        if (shift != null && shift.status == 'OPEN') {
          await (db.update(db.registerShifts)
                ..where((s) => s.id.equals(effectiveShiftId)))
              .write(
            RegisterShiftsCompanion(
              khataCashRepayments:
                  Value(shift.khataCashRepayments + amountPaisa),
              expectedCash: Value(shift.expectedCash + amountPaisa),
              updatedAt: Value(now),
            ),
          );
        }
      }

      final payload = <String, dynamic>{
        'id': txnId,
        'customer_id': customerId,
        'type': 'CREDIT_REPAYMENT',
        'amount': MoneyUtils.toDecimalString(amountPaisa),
        'balance_after': MoneyUtils.toDecimalString(newBalance),
        'payment_method': paymentMethod,
        if (cleanNotes != null) 'notes': cleanNotes,
        'created_by_user_id': userId,
        if (paymentMethod == 'CASH' && effectiveShiftId != null)
          'shift_id': effectiveShiftId,
        'created_at': _isoUtc(now),
        'updated_at': _isoUtc(now),
      };

      await db.enqueueOutboxMutation(
        mutationId: _uuid.v4(),
        targetTable: 'customer_transactions',
        recordId: txnId,
        operation: 'INSERT',
        payloadJson: jsonEncode(payload),
        clientUpdatedAt: now,
      );

      return (db.select(db.customerTransactions)
            ..where((t) => t.id.equals(txnId)))
          .getSingle();
    });

    onMutationCommitted?.call();
    return created;
  }

  /// Generates a collision-free `{deviceCode}-{0001}` bill number.
  Future<String> _allocateNextBillNo(String deviceCode) async {
    final cleanCode = deviceCode.trim().isEmpty ? '01' : deviceCode.trim();
    final key = 'pos_bill_seq_$cleanCode';
    final rawSeq = await db.getMetadata(key);
    var nextSeq = (int.tryParse(rawSeq ?? '') ?? 0) + 1;

    // Ensure no collision with synced bills from the same device code.
    final prefix = '$cleanCode-';
    final existing = await (db.selectOnly(db.saleOrders)
          ..addColumns([db.saleOrders.billNo])
          ..where(db.saleOrders.billNo.like('$prefix%')))
        .get();
    for (final row in existing) {
      final b = row.read(db.saleOrders.billNo);
      if (b == null) continue;
      final suffix = b.substring(prefix.length);
      final parsed = int.tryParse(suffix);
      if (parsed != null && parsed >= nextSeq) {
        nextSeq = parsed + 1;
      }
    }

    await db.setMetadata(key, nextSeq.toString());
    return '$cleanCode-${nextSeq.toString().padLeft(4, '0')}';
  }

  /// Commits a complete POS checkout transactionally:
  /// - `sale_orders`, `sale_items`, `sale_payments`
  /// - `batches.stock_quantity` atomic decrement + `stock_movements` (`SALE`)
  /// - `register_shifts` drawer update (`cash_sales`, `digital_sales`, `expected_cash`)
  /// - `customers` + `customer_transactions` (`DEBIT_PURCHASE`) if Khata credit is used
  /// - `sync_outbox` embedded bundle matching Go `SaleOrderRecord` (`DisallowUnknownFields`).
  Future<PosCheckoutCommitResult> completeCheckout({
    required List<PosCartItem> items,
    required PosDiscount discount,
    required List<PosPaymentLeg> payments,
    required String paymentMode,
    required String cashierUserId,
    required String cashierName,
    required String? role,
    required String deviceCode,
    String? shiftId,
    CustomerRow? customer,
    int? cashTenderedPaisa,
    int? changeDuePaisa,
    String? staticQrPayload,
  }) async {
    if (items.isEmpty) {
      throw const PosValidationException('Cart is empty.');
    }
    for (final item in items) {
      if (item.quantity <= 0) {
        throw PosValidationException(
          'Quantity must be > 0 for ${item.productName}.',
        );
      }
      if (item.unitPricePaisa < 0 ||
          item.lineTotalPaisa > MoneyUtils.maxDecimal10_2Paisa) {
        throw PosValidationException(
          'Invalid price for ${item.productName}.',
        );
      }
    }

    const allowedOrderModes = {'CASH', 'FONEPAY_QR', 'CARD', 'KHATA_CREDIT', 'SPLIT'};
    const allowedLegMethods = {'CASH', 'FONEPAY_QR', 'CARD', 'KHATA_CREDIT'};
    if (!allowedOrderModes.contains(paymentMode)) {
      throw PosValidationException('Unsupported payment mode: $paymentMode');
    }

    final subtotalPaisa =
        items.fold<int>(0, (sum, item) => sum + item.lineTotalPaisa);
    final discountPaisa = discount.computeDiscountPaisa(subtotalPaisa);
    final netTotalPaisa = subtotalPaisa - discountPaisa;
    if (netTotalPaisa < 0 ||
        subtotalPaisa > MoneyUtils.maxDecimal10_2Paisa ||
        netTotalPaisa > MoneyUtils.maxDecimal10_2Paisa) {
      throw const PosValidationException('Order total exceeds DECIMAL(10,2) limits.');
    }

    if (netTotalPaisa > 0 && payments.isEmpty) {
      throw const PosValidationException('At least one payment leg is required.');
    }
    for (final leg in payments) {
      if (!allowedLegMethods.contains(leg.method)) {
        throw PosValidationException('Unsupported payment leg: ${leg.method}');
      }
      if (leg.amountPaisa <= 0) {
        throw const PosValidationException(
          'Each payment leg amount must be greater than Rs. 0.',
        );
      }
    }

    final paymentSum =
        payments.fold<int>(0, (sum, leg) => sum + leg.amountPaisa);
    if (paymentSum != netTotalPaisa) {
      throw PosValidationException(
        'Payment sum (${MoneyUtils.formatRs(paymentSum)}) must equal net total '
        '(${MoneyUtils.formatRs(netTotalPaisa)}).',
      );
    }

    final khataAmount = payments
        .where((p) => p.method == 'KHATA_CREDIT')
        .fold<int>(0, (sum, p) => sum + p.amountPaisa);
    if (khataAmount > 0 && customer == null) {
      throw const PosValidationException(
        'Select a customer account before charging to Khata.',
      );
    }

    final now = _clock().toUtc();
    final saleOrderId = _uuid.v4();
    final isOwner = _canViewCost(role);
    final explicitShift = shiftId == null
        ? null
        : await (db.select(db.registerShifts)
              ..where((s) => s.id.equals(shiftId) & s.status.equals('OPEN')))
            .getSingleOrNull();
    final effectiveShiftId =
        explicitShift?.id ?? (await db.fetchOpenRegisterShift())?.id;

    int? khataBalanceAfter;
    late String billNo;

    await db.transaction(() async {
      billNo = await _allocateNextBillNo(deviceCode);

      // Re-verify Khata credit limit inside transaction.
      if (khataAmount > 0 && customer != null) {
        final freshCustomer = await (db.select(db.customers)
              ..where((c) => c.id.equals(customer.id) & c.deletedAt.isNull()))
            .getSingleOrNull();
        if (freshCustomer == null) {
          throw const PosValidationException('Selected customer not found.');
        }
        final projected = freshCustomer.currentBalanceDue + khataAmount;
        if (projected > freshCustomer.creditLimit) {
          throw PosValidationException(
            'Khata credit limit exceeded for ${freshCustomer.name} '
            '(Limit: ${MoneyUtils.formatRs(freshCustomer.creditLimit)}, '
            'Projected: ${MoneyUtils.formatRs(projected)}).',
          );
        }
        khataBalanceAfter = projected;

        final khataTxnId = _uuid.v4();
        await db.into(db.customerTransactions).insert(
              CustomerTransactionsCompanion.insert(
                id: khataTxnId,
                customerId: freshCustomer.id,
                type: 'DEBIT_PURCHASE',
                amount: khataAmount,
                balanceAfter: projected,
                referenceBillNo: Value(billNo),
                createdByUserId: Value(cashierUserId),
                createdAt: Value(now),
                updatedAt: Value(now),
              ),
            );

        await (db.update(db.customers)
              ..where((c) => c.id.equals(freshCustomer.id)))
            .write(
          CustomersCompanion(
            currentBalanceDue: Value(projected),
            updatedAt: Value(now),
          ),
        );

        await db.enqueueOutboxMutation(
          mutationId: _uuid.v4(),
          targetTable: 'customer_transactions',
          recordId: khataTxnId,
          operation: 'INSERT',
          payloadJson: jsonEncode(<String, dynamic>{
            'id': khataTxnId,
            'customer_id': freshCustomer.id,
            'type': 'DEBIT_PURCHASE',
            'amount': MoneyUtils.toDecimalString(khataAmount),
            'balance_after': MoneyUtils.toDecimalString(projected),
            'reference_bill_no': billNo,
            'created_by_user_id': cashierUserId,
            'created_at': _isoUtc(now),
            'updated_at': _isoUtc(now),
          }),
          clientUpdatedAt: now,
        );
      }

      // Compute authoritative cost totals only for OWNER; STAFF/MANAGER leave null.
      int? ownerCostTotal;
      int? ownerNetProfit;
      if (isOwner) {
        var sumCost = 0;
        for (final item in items) {
          final c = item.costPricePaisa ?? 0;
          sumCost += c * item.quantity;
        }
        ownerCostTotal = sumCost;
        ownerNetProfit = netTotalPaisa - sumCost;
      }

      await db.into(db.saleOrders).insert(
            SaleOrdersCompanion.insert(
              id: saleOrderId,
              billNo: billNo,
              customerId: Value(customer?.id),
              customerName: Value(customer?.name),
              customerPhone: Value(customer?.phone),
              cashierUserId: cashierUserId,
              cashierName: cashierName,
              shiftId: Value(effectiveShiftId),
              subtotal: subtotalPaisa,
              discountAmount: Value(discountPaisa),
              totalAmount: netTotalPaisa,
              costTotal: Value(ownerCostTotal),
              netProfit: Value(ownerNetProfit),
              paymentMode: paymentMode,
              syncStatus: const Value('PENDING'),
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );

      final outboxItems = <Map<String, dynamic>>[];
      final outboxMovements = <Map<String, dynamic>>[];

      for (final item in items) {
        final saleItemId = _uuid.v4();
        final movementId = _uuid.v4();
        final delta = -item.quantity;

        await db.into(db.saleItems).insert(
              SaleItemsCompanion.insert(
                id: saleItemId,
                saleOrderId: saleOrderId,
                batchId: item.batchId,
                productName: item.productName,
                variantName: item.variantName,
                quantity: item.quantity,
                costPrice: Value(isOwner ? (item.costPricePaisa ?? 0) : null),
                sellingPrice: item.unitPricePaisa,
                totalPrice: item.lineTotalPaisa,
              ),
            );

        // Atomic local stock decrement.
        final batchRow = await (db.select(db.batches)
              ..where((b) => b.id.equals(item.batchId)))
            .getSingleOrNull();
        if (batchRow == null) {
          throw PosValidationException(
            'Batch ${item.batchCode} no longer exists.',
          );
        }
        await (db.update(db.batches)..where((b) => b.id.equals(item.batchId)))
            .write(
          BatchesCompanion(
            stockQuantity: Value(batchRow.stockQuantity + delta),
            updatedAt: Value(now),
          ),
        );

        await db.into(db.stockMovements).insert(
              StockMovementsCompanion.insert(
                id: movementId,
                batchId: item.batchId,
                movementType: 'SALE',
                quantity: delta,
                referenceId: Value(billNo),
                staffName: cashierName,
                createdAt: Value(now),
                updatedAt: Value(now),
              ),
            );

        outboxItems.add(<String, dynamic>{
          'id': saleItemId,
          'sale_order_id': saleOrderId,
          'batch_id': item.batchId,
          'product_name': item.productName,
          'variant_name': item.variantName,
          'quantity': item.quantity,
          if (isOwner)
            'cost_price': MoneyUtils.toDecimalString(item.costPricePaisa ?? 0),
          'selling_price': MoneyUtils.toDecimalString(item.unitPricePaisa),
          'total_price': MoneyUtils.toDecimalString(item.lineTotalPaisa),
        });

        outboxMovements.add(<String, dynamic>{
          'id': movementId,
          'batch_id': item.batchId,
          'movement_type': 'SALE',
          'quantity': delta,
          'quantity_change': delta,
          'reference_id': billNo,
          'staff_name': cashierName,
          'created_at': _isoUtc(now),
          'updated_at': _isoUtc(now),
        });
      }

      final outboxPayments = <Map<String, dynamic>>[];
      var cashAdded = 0;
      var digitalAdded = 0;

      for (final leg in payments) {
        final paymentId = _uuid.v4();
        await db.into(db.salePayments).insert(
              SalePaymentsCompanion.insert(
                id: paymentId,
                saleOrderId: saleOrderId,
                method: leg.method,
                amount: leg.amountPaisa,
                transactionRef: Value(leg.transactionRef),
              ),
            );

        outboxPayments.add(<String, dynamic>{
          'id': paymentId,
          'sale_order_id': saleOrderId,
          'method': leg.method,
          'amount': MoneyUtils.toDecimalString(leg.amountPaisa),
          if (leg.transactionRef != null && leg.transactionRef!.isNotEmpty)
            'transaction_ref': leg.transactionRef,
        });

        if (leg.method == 'CASH') {
          cashAdded += leg.amountPaisa;
        } else if (leg.method == 'FONEPAY_QR' || leg.method == 'CARD') {
          digitalAdded += leg.amountPaisa;
        }
      }

      if (effectiveShiftId != null && (cashAdded > 0 || digitalAdded > 0)) {
        final shift = await (db.select(db.registerShifts)
              ..where((s) => s.id.equals(effectiveShiftId)))
            .getSingleOrNull();
        if (shift != null && shift.status == 'OPEN') {
          await (db.update(db.registerShifts)
                ..where((s) => s.id.equals(effectiveShiftId)))
              .write(
            RegisterShiftsCompanion(
              cashSales: Value(shift.cashSales + cashAdded),
              digitalSales: Value(shift.digitalSales + digitalAdded),
              expectedCash: Value(shift.expectedCash + cashAdded),
              updatedAt: Value(now),
            ),
          );
        }
      }

      final orderPayload = <String, dynamic>{
        'id': saleOrderId,
        'bill_no': billNo,
        if (customer != null) 'customer_id': customer.id,
        if (customer != null) 'customer_name': customer.name,
        if (customer != null) 'customer_phone': customer.phone,
        'cashier_user_id': cashierUserId,
        'cashier_name': cashierName,
        if (effectiveShiftId != null) 'shift_id': effectiveShiftId,
        'subtotal': MoneyUtils.toDecimalString(subtotalPaisa),
        'discount_amount': MoneyUtils.toDecimalString(discountPaisa),
        'total_amount': MoneyUtils.toDecimalString(netTotalPaisa),
        if (isOwner && ownerCostTotal != null)
          'cost_total': MoneyUtils.toDecimalString(ownerCostTotal),
        if (isOwner && ownerNetProfit != null)
          'net_profit': MoneyUtils.toDecimalString(ownerNetProfit),
        'payment_mode': paymentMode,
        'sync_status': 'PENDING',
        'created_at': _isoUtc(now),
        'updated_at': _isoUtc(now),
        'items': outboxItems,
        'payments': outboxPayments,
        'stock_movements': outboxMovements,
      };

      await db.enqueueOutboxMutation(
        mutationId: _uuid.v4(),
        targetTable: 'sale_orders',
        recordId: saleOrderId,
        operation: 'INSERT',
        payloadJson: jsonEncode(orderPayload),
        clientUpdatedAt: now,
      );
    });

    onMutationCommitted?.call();

    final receipt = ReceiptPrintData(
      billNo: billNo,
      printedAt: now.toLocal(),
      cashierName: cashierName,
      items: items
          .map(
            (i) => ReceiptLineItem(
              productName: i.productName,
              variantName: i.variantName,
              quantity: i.quantity,
              unitPricePaisa: i.unitPricePaisa,
              lineTotalPaisa: i.lineTotalPaisa,
            ),
          )
          .toList(growable: false),
      subtotalPaisa: subtotalPaisa,
      discountPaisa: discountPaisa,
      totalPaisa: netTotalPaisa,
      paymentMode: paymentMode,
      payments: payments
          .map(
            (p) => ReceiptPaymentLine(
              method: p.method,
              amountPaisa: p.amountPaisa,
              reference: p.transactionRef,
            ),
          )
          .toList(growable: false),
      customerName: customer?.name,
      customerPhone: customer?.phone,
      cashTenderedPaisa: cashTenderedPaisa,
      changeDuePaisa: changeDuePaisa,
      khataBalanceAfterPaisa: khataBalanceAfter,
      staticQrPayload: staticQrPayload,
    );

    return PosCheckoutCommitResult(
      saleOrderId: saleOrderId,
      billNo: billNo,
      receiptData: receipt,
      khataBalanceAfterPaisa: khataBalanceAfter,
    );
  }
}
