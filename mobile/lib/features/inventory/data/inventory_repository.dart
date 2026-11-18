import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/money.dart';
import '../../../core/printer/printer_config.dart';
import '../../../core/printer/tspl_label_builder.dart';
import '../domain/catalog_models.dart';

class InventoryPermissionException implements Exception {
  const InventoryPermissionException(this.message);
  final String message;
  @override
  String toString() => 'InventoryPermissionException: $message';
}

class InventoryValidationException implements Exception {
  const InventoryValidationException(this.message);
  final String message;
  @override
  String toString() => 'InventoryValidationException: $message';
}

/// Encrypted Drift repository for Step 8 Catalog, 1-Screen Smart Intake,
/// Owner-only cost security, and atomic FIFO `sync_outbox` enqueueing.
class InventoryRepository {
  InventoryRepository({
    required this.db,
    this.onMutationCommitted,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AppDatabase db;
  final VoidCallback? onMutationCommitted;
  final DateTime Function() _clock;
  final Uuid _uuid = const Uuid();

  static bool canManageInventory(String? role) {
    final norm = role?.trim().toUpperCase();
    return norm == 'OWNER' || norm == 'MANAGER';
  }

  static bool canViewCostPrice(String? role) {
    return role?.trim().toUpperCase() == 'OWNER';
  }

  /// Watches the complete active 3-tier hierarchy (`Product -> Variant -> Batch`)
  /// reactively from SQLite without holding stale cached snapshots.
  Stream<List<ProductCatalogNode>> watchCatalogHierarchy() {
    final productsStream = (db.select(db.products)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .watch();
    final variantsStream = (db.select(db.productVariants)
          ..where((t) => t.deletedAt.isNull() & t.isActive.equals(true))
          ..orderBy([(t) => OrderingTerm.asc(t.variantName)]))
        .watch();
    final batchesStream = (db.select(db.batches)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.expiryDate)]))
        .watch();

    return _combineLatest3(
      productsStream,
      variantsStream,
      batchesStream,
      (products, variants, batches) => _buildCatalogTree(
        products: products,
        variants: variants,
        batches: batches,
        now: _clock(),
      ),
    );
  }

  /// Streams active suppliers for `OWNER` / `MANAGER` intake selection.
  /// Strictly returns `[]` for `STAFF` (`TECHNICAL_SPEC.md` §7.5).
  Stream<List<SupplierRow>> watchSuppliersForRole(String? role) {
    if (!canManageInventory(role)) {
      return Stream<List<SupplierRow>>.value(const <SupplierRow>[]);
    }
    return (db.select(db.suppliers)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .watch();
  }

  /// Generates an 8-digit numeric barcode (`<2-digit deviceCode><6 digits>`)
  /// guaranteed unique locally and fitting Code 128 Subset C (`narrow=2`,
  /// `162 <= 215` dots) on 62x20mm Xlab 365T stickers.
  Future<String> generateUniqueStickerBarcode({
    String deviceCode = '01',
  }) async {
    final cleanDigits = deviceCode.replaceAll(RegExp(r'[^0-9]'), '');
    final prefix = cleanDigits.isEmpty
        ? '01'
        : cleanDigits.padLeft(2, '0').substring(0, 2);

    final existingRows = await (db.selectOnly(db.batches)
          ..addColumns([db.batches.stickerBarcode]))
        .get();
    final existing = existingRows
        .map((r) => r.read(db.batches.stickerBarcode))
        .whereType<String>()
        .toSet();

    final seed = _clock().millisecondsSinceEpoch % 900000;
    for (var offset = 0; offset < 1000; offset++) {
      final candidateSuffix = ((100000 + seed + offset) % 1000000)
          .toString()
          .padLeft(6, '0');
      final candidate = '$prefix$candidateSuffix';
      if (!existing.contains(candidate)) {
        return candidate;
      }
    }

    final rng = math.Random.secure();
    while (true) {
      final fallback = '$prefix${(100000 + rng.nextInt(899999))}';
      if (!existing.contains(fallback)) {
        return fallback;
      }
    }
  }

  /// Executes 1-Screen Smart Stock Intake inside a single SQLite ACID
  /// transaction (`products` -> `product_variants` -> `batches` ->
  /// `stock_movements`) + FIFO `sync_outbox` mutations.
  Future<SmartIntakeResult> submitSmartIntake({
    required SmartIntakeSubmission submission,
    required String? actorRole,
    required String actorUserName,
  }) async {
    if (!canManageInventory(actorRole)) {
      throw const InventoryPermissionException(
        'Only Manager or Store Owner can add stock intake.',
      );
    }

    final staffName = actorUserName.trim();
    if (staffName.isEmpty) {
      throw const InventoryValidationException('Active user name is required.');
    }

    final productName = submission.productName.trim();
    final brand = submission.brand.trim();
    final variantName = submission.variantName.trim();
    final batchCode = submission.batchCode.trim();
    final barcode = submission.stickerBarcode.trim();
    final sizeVolume = _trimOrNull(submission.sizeVolume);
    final colorHex = _normalizeColorHex(submission.colorHex);
    final supplierId = _trimOrNull(submission.supplierId);

    if (productName.isEmpty || productName.length > 255) {
      throw const InventoryValidationException(
        'Product name is required (max 255 characters).',
      );
    }
    if (brand.isEmpty || brand.length > 100) {
      throw const InventoryValidationException(
        'Brand name is required (max 100 characters).',
      );
    }
    if (variantName.isEmpty || variantName.length > 150) {
      throw const InventoryValidationException(
        'Shade, size, or variant label is required (max 150 characters).',
      );
    }
    if (batchCode.isEmpty || batchCode.length > 100) {
      throw const InventoryValidationException(
        'Lot / Batch code is required (max 100 characters).',
      );
    }
    if (barcode.isEmpty) {
      throw const InventoryValidationException('Sticker barcode is required.');
    }
    try {
      TsplLabelBuilder.fitBarcode(barcode);
    } on PrinterPayloadException catch (e) {
      throw InventoryValidationException(e.message);
    }

    if (submission.quantity <= 0 || submission.quantity > 1000000) {
      throw const InventoryValidationException(
        'Intake quantity must be between 1 and 1,000,000.',
      );
    }
    if (submission.sellingPricePaisa < 0 ||
        submission.sellingPricePaisa > MoneyUtils.maxDecimal10_2Paisa) {
      throw const InventoryValidationException(
        'Selling MRP must be a non-negative DECIMAL(10,2) value.',
      );
    }

    // Strict RBAC Cost Lock (`TECHNICAL_SPEC.md` §7.5 & Task 8.3):
    // Non-OWNER users can NEVER set or push cost_price.
    final bool isOwner = canViewCostPrice(actorRole);
    final int? effectiveCostPaisa = isOwner ? submission.costPricePaisa : null;
    if (effectiveCostPaisa != null &&
        (effectiveCostPaisa < 0 ||
            effectiveCostPaisa > MoneyUtils.maxDecimal10_2Paisa)) {
      throw const InventoryValidationException(
        'Wholesale cost must be a non-negative DECIMAL(10,2) value.',
      );
    }

    final normalizedExpiry = submission.category.isGeneric
        ? InventoryDateUtils.nonPerishableIsoDate
        : InventoryDateUtils.normalizeExpiryInputToIso(
            submission.expiryIsoDate,
          );
    if (normalizedExpiry == null) {
      throw const InventoryValidationException(
        'Valid expiry date required (MM/YYYY or YYYY-MM-DD).',
      );
    }

    final attributesMap = <String, dynamic>{};
    if (submission.category.asksSpfAndSkin) {
      final spf = _trimOrNull(submission.spf);
      final skin = _trimOrNull(submission.skinType);
      if (spf != null && spf != 'None') {
        attributesMap['spf'] = spf;
      }
      if (skin != null) {
        attributesMap['skin_type'] = skin;
      }
    }
    final attributesJsonStr = jsonEncode(attributesMap);

    final result = await db.transaction<SmartIntakeResult>(() async {
      final duplicateBarcode = await (db.select(db.batches)
            ..where((t) => t.stickerBarcode.equals(barcode)))
          .getSingleOrNull();
      if (duplicateBarcode != null) {
        throw InventoryValidationException(
          'Barcode "$barcode" is already assigned to another batch.',
        );
      }

      if (supplierId != null) {
        final supplier = await (db.select(db.suppliers)
              ..where((t) => t.id.equals(supplierId) & t.deletedAt.isNull()))
            .getSingleOrNull();
        if (supplier == null) {
          throw const InventoryValidationException(
            'Selected supplier was not found.',
          );
        }
      }

      final now = _clock().toUtc();
      final isoNow = now.toIso8601String();

      // 1. Product Tier
      late final ProductRow productRow;
      if (submission.existingProductId != null &&
          submission.existingProductId!.trim().isNotEmpty) {
        final existingProd = await (db.select(db.products)
              ..where((t) =>
                  t.id.equals(submission.existingProductId!.trim()) &
                  t.deletedAt.isNull()))
            .getSingleOrNull();
        if (existingProd == null) {
          throw const InventoryValidationException(
            'Selected parent product no longer exists.',
          );
        }
        productRow = existingProd;
      } else {
        final prodId = _uuid.v4();
        await db.into(db.products).insert(
              ProductsCompanion.insert(
                id: prodId,
                name: productName,
                brand: brand,
                category: submission.category.dbValue,
                isGeneric: Value(submission.category.isGeneric),
                createdAt: Value(now),
                updatedAt: Value(now),
                clientUpdatedAt: Value(now),
              ),
            );
        productRow = await (db.select(db.products)
              ..where((t) => t.id.equals(prodId)))
            .getSingle();

        await db.enqueueOutboxMutation(
          mutationId: _uuid.v4(),
          targetTable: 'products',
          recordId: prodId,
          operation: 'INSERT',
          clientUpdatedAt: now,
          createdAt: now,
          payloadJson: jsonEncode(<String, dynamic>{
            'id': prodId,
            'name': productName,
            'brand': brand,
            'category': submission.category.dbValue,
            'is_generic': submission.category.isGeneric,
            'created_at': isoNow,
            'updated_at': isoNow,
          }),
        );
      }

      // 2. Variant Tier
      late final ProductVariantRow variantRow;
      if (submission.existingVariantId != null &&
          submission.existingVariantId!.trim().isNotEmpty) {
        final existingVar = await (db.select(db.productVariants)
              ..where((t) =>
                  t.id.equals(submission.existingVariantId!.trim()) &
                  t.productId.equals(productRow.id) &
                  t.deletedAt.isNull()))
            .getSingleOrNull();
        if (existingVar == null) {
          throw const InventoryValidationException(
            'Selected product variant was not found for this product.',
          );
        }
        variantRow = existingVar;
      } else {
        final varId = _uuid.v4();
        await db.into(db.productVariants).insert(
              ProductVariantsCompanion.insert(
                id: varId,
                productId: productRow.id,
                variantName: variantName,
                sizeVolume: Value(sizeVolume),
                colorHex: Value(colorHex),
                attributes: Value(attributesJsonStr),
                isActive: const Value(true),
                createdAt: Value(now),
                updatedAt: Value(now),
                clientUpdatedAt: Value(now),
              ),
            );
        variantRow = await (db.select(db.productVariants)
              ..where((t) => t.id.equals(varId)))
            .getSingle();

        await db.enqueueOutboxMutation(
          mutationId: _uuid.v4(),
          targetTable: 'product_variants',
          recordId: varId,
          operation: 'INSERT',
          clientUpdatedAt: now,
          createdAt: now,
          payloadJson: jsonEncode(<String, dynamic>{
            'id': varId,
            'product_id': productRow.id,
            'variant_name': variantName,
            if (sizeVolume != null) 'size_volume': sizeVolume,
            if (colorHex != null) 'color_hex': colorHex,
            'attributes': attributesMap,
            'is_active': true,
            'created_at': isoNow,
            'updated_at': isoNow,
          }),
        );
      }

      // 3. Batch Tier (`stock_quantity` starts at 0 in outbox JSON per server atomic delta invariant)
      final batchId = _uuid.v4();
      await db.into(db.batches).insert(
            BatchesCompanion.insert(
              id: batchId,
              variantId: variantRow.id,
              supplierId: Value(supplierId),
              batchCode: batchCode,
              stickerBarcode: barcode,
              costPrice: Value(effectiveCostPaisa),
              sellingPrice: submission.sellingPricePaisa,
              stockQuantity: Value(submission.quantity),
              expiryDate: normalizedExpiry,
              createdAt: Value(now),
              updatedAt: Value(now),
              clientUpdatedAt: Value(now),
            ),
          );
      final batchRow = await (db.select(db.batches)
            ..where((t) => t.id.equals(batchId)))
          .getSingle();

      await db.enqueueOutboxMutation(
        mutationId: _uuid.v4(),
        targetTable: 'batches',
        recordId: batchId,
        operation: 'INSERT',
        clientUpdatedAt: now,
        createdAt: now,
        payloadJson: jsonEncode(<String, dynamic>{
          'id': batchId,
          'variant_id': variantRow.id,
          if (supplierId != null) 'supplier_id': supplierId,
          'batch_code': batchCode,
          'sticker_barcode': barcode,
          if (effectiveCostPaisa != null)
            'cost_price': MoneyUtils.toDecimalString(effectiveCostPaisa),
          'selling_price': MoneyUtils.toDecimalString(submission.sellingPricePaisa),
          'stock_quantity': 0,
          'expiry_date': normalizedExpiry,
          'created_at': isoNow,
          'updated_at': isoNow,
        }),
      );

      // 4. Stock Movement Tier (`PURCHASE_INTAKE` positive atomic delta)
      final movId = _uuid.v4();
      await db.into(db.stockMovements).insert(
            StockMovementsCompanion.insert(
              id: movId,
              batchId: batchId,
              movementType: 'PURCHASE_INTAKE',
              quantity: submission.quantity,
              reason: const Value('Direct 1-Screen Stock Intake'),
              staffName: staffName,
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );
      final movementRow = await (db.select(db.stockMovements)
            ..where((t) => t.id.equals(movId)))
          .getSingle();

      await db.enqueueOutboxMutation(
        mutationId: _uuid.v4(),
        targetTable: 'stock_movements',
        recordId: movId,
        operation: 'INSERT',
        clientUpdatedAt: now,
        createdAt: now,
        payloadJson: jsonEncode(<String, dynamic>{
          'id': movId,
          'batch_id': batchId,
          'movement_type': 'PURCHASE_INTAKE',
          'quantity': submission.quantity,
          'quantity_change': submission.quantity,
          'reason': 'Direct 1-Screen Stock Intake',
          'staff_name': staffName,
          'created_at': isoNow,
          'updated_at': isoNow,
        }),
      );

      return SmartIntakeResult(
        product: productRow,
        variant: variantRow,
        batch: batchRow,
        stockMovement: movementRow,
      );
    });

    onMutationCommitted?.call();
    return result;
  }

  /// Atomically applies a signed stock adjustment delta (`PURCHASE_INTAKE`,
  /// `CUSTOMER_RETURN`, `DAMAGED_WRITEOFF`, `EXPIRED_WRITEOFF`, `TESTER_CONVERSION`,
  /// or `COUNT_CORRECTION`) and queues an append-only `stock_movements` mutation.
  Future<BatchRow> adjustBatchStock({
    required String batchId,
    required StockAdjustmentReason reason,
    required int quantityDelta,
    required String? actorRole,
    required String actorUserName,
    String? note,
  }) async {
    if (!canManageInventory(actorRole)) {
      throw const InventoryPermissionException(
        'Only Manager or Store Owner can adjust batch stock.',
      );
    }
    final staffName = actorUserName.trim();
    if (staffName.isEmpty) {
      throw const InventoryValidationException('Active user name is required.');
    }
    if (quantityDelta == 0) {
      throw const InventoryValidationException(
        'Stock adjustment change cannot be zero.',
      );
    }
    if (quantityDelta.abs() > 1000000) {
      throw const InventoryValidationException(
        'Stock adjustment magnitude cannot exceed 1,000,000 units.',
      );
    }
    if (reason.expectedSign > 0 && quantityDelta < 0) {
      throw InventoryValidationException(
        '${reason.label} requires a positive quantity addition.',
      );
    }
    if (reason.expectedSign < 0 && quantityDelta > 0) {
      throw InventoryValidationException(
        '${reason.label} requires a negative quantity deduction.',
      );
    }

    final cleanNote = _trimOrNull(note) ?? reason.label;

    final updatedBatch = await db.transaction<BatchRow>(() async {
      final batch = await (db.select(db.batches)
            ..where((t) => t.id.equals(batchId) & t.deletedAt.isNull()))
          .getSingleOrNull();
      if (batch == null) {
        throw const InventoryValidationException('Batch record was not found.');
      }

      final nextQty = batch.stockQuantity + quantityDelta;
      if (nextQty < 0) {
        throw InventoryValidationException(
          'Adjustment would reduce stock below zero ($nextQty units).',
        );
      }

      final now = _clock().toUtc();
      final isoNow = now.toIso8601String();

      await (db.update(db.batches)..where((t) => t.id.equals(batchId))).write(
        BatchesCompanion(
          stockQuantity: Value(nextQty),
          updatedAt: Value(now),
          clientUpdatedAt: Value(now),
        ),
      );

      final movId = _uuid.v4();
      await db.into(db.stockMovements).insert(
            StockMovementsCompanion.insert(
              id: movId,
              batchId: batchId,
              movementType: reason.movementType,
              quantity: quantityDelta,
              reason: Value(cleanNote),
              staffName: staffName,
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );

      await db.enqueueOutboxMutation(
        mutationId: _uuid.v4(),
        targetTable: 'stock_movements',
        recordId: movId,
        operation: 'INSERT',
        clientUpdatedAt: now,
        createdAt: now,
        payloadJson: jsonEncode(<String, dynamic>{
          'id': movId,
          'batch_id': batchId,
          'movement_type': reason.movementType,
          'quantity': quantityDelta,
          'quantity_change': quantityDelta,
          'reason': cleanNote,
          'staff_name': staffName,
          'created_at': isoNow,
          'updated_at': isoNow,
        }),
      );

      return (db.select(db.batches)..where((t) => t.id.equals(batchId)))
          .getSingle();
    });

    onMutationCommitted?.call();
    return updatedBatch;
  }

  static List<ProductCatalogNode> _buildCatalogTree({
    required List<ProductRow> products,
    required List<ProductVariantRow> variants,
    required List<BatchRow> batches,
    required DateTime now,
  }) {
    final batchesByVariant = <String, List<BatchRow>>{};
    for (final b in batches) {
      (batchesByVariant[b.variantId] ??= <BatchRow>[]).add(b);
    }

    final variantsByProduct = <String, List<ProductVariantRow>>{};
    for (final v in variants) {
      (variantsByProduct[v.productId] ??= <ProductVariantRow>[]).add(v);
    }

    final out = <ProductCatalogNode>[];
    for (final p in products) {
      final prodVariants = variantsByProduct[p.id] ?? const <ProductVariantRow>[];
      final variantNodes = <VariantCatalogNode>[];

      var prodTotalStock = 0;
      var prodHasLow = false;
      var prodHasExp = false;
      int? prodMinPrice;
      int? prodMaxPrice;

      for (final v in prodVariants) {
        final rawBatches = batchesByVariant[v.id] ?? const <BatchRow>[];
        final batchItems = <BatchCatalogItem>[];
        var varTotalStock = 0;
        int? varMinPrice;
        int? varMaxPrice;

        for (final b in rawBatches) {
          final expStatus = InventoryDateUtils.classifyExpiry(
            b.expiryDate,
            isGeneric: p.isGeneric,
            now: now,
          );
          final isLow = b.stockQuantity > 0 &&
              b.stockQuantity <= InventoryDateUtils.defaultLowStockThreshold;
          if (expStatus == BatchExpiryStatus.expired ||
              expStatus == BatchExpiryStatus.expiringSoon) {
            prodHasExp = true;
          }

          varTotalStock += b.stockQuantity;
          varMinPrice = varMinPrice == null
              ? b.sellingPrice
              : math.min(varMinPrice, b.sellingPrice);
          varMaxPrice = varMaxPrice == null
              ? b.sellingPrice
              : math.max(varMaxPrice, b.sellingPrice);

          batchItems.add(
            BatchCatalogItem(
              batch: b,
              expiryStatus: expStatus,
              isLowStock: isLow,
            ),
          );
        }

        // Low reserve is evaluated per active variant (shade/size), so a depleted
        // old lot (0 units) does not trigger false-positive LOW alerts when a newer
        // batch of the same variant has sufficient stock.
        if (varTotalStock <= InventoryDateUtils.defaultLowStockThreshold) {
          prodHasLow = true;
        }
        prodTotalStock += varTotalStock;
        if (varMinPrice != null) {
          prodMinPrice = prodMinPrice == null
              ? varMinPrice
              : math.min(prodMinPrice, varMinPrice);
        }
        if (varMaxPrice != null) {
          prodMaxPrice = prodMaxPrice == null
              ? varMaxPrice
              : math.max(prodMaxPrice, varMaxPrice);
        }

        variantNodes.add(
          VariantCatalogNode(
            variant: v,
            batches: batchItems,
            totalStock: varTotalStock,
            minSellingPricePaisa: varMinPrice ?? 0,
            maxSellingPricePaisa: varMaxPrice ?? 0,
            attributesMap: VariantCatalogNode.decodeAttributes(v.attributes),
          ),
        );
      }

      if (prodTotalStock <= InventoryDateUtils.defaultLowStockThreshold &&
          variantNodes.isNotEmpty) {
        prodHasLow = true;
      }

      out.add(
        ProductCatalogNode(
          product: p,
          variants: variantNodes,
          totalStock: prodTotalStock,
          hasLowStock: prodHasLow,
          hasExpiringOrExpired: prodHasExp,
          minSellingPricePaisa: prodMinPrice ?? 0,
          maxSellingPricePaisa: prodMaxPrice ?? 0,
        ),
      );
    }
    return out;
  }

  static String? _trimOrNull(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String? _normalizeColorHex(String? raw) {
    final trimmed = _trimOrNull(raw);
    if (trimmed == null) return null;
    final hex = trimmed.startsWith('#') ? trimmed.substring(1) : trimmed;
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) {
      return null;
    }
    return '#${hex.toUpperCase()}';
  }
}

/// Combines 3 streams in pure Dart without `rxdart`, emitting whenever all 3
/// have delivered their initial value and on every subsequent update.
Stream<R> _combineLatest3<A, B, C, R>(
  Stream<A> sA,
  Stream<B> sB,
  Stream<C> sC,
  R Function(A a, B b, C c) combiner,
) {
  late StreamController<R> controller;
  StreamSubscription<A>? subA;
  StreamSubscription<B>? subB;
  StreamSubscription<C>? subC;

  A? latestA;
  B? latestB;
  C? latestC;
  var hasA = false;
  var hasB = false;
  var hasC = false;

  void emitIfReady() {
    if (hasA && hasB && hasC && !controller.isClosed) {
      controller.add(combiner(latestA as A, latestB as B, latestC as C));
    }
  }

  controller = StreamController<R>(
    onListen: () {
      subA = sA.listen(
        (v) {
          latestA = v;
          hasA = true;
          emitIfReady();
        },
        onError: controller.addError,
      );
      subB = sB.listen(
        (v) {
          latestB = v;
          hasB = true;
          emitIfReady();
        },
        onError: controller.addError,
      );
      subC = sC.listen(
        (v) {
          latestC = v;
          hasC = true;
          emitIfReady();
        },
        onError: controller.addError,
      );
    },
    onCancel: () => Future.wait<dynamic>(<Future<dynamic>>[
      if (subA != null) subA!.cancel(),
      if (subB != null) subB!.cancel(),
      if (subC != null) subC!.cancel(),
    ]),
  );

  return controller.stream;
}
