import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/money.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../../suppliers/application/supplier_providers.dart';
import '../../suppliers/domain/supplier_models.dart';

/// Modal sheet to log a petty cash / shop expense (e.g. Tea, Courier, Bags).
Future<bool?> showPettyExpenseSheet(
  BuildContext context,
  WidgetRef ref, {
  String? shiftId,
}) {
  return showPasalBottomSheet<bool>(
    context: context,
    useSafeArea: true,
    backgroundColor: context.pasalColors.surfaceContainerLowest,
    builder: (_) => _PettyExpenseSheet(ref: ref, shiftId: shiftId),
  );
}

class _PettyExpenseSheet extends StatefulWidget {
  const _PettyExpenseSheet({required this.ref, this.shiftId});

  final WidgetRef ref;
  final String? shiftId;

  @override
  State<_PettyExpenseSheet> createState() => _PettyExpenseSheetState();
}

class _PettyExpenseSheetState extends State<_PettyExpenseSheet> {
  final _titleCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _paidToCtrl = TextEditingController();
  String _category = ExpenseCategories.presets.first;
  String _method = ExpensePaymentMethods.cash;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _amountCtrl.dispose();
    _paidToCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final repo = widget.ref.read(supplierRepositoryProvider);
    final userId = widget.ref.read(ramKeyHolderProvider).session?.userId;
    if (repo == null || userId == null) return;

    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Expense description is required.');
      return;
    }
    final paisa = MoneyUtils.tryParseToPaisa(_amountCtrl.text);
    if (paisa == null || paisa <= 0) {
      setState(() => _error = 'Enter a valid amount greater than 0.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await repo.recordPettyExpense(
        category: _category,
        title: title,
        amountPaisa: paisa,
        paymentMethod: _method,
        paidTo: _paidToCtrl.text,
        shiftId: widget.shiftId,
        createdByUserId: userId,
      );
      widget.ref.read(syncOutboxWorkerProvider).scheduleImmediateSync();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.gutterMobile,
        AppSpacing.md,
        AppSpacing.gutterMobile,
        AppSpacing.md + bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Log Petty Expense', style: t.headlineMedium),
            const SizedBox(height: 4),
            Text(
              'Cash expenses automatically deduct from today\'s Single-Galla expected drawer.',
              style: t.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('CATEGORY', style: t.labelSmall),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: ExpenseCategories.presets.map((cat) {
                return ChoiceChip(
                  label: Text(cat),
                  selected: _category == cat,
                  onSelected: (_) => setState(() => _category = cat),
                );
              }).toList(),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _titleCtrl,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Expense Title / Note *',
                hintText: 'e.g., Staff tea & snacks / Pathao parcel',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _amountCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'^\d*\.?\d{0,2}'),
                      ),
                    ],
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Amount (Rs.) *',
                      prefixText: 'Rs. ',
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: TextField(
                    controller: _paidToCtrl,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'Paid To',
                      hintText: 'Optional',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text('PAYMENT SOURCE', style: t.labelSmall),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: ExpensePaymentMethods.all.map((method) {
                return ChoiceChip(
                  label: Text(ExpensePaymentMethods.label(method)),
                  selected: _method == method,
                  onSelected: (_) => setState(() => _method = method),
                );
              }).toList(),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(_error!, style: t.bodySmall?.copyWith(color: c.error)),
            ],
            const SizedBox(height: AppSpacing.md),
            FilledButton(
              onPressed: _saving ? null : _submit,
              child: Text(_saving ? 'Saving...' : 'Save Expense'),
            ),
          ],
        ),
      ),
    );
  }
}

