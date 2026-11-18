import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../database/money.dart';

/// Outbox mutation sent in `POST /api/sync/push` (`server/internal/sync/types.go`).
@immutable
class OutboxMutationPayload {
  const OutboxMutationPayload({
    required this.id,
    required this.tableName,
    required this.recordId,
    required this.operation,
    required this.payload,
    this.clientUpdatedAt,
  });

  final String id;
  final String tableName;
  final String recordId;
  final String operation;
  final DateTime? clientUpdatedAt;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'table_name': tableName,
      'record_id': recordId,
      'operation': operation,
      if (clientUpdatedAt != null)
        'client_updated_at': clientUpdatedAt!.toUtc().toIso8601String(),
      'payload': payload,
    };
  }
}

@immutable
class MutationApplyResult {
  const MutationApplyResult({
    required this.id,
    required this.tableName,
    required this.recordId,
    required this.status,
  });

  factory MutationApplyResult.fromJson(Map<String, dynamic> json) {
    return MutationApplyResult(
      id: json['id'] as String,
      tableName: json['table_name'] as String,
      recordId: json['record_id'] as String,
      status: json['status'] as String,
    );
  }

  final String id;
  final String tableName;
  final String recordId;
  final String status; // 'APPLIED' | 'ALREADY_APPLIED'
}

@immutable
class DiscrepancyAlert {
  const DiscrepancyAlert({
    required this.auditId,
    required this.batchId,
    this.stockMovementId,
    required this.deviceCode,
    required this.preSyncQty,
    required this.postSyncQty,
    required this.quantityChange,
    this.referenceId,
  });

  factory DiscrepancyAlert.fromJson(Map<String, dynamic> json) {
    return DiscrepancyAlert(
      auditId: json['audit_id'] as String,
      batchId: json['batch_id'] as String,
      stockMovementId: json['stock_movement_id'] as String?,
      deviceCode: json['device_code'] as String,
      preSyncQty: (json['pre_sync_qty'] as num).toInt(),
      postSyncQty: (json['post_sync_qty'] as num).toInt(),
      quantityChange: (json['quantity_change'] as num).toInt(),
      referenceId: json['reference_id'] as String?,
    );
  }

  final String auditId;
  final String batchId;
  final String? stockMovementId;
  final String deviceCode;
  final int preSyncQty;
  final int postSyncQty;
  final int quantityChange;
  final String? referenceId;
}

@immutable
class SyncPushResult {
  const SyncPushResult({
    required this.serverTime,
    required this.processedCount,
    required this.appliedCount,
    required this.duplicateCount,
    required this.results,
    required this.discrepancies,
  });

  factory SyncPushResult.fromJson(Map<String, dynamic> json) {
    final resultsList = (json['results'] as List<dynamic>? ?? const [])
        .map((e) => MutationApplyResult.fromJson(e as Map<String, dynamic>))
        .toList();
    final discList = (json['discrepancies'] as List<dynamic>? ?? const [])
        .map((e) => DiscrepancyAlert.fromJson(e as Map<String, dynamic>))
        .toList();
    return SyncPushResult(
      serverTime: DateTime.parse(json['server_time'] as String).toUtc(),
      processedCount: (json['processed_count'] as num).toInt(),
      appliedCount: (json['applied_count'] as num).toInt(),
      duplicateCount: (json['duplicate_count'] as num).toInt(),
      results: resultsList,
      discrepancies: discList,
    );
  }

  final DateTime serverTime;
  final int processedCount;
  final int appliedCount;
  final int duplicateCount;
  final List<MutationApplyResult> results;
  final List<DiscrepancyAlert> discrepancies;
}

/// Complete typed response from `GET /api/sync/pull`.
@immutable
class SyncPullResult {
  const SyncPullResult({
    required this.serverTime,
    required this.since,
    required this.hasMore,
    required this.role,
    required this.changes,
  });

  factory SyncPullResult.fromJson(Map<String, dynamic> json) {
    return SyncPullResult(
      serverTime: DateTime.parse(json['server_time'] as String).toUtc(),
      since: DateTime.parse(json['since'] as String).toUtc(),
      hasMore: json['has_more'] as bool? ?? false,
      role: json['role'] as String,
      changes: SyncPullChanges.fromJson(
        (json['changes'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
      ),
    );
  }

  final DateTime serverTime;
  final DateTime since;
  final bool hasMore;
  final String role;
  final SyncPullChanges changes;
}

@immutable
class SyncPullChanges {
  const SyncPullChanges({
    this.stores = const [],
    this.storeMembers = const [],
    required this.products,
    required this.productVariants,
    required this.batches,
    required this.customers,
    required this.customerShadeProfiles,
    required this.customerTransactions,
    required this.suppliers,
    required this.purchaseInvoices,
    required this.purchaseInvoiceItems,
    required this.supplierPayments,
    required this.stockMovements,
    required this.saleOrders,
    required this.saleItems,
    required this.salePayments,
    required this.registerShifts,
    required this.staffShiftSessions,
    required this.expenses,
    required this.inventorySyncAudit,
  });

  factory SyncPullChanges.fromJson(Map<String, dynamic> json) {
    return SyncPullChanges(
      stores: _decodeList(json['stores'], PullStoreProfile.fromJson),
      storeMembers:
          _decodeList(json['store_members'], PullStoreMember.fromJson),
      products: _decodeList(json['products'], PullProduct.fromJson),
      productVariants:
          _decodeList(json['product_variants'], PullProductVariant.fromJson),
      batches: _decodeList(json['batches'], PullBatch.fromJson),
      customers: _decodeList(json['customers'], PullCustomer.fromJson),
      customerShadeProfiles: _decodeList(
        json['customer_shade_profiles'],
        PullCustomerShadeProfile.fromJson,
      ),
      customerTransactions: _decodeList(
        json['customer_transactions'],
        PullCustomerTransaction.fromJson,
      ),
      suppliers: _decodeList(json['suppliers'], PullSupplier.fromJson),
      purchaseInvoices:
          _decodeList(json['purchase_invoices'], PullPurchaseInvoice.fromJson),
      purchaseInvoiceItems: _decodeList(
        json['purchase_invoice_items'],
        PullPurchaseInvoiceItem.fromJson,
      ),
      supplierPayments:
          _decodeList(json['supplier_payments'], PullSupplierPayment.fromJson),
      stockMovements:
          _decodeList(json['stock_movements'], PullStockMovement.fromJson),
      saleOrders: _decodeList(json['sale_orders'], PullSaleOrder.fromJson),
      saleItems: _decodeList(json['sale_items'], PullSaleItem.fromJson),
      salePayments:
          _decodeList(json['sale_payments'], PullSalePayment.fromJson),
      registerShifts:
          _decodeList(json['register_shifts'], PullRegisterShift.fromJson),
      staffShiftSessions: _decodeList(
        json['staff_shift_sessions'],
        PullStaffShiftSession.fromJson,
      ),
      expenses: _decodeList(json['expenses'], PullExpense.fromJson),
      inventorySyncAudit: _decodeList(
        json['inventory_sync_audit'],
        PullInventorySyncAudit.fromJson,
      ),
    );
  }

  final List<PullStoreProfile> stores;
  final List<PullStoreMember> storeMembers;
  final List<PullProduct> products;
  final List<PullProductVariant> productVariants;
  final List<PullBatch> batches;
  final List<PullCustomer> customers;
  final List<PullCustomerShadeProfile> customerShadeProfiles;
  final List<PullCustomerTransaction> customerTransactions;
  final List<PullSupplier> suppliers;
  final List<PullPurchaseInvoice> purchaseInvoices;
  final List<PullPurchaseInvoiceItem> purchaseInvoiceItems;
  final List<PullSupplierPayment> supplierPayments;
  final List<PullStockMovement> stockMovements;
  final List<PullSaleOrder> saleOrders;
  final List<PullSaleItem> saleItems;
  final List<PullSalePayment> salePayments;
  final List<PullRegisterShift> registerShifts;
  final List<PullStaffShiftSession> staffShiftSessions;
  final List<PullExpense> expenses;
  final List<PullInventorySyncAudit> inventorySyncAudit;

  int get totalRecordCount =>
      stores.length +
      storeMembers.length +
      products.length +
      productVariants.length +
      batches.length +
      customers.length +
      customerShadeProfiles.length +
      customerTransactions.length +
      suppliers.length +
      purchaseInvoices.length +
      purchaseInvoiceItems.length +
      supplierPayments.length +
      stockMovements.length +
      saleOrders.length +
      saleItems.length +
      salePayments.length +
      registerShifts.length +
      staffShiftSessions.length +
      expenses.length +
      inventorySyncAudit.length;
}

class PullProduct {
  const PullProduct({
    required this.id,
    required this.name,
    required this.brand,
    required this.category,
    required this.isGeneric,
    this.photoUrl,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  factory PullProduct.fromJson(Map<String, dynamic> j) => PullProduct(
        id: j['id'] as String,
        name: j['name'] as String,
        brand: j['brand'] as String,
        category: j['category'] as String,
        isGeneric: j['is_generic'] as bool? ?? false,
        photoUrl: j['photo_url'] as String?,
        createdAt: _dt(j['created_at']),
        updatedAt: _dt(j['updated_at']),
        deletedAt: _dt(j['deleted_at']),
      );

  final String id;
  final String name;
  final String brand;
  final String category;
  final bool isGeneric;
  final String? photoUrl;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;
}

class PullProductVariant {
  const PullProductVariant({
    required this.id,
    required this.productId,
    required this.variantName,
    this.sizeVolume,
    this.colorHex,
    required this.attributesJson,
    required this.isActive,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  factory PullProductVariant.fromJson(Map<String, dynamic> j) {
    final rawAttr = j['attributes'];
    final attrJson = rawAttr == null
        ? '{}'
        : (rawAttr is String ? rawAttr : jsonEncode(rawAttr));
    return PullProductVariant(
      id: j['id'] as String,
      productId: j['product_id'] as String,
      variantName: j['variant_name'] as String,
      sizeVolume: j['size_volume'] as String?,
      colorHex: j['color_hex'] as String?,
      attributesJson: attrJson,
      isActive: j['is_active'] as bool? ?? true,
      createdAt: _dt(j['created_at']),
      updatedAt: _dt(j['updated_at']),
      deletedAt: _dt(j['deleted_at']),
    );
  }

  final String id;
  final String productId;
  final String variantName;
  final String? sizeVolume;
  final String? colorHex;
  final String attributesJson;
  final bool isActive;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;
}

class PullBatch {
  const PullBatch({
    required this.id,
    required this.variantId,
    this.supplierId,
    this.purchaseInvoiceId,
    required this.batchCode,
    required this.stickerBarcode,
    this.costPricePaisa,
    required this.sellingPricePaisa,
    required this.stockQuantity,
    required this.expiryDate,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  factory PullBatch.fromJson(Map<String, dynamic> j) => PullBatch(
        id: j['id'] as String,
        variantId: j['variant_id'] as String,
        supplierId: j['supplier_id'] as String?,
        purchaseInvoiceId: j['purchase_invoice_id'] as String?,
        batchCode: j['batch_code'] as String,
        stickerBarcode: j['sticker_barcode'] as String,
        costPricePaisa: MoneyUtils.parseNullableToPaisa(j['cost_price']),
        sellingPricePaisa: MoneyUtils.parseToPaisa(j['selling_price'] as Object),
        stockQuantity: (j['stock_quantity'] as num).toInt(),
        expiryDate: j['expiry_date'] as String,
        createdAt: _dt(j['created_at']),
        updatedAt: _dt(j['updated_at']),
        deletedAt: _dt(j['deleted_at']),
      );

  final String id;
  final String variantId;
  final String? supplierId;
  final String? purchaseInvoiceId;
  final String batchCode;
  final String stickerBarcode;
  final int? costPricePaisa;
  final int sellingPricePaisa;
  final int stockQuantity;
  final String expiryDate;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;
}

class PullCustomer {
  const PullCustomer({
    required this.id,
    required this.name,
    required this.phone,
    this.address,
    this.creditLimitPaisa,
    required this.currentBalanceDuePaisa,
    this.favoriteShadeNotes,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  factory PullCustomer.fromJson(Map<String, dynamic> j) => PullCustomer(
        id: j['id'] as String,
        name: j['name'] as String,
        phone: j['phone'] as String,
        address: j['address'] as String?,
        creditLimitPaisa: MoneyUtils.parseNullableToPaisa(j['credit_limit']),
        currentBalanceDuePaisa:
            MoneyUtils.parseToPaisa(j['current_balance_due'] as Object),
        favoriteShadeNotes: j['favorite_shade_notes'] as String?,
        createdAt: _dt(j['created_at']),
        updatedAt: _dt(j['updated_at']),
        deletedAt: _dt(j['deleted_at']),
      );

  final String id;
  final String name;
  final String phone;
  final String? address;
  final int? creditLimitPaisa;
  final int currentBalanceDuePaisa;
  final String? favoriteShadeNotes;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;
}

class PullCustomerShadeProfile {
  const PullCustomerShadeProfile({
    required this.id,
    required this.customerId,
    required this.productName,
    required this.brand,
    required this.shadeVariant,
    this.notes,
    this.createdAt,
    this.updatedAt,
  });

  factory PullCustomerShadeProfile.fromJson(Map<String, dynamic> j) =>
      PullCustomerShadeProfile(
        id: j['id'] as String,
        customerId: j['customer_id'] as String,
        productName: j['product_name'] as String,
        brand: j['brand'] as String,
        shadeVariant: j['shade_variant'] as String,
        notes: j['notes'] as String?,
        createdAt: _dt(j['created_at']),
        updatedAt: _dt(j['updated_at']),
      );

  final String id;
  final String customerId;
  final String productName;
  final String brand;
  final String shadeVariant;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

class PullCustomerTransaction {
  const PullCustomerTransaction({
    required this.id,
    required this.customerId,
    required this.type,
    required this.amountPaisa,
    required this.balanceAfterPaisa,
    this.referenceBillNo,
    this.paymentMethod,
    this.notes,
    this.createdByUserId,
    this.createdAt,
    this.updatedAt,
  });

  factory PullCustomerTransaction.fromJson(Map<String, dynamic> j) =>
      PullCustomerTransaction(
        id: j['id'] as String,
        customerId: j['customer_id'] as String,
        type: j['type'] as String,
        amountPaisa: MoneyUtils.parseToPaisa(j['amount'] as Object),
        balanceAfterPaisa:
            MoneyUtils.parseToPaisa(j['balance_after'] as Object),
        referenceBillNo: j['reference_bill_no'] as String?,
        paymentMethod: j['payment_method'] as String?,
        notes: j['notes'] as String?,
        createdByUserId: j['created_by_user_id'] as String?,
        createdAt: _dt(j['created_at']),
        updatedAt: _dt(j['updated_at']),
      );

  final String id;
  final String customerId;
  final String type;
  final int amountPaisa;
  final int balanceAfterPaisa;
  final String? referenceBillNo;
  final String? paymentMethod;
  final String? notes;
  final String? createdByUserId;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

class PullSupplier {
  const PullSupplier({
    required this.id,
    required this.name,
    this.phone,
    this.panVat,
    this.address,
    required this.totalPurchasedPaisa,
    required this.totalPaidPaisa,
    required this.balanceDuePaisa,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  factory PullSupplier.fromJson(Map<String, dynamic> j) => PullSupplier(
        id: j['id'] as String,
        name: j['name'] as String,
        phone: j['phone'] as String?,
        panVat: j['pan_vat'] as String?,
        address: j['address'] as String?,
        totalPurchasedPaisa:
            MoneyUtils.parseToPaisa(j['total_purchased'] as Object),
        totalPaidPaisa: MoneyUtils.parseToPaisa(j['total_paid'] as Object),
        balanceDuePaisa: MoneyUtils.parseToPaisa(j['balance_due'] as Object),
        createdAt: _dt(j['created_at']),
        updatedAt: _dt(j['updated_at']),
        deletedAt: _dt(j['deleted_at']),
      );

  final String id;
  final String name;
  final String? phone;
  final String? panVat;
  final String? address;
  final int totalPurchasedPaisa;
  final int totalPaidPaisa;
  final int balanceDuePaisa;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;
}

class PullPurchaseInvoice {
  const PullPurchaseInvoice({
    required this.id,
    required this.supplierId,
    required this.invoiceNo,
    required this.invoiceDate,
    required this.totalAmountPaisa,
    required this.paidAmountPaisa,
    required this.dueAmountPaisa,
    required this.status,
    this.notes,
    this.createdByUserId,
    this.createdAt,
    this.updatedAt,
  });

  factory PullPurchaseInvoice.fromJson(Map<String, dynamic> j) =>
      PullPurchaseInvoice(
        id: j['id'] as String,
        supplierId: j['supplier_id'] as String,
        invoiceNo: j['invoice_no'] as String,
        invoiceDate: j['invoice_date'] as String,
        totalAmountPaisa: MoneyUtils.parseToPaisa(j['total_amount'] as Object),
        paidAmountPaisa: MoneyUtils.parseToPaisa(j['paid_amount'] as Object),
        dueAmountPaisa: MoneyUtils.parseToPaisa(j['due_amount'] as Object),
        status: j['status'] as String,
        notes: j['notes'] as String?,
        createdByUserId: j['created_by_user_id'] as String?,
        createdAt: _dt(j['created_at']),
        updatedAt: _dt(j['updated_at']),
      );

  final String id;
  final String supplierId;
  final String invoiceNo;
  final String invoiceDate;
  final int totalAmountPaisa;
  final int paidAmountPaisa;
  final int dueAmountPaisa;
  final String status;
  final String? notes;
  final String? createdByUserId;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

class PullPurchaseInvoiceItem {
  const PullPurchaseInvoiceItem({
    required this.id,
    required this.purchaseInvoiceId,
    required this.variantId,
    this.batchId,
    required this.productName,
    required this.variantName,
    required this.quantityReceived,
    this.unitCostPricePaisa,
    required this.unitSellingPricePaisa,
    this.totalCostPaisa,
    this.batchCode,
    required this.expiryDate,
    this.createdAt,
    this.updatedAt,
  });

  factory PullPurchaseInvoiceItem.fromJson(Map<String, dynamic> j) =>
      PullPurchaseInvoiceItem(
        id: j['id'] as String,
        purchaseInvoiceId: j['purchase_invoice_id'] as String,
        variantId: j['variant_id'] as String,
        batchId: j['batch_id'] as String?,
        productName: j['product_name'] as String,
        variantName: j['variant_name'] as String,
        quantityReceived: (j['quantity_received'] as num).toInt(),
        unitCostPricePaisa:
            MoneyUtils.parseNullableToPaisa(j['unit_cost_price']),
        unitSellingPricePaisa:
            MoneyUtils.parseToPaisa(j['unit_selling_price'] as Object),
        totalCostPaisa: MoneyUtils.parseNullableToPaisa(j['total_cost']),
        batchCode: j['batch_code'] as String?,
        expiryDate: j['expiry_date'] as String,
        createdAt: _dt(j['created_at']),
        updatedAt: _dt(j['updated_at']),
      );

  final String id;
  final String purchaseInvoiceId;
  final String variantId;
  final String? batchId;
  final String productName;
  final String variantName;
  final int quantityReceived;
  final int? unitCostPricePaisa;
  final int unitSellingPricePaisa;
  final int? totalCostPaisa;
  final String? batchCode;
  final String expiryDate;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

class PullSupplierPayment {
  const PullSupplierPayment({
    required this.id,
    required this.supplierId,
    this.purchaseInvoiceId,
    required this.amountPaisa,
    required this.paymentMethod,
    this.referenceNo,
    this.createdByUserId,
    this.createdAt,
    this.updatedAt,
  });

  factory PullSupplierPayment.fromJson(Map<String, dynamic> j) =>
      PullSupplierPayment(
        id: j['id'] as String,
        supplierId: j['supplier_id'] as String,
        purchaseInvoiceId: j['purchase_invoice_id'] as String?,
        amountPaisa: MoneyUtils.parseToPaisa(j['amount'] as Object),
        paymentMethod: j['payment_method'] as String,
        referenceNo: j['reference_no'] as String?,
        createdByUserId: j['created_by_user_id'] as String?,
        createdAt: _dt(j['created_at']),
        updatedAt: _dt(j['updated_at']),
      );

  final String id;
  final String supplierId;
  final String? purchaseInvoiceId;
  final int amountPaisa;
  final String paymentMethod;
  final String? referenceNo;
  final String? createdByUserId;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

class PullStockMovement {
  const PullStockMovement({
    required this.id,
    required this.batchId,
    required this.movementType,
    required this.quantity,
    this.referenceId,
    this.reason,
    required this.staffName,
    this.createdAt,
    this.updatedAt,
  });

  factory PullStockMovement.fromJson(Map<String, dynamic> j) {
    final qty =
        (j['quantity'] as num?)?.toInt() ?? (j['quantity_change'] as num).toInt();
    return PullStockMovement(
      id: j['id'] as String,
      batchId: j['batch_id'] as String,
      movementType: j['movement_type'] as String,
      quantity: qty,
      referenceId: j['reference_id'] as String?,
      reason: j['reason'] as String?,
      staffName: j['staff_name'] as String,
      createdAt: _dt(j['created_at']),
      updatedAt: _dt(j['updated_at']),
    );
  }

  final String id;
  final String batchId;
  final String movementType;
  final int quantity;
  final String? referenceId;
  final String? reason;
  final String staffName;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

class PullSaleOrder {
  const PullSaleOrder({
    required this.id,
    required this.billNo,
    this.customerId,
    this.customerName,
    this.customerPhone,
    required this.cashierUserId,
    required this.cashierName,
    this.shiftId,
    required this.subtotalPaisa,
    required this.discountAmountPaisa,
    required this.totalAmountPaisa,
    this.costTotalPaisa,
    this.netProfitPaisa,
    required this.paymentMode,
    required this.syncStatus,
    this.createdAt,
    this.updatedAt,
  });

  factory PullSaleOrder.fromJson(Map<String, dynamic> j) => PullSaleOrder(
        id: j['id'] as String,
        billNo: j['bill_no'] as String,
        customerId: j['customer_id'] as String?,
        customerName: j['customer_name'] as String?,
        customerPhone: j['customer_phone'] as String?,
        cashierUserId: j['cashier_user_id'] as String,
        cashierName: j['cashier_name'] as String,
        shiftId: j['shift_id'] as String?,
        subtotalPaisa: MoneyUtils.parseToPaisa(j['subtotal'] as Object),
        discountAmountPaisa:
            MoneyUtils.parseToPaisa(j['discount_amount'] ?? 0),
        totalAmountPaisa: MoneyUtils.parseToPaisa(j['total_amount'] as Object),
        costTotalPaisa: MoneyUtils.parseNullableToPaisa(j['cost_total']),
        netProfitPaisa: MoneyUtils.parseNullableToPaisa(j['net_profit']),
        paymentMode: j['payment_mode'] as String,
        syncStatus: j['sync_status'] as String? ?? 'SYNCED',
        createdAt: _dt(j['created_at']),
        updatedAt: _dt(j['updated_at']),
      );

  final String id;
  final String billNo;
  final String? customerId;
  final String? customerName;
  final String? customerPhone;
  final String cashierUserId;
  final String cashierName;
  final String? shiftId;
  final int subtotalPaisa;
  final int discountAmountPaisa;
  final int totalAmountPaisa;
  final int? costTotalPaisa;
  final int? netProfitPaisa;
  final String paymentMode;
  final String syncStatus;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

class PullSaleItem {
  const PullSaleItem({
    required this.id,
    required this.saleOrderId,
    required this.batchId,
    required this.productName,
    required this.variantName,
    required this.quantity,
    this.costPricePaisa,
    required this.sellingPricePaisa,
    required this.totalPricePaisa,
  });

  factory PullSaleItem.fromJson(Map<String, dynamic> j) => PullSaleItem(
        id: j['id'] as String,
        saleOrderId: j['sale_order_id'] as String,
        batchId: j['batch_id'] as String,
        productName: j['product_name'] as String,
        variantName: j['variant_name'] as String,
        quantity: (j['quantity'] as num).toInt(),
        costPricePaisa: MoneyUtils.parseNullableToPaisa(j['cost_price']),
        sellingPricePaisa:
            MoneyUtils.parseToPaisa(j['selling_price'] as Object),
        totalPricePaisa: MoneyUtils.parseToPaisa(j['total_price'] as Object),
      );

  final String id;
  final String saleOrderId;
  final String batchId;
  final String productName;
  final String variantName;
  final int quantity;
  final int? costPricePaisa;
  final int sellingPricePaisa;
  final int totalPricePaisa;
}

class PullSalePayment {
  const PullSalePayment({
    required this.id,
    required this.saleOrderId,
    required this.method,
    required this.amountPaisa,
    this.transactionRef,
  });

  factory PullSalePayment.fromJson(Map<String, dynamic> j) => PullSalePayment(
        id: j['id'] as String,
        saleOrderId: j['sale_order_id'] as String,
        method: j['method'] as String,
        amountPaisa: MoneyUtils.parseToPaisa(j['amount'] as Object),
        transactionRef: j['transaction_ref'] as String?,
      );

  final String id;
  final String saleOrderId;
  final String method;
  final int amountPaisa;
  final String? transactionRef;
}

class PullRegisterShift {
  const PullRegisterShift({
    required this.id,
    required this.openedByUserId,
    this.closedByUserId,
    this.openedAt,
    this.closedAt,
    required this.openingFloatPaisa,
    required this.cashSalesPaisa,
    required this.digitalSalesPaisa,
    required this.khataCashRepaymentsPaisa,
    required this.cashExpensesPaisa,
    required this.expectedCashPaisa,
    this.actualCashCountedPaisa,
    this.discrepancyPaisa,
    required this.cashWithdrawnDepositPaisa,
    required this.retainedNextDayFloatPaisa,
    required this.status,
    this.notes,
    this.createdAt,
    this.updatedAt,
  });

  factory PullRegisterShift.fromJson(Map<String, dynamic> j) =>
      PullRegisterShift(
        id: j['id'] as String,
        openedByUserId: j['opened_by_user_id'] as String,
        closedByUserId: j['closed_by_user_id'] as String?,
        openedAt: _dt(j['opened_at']),
        closedAt: _dt(j['closed_at']),
        openingFloatPaisa:
            MoneyUtils.parseToPaisa(j['opening_float'] as Object),
        cashSalesPaisa: MoneyUtils.parseToPaisa(j['cash_sales'] ?? 0),
        digitalSalesPaisa: MoneyUtils.parseToPaisa(j['digital_sales'] ?? 0),
        khataCashRepaymentsPaisa:
            MoneyUtils.parseToPaisa(j['khata_cash_repayments'] ?? 0),
        cashExpensesPaisa: MoneyUtils.parseToPaisa(j['cash_expenses'] ?? 0),
        expectedCashPaisa:
            MoneyUtils.parseToPaisa(j['expected_cash'] as Object),
        actualCashCountedPaisa:
            MoneyUtils.parseNullableToPaisa(j['actual_cash_counted']),
        discrepancyPaisa: MoneyUtils.parseNullableToPaisa(j['discrepancy']),
        cashWithdrawnDepositPaisa:
            MoneyUtils.parseToPaisa(j['cash_withdrawn_deposit'] ?? 0),
        retainedNextDayFloatPaisa:
            MoneyUtils.parseToPaisa(j['retained_next_day_float'] ?? 0),
        status: j['status'] as String,
        notes: j['notes'] as String?,
        createdAt: _dt(j['created_at']),
        updatedAt: _dt(j['updated_at']),
      );

  final String id;
  final String openedByUserId;
  final String? closedByUserId;
  final DateTime? openedAt;
  final DateTime? closedAt;
  final int openingFloatPaisa;
  final int cashSalesPaisa;
  final int digitalSalesPaisa;
  final int khataCashRepaymentsPaisa;
  final int cashExpensesPaisa;
  final int expectedCashPaisa;
  final int? actualCashCountedPaisa;
  final int? discrepancyPaisa;
  final int cashWithdrawnDepositPaisa;
  final int retainedNextDayFloatPaisa;
  final String status;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

class PullStaffShiftSession {
  const PullStaffShiftSession({
    required this.id,
    required this.registerShiftId,
    required this.userId,
    required this.deviceCode,
    this.punchedInAt,
    this.punchedOutAt,
    this.lastSyncedAt,
    required this.status,
    this.forceClosedByUserId,
    this.updatedAt,
  });

  factory PullStaffShiftSession.fromJson(Map<String, dynamic> j) =>
      PullStaffShiftSession(
        id: j['id'] as String,
        registerShiftId: j['register_shift_id'] as String,
        userId: j['user_id'] as String,
        deviceCode: j['device_code'] as String,
        punchedInAt: _dt(j['punched_in_at']),
        punchedOutAt: _dt(j['punched_out_at']),
        lastSyncedAt: _dt(j['last_synced_at']),
        status: j['status'] as String,
        forceClosedByUserId: j['force_closed_by_user_id'] as String?,
        updatedAt: _dt(j['updated_at']),
      );

  final String id;
  final String registerShiftId;
  final String userId;
  final String deviceCode;
  final DateTime? punchedInAt;
  final DateTime? punchedOutAt;
  final DateTime? lastSyncedAt;
  final String status;
  final String? forceClosedByUserId;
  final DateTime? updatedAt;
}

class PullExpense {
  const PullExpense({
    required this.id,
    required this.category,
    required this.title,
    required this.amountPaisa,
    required this.paymentMethod,
    this.paidTo,
    this.shiftId,
    required this.createdByUserId,
    this.createdAt,
    this.updatedAt,
  });

  factory PullExpense.fromJson(Map<String, dynamic> j) => PullExpense(
        id: j['id'] as String,
        category: j['category'] as String,
        title: j['title'] as String,
        amountPaisa: MoneyUtils.parseToPaisa(j['amount'] as Object),
        paymentMethod: j['payment_method'] as String,
        paidTo: j['paid_to'] as String?,
        shiftId: j['shift_id'] as String?,
        createdByUserId: j['created_by_user_id'] as String,
        createdAt: _dt(j['created_at']),
        updatedAt: _dt(j['updated_at']),
      );

  final String id;
  final String category;
  final String title;
  final int amountPaisa;
  final String paymentMethod;
  final String? paidTo;
  final String? shiftId;
  final String createdByUserId;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

class PullInventorySyncAudit {
  const PullInventorySyncAudit({
    required this.id,
    required this.batchId,
    required this.deviceCode,
    required this.operation,
    required this.quantityChange,
    this.preSyncQty,
    this.postSyncQty,
    required this.isDiscrepancy,
    this.referenceId,
    this.stockMovementId,
    this.createdAt,
    this.updatedAt,
  });

  factory PullInventorySyncAudit.fromJson(Map<String, dynamic> j) =>
      PullInventorySyncAudit(
        id: j['id'] as String,
        batchId: j['batch_id'] as String,
        deviceCode: j['device_code'] as String,
        operation: j['operation'] as String,
        quantityChange: (j['quantity_change'] as num).toInt(),
        preSyncQty: (j['pre_sync_qty'] as num?)?.toInt(),
        postSyncQty: (j['post_sync_qty'] as num?)?.toInt(),
        isDiscrepancy: j['is_discrepancy'] as bool? ?? false,
        referenceId: j['reference_id'] as String?,
        stockMovementId: j['stock_movement_id'] as String?,
        createdAt: _dt(j['created_at']),
        updatedAt: _dt(j['updated_at']),
      );

  final String id;
  final String batchId;
  final String deviceCode;
  final String operation;
  final int quantityChange;
  final int? preSyncQty;
  final int? postSyncQty;
  final bool isDiscrepancy;
  final String? referenceId;
  final String? stockMovementId;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

@immutable
class PullStoreProfile {
  const PullStoreProfile({
    required this.id,
    required this.name,
    this.panNumber,
    this.phone,
    this.address,
    required this.status,
    this.updatedAt,
  });

  factory PullStoreProfile.fromJson(Map<String, dynamic> json) {
    return PullStoreProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      panNumber: json['pan_number'] as String?,
      phone: json['phone'] as String?,
      address: json['address'] as String?,
      status: json['status'] as String? ?? 'ACTIVE',
      updatedAt: _dt(json['updated_at']),
    );
  }

  final String id;
  final String name;
  final String? panNumber;
  final String? phone;
  final String? address;
  final String status;
  final DateTime? updatedAt;
}

@immutable
class PullStoreMember {
  const PullStoreMember({
    required this.id,
    required this.userId,
    required this.name,
    required this.username,
    required this.role,
    required this.status,
    this.updatedAt,
  });

  factory PullStoreMember.fromJson(Map<String, dynamic> json) {
    return PullStoreMember(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      name: json['name'] as String,
      username: json['username'] as String,
      role: json['role'] as String,
      status: json['status'] as String,
      updatedAt: _dt(json['updated_at']),
    );
  }

  final String id;
  final String userId;
  final String name;
  final String username;
  final String role;
  final String status;
  final DateTime? updatedAt;
}

List<T> _decodeList<T>(
  Object? raw,
  T Function(Map<String, dynamic>) fromJson,
) {
  if (raw == null) return const [];
  return (raw as List<dynamic>)
      .map((item) => fromJson(item as Map<String, dynamic>))
      .toList();
}

DateTime? _dt(Object? raw) {
  if (raw == null) return null;
  final s = raw.toString().trim();
  if (s.isEmpty) return null;
  return DateTime.parse(s).toUtc();
}

