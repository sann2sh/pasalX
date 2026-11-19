import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/money.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../application/pos_providers.dart';
import '../domain/pos_models.dart';

/// Result of 2-step Generic Quick-Pad entry (custom selling price + quantity).
@immutable
class QuickPadEntryResult {
  const QuickPadEntryResult({
    required this.batch,
    required this.unitPricePaisa,
    required this.quantity,
  });

  final PosScannedBatch batch;
  final int unitPricePaisa;
  final int quantity;
}

/// Opens the 2-step Custom Price & Quantity popup for a Generic item
/// (e.g., Hair Rubbers, Bangles, Pins).
Future<QuickPadEntryResult?> showQuickPadEntryDialog(
  BuildContext context,
  PosScannedBatch item,
) {
  return showPasalDialog<QuickPadEntryResult>(
    context: context,
    builder: (ctx) => _QuickPadEntryDialog(item: item),
  );
}

class _QuickPadEntryDialog extends StatefulWidget {
  const _QuickPadEntryDialog({required this.item});

  final PosScannedBatch item;

  @override
  State<_QuickPadEntryDialog> createState() => _QuickPadEntryDialogState();
}

class _QuickPadEntryDialogState extends State<_QuickPadEntryDialog> {
  late final TextEditingController _priceCtrl;
  int _qty = 1;
  String? _error;

  @override
  void initState() {
    super.initState();
    final defaultRs = widget.item.sellingPricePaisa > 0
        ? (widget.item.sellingPricePaisa ~/ 100).toString()
        : '';
    _priceCtrl = TextEditingController(text: defaultRs);
  }

  @override
  void dispose() {
    _priceCtrl.dispose();
    super.dispose();
  }

  void _setQuickPrice(int rs) {
    setState(() {
      _priceCtrl.text = rs.toString();
      _error = null;
    });
  }

  void _submit() {
    final raw = _priceCtrl.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = 'Enter selling price');
      return;
    }
    try {
      final paisa = MoneyUtils.parseToPaisa(raw);
      if (paisa <= 0 || paisa > MoneyUtils.maxDecimal10_2Paisa) {
        setState(() => _error = 'Price must be greater than Rs. 0');
        return;
      }
      Navigator.of(context).pop(
        QuickPadEntryResult(
          batch: widget.item,
          unitPricePaisa: paisa,
          quantity: _qty,
        ),
      );
    } on FormatException {
      setState(() => _error = 'Invalid price format');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    int previewLineTotal = 0;
    try {
      final p = MoneyUtils.parseToPaisa(_priceCtrl.text.trim());
      if (p > 0) previewLineTotal = p * _qty;
    } catch (_) {}

    return AlertDialog(
      backgroundColor: c.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.xl),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.item.productName,
            style: t.titleLarge,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            'Generic Quick-Pad • Step 1: Price, Step 2: Qty',
            style: t.bodySmall,
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _priceCtrl,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
              ],
              decoration: InputDecoration(
                labelText: 'Selling Price (Rs.)',
                prefixText: 'Rs. ',
                errorText: _error,
              ),
              onChanged: (_) => setState(() => _error = null),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final rs in const [20, 50, 100, 150, 250])
                  ActionChip(
                    label: Text('Rs. $rs'),
                    onPressed: () => _setQuickPrice(rs),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(child: Text('Quantity', style: t.titleMedium)),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton.outlined(
                      visualDensity: VisualDensity.compact,
                      onPressed:
                          _qty > 1 ? () => setState(() => _qty -= 1) : null,
                      icon: const Icon(Icons.remove_rounded, size: 18),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: PasalTabularText(
                        '$_qty',
                        style: t.titleLarge,
                      ),
                    ),
                    IconButton.outlined(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _qty += 1),
                      icon: const Icon(Icons.add_rounded, size: 18),
                    ),
                  ],
                ),
              ],
            ),
            if (previewLineTotal > 0) ...[
              const SizedBox(height: AppSpacing.sm),
              PasalCard(
                color: c.surfaceContainerLow,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: Text('Line Total', style: t.bodySmall)),
                    const SizedBox(width: 8),
                    PasalTabularText(
                      MoneyUtils.formatRs(previewLineTotal),
                      style: t.titleMedium?.copyWith(color: c.primary),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.add_shopping_cart_rounded, size: 18),
          label: const Text('Add to Bill'),
        ),
      ],
    );
  }
}

/// 3x3 Quick-Pad Grid widget (instant tap, zero sluggish fade-ins).
class QuickPadGrid extends StatelessWidget {
  const QuickPadGrid({
    super.key,
    required this.items,
    required this.onItemSelected,
  });

  final List<PosScannedBatch> items;
  final ValueChanged<PosScannedBatch> onItemSelected;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;

    if (items.isEmpty) {
      return PasalCard(
        color: c.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            children: [
              Icon(Icons.grid_view_rounded, color: c.outline, size: 28),
              const SizedBox(height: 6),
              Text(
                'No Generic Quick-Pad items yet',
                style: t.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                'Add items under category "Generic" in Stock Intake to pin '
                'them to this 3x3 Quick-Pad.',
                style: t.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: items.length > 9 ? 9 : items.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: AppSpacing.xs,
        crossAxisSpacing: AppSpacing.xs,
        childAspectRatio: 1.15,
      ),
      itemBuilder: (context, index) {
        final item = items[index];
        return PasalPressable(
          haptic: PasalHaptic.selection,
          onTap: () => onItemSelected(item),
          borderRadius: BorderRadius.circular(AppRadii.md),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: c.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(color: c.hairline),
            ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.auto_awesome_rounded,
                    size: 18,
                    color: c.primary,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.productName,
                    style: t.labelMedium?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 2),
                  PasalTabularText(
                    item.sellingPricePaisa > 0
                        ? MoneyUtils.formatRs(item.sellingPricePaisa)
                        : 'Custom Rs.',
                    style: t.labelSmall?.copyWith(color: c.primary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
          ),
        );
      },
    );
  }
}

/// Screen 10: Dedicated Accessories Quick-Pad (3x3 visual grid + bottom numeric
/// price keypad + quantity stepper + Add to Bill).
class QuickPadScreen extends ConsumerStatefulWidget {
  const QuickPadScreen({super.key});

  @override
  ConsumerState<QuickPadScreen> createState() => _QuickPadScreenState();
}

class _QuickPadScreenState extends ConsumerState<QuickPadScreen> {
  PosScannedBatch? _selected;
  String _priceDigits = '0';
  int _qty = 1;

  void _selectItem(PosScannedBatch item) {
    final defaultRs = item.sellingPricePaisa > 0
        ? (item.sellingPricePaisa ~/ 100).toString()
        : '50';
    setState(() {
      _selected = item;
      _priceDigits = defaultRs;
      _qty = 1;
    });
  }

  void _tapDigit(String d) {
    setState(() {
      if (_priceDigits == '0') {
        _priceDigits = d;
      } else if (_priceDigits.length < 6) {
        _priceDigits += d;
      }
    });
  }

  void _tapClear() {
    setState(() => _priceDigits = '0');
  }

  void _tapBackspace() {
    setState(() {
      if (_priceDigits.length <= 1) {
        _priceDigits = '0';
      } else {
        _priceDigits = _priceDigits.substring(0, _priceDigits.length - 1);
      }
    });
  }

  int get _unitPricePaisa {
    final rs = int.tryParse(_priceDigits) ?? 0;
    return rs * 100;
  }

  int get _lineTotalPaisa => _unitPricePaisa * _qty;

  void _addToBill() {
    final item = _selected;
    if (item == null) {
      ref
          .read(pasalAlertProvider.notifier)
          .showWarning('Select an accessory tile first.');
      return;
    }
    final pricePaisa = _unitPricePaisa;
    if (pricePaisa <= 0 || pricePaisa > MoneyUtils.maxDecimal10_2Paisa) {
      ref
          .read(pasalAlertProvider.notifier)
          .showWarning('Enter a selling price greater than Rs. 0.');
      return;
    }
    HapticFeedback.lightImpact();
    ref.read(posCartProvider.notifier).addBatch(
          item,
          overrideUnitPricePaisa: pricePaisa,
          quantity: _qty,
        );
    ref.read(pasalAlertProvider.notifier).showSuccess(
          'Added $_qty × ${item.productName}',
        );
    Navigator.of(context).pop();
  }

  static IconData _iconForName(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('clip') || lower.contains('pin')) {
      return Icons.push_pin_outlined;
    }
    if (lower.contains('rubber') || lower.contains('band')) {
      return Icons.radio_button_unchecked_rounded;
    }
    if (lower.contains('mirror')) return Icons.crop_portrait_rounded;
    if (lower.contains('comb') || lower.contains('brush')) {
      return Icons.brush_rounded;
    }
    if (lower.contains('puff') || lower.contains('blender')) {
      return Icons.spa_outlined;
    }
    if (lower.contains('bindi')) return Icons.brightness_1_outlined;
    return Icons.auto_awesome_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final quickPadAsync = ref.watch(quickPadItemsProvider);

    return Scaffold(
      backgroundColor: c.surface,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Accessories Quick-Pad'),
            Text(
              'Unmarked Items',
              style: t.bodySmall?.copyWith(color: c.primary),
            ),
          ],
        ),
      ),
      body: quickPadAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load Quick-Pad: $e')),
        data: (items) {
          if (items.isNotEmpty &&
              (_selected == null ||
                  !items.any((i) => i.batchId == _selected!.batchId))) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _selected == null) {
                _selectItem(items.first);
              }
            });
          }

          final visible = items.take(9).toList(growable: false);

          return Column(
            children: [
              Expanded(
                child: visible.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.lg),
                          child: PasalCard(
                            color: c.surfaceContainerLow,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.grid_view_rounded,
                                  color: c.outline,
                                  size: 32,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'No Generic Quick-Pad items yet',
                                  style: t.titleMedium,
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Add items under category "Generic" in '
                                  'Stock Intake to pin them to this 3x3 grid.',
                                  style: t.bodySmall,
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(AppSpacing.gutterMobile),
                        itemCount: visible.length,
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: AppSpacing.xs,
                          crossAxisSpacing: AppSpacing.xs,
                          childAspectRatio: 1.08,
                        ),
                        itemBuilder: (context, index) {
                          final item = visible[index];
                          final isSelected = _selected?.batchId == item.batchId;
                          return PasalPressable(
                            haptic: PasalHaptic.selection,
                            onTap: () => _selectItem(item),
                            borderRadius: BorderRadius.circular(AppRadii.md),
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: c.surfaceContainerLowest,
                                borderRadius:
                                    BorderRadius.circular(AppRadii.md),
                                border: Border.all(
                                  color: isSelected ? c.primary : c.hairline,
                                  width: isSelected ? 2 : 1,
                                ),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _iconForName(item.productName),
                                    size: 22,
                                    color: isSelected
                                        ? c.primary
                                        : c.onSurfaceVariant,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    item.productName,
                                    style: t.labelMedium?.copyWith(
                                      fontWeight: isSelected
                                          ? FontWeight.w700
                                          : FontWeight.w600,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 2),
                                  PasalTabularText(
                                    item.sellingPricePaisa > 0
                                        ? MoneyUtils.formatRs(
                                            item.sellingPricePaisa,
                                          )
                                        : 'Any Price',
                                    style: t.labelSmall?.copyWith(
                                      color: isSelected
                                          ? c.primary
                                          : c.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),

              // Bottom Docked Keypad
              Container(
                decoration: BoxDecoration(
                  color: c.surfaceContainerLowest,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(AppRadii.sheetTop),
                  ),
                  border: Border(top: BorderSide(color: c.hairline)),
                ),
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutterMobile,
                  AppSpacing.md,
                  AppSpacing.gutterMobile,
                  AppSpacing.md,
                ),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Selected item + Price + Qty Stepper
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: c.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(AppRadii.md),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${_selected?.productName ?? 'Select item'} '
                                    '• Unit Price',
                                    style: t.labelSmall,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  PasalTabularText(
                                    MoneyUtils.formatRs(_unitPricePaisa),
                                    style: t.titleLarge?.copyWith(
                                      color: c.primary,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: c.surfaceContainerLowest,
                                borderRadius: BorderRadius.circular(AppRadii.sm),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    onPressed: _qty > 1
                                        ? () => setState(() => _qty -= 1)
                                        : null,
                                    icon: const Icon(
                                      Icons.remove_rounded,
                                      size: 18,
                                    ),
                                  ),
                                  SizedBox(
                                    width: 24,
                                    child: PasalTabularText(
                                      '$_qty',
                                      textAlign: TextAlign.center,
                                      style: t.titleMedium,
                                    ),
                                  ),
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => setState(() => _qty += 1),
                                    icon: const Icon(
                                      Icons.add_rounded,
                                      size: 18,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),

                      // 3x4 Numeric Keypad
                      GridView.count(
                        crossAxisCount: 3,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 6,
                        crossAxisSpacing: 6,
                        childAspectRatio: 2.35,
                        children: [
                          for (final key in const [
                            '1',
                            '2',
                            '3',
                            '4',
                            '5',
                            '6',
                            '7',
                            '8',
                            '9',
                            'CLR',
                            '0',
                            '⌫',
                          ])
                            PasalPressable(
                              haptic: PasalHaptic.selection,
                              borderRadius: BorderRadius.circular(AppRadii.md),
                              onTap: () {
                                if (key == 'CLR') {
                                  _tapClear();
                                } else if (key == '⌫') {
                                  _tapBackspace();
                                } else {
                                  _tapDigit(key);
                                }
                              },
                              child: Container(
                                decoration: BoxDecoration(
                                  color: (key == 'CLR' || key == '⌫')
                                      ? c.surfaceContainer
                                      : c.surfaceContainerLow,
                                  borderRadius:
                                      BorderRadius.circular(AppRadii.md),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  key,
                                  style: (key == 'CLR' || key == '⌫')
                                      ? t.labelLarge?.copyWith(
                                          color: c.onSurfaceVariant,
                                        )
                                      : t.titleMedium?.copyWith(
                                          fontWeight: FontWeight.w700,
                                        ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.sm),

                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _selected == null ? null : _addToBill,
                          child: Text(
                            'Add to Bill (${MoneyUtils.formatRs(_lineTotalPaisa)})',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
