import 'package:flutter/foundation.dart';

import '../../../core/database/app_database.dart';
import '../../../core/printer/esc_pos_receipt_builder.dart';

/// Expiry & FEFO status for a scanned or catalog batch.
enum PosBatchScanStatus {
  /// Safe to add immediately.
  ok,

  /// Batch is past its expiry date — HARD BLOCKED.
  expiredBlocked,

  /// An older non-expired batch of the same variant has stock > 0.
  fefoOlderExists,

  /// Batch has 0 or negative stock (only used for explicit stock checks if needed).
  outOfStock,

  /// No matching barcode found in local encrypted SQLite.
  notFound,
}

/// Resolved 3-tier product + variant + batch record for POS billing.
@immutable
class PosScannedBatch {
  const PosScannedBatch({
    required this.batchId,
    required this.variantId,
    required this.productId,
    required this.productName,
    required this.brand,
    required this.category,
    required this.isGeneric,
    required this.variantName,
    required this.batchCode,
    required this.stickerBarcode,
    required this.sellingPricePaisa,
    this.costPricePaisa,
    required this.stockQuantity,
    required this.expiryDate,
    this.colorHex,
    this.sizeVolume,
  });

  final String batchId;
  final String variantId;
  final String productId;
  final String productName;
  final String brand;
  final String category;
  final bool isGeneric;
  final String variantName;
  final String batchCode;
  final String stickerBarcode;
  final int sellingPricePaisa;

  /// Strictly populated only when `role == 'OWNER'`; null for STAFF/MANAGER.
  final int? costPricePaisa;
  final int stockQuantity;
  final DateTime expiryDate;
  final String? colorHex;
  final String? sizeVolume;

  bool get isNonPerishable => expiryDate.year >= 2099;

  bool isExpiredAt(DateTime now) {
    if (isNonPerishable) return false;
    final today = DateTime.utc(now.year, now.month, now.day);
    final exp = DateTime.utc(expiryDate.year, expiryDate.month, expiryDate.day);
    return exp.isBefore(today);
  }
}

/// Result of looking up a scanned barcode with FEFO & expiry checks.
@immutable
class PosScanLookupResult {
  const PosScanLookupResult._({
    required this.status,
    this.scannedBatch,
    this.olderFefoBatch,
  });

  const PosScanLookupResult.notFound()
      : this._(status: PosBatchScanStatus.notFound);

  const PosScanLookupResult.ok(PosScannedBatch batch)
      : this._(status: PosBatchScanStatus.ok, scannedBatch: batch);

  const PosScanLookupResult.expired(PosScannedBatch batch)
      : this._(status: PosBatchScanStatus.expiredBlocked, scannedBatch: batch);

  const PosScanLookupResult.fefoWarning({
    required PosScannedBatch scanned,
    required PosScannedBatch older,
  }) : this._(
          status: PosBatchScanStatus.fefoOlderExists,
          scannedBatch: scanned,
          olderFefoBatch: older,
        );

  final PosBatchScanStatus status;
  final PosScannedBatch? scannedBatch;
  final PosScannedBatch? olderFefoBatch;
}

/// Single line item in the active POS cart.
@immutable
class PosCartItem {
  const PosCartItem({
    required this.lineKey,
    required this.batchId,
    required this.productId,
    required this.variantId,
    required this.productName,
    required this.variantName,
    required this.batchCode,
    required this.stickerBarcode,
    required this.isGeneric,
    required this.unitPricePaisa,
    int? mrpPaisa,
    this.itemDiscountPaisa = 0,
    this.costPricePaisa,
    required this.quantity,
    required this.availableStock,
    required this.expiryDate,
    this.colorHex,
    this.sizeVolume,
  }) : mrpPaisa = mrpPaisa ?? unitPricePaisa;

  /// Unique key in cart (`batchId` for standard items, or
  /// `batchId#<unitPricePaisa>` for custom-priced generic items).
  final String lineKey;
  final String batchId;
  final String productId;
  final String variantId;
  final String productName;
  final String variantName;
  final String batchCode;
  final String stickerBarcode;
  final bool isGeneric;
  final int unitPricePaisa;

  /// Original catalog MRP in paisa so POS Negotiation can "Reset MRP".
  final int mrpPaisa;

  /// Per-line negotiated discount in paisa (subtracted from unitPrice * qty).
  final int itemDiscountPaisa;

  /// Populated only for OWNER; always null for STAFF/MANAGER.
  final int? costPricePaisa;
  final int quantity;
  final int availableStock;
  final DateTime expiryDate;
  final String? colorHex;
  final String? sizeVolume;

  int get lineTotalPaisa {
    final raw = (unitPricePaisa * quantity) - itemDiscountPaisa;
    return raw < 0 ? 0 : raw;
  }

  PosCartItem copyWith({
    int? quantity,
    int? unitPricePaisa,
    int? itemDiscountPaisa,
  }) {
    return PosCartItem(
      lineKey: lineKey,
      batchId: batchId,
      productId: productId,
      variantId: variantId,
      productName: productName,
      variantName: variantName,
      batchCode: batchCode,
      stickerBarcode: stickerBarcode,
      isGeneric: isGeneric,
      unitPricePaisa: unitPricePaisa ?? this.unitPricePaisa,
      mrpPaisa: mrpPaisa,
      itemDiscountPaisa: itemDiscountPaisa ?? this.itemDiscountPaisa,
      costPricePaisa: costPricePaisa,
      quantity: quantity ?? this.quantity,
      availableStock: availableStock,
      expiryDate: expiryDate,
      colorHex: colorHex,
      sizeVolume: sizeVolume,
    );
  }
}

/// 4-tier Negotiation Sheet discount options + optional custom flat discount.
enum DiscountTier {
  none,
  percent5,
  percent10,
  percent15,
  flat100,
  custom,
}

@immutable
class PosDiscount {
  const PosDiscount({
    this.tier = DiscountTier.none,
    this.customAmountPaisa = 0,
  });

  const PosDiscount.none()
      : tier = DiscountTier.none,
        customAmountPaisa = 0;

  final DiscountTier tier;
  final int customAmountPaisa;

  int computeDiscountPaisa(int subtotalPaisa) {
    if (subtotalPaisa <= 0) return 0;
    final raw = switch (tier) {
      DiscountTier.none => 0,
      DiscountTier.percent5 => (subtotalPaisa * 5) ~/ 100,
      DiscountTier.percent10 => (subtotalPaisa * 10) ~/ 100,
      DiscountTier.percent15 => (subtotalPaisa * 15) ~/ 100,
      DiscountTier.flat100 => 10000,
      DiscountTier.custom => customAmountPaisa,
    };
    if (raw <= 0) return 0;
    return raw > subtotalPaisa ? subtotalPaisa : raw;
  }

  String get label => switch (tier) {
        DiscountTier.none => 'No Discount',
        DiscountTier.percent5 => '5% Loyalty',
        DiscountTier.percent10 => '10% Bundle',
        DiscountTier.percent15 => '15% VIP',
        DiscountTier.flat100 => 'Flat Rs. 100',
        DiscountTier.custom => 'Custom Off',
      };
}

/// Single payment leg during checkout (supports Cash, Fonepay QR, Khata, Card, Split).
@immutable
class PosPaymentLeg {
  const PosPaymentLeg({
    required this.method,
    required this.amountPaisa,
    this.transactionRef,
  });

  /// `CASH`, `FONEPAY_QR`, `CARD`, `KHATA_CREDIT`.
  final String method;
  final int amountPaisa;
  final String? transactionRef;
}

/// Customer summary with Khata ledger and recorded shade profiles.
@immutable
class CustomerProfileBundle {
  const CustomerProfileBundle({
    required this.customer,
    required this.shades,
    required this.recentTransactions,
  });

  final CustomerRow customer;
  final List<CustomerShadeProfileRow> shades;
  final List<CustomerTransactionRow> recentTransactions;

  int get availableCreditPaisa =>
      customer.creditLimit - customer.currentBalanceDue;
}

/// Active POS cart state managed by `PosCartController`.
@immutable
class PosCartState {
  const PosCartState({
    this.items = const <PosCartItem>[],
    this.discount = const PosDiscount.none(),
    this.selectedCustomer,
    this.isCheckingOut = false,
    this.lastReceipt,
  });

  final List<PosCartItem> items;
  final PosDiscount discount;
  final CustomerRow? selectedCustomer;
  final bool isCheckingOut;
  final ReceiptPrintData? lastReceipt;

  int get itemCount => items.fold<int>(0, (sum, i) => sum + i.quantity);

  int get subtotalPaisa =>
      items.fold<int>(0, (sum, i) => sum + i.lineTotalPaisa);

  int get discountPaisa => discount.computeDiscountPaisa(subtotalPaisa);

  int get netTotalPaisa {
    final net = subtotalPaisa - discountPaisa;
    return net < 0 ? 0 : net;
  }

  PosCartState copyWith({
    List<PosCartItem>? items,
    PosDiscount? discount,
    CustomerRow? selectedCustomer,
    bool clearCustomer = false,
    bool? isCheckingOut,
    ReceiptPrintData? lastReceipt,
  }) {
    return PosCartState(
      items: items ?? this.items,
      discount: discount ?? this.discount,
      selectedCustomer: clearCustomer
          ? null
          : (selectedCustomer ?? this.selectedCustomer),
      isCheckingOut: isCheckingOut ?? this.isCheckingOut,
      lastReceipt: lastReceipt ?? this.lastReceipt,
    );
  }
}

/// Result returned by `PosRepository.completeCheckout`.
@immutable
class PosCheckoutCommitResult {
  const PosCheckoutCommitResult({
    required this.saleOrderId,
    required this.billNo,
    required this.receiptData,
    this.khataBalanceAfterPaisa,
  });

  final String saleOrderId;
  final String billNo;
  final ReceiptPrintData receiptData;
  final int? khataBalanceAfterPaisa;
}

