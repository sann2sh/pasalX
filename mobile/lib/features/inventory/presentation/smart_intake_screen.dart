import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/money.dart';
import '../../../core/printer/printer.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../application/inventory_providers.dart';
import '../domain/catalog_models.dart';
import 'barcode_scanner_sheet.dart';
import 'dual_label_preview.dart';

/// 1-Screen Category-Driven Smart Stock Intake & Dual 62x20mm Sticker Printer
/// (`google_stitch.html` lines 3064–3362, Tasks 8.2–8.4).
class SmartIntakeScreen extends ConsumerStatefulWidget {
  const SmartIntakeScreen({
    super.key,
    this.initialProductId,
    this.initialVariantId,
  });

  final String? initialProductId;
  final String? initialVariantId;

  @override
  ConsumerState<SmartIntakeScreen> createState() => _SmartIntakeScreenState();
}

class _SmartIntakeScreenState extends ConsumerState<SmartIntakeScreen> {
  final _productNameCtrl = TextEditingController();
  final _brandCtrl = TextEditingController();
  final _shadeNameCtrl = TextEditingController();
  final _sizeVolumeCtrl = TextEditingController();
  final _genericLabelCtrl = TextEditingController(text: 'Standard');
  final _costCtrl = TextEditingController();
  final _mrpCtrl = TextEditingController();
  final _lotCtrl = TextEditingController();
  final _barcodeCtrl = TextEditingController();
  final _expiryCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController(text: '12');

  SmartIntakeCategory _category = SmartIntakeCategory.lipsNails;
  String _selectedShadeHex = kCosmeticShadeSwatches.first.hex;
  String _selectedSpf = 'None';
  String _selectedSkinType = 'All Skin';
  String? _selectedSupplierId;
  String? _selectedExistingProductId;
  String? _selectedExistingVariantId;
  bool _prefillApplied = false;

  TsplLabelStyle _labelStyle = TsplLabelStyle.barcode128;
  bool _submitting = false;
  String? _error;
  SmartIntakeResult? _savedResult;
  bool _printSucceeded = false;

  @override
  void initState() {
    super.initState();
    _selectedExistingProductId = widget.initialProductId;
    _selectedExistingVariantId = widget.initialVariantId;
    final now = DateTime.now();
    _lotCtrl.text =
        'LOT-${now.year}${now.month.toString().padLeft(2, '0')}-${(now.millisecondsSinceEpoch % 90 + 10)}';
    _expiryCtrl.text =
        '${now.month.toString().padLeft(2, '0')}/${now.year + 2}';
    Future<void>.microtask(_regenerateBarcode);
  }

  @override
  void dispose() {
    _productNameCtrl.dispose();
    _brandCtrl.dispose();
    _shadeNameCtrl.dispose();
    _sizeVolumeCtrl.dispose();
    _genericLabelCtrl.dispose();
    _costCtrl.dispose();
    _mrpCtrl.dispose();
    _lotCtrl.dispose();
    _barcodeCtrl.dispose();
    _expiryCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }

  Future<void> _regenerateBarcode() async {
    final repo = ref.read(inventoryRepositoryProvider);
    final deviceCode =
        ref.read(ramKeyHolderProvider).session?.deviceCode ?? '01';
    if (repo == null) return;
    final code = await repo.generateUniqueStickerBarcode(deviceCode: deviceCode);
    if (mounted) {
      setState(() => _barcodeCtrl.text = code);
    }
  }

  void _applyInitialPrefill(List<ProductCatalogNode> nodes) {
    if (_prefillApplied || _selectedExistingProductId == null || nodes.isEmpty) {
      return;
    }
    for (final node in nodes) {
      if (node.product.id == _selectedExistingProductId) {
        _prefillApplied = true;
        _selectExistingProduct(
          node,
          variantId: _selectedExistingVariantId,
          insideBuild: true,
        );
        break;
      }
    }
  }

  void _clearVariantFields() {
    _selectedExistingVariantId = null;
    _shadeNameCtrl.clear();
    _sizeVolumeCtrl.clear();
    _genericLabelCtrl.text = 'Standard';
    _selectedShadeHex = kCosmeticShadeSwatches.first.hex;
    _selectedSpf = 'None';
    _selectedSkinType = 'All Skin';
  }

  void _selectExistingProduct(
    ProductCatalogNode? node, {
    String? variantId,
    bool insideBuild = false,
  }) {
    void assign() {
      if (node == null) {
        _selectedExistingProductId = null;
        _clearVariantFields();
        return;
      }
      _selectedExistingProductId = node.product.id;
      _productNameCtrl.text = node.product.name;
      _brandCtrl.text = node.product.brand;
      _category = node.categoryKind;

      VariantCatalogNode? matchedVar;
      if (variantId != null) {
        for (final v in node.variants) {
          if (v.variant.id == variantId) {
            matchedVar = v;
            break;
          }
        }
      }
      if (matchedVar != null) {
        _applyVariantFields(matchedVar);
      } else {
        _clearVariantFields();
      }
    }

    if (insideBuild) {
      assign();
    } else {
      setState(assign);
    }
  }

  void _applyVariantFields(VariantCatalogNode? vNode) {
    if (vNode == null) {
      _selectedExistingVariantId = null;
      return;
    }
    _selectedExistingVariantId = vNode.variant.id;
    _shadeNameCtrl.text = vNode.variant.variantName;
    _sizeVolumeCtrl.text = vNode.variant.sizeVolume ?? '';
    _genericLabelCtrl.text = vNode.variant.variantName;
    if (vNode.variant.colorHex != null) {
      _selectedShadeHex = vNode.variant.colorHex!;
    }
    _selectedSpf = vNode.spfLabel ?? 'None';
    _selectedSkinType = vNode.skinTypeLabel ?? 'All Skin';
    if (vNode.batches.isNotEmpty) {
      final latest = vNode.batches.first.batch;
      _mrpCtrl.text = MoneyUtils.toDecimalString(latest.sellingPrice);
      if (ref.read(canViewCostPriceProvider) && latest.costPrice != null) {
        _costCtrl.text = MoneyUtils.toDecimalString(latest.costPrice!);
      }
    }
  }

  String _resolvedVariantName() {
    switch (_category) {
      case SmartIntakeCategory.lipsNails:
      case SmartIntakeCategory.faceMakeup:
        return _shadeNameCtrl.text.trim();
      case SmartIntakeCategory.haircare:
        final size = _sizeVolumeCtrl.text.trim();
        return size;
      case SmartIntakeCategory.skincare:
        final size = _sizeVolumeCtrl.text.trim();
        final parts = <String>[
          if (size.isNotEmpty) size,
          if (_selectedSpf != 'None') _selectedSpf,
          if (_selectedSkinType.isNotEmpty && _selectedSkinType != 'All Skin')
            _selectedSkinType,
        ];
        return parts.join(' · ');
      case SmartIntakeCategory.generic:
        final custom = _genericLabelCtrl.text.trim();
        return custom.isEmpty ? 'Standard' : custom;
    }
  }

  int _parseSellingPricePaisaOrZero() {
    final raw = _mrpCtrl.text.replaceAll(',', '').trim();
    if (raw.isEmpty) return 0;
    try {
      return MoneyUtils.parseToPaisa(raw);
    } on FormatException {
      return 0;
    }
  }

  int? _parseCostPricePaisaOrNull() {
    final raw = _costCtrl.text.replaceAll(',', '').trim();
    if (raw.isEmpty) return null;
    return MoneyUtils.parseToPaisa(raw);
  }

  int _parseQtyOrZero() {
    return int.tryParse(_qtyCtrl.text.trim()) ?? 0;
  }

  Future<void> _submit({required bool printAfterSave}) async {
    if (_submitting) return;
    if (_savedResult != null) {
      if (printAfterSave) {
        await _dispatchLabels(_savedResult!);
      }
      return;
    }

    final repo = ref.read(inventoryRepositoryProvider);
    final session = ref.read(ramKeyHolderProvider).session;
    final canViewCost = ref.read(canViewCostPriceProvider);
    if (repo == null || session == null) {
      setState(() => _error = 'Encrypted database is locked.');
      return;
    }

    int sellingPaisa;
    try {
      final mrpRaw = _mrpCtrl.text.replaceAll(',', '').trim();
      if (mrpRaw.isEmpty) {
        throw const FormatException('Retail MRP (Rs.) is required.');
      }
      sellingPaisa = MoneyUtils.parseToPaisa(mrpRaw);
      if (sellingPaisa <= 0 || sellingPaisa > MoneyUtils.maxDecimal10_2Paisa) {
        throw const FormatException(
          'Retail MRP must be greater than 0 and <= Rs. 9,99,99,999.99.',
        );
      }
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }

    int? costPaisa;
    if (canViewCost) {
      try {
        costPaisa = _parseCostPricePaisaOrNull();
        if (costPaisa != null &&
            (costPaisa < 0 || costPaisa > MoneyUtils.maxDecimal10_2Paisa)) {
          throw const FormatException('Wholesale cost exceeds DECIMAL(10,2).');
        }
      } on FormatException catch (e) {
        setState(() => _error = e.message);
        return;
      }
    }

    final qty = _parseQtyOrZero();
    if (qty <= 0) {
      setState(() => _error = 'Intake quantity must be at least 1 unit.');
      return;
    }

    final resolvedVariant = _resolvedVariantName();
    if (resolvedVariant.isEmpty) {
      setState(() {
        _error = _category.asksShadeColor
            ? 'Enter shade name / code.'
            : 'Enter bottle size / volume.';
      });
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final result = await repo.submitSmartIntake(
        actorRole: session.role,
        actorUserName: session.username,
        submission: SmartIntakeSubmission(
          existingProductId: _selectedExistingProductId,
          existingVariantId: _selectedExistingVariantId,
          category: _category,
          productName: _productNameCtrl.text,
          brand: _brandCtrl.text,
          variantName: resolvedVariant,
          sizeVolume: _sizeVolumeCtrl.text,
          colorHex: _category.asksShadeColor ? _selectedShadeHex : null,
          spf: _category.asksSpfAndSkin ? _selectedSpf : null,
          skinType: _category.asksSpfAndSkin ? _selectedSkinType : null,
          supplierId: _selectedSupplierId,
          batchCode: _lotCtrl.text,
          stickerBarcode: _barcodeCtrl.text,
          costPricePaisa: costPaisa,
          sellingPricePaisa: sellingPaisa,
          quantity: qty,
          expiryIsoDate: _category.asksExpiry
              ? _expiryCtrl.text
              : InventoryDateUtils.nonPerishableIsoDate,
        ),
      );

      if (!mounted) return;
      _savedResult = result;

      if (!printAfterSave) {
        ref.read(pasalAlertProvider.notifier).showSuccess(
              'Saved ${result.product.name} (${result.batch.stockQuantity} units) to encrypted vault.',
            );
        if (context.canPop()) {
          context.pop(true);
        } else {
          context.go('/inventory');
        }
        return;
      }

      await _dispatchLabels(result, fromSubmit: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.toString().replaceFirst(RegExp(r'^.*Exception:\s*'), '');
      });
    }
  }

  Future<void> _dispatchLabels(
    SmartIntakeResult saved, {
    bool fromSubmit = false,
  }) async {
    if (_submitting && !fromSubmit) return;
    final driver = ref.read(xlabPrinterDriverProvider);
    final qty = saved.batch.stockQuantity.clamp(1, 200);
    final expDt = InventoryDateUtils.parseIsoDate(saved.batch.expiryDate) ??
        DateTime(2099, 12, 31);

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await driver.printBatchCopies(
        BatchLabelData(
          productName: saved.product.name,
          variantName: saved.variant.variantName,
          stickerBarcode: saved.batch.stickerBarcode,
          sellingPricePaisa: saved.batch.sellingPrice,
          expiryDate: expDt,
          batchCode: saved.batch.batchCode,
        ),
        quantity: qty,
        style: _labelStyle,
      );
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _printSucceeded = true;
      });
      ref.read(pasalAlertProvider.notifier).showSuccess(
            'Stock saved & $qty labels sent to printer',
          );
      if (context.canPop()) {
        context.pop(true);
      } else {
        context.go('/inventory');
      }
    } on PrinterException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _printSucceeded = false;
        _error =
            'Batch saved locally & queued for sync, but printer print failed: '
            '${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _printSucceeded = false;
        _error =
            'Batch saved locally & queued for sync, but printer print failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final canManage = ref.watch(canManageInventoryProvider);
    final canViewCost = ref.watch(canViewCostPriceProvider);
    final printerConfig = ref.watch(printerConfigProvider);
    final deviceCode =
        ref.watch(ramKeyHolderProvider).session?.deviceCode ?? '01';
    final catalogNodes = ref.watch(catalogNodesProvider).asData?.value ??
        const <ProductCatalogNode>[];
    final suppliers = ref.watch(inventorySuppliersProvider).asData?.value ??
        const <SupplierRow>[];

    _applyInitialPrefill(catalogNodes);

    if (!canManage) {
      return Scaffold(
        backgroundColor: c.surface,
        appBar: AppBar(title: const Text('Stock Intake')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: PasalCard(
              color: c.errorContainer,
              borderColor: c.error.withValues(alpha: 0.25),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline_rounded, size: 40, color: c.error),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Manager or Owner Required',
                    style: t.headlineSmall?.copyWith(color: c.onErrorContainer),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Staff accounts have read-only catalog access and cannot add inventory batches or wholesale prices.',
                    style: t.bodySmall?.copyWith(color: c.onErrorContainer),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  ElevatedButton(
                    onPressed: () {
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go('/inventory');
                      }
                    },
                    child: const Text('Back to Catalog'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    ProductCatalogNode? selectedProductNode;
    if (_selectedExistingProductId != null) {
      for (final node in catalogNodes) {
        if (node.product.id == _selectedExistingProductId) {
          selectedProductNode = node;
          break;
        }
      }
    }

    final qty = _parseQtyOrZero();
    final mrpPaisa = _parseSellingPricePaisaOrZero();
    int? costPaisaPreview;
    if (canViewCost) {
      try {
        costPaisaPreview = _parseCostPricePaisaOrNull();
      } on FormatException {
        costPaisaPreview = null;
      }
    }
    final bool isLossMargin = canViewCost &&
        costPaisaPreview != null &&
        mrpPaisa > 0 &&
        costPaisaPreview > mrpPaisa;
    final marginText = (canViewCost && costPaisaPreview != null && mrpPaisa > 0)
        ? (isLossMargin
            ? 'Loss -${MoneyUtils.formatRs(costPaisaPreview - mrpPaisa)} (Cost > MRP)'
            : 'Margin ${MoneyUtils.formatRs(mrpPaisa - costPaisaPreview)} '
                '(${(((mrpPaisa - costPaisaPreview) * 100) / mrpPaisa).toStringAsFixed(0)}%)')
        : null;

    final formLockedAfterSave = _savedResult != null;

    return Scaffold(
      backgroundColor: c.surface,
      appBar: AppBar(
        title: const Text('Smart Stock Intake'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.gutterMobile),
            child: Center(
              child: PasalStatusBadge(
                label: '365T ${printerConfig.host}:${printerConfig.port}',
                icon: Icons.print_rounded,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutterMobile,
          AppSpacing.sm,
          AppSpacing.gutterMobile,
          AppSpacing.xl,
        ),
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: c.primary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'DIRECT 1-SCREEN INWARD',
                style: t.labelMedium?.copyWith(
                  color: c.primary,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),

          // Optional existing SKU matcher
          if (catalogNodes.isNotEmpty) ...[
            PasalCard(
              color: c.surfaceContainerHigh,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        selectedProductNode != null
                            ? Icons.check_circle_rounded
                            : Icons.add_box_outlined,
                        size: 16,
                        color: c.primary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          selectedProductNode != null
                              ? 'SKU CATALOG MATCHED'
                              : 'LINK TO EXISTING PRODUCT (OPTIONAL)',
                          style: t.labelSmall?.copyWith(
                            color: c.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (selectedProductNode != null && !formLockedAfterSave)
                        TextButton(
                          onPressed: () => _selectExistingProduct(null),
                          child: const Text('New Product'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String?>(
                    key: const ValueKey('intake-existing-product-dropdown'),
                    value: selectedProductNode?.product.id,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Parent Product',
                      isDense: true,
                    ),
                    items: <DropdownMenuItem<String?>>[
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('+ Create New Master Product'),
                      ),
                      ...catalogNodes.map(
                        (node) => DropdownMenuItem<String?>(
                          value: node.product.id,
                          child: Text(
                            '${node.product.name} (${node.product.brand})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                    onChanged: formLockedAfterSave
                        ? null
                        : (val) {
                            if (val == null) {
                              _selectExistingProduct(null);
                            } else {
                              final matched = catalogNodes.firstWhere(
                                (n) => n.product.id == val,
                              );
                              _selectExistingProduct(matched);
                            }
                          },
                  ),
                  if (selectedProductNode != null &&
                      selectedProductNode.variants.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String?>(
                      key: const ValueKey('intake-existing-variant-dropdown'),
                      value: selectedProductNode.variants.any(
                        (v) => v.variant.id == _selectedExistingVariantId,
                      )
                          ? _selectedExistingVariantId
                          : null,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Shade / Variant',
                        isDense: true,
                      ),
                      items: <DropdownMenuItem<String?>>[
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('+ Add New Shade / Size Variant'),
                        ),
                        ...selectedProductNode.variants.map(
                          (v) => DropdownMenuItem<String?>(
                            value: v.variant.id,
                            child: Text(
                              '${v.variant.variantName} (${v.totalStock} in stock)',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                      onChanged: formLockedAfterSave
                          ? null
                          : (val) {
                              setState(() {
                                if (val == null) {
                                  _selectedExistingVariantId = null;
                                } else {
                                  final v = selectedProductNode!.variants
                                      .firstWhere((e) => e.variant.id == val);
                                  _applyVariantFields(v);
                                }
                              });
                            },
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
          ],

          // Category selector pills driving dynamic form fields
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: SmartIntakeCategory.values.map((cat) {
              final active = cat == _category;
              final locked =
                  formLockedAfterSave || _selectedExistingProductId != null;
              return ChoiceChip(
                key: ValueKey('intake-category-${cat.name}'),
                selected: active,
                label: Text('${cat.emoji} ${cat.displayLabel}'),
                onSelected: locked
                    ? null
                    : (_) => setState(() {
                          _category = cat;
                          _error = null;
                        }),
                selectedColor: c.primary,
                backgroundColor: c.surfaceContainer,
                labelStyle: t.labelMedium?.copyWith(
                  color: active ? c.onPrimary : c.onSurfaceVariant,
                ),
              );
            }).toList(growable: false),
          ),
          const SizedBox(height: AppSpacing.md),

          // Smart Form Card
          PasalCard(
            color: c.surfaceContainerLow,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const ValueKey('intake-product-name'),
                  controller: _productNameCtrl,
                  enabled: !formLockedAfterSave &&
                      _selectedExistingProductId == null,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Product Name',
                    hintText: 'e.g. Maybelline Fit Me Matte Foundation',
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  key: const ValueKey('intake-brand'),
                  controller: _brandCtrl,
                  enabled: !formLockedAfterSave &&
                      _selectedExistingProductId == null,
                  decoration: const InputDecoration(
                    labelText: 'Brand',
                    hintText: 'e.g. Maybelline New York',
                  ),
                ),
                const SizedBox(height: AppSpacing.md),

                // Category-driven dynamic fields with synchronized AnimatedSize + crossfade
                AnimatedSize(
                  duration: AppMotion.resolveDuration(context, AppMotion.popover),
                  curve: AppMotion.easeOut,
                  alignment: Alignment.topCenter,
                  child: PasalBlurStateSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: Column(
                      key: ValueKey<SmartIntakeCategory>(_category),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Dynamic Section 1: Cosmetics Shades + Color Picker
                        if (_category.asksShadeColor) ...[
                          Text('SHADE & VISUAL COLOR DOT', style: t.labelMedium),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: InventoryDateUtils.parseHexColor(
                                        _selectedShadeHex,
                                      ) ??
                                      c.secondaryContainer,
                                  shape: BoxShape.circle,
                                  border:
                                      Border.all(color: c.hairline, width: 1.5),
                                ),
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              Expanded(
                                child: TextField(
                                  key: const ValueKey('intake-shade-name'),
                                  controller: _shadeNameCtrl,
                                  enabled: !formLockedAfterSave &&
                                      _selectedExistingVariantId == null,
                                  onChanged: (_) => setState(() {}),
                                  decoration: const InputDecoration(
                                    labelText: 'Shade Name / Code',
                                    hintText:
                                        'e.g. #128 Warm Nude or Velvet Teddy',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: kCosmeticShadeSwatches.map((swatch) {
                              final isSelected = swatch.hex.toUpperCase() ==
                                  _selectedShadeHex.toUpperCase();
                              final dotColor = InventoryDateUtils.parseHexColor(
                                  swatch.hex)!;
                              return Tooltip(
                                message: swatch.name,
                                child: InkWell(
                                  key: ValueKey('swatch-${swatch.hex}'),
                                  borderRadius:
                                      BorderRadius.circular(AppRadii.pill),
                                  onTap: formLockedAfterSave ||
                                          _selectedExistingVariantId != null
                                      ? null
                                      : () {
                                          setState(() {
                                            _selectedShadeHex = swatch.hex;
                                            if (_shadeNameCtrl.text
                                                .trim()
                                                .isEmpty) {
                                              _shadeNameCtrl.text = swatch.name;
                                            }
                                          });
                                        },
                                  child: Container(
                                    width: 34,
                                    height: 34,
                                    decoration: BoxDecoration(
                                      color: dotColor,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color:
                                            isSelected ? c.primary : c.hairline,
                                        width: isSelected ? 3 : 1,
                                      ),
                                    ),
                                    child: isSelected
                                        ? const Icon(
                                            Icons.check_rounded,
                                            size: 16,
                                            color: Colors.white,
                                          )
                                        : null,
                                  ),
                                ),
                              );
                            }).toList(growable: false),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          TextField(
                            key: const ValueKey('intake-size-optional'),
                            controller: _sizeVolumeCtrl,
                            enabled: !formLockedAfterSave &&
                                _selectedExistingVariantId == null,
                            decoration: const InputDecoration(
                              labelText: 'Pack Weight / Volume (Optional)',
                              hintText: 'e.g. 30ml or 3.0g',
                            ),
                          ),
                        ],

                        // Dynamic Section 2: Haircare / Skincare Volume + SPF/Skin Type
                        if (_category.asksSizeVolume) ...[
                          Text('BOTTLE SIZE / VOLUME', style: t.labelMedium),
                          const SizedBox(height: 6),
                          TextField(
                            key: const ValueKey('intake-size-volume'),
                            controller: _sizeVolumeCtrl,
                            enabled: !formLockedAfterSave &&
                                _selectedExistingVariantId == null,
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              labelText: _category == SmartIntakeCategory.haircare
                                  ? 'Bottle Size / Volume (ml / L)'
                                  : 'Tube / Bottle Size (ml / g)',
                              hintText: _category == SmartIntakeCategory.haircare
                                  ? 'e.g. 400ml'
                                  : 'e.g. 50ml',
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: (_category == SmartIntakeCategory.haircare
                                    ? kHaircareSizePresets
                                    : kSkincareSizePresets)
                                .map(
                                  (preset) => ActionChip(
                                    label: Text(preset),
                                    onPressed: formLockedAfterSave ||
                                            _selectedExistingVariantId != null
                                        ? null
                                        : () => setState(
                                              () => _sizeVolumeCtrl.text = preset,
                                            ),
                                  ),
                                )
                                .toList(growable: false),
                          ),
                        ],

                        if (_category.asksSpfAndSkin) ...[
                          const SizedBox(height: AppSpacing.md),
                          Text('SPF PROTECTION', style: t.labelMedium),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: kSpfPresets
                                .map(
                                  (spf) => ChoiceChip(
                                    key: ValueKey('intake-spf-$spf'),
                                    selected: _selectedSpf == spf,
                                    label: Text(spf),
                                    onSelected: formLockedAfterSave ||
                                            _selectedExistingVariantId != null
                                        ? null
                                        : (_) =>
                                            setState(() => _selectedSpf = spf),
                                  ),
                                )
                                .toList(growable: false),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text('SKIN TYPE TARGET', style: t.labelMedium),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: kSkinTypePresets
                                .map(
                                  (skin) => ChoiceChip(
                                    key: ValueKey('intake-skin-$skin'),
                                    selected: _selectedSkinType == skin,
                                    label: Text(skin),
                                    onSelected: formLockedAfterSave ||
                                            _selectedExistingVariantId != null
                                        ? null
                                        : (_) => setState(
                                            () => _selectedSkinType = skin),
                                  ),
                                )
                                .toList(growable: false),
                          ),
                        ],

                        if (_category.isGeneric) ...[
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: c.secondaryContainer.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(AppRadii.md),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.all_inclusive_rounded,
                                  size: 18,
                                  color: c.onSecondaryContainer,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Generic unpacked accessories omit shade pickers & expiry dates.',
                                    style: t.bodySmall
                                        ?.copyWith(color: c.onSecondaryContainer),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          TextField(
                            key: const ValueKey('intake-generic-label'),
                            controller: _genericLabelCtrl,
                            enabled: !formLockedAfterSave &&
                                _selectedExistingVariantId == null,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              labelText: 'Pack / Assortment Label',
                              hintText: 'Standard',
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                if (suppliers.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  DropdownButtonFormField<String?>(
                    key: const ValueKey('intake-supplier-dropdown'),
                    value: suppliers.any((s) => s.id == _selectedSupplierId)
                        ? _selectedSupplierId
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Supplier (Optional)',
                    ),
                    items: <DropdownMenuItem<String?>>[
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('No Supplier Linked'),
                      ),
                      ...suppliers.map(
                        (s) => DropdownMenuItem<String?>(
                          value: s.id,
                          child: Text(
                            s.panVat != null && s.panVat!.isNotEmpty
                                ? '${s.name} (PAN ${s.panVat})'
                                : s.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                    onChanged: formLockedAfterSave
                        ? null
                        : (v) => setState(() => _selectedSupplierId = v),
                  ),
                ],

                const SizedBox(height: AppSpacing.md),

                // Pricing row with strictly enforced Task 8.3 Owner-Only Cost Lock
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: canViewCost
                          ? TextField(
                              key: const ValueKey('intake-cost-price'),
                              controller: _costCtrl,
                              enabled: !formLockedAfterSave,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                labelText: 'Wholesale Cost',
                                prefixText: 'Rs. ',
                              ),
                            )
                          : Container(
                              key: const ValueKey('intake-cost-locked-box'),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 11,
                              ),
                              decoration: BoxDecoration(
                                color: c.surfaceContainerHigh,
                                borderRadius:
                                    BorderRadius.circular(AppRadii.md),
                                border: Border.all(color: c.hairline),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.lock_outline_rounded,
                                    size: 16,
                                    color: c.tertiary,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      'Cost Locked\n(Owner Only)',
                                      style: t.labelSmall?.copyWith(
                                        color: c.tertiary,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('intake-selling-price'),
                        controller: _mrpCtrl,
                        enabled: !formLockedAfterSave,
                        textInputAction: TextInputAction.next,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: 'Retail MRP',
                          prefixText: 'Rs. ',
                        ),
                      ),
                    ),
                  ],
                ),
                if (marginText != null) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: PasalStatusBadge(
                      label: marginText,
                      backgroundColor: isLossMargin ? c.errorContainer : null,
                      foregroundColor:
                          isLossMargin ? c.onErrorContainer : null,
                    ),
                  ),
                ],

                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('intake-lot-code'),
                        controller: _lotCtrl,
                        enabled: !formLockedAfterSave,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Lot / Batch Code',
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    if (_category.asksExpiry)
                      Expanded(
                        child: TextField(
                          key: const ValueKey('intake-expiry-date'),
                          controller: _expiryCtrl,
                          enabled: !formLockedAfterSave,
                          autocorrect: false,
                          enableSuggestions: false,
                          textInputAction: TextInputAction.next,
                          keyboardType: TextInputType.datetime,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            labelText: 'Exp (MM/YYYY)',
                            hintText: '05/2028',
                          ),
                        ),
                      )
                    else
                      Expanded(
                        child: TextField(
                          key: const ValueKey('intake-qty-generic'),
                          controller: _qtyCtrl,
                          enabled: !formLockedAfterSave,
                          textInputAction: TextInputAction.next,
                          keyboardType: TextInputType.number,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            labelText: 'Qty Inward',
                          ),
                        ),
                      ),
                  ],
                ),
                if (_category.asksExpiry) ...[
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    key: const ValueKey('intake-qty'),
                    controller: _qtyCtrl,
                    enabled: !formLockedAfterSave,
                    textInputAction: TextInputAction.next,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Qty Inward (Units)',
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('intake-sticker-barcode'),
                        controller: _barcodeCtrl,
                        enabled: !formLockedAfterSave,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: 'Sticker Barcode (TSPL Code 128)',
                          hintText: '01100024',
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton.filledTonal(
                      key: const ValueKey('intake-regen-barcode-btn'),
                      tooltip: 'Generate numeric Subset C barcode',
                      onPressed:
                          formLockedAfterSave ? null : _regenerateBarcode,
                      icon: const Icon(Icons.autorenew_rounded),
                    ),
                    const SizedBox(width: 4),
                    IconButton.filledTonal(
                      key: const ValueKey('intake-scan-barcode-btn'),
                      tooltip: 'Scan manufacturer barcode',
                      onPressed: formLockedAfterSave
                          ? null
                          : () async {
                              final scanned =
                                  await showBarcodeScannerSheet(context);
                              if (scanned != null && mounted) {
                                setState(() => _barcodeCtrl.text = scanned);
                              }
                            },
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: AppSpacing.md),

          // Label Style Toggle + Live Dual 62x20mm Preview
          SegmentedButton<TsplLabelStyle>(
            segments: const <ButtonSegment<TsplLabelStyle>>[
              ButtonSegment<TsplLabelStyle>(
                value: TsplLabelStyle.barcode128,
                icon: Icon(Icons.barcode_reader, size: 16),
                label: Text('Code 128 Label'),
              ),
              ButtonSegment<TsplLabelStyle>(
                value: TsplLabelStyle.qrSideBySide,
                icon: Icon(Icons.qr_code_2_rounded, size: 16),
                label: Text('QR Side Label'),
              ),
            ],
            selected: <TsplLabelStyle>{_labelStyle},
            onSelectionChanged: (s) => setState(() => _labelStyle = s.first),
          ),
          const SizedBox(height: AppSpacing.sm),
          PasalBlurStateSwitcher(
            duration: const Duration(milliseconds: 160),
            child: DualThermalLabelPreview(
              key: ValueKey<TsplLabelStyle>(_labelStyle),
              productName: _productNameCtrl.text,
              variantName: _resolvedVariantName(),
              stickerBarcode: _barcodeCtrl.text,
              sellingPricePaisa: mrpPaisa,
              expiryLabel:
                  _category.asksExpiry ? _expiryCtrl.text.trim() : 'Non-Exp',
              deviceCode: deviceCode,
              style: _labelStyle,
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.errorContainer,
                borderRadius: BorderRadius.circular(AppRadii.lg),
              ),
              child: Text(
                _error!,
                style: t.bodySmall?.copyWith(color: c.onErrorContainer),
              ),
            ),
          ],

          const SizedBox(height: AppSpacing.md),

          if (_savedResult != null && !_printSucceeded) ...[
            ElevatedButton.icon(
              key: const ValueKey('intake-retry-print-btn'),
              onPressed:
                  _submitting ? null : () => _dispatchLabels(_savedResult!),
              icon: const Icon(Icons.print_rounded),
              label: Text(
                'Retry Print ${_savedResult!.batch.stockQuantity} Labels',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton(
              onPressed: () {
                if (context.canPop()) {
                  context.pop(true);
                } else {
                  context.go('/inventory');
                }
              },
              child: const Text('Done (Keep Saved Without Printing)'),
            ),
          ] else ...[
            ElevatedButton.icon(
              key: const ValueKey('intake-save-and-print-btn'),
              onPressed:
                  _submitting ? null : () => _submit(printAfterSave: true),
              icon: _submitting
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.print_rounded),
              label: PasalBlurStateSwitcher(
                child: Text(
                  _submitting
                      ? 'Saving & Printing...'
                      : (qty > 200
                          ? 'Save Batch & Print 200 Labels (max/job)'
                          : 'Save Batch & Print ${qty > 0 ? qty : 1} Labels'),
                  key: ValueKey<bool>(_submitting),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton.icon(
              key: const ValueKey('intake-save-only-btn'),
              onPressed:
                  _submitting ? null : () => _submit(printAfterSave: false),
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save Inward Without Printing'),
            ),
          ],
        ],
      ),
    );
  }
}
