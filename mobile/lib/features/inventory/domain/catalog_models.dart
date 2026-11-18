import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/money.dart';

/// Supported cosmetics retail categories controlling Smart Intake dynamic fields.
enum SmartIntakeCategory {
  lipsNails(
    dbValue: 'Makeup - Lips',
    displayLabel: 'Lips & Nails',
    shortLabel: 'Lips & Nails',
    emoji: '💄',
    asksShadeColor: true,
    asksSizeVolume: false,
    asksSpfAndSkin: false,
    asksExpiry: true,
    isGeneric: false,
  ),
  faceMakeup(
    dbValue: 'Makeup - Face',
    displayLabel: 'Face Makeup',
    shortLabel: 'Face Makeup',
    emoji: '✨',
    asksShadeColor: true,
    asksSizeVolume: false,
    asksSpfAndSkin: false,
    asksExpiry: true,
    isGeneric: false,
  ),
  haircare(
    dbValue: 'Haircare',
    displayLabel: 'Haircare / Bottles',
    shortLabel: 'Haircare',
    emoji: '🧴',
    asksShadeColor: false,
    asksSizeVolume: true,
    asksSpfAndSkin: false,
    asksExpiry: true,
    isGeneric: false,
  ),
  skincare(
    dbValue: 'Skincare',
    displayLabel: 'Skincare / SPF',
    shortLabel: 'Skincare',
    emoji: '☀️',
    asksShadeColor: false,
    asksSizeVolume: true,
    asksSpfAndSkin: true,
    asksExpiry: true,
    isGeneric: false,
  ),
  generic(
    dbValue: 'Generic',
    displayLabel: 'Accessories (Generic)',
    shortLabel: 'Accessories',
    emoji: '💍',
    asksShadeColor: false,
    asksSizeVolume: false,
    asksSpfAndSkin: false,
    asksExpiry: false,
    isGeneric: true,
  );

  const SmartIntakeCategory({
    required this.dbValue,
    required this.displayLabel,
    required this.shortLabel,
    required this.emoji,
    required this.asksShadeColor,
    required this.asksSizeVolume,
    required this.asksSpfAndSkin,
    required this.asksExpiry,
    required this.isGeneric,
  });

  final String dbValue;
  final String displayLabel;
  final String shortLabel;
  final String emoji;
  final bool asksShadeColor;
  final bool asksSizeVolume;
  final bool asksSpfAndSkin;
  final bool asksExpiry;
  final bool isGeneric;

  static SmartIntakeCategory fromDbValue(String raw) {
    final normalized = raw.trim().toLowerCase();
    for (final cat in values) {
      if (cat.dbValue.toLowerCase() == normalized ||
          cat.shortLabel.toLowerCase() == normalized) {
        return cat;
      }
    }
    if (normalized.contains('lip') || normalized.contains('nail')) {
      return SmartIntakeCategory.lipsNails;
    }
    if (normalized.contains('face') || normalized.contains('foundation')) {
      return SmartIntakeCategory.faceMakeup;
    }
    if (normalized.contains('hair') || normalized.contains('shampoo')) {
      return SmartIntakeCategory.haircare;
    }
    if (normalized.contains('skin') ||
        normalized.contains('cream') ||
        normalized.contains('serum') ||
        normalized.contains('spf')) {
      return SmartIntakeCategory.skincare;
    }
    if (normalized.contains('generic') || normalized.contains('accessor')) {
      return SmartIntakeCategory.generic;
    }
    return SmartIntakeCategory.skincare;
  }
}

/// Curated cosmetics shade swatch presets for Lipsticks, Foundations, and Nails.
@immutable
class ShadeSwatchPreset {
  const ShadeSwatchPreset({required this.name, required this.hex});

  final String name;
  final String hex;
}

const List<ShadeSwatchPreset> kCosmeticShadeSwatches = <ShadeSwatchPreset>[
  ShadeSwatchPreset(name: 'Warm Nude', hex: '#E0B083'),
  ShadeSwatchPreset(name: 'Classic Ivory', hex: '#ECC096'),
  ShadeSwatchPreset(name: 'Velvet Teddy', hex: '#AD6D62'),
  ShadeSwatchPreset(name: 'Dusty Rose', hex: '#C97A7E'),
  ShadeSwatchPreset(name: 'Ruby Red', hex: '#9E2A2B'),
  ShadeSwatchPreset(name: 'Terracotta', hex: '#B5654D'),
  ShadeSwatchPreset(name: 'Caramel Tan', hex: '#C68B59'),
  ShadeSwatchPreset(name: 'Deep Espresso', hex: '#7F4F24'),
];

const List<String> kHaircareSizePresets = <String>[
  '100ml',
  '200ml',
  '250ml',
  '400ml',
  '500ml',
  '1L',
];

const List<String> kSkincareSizePresets = <String>[
  '15ml',
  '30ml',
  '50ml',
  '100ml',
  '150ml',
  '50g',
];

const List<String> kSpfPresets = <String>[
  'None',
  'SPF 30',
  'SPF 50',
  'SPF 50+',
];

const List<String> kSkinTypePresets = <String>[
  'All Skin',
  'Oily / Acne',
  'Dry / Hydrating',
  'Sensitive',
];

/// Supported Fast Stock Adjustment reasons mapped 1-to-1 to Go's
/// `stock_movements.movement_type` enum.
enum StockAdjustmentReason {
  purchaseIntake(
    movementType: 'PURCHASE_INTAKE',
    label: 'Intake / Restock',
    expectedSign: 1,
  ),
  customerReturn(
    movementType: 'CUSTOMER_RETURN',
    label: 'Customer Return',
    expectedSign: 1,
  ),
  countCorrection(
    movementType: 'COUNT_CORRECTION',
    label: 'Count Correction',
    expectedSign: 0,
  ),
  damagedWriteoff(
    movementType: 'DAMAGED_WRITEOFF',
    label: 'Damaged / Write-off',
    expectedSign: -1,
  ),
  expiredWriteoff(
    movementType: 'EXPIRED_WRITEOFF',
    label: 'Expired Write-off',
    expectedSign: -1,
  ),
  testerConversion(
    movementType: 'TESTER_CONVERSION',
    label: 'Tester Sample',
    expectedSign: -1,
  );

  const StockAdjustmentReason({
    required this.movementType,
    required this.label,
    required this.expectedSign,
  });

  final String movementType;
  final String label;
  final int expectedSign; // +1 positive, -1 negative, 0 any non-zero
}

enum BatchExpiryStatus {
  fresh,
  expiringSoon,
  expired,
  nonPerishable,
}

abstract final class InventoryDateUtils {
  /// Sentinel non-perishable date stored in NOT NULL `batches.expiry_date` for Generic items.
  static const String nonPerishableIsoDate = '2099-12-31';
  static const int defaultLowStockThreshold = 6;
  static const int expiringSoonDays = 60;

  /// Parses `YYYY-MM-DD` (or `YYYY-MM-DDTHH:mm...`) into local/UTC [DateTime].
  static DateTime? parseIsoDate(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final datePart = trimmed.length >= 10 ? trimmed.substring(0, 10) : trimmed;
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(datePart);
    if (match == null) return null;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    final dt = DateTime(year, month, day);
    if (dt.year != year || dt.month != month || dt.day != day) return null;
    return dt;
  }

  /// Accepts `MM/YYYY`, `MM-YYYY`, or `YYYY-MM-DD` and normalizes to `YYYY-MM-DD`
  /// (using the last calendar day of the month when `MM/YYYY` is entered).
  static String? normalizeExpiryInputToIso(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    final iso = parseIsoDate(trimmed);
    if (iso != null) {
      return formatIsoDate(iso);
    }

    final mmYyyy =
        RegExp(r'^(\d{1,2})\s*[/\-]\s*(\d{4})$').firstMatch(trimmed);
    if (mmYyyy != null) {
      final month = int.parse(mmYyyy.group(1)!);
      final year = int.parse(mmYyyy.group(2)!);
      if (month < 1 || month > 12 || year < 2000 || year > 2199) {
        return null;
      }
      final lastDay = DateTime(year, month + 1, 0);
      return formatIsoDate(lastDay);
    }

    final yyyyMm =
        RegExp(r'^(\d{4})\s*[/\-]\s*(\d{1,2})$').firstMatch(trimmed);
    if (yyyyMm != null) {
      final year = int.parse(yyyyMm.group(1)!);
      final month = int.parse(yyyyMm.group(2)!);
      if (month < 1 || month > 12 || year < 2000 || year > 2199) {
        return null;
      }
      final lastDay = DateTime(year, month + 1, 0);
      return formatIsoDate(lastDay);
    }

    return null;
  }

  static String formatIsoDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String formatExpiryMmYyyy(String isoDate) {
    if (isoDate.trim() == nonPerishableIsoDate) {
      return 'Non-Exp';
    }
    final parsed = parseIsoDate(isoDate);
    if (parsed == null) return isoDate;
    final m = parsed.month.toString().padLeft(2, '0');
    final y = parsed.year.toString().padLeft(4, '0');
    return '$m/$y';
  }

  static BatchExpiryStatus classifyExpiry(
    String isoDate, {
    bool isGeneric = false,
    DateTime? now,
  }) {
    if (isGeneric || isoDate.trim() == nonPerishableIsoDate) {
      return BatchExpiryStatus.nonPerishable;
    }
    final parsed = parseIsoDate(isoDate);
    if (parsed == null) return BatchExpiryStatus.fresh;

    final ref = now ?? DateTime.now();
    final today = DateTime(ref.year, ref.month, ref.day);
    if (parsed.isBefore(today)) {
      return BatchExpiryStatus.expired;
    }
    if (!parsed.isAfter(today.add(const Duration(days: expiringSoonDays)))) {
      return BatchExpiryStatus.expiringSoon;
    }
    return BatchExpiryStatus.fresh;
  }

  static Color? parseHexColor(String? rawHex) {
    if (rawHex == null) return null;
    final cleaned = rawHex.trim().replaceFirst('#', '');
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(cleaned)) {
      return null;
    }
    return Color(int.parse('FF$cleaned', radix: 16));
  }
}

/// Tier 3 Catalog node representing one physical batch lot.
@immutable
class BatchCatalogItem {
  const BatchCatalogItem({
    required this.batch,
    required this.expiryStatus,
    required this.isLowStock,
  });

  final BatchRow batch;
  final BatchExpiryStatus expiryStatus;
  final bool isLowStock;

  String get displayExpiry =>
      InventoryDateUtils.formatExpiryMmYyyy(batch.expiryDate);

  DateTime get expiryDateTime =>
      InventoryDateUtils.parseIsoDate(batch.expiryDate) ?? DateTime(2099, 12, 31);
}

/// Tier 2 Catalog node representing a Shade, Size, or Generic Variant.
@immutable
class VariantCatalogNode {
  const VariantCatalogNode({
    required this.variant,
    required this.batches,
    required this.totalStock,
    required this.minSellingPricePaisa,
    required this.maxSellingPricePaisa,
    required this.attributesMap,
  });

  final ProductVariantRow variant;
  final List<BatchCatalogItem> batches;
  final int totalStock;
  final int minSellingPricePaisa;
  final int maxSellingPricePaisa;
  final Map<String, String> attributesMap;

  Color? get swatchColor => InventoryDateUtils.parseHexColor(variant.colorHex);

  String? get spfLabel {
    final v = attributesMap['spf'];
    return (v == null || v.isEmpty || v == 'None') ? null : v;
  }

  String? get skinTypeLabel {
    final v = attributesMap['skin_type'];
    return (v == null || v.isEmpty) ? null : v;
  }

  String get formattedPriceLabel {
    if (batches.isEmpty) return 'No Stock';
    if (minSellingPricePaisa == maxSellingPricePaisa) {
      return MoneyUtils.formatRs(minSellingPricePaisa);
    }
    return '${MoneyUtils.formatRs(minSellingPricePaisa)}–${MoneyUtils.formatRs(maxSellingPricePaisa)}';
  }

  static Map<String, String> decodeAttributes(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is Map) {
        return <String, String>{
          for (final entry in decoded.entries)
            if (entry.value != null && entry.value.toString().trim().isNotEmpty)
              entry.key.toString(): entry.value.toString().trim(),
        };
      }
    } catch (_) {
      // Ignore malformed attribute JSON gracefully.
    }
    return const <String, String>{};
  }
}

/// Tier 1 Catalog node representing the Master Product and all nested variants/batches.
@immutable
class ProductCatalogNode {
  const ProductCatalogNode({
    required this.product,
    required this.variants,
    required this.totalStock,
    required this.hasLowStock,
    required this.hasExpiringOrExpired,
    required this.minSellingPricePaisa,
    required this.maxSellingPricePaisa,
  });

  final ProductRow product;
  final List<VariantCatalogNode> variants;
  final int totalStock;
  final bool hasLowStock;
  final bool hasExpiringOrExpired;
  final int minSellingPricePaisa;
  final int maxSellingPricePaisa;

  SmartIntakeCategory get categoryKind =>
      SmartIntakeCategory.fromDbValue(product.category);

  int get batchCount =>
      variants.fold<int>(0, (sum, v) => sum + v.batches.length);

  String get formattedPriceRange {
    if (variants.isEmpty || minSellingPricePaisa == 0 && maxSellingPricePaisa == 0) {
      return 'MRP Pending';
    }
    if (minSellingPricePaisa == maxSellingPricePaisa) {
      return MoneyUtils.formatRs(minSellingPricePaisa);
    }
    return '${MoneyUtils.formatRs(minSellingPricePaisa)}–${MoneyUtils.formatRs(maxSellingPricePaisa)}';
  }
}

@immutable
class CatalogSummaryStats {
  const CatalogSummaryStats({
    required this.activeProductCount,
    required this.categoryCount,
    required this.lowReserveCount,
    required this.expiringCount,
    required this.totalUnits,
  });

  final int activeProductCount;
  final int categoryCount;
  final int lowReserveCount;
  final int expiringCount;
  final int totalUnits;
}

@immutable
class CatalogFilterState {
  const CatalogFilterState({
    this.query = '',
    this.selectedCategory,
    this.lowReserveOnly = false,
    this.expiringOnly = false,
    this.lowOrExpiringOnly = false,
  });

  final String query;
  final SmartIntakeCategory? selectedCategory;
  final bool lowReserveOnly;
  final bool expiringOnly;
  final bool lowOrExpiringOnly;

  CatalogFilterState copyWith({
    String? query,
    SmartIntakeCategory? selectedCategory,
    bool clearCategory = false,
    bool? lowReserveOnly,
    bool? expiringOnly,
    bool? lowOrExpiringOnly,
  }) {
    return CatalogFilterState(
      query: query ?? this.query,
      selectedCategory:
          clearCategory ? null : (selectedCategory ?? this.selectedCategory),
      lowReserveOnly: lowReserveOnly ?? this.lowReserveOnly,
      expiringOnly: expiringOnly ?? this.expiringOnly,
      lowOrExpiringOnly: lowOrExpiringOnly ?? this.lowOrExpiringOnly,
    );
  }
}

@immutable
class SmartIntakeSubmission {
  const SmartIntakeSubmission({
    this.existingProductId,
    this.existingVariantId,
    required this.category,
    required this.productName,
    required this.brand,
    required this.variantName,
    this.sizeVolume,
    this.colorHex,
    this.spf,
    this.skinType,
    this.supplierId,
    required this.batchCode,
    required this.stickerBarcode,
    this.costPricePaisa,
    required this.sellingPricePaisa,
    required this.quantity,
    required this.expiryIsoDate,
  });

  final String? existingProductId;
  final String? existingVariantId;
  final SmartIntakeCategory category;
  final String productName;
  final String brand;
  final String variantName;
  final String? sizeVolume;
  final String? colorHex;
  final String? spf;
  final String? skinType;
  final String? supplierId;
  final String batchCode;
  final String stickerBarcode;
  final int? costPricePaisa;
  final int sellingPricePaisa;
  final int quantity;
  final String expiryIsoDate;
}

@immutable
class SmartIntakeResult {
  const SmartIntakeResult({
    required this.product,
    required this.variant,
    required this.batch,
    required this.stockMovement,
  });

  final ProductRow product;
  final ProductVariantRow variant;
  final BatchRow batch;
  final StockMovementRow stockMovement;
}

