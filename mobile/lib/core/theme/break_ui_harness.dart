import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../database/app_database.dart';
import '../database/money.dart';
import '../../features/inventory/domain/catalog_models.dart';
import '../../features/pos/domain/pos_models.dart';

/// Dataset modes for the dev-only `break-ui` stress-testing toggle.
enum BreakUiDatasetMode {
  demo('Demo'),
  worstCase('Worst case'),
  empty('Empty'),
  singular('1 item'),
  huge1000('1,000 rows');

  const BreakUiDatasetMode(this.label);
  final String label;
}

/// Realistic schema-backed worst-case fixtures per `break-ui` skill rules:
/// long multi-script cosmetics names, unbreakable emails, 1-char names,
/// `DECIMAL(10,2)` ceiling money, and 1,000-row catalogs.
abstract final class BreakUiWorstCaseFixtures {
  static const String longCustomerName = 'Aleksandra Wiśniewska-Chaudhary';
  static const String emojiDevanagariName = '🙏 लक्ष्मी श्रेष्ठ';
  static const String singleWordShortName = 'Jo';
  static const String unbreakableEmail =
      'bartholomew.fitzgerald@northwind-cosmetics-holdings.example.com';

  static const String longProductName =
      "L'Oréal Paris Infallible 24H Fresh Wear Foundation SPF 25 — Warm Undertone Bridal Edition";
  static const String longVariantName =
      'Shade #330 Hazelnut Amber / 120ml Twin Pack • SPF 50+ PA++++';

  static final DateTime _now = DateTime.utc(2026, 11, 19, 10, 0);

  static List<PosScannedBatch> posBatchesFor(BreakUiDatasetMode mode) {
    switch (mode) {
      case BreakUiDatasetMode.empty:
        return const <PosScannedBatch>[];
      case BreakUiDatasetMode.singular:
        return <PosScannedBatch>[
          PosScannedBatch(
            batchId: 'b-single',
            variantId: 'v-single',
            productId: 'p-single',
            productName: 'Lip Balm',
            brand: 'Nivea',
            category: 'Makeup - Lips',
            isGeneric: false,
            variantName: 'Cherry',
            batchCode: 'LOT-01',
            stickerBarcode: '01000001',
            sellingPricePaisa: 35000,
            stockQuantity: 1,
            expiryDate: DateTime(2027, 12, 31),
          ),
        ];
      case BreakUiDatasetMode.demo:
        return <PosScannedBatch>[
          PosScannedBatch(
            batchId: 'b-demo-1',
            variantId: 'v-demo-1',
            productId: 'p-demo-1',
            productName: 'Maybelline Fit Me Matte',
            brand: 'Maybelline',
            category: 'Makeup - Face',
            isGeneric: false,
            variantName: '#128 Warm Nude',
            colorHex: '#D8A27C',
            batchCode: 'LOT-2611',
            stickerBarcode: '01100024',
            sellingPricePaisa: 125000,
            stockQuantity: 18,
            expiryDate: DateTime(2028, 5, 31),
          ),
        ];
      case BreakUiDatasetMode.worstCase:
      case BreakUiDatasetMode.huge1000:
        return <PosScannedBatch>[
          PosScannedBatch(
            batchId: 'b-worst-1',
            variantId: 'v-worst-1',
            productId: 'p-worst-1',
            productName: longProductName,
            brand: 'Maybelline New York × Kathmandu Exclusive',
            category: 'Makeup - Face',
            isGeneric: false,
            variantName: longVariantName,
            colorHex: '#8E5338',
            batchCode: 'LOT-20261119-EXTREME-99',
            stickerBarcode: '019999999999',
            sellingPricePaisa: MoneyUtils.maxDecimal10_2Paisa,
            stockQuantity: 999,
            expiryDate: DateTime(2029, 12, 31),
          ),
          PosScannedBatch(
            batchId: 'b-worst-2',
            variantId: 'v-worst-2',
            productId: 'p-worst-2',
            productName: emojiDevanagariName,
            brand: 'Himalayan',
            category: 'Skincare',
            isGeneric: false,
            variantName: 'X',
            batchCode: 'L1',
            stickerBarcode: '01000002',
            sellingPricePaisa: 100,
            stockQuantity: 1,
            expiryDate: DateTime(2027, 1, 31),
          ),
        ];
    }
  }

  static List<ProductCatalogNode> catalogNodesFor(BreakUiDatasetMode mode) {
    switch (mode) {
      case BreakUiDatasetMode.empty:
        return const <ProductCatalogNode>[];
      case BreakUiDatasetMode.singular:
        return <ProductCatalogNode>[
          ProductCatalogNode(
            product: ProductRow(
              id: 'p-1',
              name: 'Soft Lip Balm',
              brand: 'Himalaya',
              category: 'Makeup - Lips',
              isGeneric: false,
              createdAt: _now,
              updatedAt: _now,
            ),
            variants: const <VariantCatalogNode>[],
            totalStock: 1,
            hasLowStock: true,
            hasExpiringOrExpired: false,
            minSellingPricePaisa: 15000,
            maxSellingPricePaisa: 15000,
          ),
        ];
      case BreakUiDatasetMode.demo:
        return <ProductCatalogNode>[
          ProductCatalogNode(
            product: ProductRow(
              id: 'p-demo',
              name: 'Fit Me Matte Foundation',
              brand: 'Maybelline',
              category: 'Makeup - Face',
              isGeneric: false,
              createdAt: _now,
              updatedAt: _now,
            ),
            variants: const <VariantCatalogNode>[],
            totalStock: 24,
            hasLowStock: false,
            hasExpiringOrExpired: false,
            minSellingPricePaisa: 125000,
            maxSellingPricePaisa: 125000,
          ),
        ];
      case BreakUiDatasetMode.worstCase:
        return <ProductCatalogNode>[
          ProductCatalogNode(
            product: ProductRow(
              id: 'p-worst',
              name: longProductName,
              brand: 'Maybelline New York × Kathmandu Exclusive',
              category: 'Makeup - Face',
              isGeneric: false,
              createdAt: _now,
              updatedAt: _now,
            ),
            variants: const <VariantCatalogNode>[],
            totalStock: 1,
            hasLowStock: true,
            hasExpiringOrExpired: true,
            minSellingPricePaisa: 100,
            maxSellingPricePaisa: MoneyUtils.maxDecimal10_2Paisa,
          ),
          ProductCatalogNode(
            product: ProductRow(
              id: 'p-nep',
              name: emojiDevanagariName,
              brand: singleWordShortName,
              category: 'Skincare',
              isGeneric: false,
              createdAt: _now,
              updatedAt: _now,
            ),
            variants: const <VariantCatalogNode>[],
            totalStock: 9999,
            hasLowStock: false,
            hasExpiringOrExpired: false,
            minSellingPricePaisa: MoneyUtils.maxDecimal10_2Paisa,
            maxSellingPricePaisa: MoneyUtils.maxDecimal10_2Paisa,
          ),
        ];
      case BreakUiDatasetMode.huge1000:
        return List<ProductCatalogNode>.generate(1000, (i) {
          final id = i.toString().padLeft(4, '0');
          return ProductCatalogNode(
            product: ProductRow(
              id: 'p-1k-$id',
              name: 'Catalog Stress SKU-$id $longVariantName',
              brand: 'Brand-$id',
              category: 'Skincare',
              isGeneric: false,
              createdAt: _now,
              updatedAt: _now,
            ),
            variants: const <VariantCatalogNode>[],
            totalStock: i % 5 == 0 ? 1 : 45,
            hasLowStock: i % 5 == 0,
            hasExpiringOrExpired: i % 10 == 0,
            minSellingPricePaisa: 85000,
            maxSellingPricePaisa: 195000,
          );
        });
    }
  }
}

/// Dev-only bottom-center segmented chrome (`Demo | Worst case | Empty | 1 item | 1,000 rows`)
/// for visual adversarial testing (`break-ui`). Never rendered in release mode.
class BreakUiOverlayToggle extends StatelessWidget {
  const BreakUiOverlayToggle({
    super.key,
    required this.mode,
    required this.onChanged,
    required this.child,
    this.enabled = kDebugMode,
  });

  final BreakUiDatasetMode mode;
  final ValueChanged<BreakUiDatasetMode> onChanged;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled || kReleaseMode) return child;
    return Stack(
      children: [
        child,
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: SafeArea(
            top: false,
            child: Center(
              child: Material(
                color: const Color(0xFFECEFED),
                elevation: 4,
                borderRadius: BorderRadius.circular(18),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 2,
                    runSpacing: 2,
                    children: [
                      for (final m in BreakUiDatasetMode.values)
                        GestureDetector(
                          onTap: () => onChanged(m),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: m == mode
                                  ? Colors.white
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              m.label,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: m == mode
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
