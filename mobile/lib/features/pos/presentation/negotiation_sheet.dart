import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/database/money.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../domain/pos_models.dart';

/// Opens the 4-tier Negotiation Sheet (5%, 10%, 15%, Flat Rs. 100, plus
/// optional custom flat discount) and returns the selected [PosDiscount].
Future<PosDiscount?> showNegotiationSheet(
  BuildContext context, {
  required int subtotalPaisa,
  required PosDiscount initialDiscount,
}) {
  return showModalBottomSheet<PosDiscount>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _NegotiationSheet(
      subtotalPaisa: subtotalPaisa,
      initialDiscount: initialDiscount,
    ),
  );
}

class _NegotiationSheet extends StatefulWidget {
  const _NegotiationSheet({
    required this.subtotalPaisa,
    required this.initialDiscount,
  });

  final int subtotalPaisa;
  final PosDiscount initialDiscount;

  @override
  State<_NegotiationSheet> createState() => _NegotiationSheetState();
}

class _NegotiationSheetState extends State<_NegotiationSheet> {
  late PosDiscount _selected;
  late final TextEditingController _customCtrl;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialDiscount;
    _customCtrl = TextEditingController(
      text: widget.initialDiscount.tier == DiscountTier.custom &&
              widget.initialDiscount.customAmountPaisa > 0
          ? MoneyUtils.toDecimalString(widget.initialDiscount.customAmountPaisa)
          : '',
    );
  }

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  void _selectTier(DiscountTier tier) {
    setState(() {
      _selected = PosDiscount(tier: tier);
      if (tier != DiscountTier.custom) {
        _customCtrl.clear();
      }
    });
  }

  void _onCustomChanged(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      setState(() => _selected = const PosDiscount.none());
      return;
    }
    try {
      final paisa = MoneyUtils.parseToPaisa(trimmed);
      setState(() {
        _selected = PosDiscount(
          tier: DiscountTier.custom,
          customAmountPaisa: paisa < 0 ? 0 : paisa,
        );
      });
    } on FormatException {
      // Wait for valid decimal input.
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final discountPaisa = _selected.computeDiscountPaisa(widget.subtotalPaisa);
    final netTotalPaisa = widget.subtotalPaisa - discountPaisa;

    const tiers = <({DiscountTier tier, String title, String subtitle})>[
      (
        tier: DiscountTier.percent5,
        title: '5% OFF',
        subtitle: 'Loyalty Nudge',
      ),
      (
        tier: DiscountTier.percent10,
        title: '10% OFF',
        subtitle: 'Bundle / Shade',
      ),
      (
        tier: DiscountTier.percent15,
        title: '15% OFF',
        subtitle: 'VIP Goodwill',
      ),
      (
        tier: DiscountTier.flat100,
        title: 'Flat Rs. 100',
        subtitle: 'Round-off',
      ),
    ];

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
                      Text('Negotiation & Discount', style: t.titleLarge),
                      Text(
                        '4-Tier Counter Allowance',
                        style: t.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: AppSpacing.sm,
              crossAxisSpacing: AppSpacing.sm,
              childAspectRatio: 1.85,
              children: [
                for (final item in tiers)
                  _TierButton(
                    title: item.title,
                    subtitle: item.subtitle,
                    savingsText:
                        '-${MoneyUtils.formatRs(PosDiscount(tier: item.tier).computeDiscountPaisa(widget.subtotalPaisa))}',
                    selected: _selected.tier == item.tier,
                    onTap: () => _selectTier(item.tier),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _customCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
              ],
              decoration: const InputDecoration(
                labelText: 'Custom Flat Discount (Rs.)',
                hintText: 'e.g. 150',
                prefixText: 'Rs. ',
              ),
              onChanged: _onCustomChanged,
            ),
            const SizedBox(height: AppSpacing.md),
            PasalCard(
              color: c.surfaceContainerLow,
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                children: [
                  _SummaryRow(
                    label: 'Cart Subtotal',
                    value: MoneyUtils.formatRs(widget.subtotalPaisa),
                  ),
                  const SizedBox(height: 6),
                  _SummaryRow(
                    label: 'Discount (${_selected.label})',
                    value: '-${MoneyUtils.formatRs(discountPaisa)}',
                    valueColor: discountPaisa > 0 ? c.primary : null,
                  ),
                  const Divider(height: 16),
                  _SummaryRow(
                    label: 'Net Payable',
                    value: MoneyUtils.formatRs(netTotalPaisa),
                    bold: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () =>
                        Navigator.of(context).pop(const PosDiscount.none()),
                    child: const Text('Remove Discount'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(_selected),
                    child: const Text('Apply Discount'),
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

class _TierButton extends StatelessWidget {
  const _TierButton({
    required this.title,
    required this.subtitle,
    required this.savingsText,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final String savingsText;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.lg),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? c.secondaryContainer : c.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          border: Border.all(
            color: selected ? c.primary : c.hairline,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: t.titleMedium?.copyWith(
                      color: selected ? c.onSecondaryContainer : c.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 4),
                PasalTabularText(
                  savingsText,
                  style: t.labelMedium?.copyWith(
                    color: c.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: t.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.value,
    this.valueColor,
    this.bold = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final t = context.textTheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            label,
            style: bold ? t.titleMedium : t.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        PasalTabularText(
          value,
          style: (bold ? t.titleLarge : t.bodyMedium)?.copyWith(
            color: valueColor,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// Result returned by Screen 9 (`showItemNegotiationSheet`).
@immutable
class ItemNegotiationResult {
  const ItemNegotiationResult.update({
    required this.unitPricePaisa,
    required this.quantity,
    required this.itemDiscountPaisa,
  }) : removed = false;

  const ItemNegotiationResult.remove()
      : removed = true,
        unitPricePaisa = 0,
        quantity = 0,
        itemDiscountPaisa = 0;

  final bool removed;
  final int unitPricePaisa;
  final int quantity;
  final int itemDiscountPaisa;
}

/// Screen 9: Item Details & Negotiation (POS private — never displays Wholesale
/// Cost or Profit Margin, even for Owner).
Future<ItemNegotiationResult?> showItemNegotiationSheet(
  BuildContext context, {
  required PosCartItem item,
}) {
  return showModalBottomSheet<ItemNegotiationResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _ItemNegotiationSheet(item: item),
  );
}

enum _ItemDiscKind { none, pct5, pct10, pct15, flat50, flat100 }

class _ItemNegotiationSheet extends StatefulWidget {
  const _ItemNegotiationSheet({required this.item});

  final PosCartItem item;

  @override
  State<_ItemNegotiationSheet> createState() => _ItemNegotiationSheetState();
}

class _ItemNegotiationSheetState extends State<_ItemNegotiationSheet> {
  late final TextEditingController _priceCtrl;
  late int _qty;
  _ItemDiscKind _discKind = _ItemDiscKind.none;
  int _customExistingDiscount = 0;

  @override
  void initState() {
    super.initState();
    _qty = widget.item.quantity;
    _priceCtrl = TextEditingController(
      text: MoneyUtils.toDecimalString(widget.item.unitPricePaisa),
    );
    _customExistingDiscount = widget.item.itemDiscountPaisa;
  }

  @override
  void dispose() {
    _priceCtrl.dispose();
    super.dispose();
  }

  int get _unitPricePaisa {
    final raw = _priceCtrl.text.trim();
    if (raw.isEmpty) return 0;
    try {
      final p = MoneyUtils.parseToPaisa(raw);
      return p < 0 ? 0 : p;
    } on FormatException {
      return widget.item.unitPricePaisa;
    }
  }

  int get _grossLinePaisa => _unitPricePaisa * _qty;

  int get _discountPaisa {
    final gross = _grossLinePaisa;
    if (gross <= 0) return 0;
    final raw = switch (_discKind) {
      _ItemDiscKind.none => _customExistingDiscount,
      _ItemDiscKind.pct5 => (gross * 5) ~/ 100,
      _ItemDiscKind.pct10 => (gross * 10) ~/ 100,
      _ItemDiscKind.pct15 => (gross * 15) ~/ 100,
      _ItemDiscKind.flat50 => 5000,
      _ItemDiscKind.flat100 => 10000,
    };
    return raw > gross ? gross : raw;
  }

  int get _finalTotalPaisa {
    final net = _grossLinePaisa - _discountPaisa;
    return net < 0 ? 0 : net;
  }

  Color? _parseHex(String? hex) {
    if (hex == null || hex.trim().isEmpty) return null;
    final clean = hex.trim().replaceFirst('#', '');
    if (clean.length != 6) return null;
    final val = int.tryParse(clean, radix: 16);
    if (val == null) return null;
    return Color(0xFF000000 | val);
  }

  void _resetMrp() {
    setState(() {
      _priceCtrl.text = MoneyUtils.toDecimalString(widget.item.mrpPaisa);
      _discKind = _ItemDiscKind.none;
      _customExistingDiscount = 0;
    });
  }

  void _selectDisc(_ItemDiscKind kind) {
    setState(() {
      _discKind = kind;
      _customExistingDiscount = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final swatchColor = _parseHex(widget.item.colorHex) ?? c.secondaryContainer;
    final gross = _grossLinePaisa;
    final disc = _discountPaisa;
    final finalTotal = _finalTotalPaisa;

    const chips = <(_ItemDiscKind, String)>[
      (_ItemDiscKind.none, 'None'),
      (_ItemDiscKind.pct5, '5% Off'),
      (_ItemDiscKind.pct10, '10% Off'),
      (_ItemDiscKind.pct15, '15% Off'),
      (_ItemDiscKind.flat50, 'Rs. 50'),
      (_ItemDiscKind.flat100, 'Rs. 100'),
    ];

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
                  child: Text('Edit Cart Item', style: t.titleLarge),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),

            // Product Header Card (no Cost or Margin)
            PasalCard(
              color: c.surfaceContainerLow,
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: swatchColor,
                      borderRadius: BorderRadius.circular(AppRadii.md),
                      border: Border.all(color: c.hairline),
                    ),
                    alignment: Alignment.center,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(AppRadii.sm),
                      ),
                      child: Text(
                        widget.item.variantName.length > 6
                            ? widget.item.variantName.substring(0, 6)
                            : widget.item.variantName,
                        style: t.labelSmall?.copyWith(
                          color: c.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'BATCH ${widget.item.batchCode}',
                          style: t.labelSmall?.copyWith(
                            color: c.primary,
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          widget.item.productName,
                          style: t.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${widget.item.variantName}'
                          '${widget.item.sizeVolume != null ? ' • ${widget.item.sizeVolume}' : ''}'
                          ' • ${widget.item.availableStock} in stock',
                          style: t.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),

            // Editable Unit Price + Reset MRP
            PasalCard(
              color: c.surfaceContainerLowest,
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          'SELLING PRICE (EDITABLE)',
                          style: t.labelLarge,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _resetMrp,
                        icon: const Icon(Icons.restart_alt_rounded, size: 16),
                        label: const Text('Reset MRP'),
                      ),
                    ],
                  ),
                  TextField(
                    controller: _priceCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'^\d*\.?\d{0,2}'),
                      ),
                    ],
                    style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                    decoration: const InputDecoration(
                      prefixText: 'Rs. ',
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),

            // Quantity Stepper
            PasalCard(
              color: c.surfaceContainerLowest,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('QUANTITY', style: t.labelLarge),
                        Text(
                          '${widget.item.availableStock} units available',
                          style: t.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: c.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(AppRadii.md),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton.filledTonal(
                          visualDensity: VisualDensity.compact,
                          onPressed:
                              _qty > 1 ? () => setState(() => _qty -= 1) : null,
                          icon: const Icon(Icons.remove_rounded, size: 18),
                        ),
                        SizedBox(
                          width: 34,
                          child: PasalTabularText(
                            '$_qty',
                            textAlign: TextAlign.center,
                            style: t.titleMedium,
                          ),
                        ),
                        IconButton.filledTonal(
                          visualDensity: VisualDensity.compact,
                          onPressed: () => setState(() => _qty += 1),
                          icon: const Icon(Icons.add_rounded, size: 18),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),

            // Quick Discount Chips
            PasalCard(
              color: c.surfaceContainerLowest,
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('QUICK DISCOUNT', style: t.labelLarge),
                  const SizedBox(height: AppSpacing.xs),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final chip in chips)
                        ChoiceChip(
                          label: Text(chip.$2),
                          selected: _discKind == chip.$1,
                          onSelected: (_) => _selectDisc(chip.$1),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),

            // Final Line Total Summary
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: c.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(AppRadii.lg),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('FINAL LINE TOTAL', style: t.labelMedium),
                        Text(
                          disc > 0
                              ? '${MoneyUtils.formatRs(gross)} - '
                                  '${MoneyUtils.formatRs(disc)} discount'
                              : '$_qty × ${MoneyUtils.formatRs(_unitPricePaisa)}',
                          style: t.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: PasalTabularText(
                      MoneyUtils.formatRs(finalTotal),
                      style: t.headlineMedium?.copyWith(
                        color: c.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),

            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                ItemNegotiationResult.update(
                  unitPricePaisa: _unitPricePaisa,
                  quantity: _qty,
                  itemDiscountPaisa: disc,
                ),
              ),
              child: const Text('Done & Update Cart'),
            ),
            const SizedBox(height: AppSpacing.xs),
            TextButton(
              onPressed: () => Navigator.of(context).pop(
                const ItemNegotiationResult.remove(),
              ),
              style: TextButton.styleFrom(foregroundColor: c.error),
              child: const Text('Remove Item From Cart'),
            ),
          ],
        ),
      ),
    );
  }
}
