import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/printer/printer.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../application/inventory_providers.dart';
import '../domain/catalog_models.dart';
import 'dual_label_preview.dart';

/// Opens the Stitch Inventory Control bottom sheet for fast batch stock adjustment.
Future<bool?> showStockAdjustmentSheet(
  BuildContext context, {
  required ProductRow product,
  required ProductVariantRow variant,
  required BatchRow batch,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _StockAdjustmentSheet(
      product: product,
      variant: variant,
      batch: batch,
    ),
  );
}

class _StockAdjustmentSheet extends ConsumerStatefulWidget {
  const _StockAdjustmentSheet({
    required this.product,
    required this.variant,
    required this.batch,
  });

  final ProductRow product;
  final ProductVariantRow variant;
  final BatchRow batch;

  @override
  ConsumerState<_StockAdjustmentSheet> createState() =>
      _StockAdjustmentSheetState();
}

class _StockAdjustmentSheetState extends ConsumerState<_StockAdjustmentSheet> {
  final TextEditingController _noteController = TextEditingController();
  StockAdjustmentReason _reason = StockAdjustmentReason.purchaseIntake;
  int _delta = 1;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  void _selectReason(StockAdjustmentReason reason) {
    setState(() {
      _reason = reason;
      _error = null;
      if (reason.expectedSign > 0 && _delta <= 0) {
        _delta = 1;
      } else if (reason.expectedSign < 0 && _delta >= 0) {
        _delta = widget.batch.stockQuantity > 0 ? -1 : 0;
      } else if (reason.expectedSign == 0 && _delta == 0) {
        _delta = 1;
      }
    });
  }

  void _stepDelta(int step) {
    setState(() {
      _error = null;
      var next = _delta + step;
      if (_reason.expectedSign > 0 && next < 1) {
        next = 1;
      } else if (_reason.expectedSign < 0 && next > -1) {
        next = -1;
      } else if (_reason.expectedSign == 0 && next == 0) {
        next = step > 0 ? 1 : -1;
      }
      if (widget.batch.stockQuantity + next < 0) {
        _error = 'Resulting stock cannot drop below 0 units.';
        return;
      }
      _delta = next;
    });
  }

  Future<void> _save() async {
    final repo = ref.read(inventoryRepositoryProvider);
    final session = ref.read(ramKeyHolderProvider).session;
    if (repo == null || session == null) {
      setState(() => _error = 'Encrypted vault is locked.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await repo.adjustBatchStock(
        batchId: widget.batch.id,
        reason: _reason,
        quantityDelta: _delta,
        actorRole: session.role,
        actorUserName: session.username,
        note: _noteController.text,
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString().replaceFirst(RegExp(r'^.*Exception:\s*'), '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final currentQty = widget.batch.stockQuantity;
    final projectedQty = currentQty + _delta;
    final canSave = !_saving && _delta != 0 && projectedQty >= 0;

    return Container(
      decoration: BoxDecoration(
        color: c.surfaceContainerLowest,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadii.sheetTop),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        AppSpacing.gutterMobile,
        AppSpacing.sm,
        AppSpacing.gutterMobile,
        AppSpacing.md + bottomInset,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: c.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'INVENTORY CONTROL',
                        style: t.labelSmall?.copyWith(
                          color: c.secondary,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.product.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.headlineSmall,
                      ),
                      Text(
                        '${widget.variant.variantName} • Lot ${widget.batch.batchCode}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppRadii.lg),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('STOCK UPDATE', style: t.labelSmall),
                        const SizedBox(height: 2),
                        PasalTabularText(
                          '$currentQty → $projectedQty units '
                          '(${_delta >= 0 ? "+$_delta" : "$_delta"})',
                          style: t.titleMedium?.copyWith(
                            color: projectedQty < 0 ? c.error : c.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _StepperButton(
                        key: const ValueKey('adjust-qty-decrement'),
                        icon: Icons.remove_rounded,
                        onPressed: _saving ? null : () => _stepDelta(-1),
                      ),
                      SizedBox(
                        width: 44,
                        child: Center(
                          child: PasalTabularText(
                            _delta >= 0 ? '+$_delta' : '$_delta',
                            style: t.titleLarge,
                          ),
                        ),
                      ),
                      _StepperButton(
                        key: const ValueKey('adjust-qty-increment'),
                        icon: Icons.add_rounded,
                        onPressed: _saving ? null : () => _stepDelta(1),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text('REASON FOR MODIFICATION', style: t.labelMedium),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: StockAdjustmentReason.values.map((reason) {
                final selected = reason == _reason;
                return ChoiceChip(
                  selected: selected,
                  label: Text(reason.label),
                  onSelected: _saving ? null : (_) => _selectReason(reason),
                  selectedColor: c.secondaryContainer,
                  backgroundColor: c.surfaceContainerLow,
                  labelStyle: t.labelMedium?.copyWith(
                    color: selected ? c.onSecondaryContainer : c.onSurface,
                  ),
                );
              }).toList(growable: false),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _noteController,
              enabled: !_saving,
              decoration: const InputDecoration(
                labelText: 'Note (Optional)',
                hintText: 'Shelf recount, broken seal, tester box...',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: c.errorContainer,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                ),
                child: Text(
                  _error!,
                  style: t.bodySmall?.copyWith(color: c.onErrorContainer),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        _saving ? null : () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: ElevatedButton(
                    key: const ValueKey('confirm-stock-adjustment-btn'),
                    onPressed: canSave ? _save : null,
                    child: _saving
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Save Update'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens a 1-tap dual 62x20mm TSPL sticker dispatch bottom sheet for a batch.
Future<void> showPrintLabelsSheet(
  BuildContext context, {
  required ProductRow product,
  required ProductVariantRow variant,
  required BatchRow batch,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _PrintLabelsSheet(
      product: product,
      variant: variant,
      batch: batch,
    ),
  );
}

class _PrintLabelsSheet extends ConsumerStatefulWidget {
  const _PrintLabelsSheet({
    required this.product,
    required this.variant,
    required this.batch,
  });

  final ProductRow product;
  final ProductVariantRow variant;
  final BatchRow batch;

  @override
  ConsumerState<_PrintLabelsSheet> createState() => _PrintLabelsSheetState();
}

class _PrintLabelsSheetState extends ConsumerState<_PrintLabelsSheet> {
  late int _copies;
  TsplLabelStyle _style = TsplLabelStyle.barcode128;
  bool _printing = false;
  String? _error;
  String? _successMsg;

  @override
  void initState() {
    super.initState();
    _copies = widget.batch.stockQuantity > 0
        ? widget.batch.stockQuantity.clamp(1, 50)
        : 2;
  }

  BatchLabelData _buildLabelData() {
    final expiryDt = InventoryDateUtils.parseIsoDate(widget.batch.expiryDate) ??
        DateTime(2099, 12, 31);
    return BatchLabelData(
      productName: widget.product.name,
      variantName: widget.variant.variantName,
      stickerBarcode: widget.batch.stickerBarcode,
      sellingPricePaisa: widget.batch.sellingPrice,
      expiryDate: expiryDt,
      batchCode: widget.batch.batchCode,
    );
  }

  Future<void> _dispatchPrint() async {
    final driver = ref.read(xlabPrinterDriverProvider);
    setState(() {
      _printing = true;
      _error = null;
      _successMsg = null;
    });
    try {
      await driver.printBatchCopies(
        _buildLabelData(),
        quantity: _copies,
        style: _style,
      );
      if (!mounted) return;
      setState(() {
        _printing = false;
        _successMsg = '$_copies sticker(s) sent to '
            '${driver.config.host}:${driver.config.port}';
      });
    } on PrinterException catch (e) {
      if (!mounted) return;
      setState(() {
        _printing = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _printing = false;
        _error = 'Printer dispatch failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final config = ref.watch(printerConfigProvider);
    final deviceCode =
        ref.watch(ramKeyHolderProvider).session?.deviceCode ?? '01';
    final expLabel =
        InventoryDateUtils.formatExpiryMmYyyy(widget.batch.expiryDate);

    return Container(
      decoration: BoxDecoration(
        color: c.surfaceContainerLowest,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadii.sheetTop),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        AppSpacing.gutterMobile,
        AppSpacing.sm,
        AppSpacing.gutterMobile,
        AppSpacing.md + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: c.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('TSPL STICKER PRINT', style: t.labelSmall),
                      Text(
                        '${widget.product.name} • ${widget.variant.variantName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.titleLarge,
                      ),
                    ],
                  ),
                ),
                PasalStatusBadge(
                  label: '${config.host}:${config.port}',
                  icon: Icons.print_rounded,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            SegmentedButton<TsplLabelStyle>(
              segments: const <ButtonSegment<TsplLabelStyle>>[
                ButtonSegment<TsplLabelStyle>(
                  value: TsplLabelStyle.barcode128,
                  icon: Icon(Icons.barcode_reader, size: 16),
                  label: Text('Code 128'),
                ),
                ButtonSegment<TsplLabelStyle>(
                  value: TsplLabelStyle.qrSideBySide,
                  icon: Icon(Icons.qr_code_2_rounded, size: 16),
                  label: Text('QR Side'),
                ),
              ],
              selected: <TsplLabelStyle>{_style},
              onSelectionChanged: (s) {
                setState(() => _style = s.first);
              },
            ),
            const SizedBox(height: AppSpacing.md),
            DualThermalLabelPreview(
              productName: widget.product.name,
              variantName: widget.variant.variantName,
              stickerBarcode: widget.batch.stickerBarcode,
              sellingPricePaisa: widget.batch.sellingPrice,
              expiryLabel: expLabel,
              deviceCode: deviceCode,
              style: _style,
            ),
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: c.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppRadii.lg),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('STICKER COPIES', style: t.labelSmall),
                        Text(
                          '${(_copies + 1) ~/ 2} dual row(s) on 62×20mm roll',
                          style: t.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  _StepperButton(
                    icon: Icons.remove_rounded,
                    onPressed: _printing || _copies <= 1
                        ? null
                        : () => setState(() => _copies--),
                  ),
                  SizedBox(
                    width: 44,
                    child: Center(
                      child: PasalTabularText('$_copies', style: t.titleLarge),
                    ),
                  ),
                  _StepperButton(
                    icon: Icons.add_rounded,
                    onPressed: _printing || _copies >= 200
                        ? null
                        : () => setState(() => _copies++),
                  ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: c.errorContainer,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                ),
                child: Text(
                  _error!,
                  style: t.bodySmall?.copyWith(color: c.onErrorContainer),
                ),
              ),
            ],
            if (_successMsg != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: c.secondaryContainer,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                ),
                child: Text(
                  _successMsg!,
                  style: t.bodySmall?.copyWith(color: c.onSecondaryContainer),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            ElevatedButton.icon(
              key: const ValueKey('dispatch-tspl-print-btn'),
              onPressed: _printing ? null : _dispatchPrint,
              icon: _printing
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.print_rounded),
              label: Text('Print $_copies Barcode Labels'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StepperButton extends StatelessWidget {
  const _StepperButton({
    super.key,
    required this.icon,
    required this.onPressed,
  });

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    return Material(
      color: c.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(color: c.hairline),
          ),
          child: Icon(
            icon,
            size: 18,
            color: onPressed == null ? c.outline : c.onSurface,
          ),
        ),
      ),
    );
  }
}
