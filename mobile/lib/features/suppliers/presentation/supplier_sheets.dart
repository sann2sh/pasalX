import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/money.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../application/supplier_providers.dart';
import '../domain/supplier_models.dart';

/// Modal to add or edit a cosmetic distributor/supplier.
Future<SupplierRow?> showSupplierFormSheet(
  BuildContext context,
  WidgetRef ref, {
  SupplierRow? existing,
}) {
  return showPasalBottomSheet<SupplierRow>(
    context: context,
    useSafeArea: true,
    backgroundColor: context.pasalColors.surfaceContainerLowest,
    builder: (_) => _SupplierFormSheet(existing: existing, ref: ref),
  );
}

class _SupplierFormSheet extends StatefulWidget {
  const _SupplierFormSheet({required this.ref, this.existing});

  final WidgetRef ref;
  final SupplierRow? existing;

  @override
  State<_SupplierFormSheet> createState() => _SupplierFormSheetState();
}

class _SupplierFormSheetState extends State<_SupplierFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _panCtrl;
  late final TextEditingController _addressCtrl;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.existing?.name ?? '');
    _phoneCtrl = TextEditingController(text: widget.existing?.phone ?? '');
    _panCtrl = TextEditingController(text: widget.existing?.panVat ?? '');
    _addressCtrl = TextEditingController(text: widget.existing?.address ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _panCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final repo = widget.ref.read(supplierRepositoryProvider);
    final session = widget.ref.read(ramKeyHolderProvider).session;
    if (repo == null || session == null) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await repo.saveSupplier(
        role: session.role,
        existingId: widget.existing?.id,
        name: _nameCtrl.text,
        phone: _phoneCtrl.text,
        panVat: _panCtrl.text,
        address: _addressCtrl.text,
      );
      widget.ref.read(syncOutboxWorkerProvider).scheduleImmediateSync();
      if (mounted) Navigator.of(context).pop(saved);
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
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.existing == null ? 'Add Supplier' : 'Edit Supplier',
                style: t.headlineMedium,
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _nameCtrl,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Distributor / Supplier Name *',
                  hintText: 'e.g., Beauty Hub Nepal Pvt. Ltd.',
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Supplier name is required'
                    : null,
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _phoneCtrl,
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Phone',
                        hintText: '98XXXXXXXX',
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextFormField(
                      controller: _panCtrl,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'PAN / VAT No.',
                        hintText: '601234567',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              TextFormField(
                controller: _addressCtrl,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Address',
                  hintText: 'New Road, Kathmandu',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(_error!, style: t.bodySmall?.copyWith(color: c.error)),
              ],
              const SizedBox(height: AppSpacing.md),
              FilledButton(
                onPressed: _saving ? null : _submit,
                child: Text(_saving ? 'Saving...' : 'Save Supplier'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Modal to record a payment against a supplier (optionally linked to an invoice).
Future<bool?> showPaySupplierSheet(
  BuildContext context,
  WidgetRef ref, {
  required SupplierRow supplier,
  List<PurchaseInvoiceRow> openInvoices = const <PurchaseInvoiceRow>[],
  PurchaseInvoiceRow? preselectedInvoice,
}) {
  return showPasalBottomSheet<bool>(
    context: context,
    useSafeArea: true,
    backgroundColor: context.pasalColors.surfaceContainerLowest,
    builder: (_) => _PaySupplierSheet(
      ref: ref,
      supplier: supplier,
      openInvoices: openInvoices,
      preselectedInvoice: preselectedInvoice,
    ),
  );
}

class _PaySupplierSheet extends StatefulWidget {
  const _PaySupplierSheet({
    required this.ref,
    required this.supplier,
    required this.openInvoices,
    this.preselectedInvoice,
  });

  final WidgetRef ref;
  final SupplierRow supplier;
  final List<PurchaseInvoiceRow> openInvoices;
  final PurchaseInvoiceRow? preselectedInvoice;

  @override
  State<_PaySupplierSheet> createState() => _PaySupplierSheetState();
}

class _PaySupplierSheetState extends State<_PaySupplierSheet> {
  final _amountCtrl = TextEditingController();
  final _refCtrl = TextEditingController();
  String? _selectedInvoiceId;
  String _method = SupplierPaymentMethods.bankTransfer;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selectedInvoiceId = widget.preselectedInvoice?.id;
    final defaultPaisa =
        widget.preselectedInvoice?.dueAmount ?? widget.supplier.balanceDue;
    if (defaultPaisa > 0) {
      _amountCtrl.text = MoneyUtils.toDecimalString(defaultPaisa);
    }
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _refCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final repo = widget.ref.read(supplierRepositoryProvider);
    final session = widget.ref.read(ramKeyHolderProvider).session;
    if (repo == null || session == null) return;

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
      await repo.recordSupplierPayment(
        role: session.role,
        supplierId: widget.supplier.id,
        purchaseInvoiceId: _selectedInvoiceId,
        amountPaisa: paisa,
        paymentMethod: _method,
        referenceNo: _refCtrl.text,
        createdByUserId: session.userId,
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
    final unpaidInvoices =
        widget.openInvoices.where((i) => i.dueAmount > 0).toList();

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
            Text(
              'Pay Supplier',
              style: t.headlineMedium,
            ),
            const SizedBox(height: 4),
            Text(
              widget.supplier.name,
              style: t.titleMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpacing.xs),
            PasalTabularText(
              'Total Payable Due: ${MoneyUtils.formatRs(widget.supplier.balanceDue)}',
              style: t.bodySmall?.copyWith(color: c.secondary),
            ),
            const SizedBox(height: AppSpacing.md),
            if (unpaidInvoices.isNotEmpty) ...[
              DropdownButtonFormField<String?>(
                initialValue: _selectedInvoiceId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Against Invoice (Optional)',
                ),
                items: <DropdownMenuItem<String?>>[
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('General Account Payment'),
                  ),
                  ...unpaidInvoices.map(
                    (inv) => DropdownMenuItem<String?>(
                      value: inv.id,
                      child: Text(
                        '${inv.invoiceNo} — Due ${MoneyUtils.formatRs(inv.dueAmount)}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                onChanged: (val) {
                  setState(() {
                    _selectedInvoiceId = val;
                    if (val != null) {
                      final inv = unpaidInvoices.firstWhere((e) => e.id == val);
                      _amountCtrl.text = MoneyUtils.toDecimalString(inv.dueAmount);
                    }
                  });
                },
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            TextField(
              controller: _amountCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
              ],
              decoration: const InputDecoration(
                labelText: 'Payment Amount (Rs.) *',
                prefixText: 'Rs. ',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text('PAYMENT METHOD', style: t.labelSmall),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: SupplierPaymentMethods.all.map((method) {
                final selected = _method == method;
                return ChoiceChip(
                  label: Text(SupplierPaymentMethods.label(method)),
                  selected: selected,
                  onSelected: (_) => setState(() => _method = method),
                );
              }).toList(),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _refCtrl,
              decoration: const InputDecoration(
                labelText: 'Reference / Cheque / TXN ID',
                hintText: 'Optional reference number',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(_error!, style: t.bodySmall?.copyWith(color: c.error)),
            ],
            const SizedBox(height: AppSpacing.md),
            FilledButton(
              onPressed: _saving ? null : _submit,
              child: Text(_saving ? 'Recording...' : 'Confirm Payment'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Detail sheet showing a supplier's Purchase Invoices and Payment History.
Future<void> showSupplierDetailSheet(
  BuildContext context,
  WidgetRef ref, {
  required String supplierId,
}) {
  return showPasalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    backgroundColor: context.pasalColors.surfaceContainerLowest,
    builder: (_) => _SupplierDetailSheet(ref: ref, supplierId: supplierId),
  );
}

class _SupplierDetailSheet extends StatefulWidget {
  const _SupplierDetailSheet({required this.ref, required this.supplierId});

  final WidgetRef ref;
  final String supplierId;

  @override
  State<_SupplierDetailSheet> createState() => _SupplierDetailSheetState();
}

class _SupplierDetailSheetState extends State<_SupplierDetailSheet> {
  SupplierDetailBundle? _bundle;
  bool _loading = true;
  static final DateFormat _dtFmt = DateFormat('yyyy-MM-dd HH:mm');

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final repo = widget.ref.read(supplierRepositoryProvider);
    if (repo == null) return;
    final bundle = await repo.loadSupplierDetail(widget.supplierId);
    if (mounted) {
      setState(() {
        _bundle = bundle;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;

    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final bundle = _bundle;
    if (bundle == null) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Center(child: Text('Supplier not found.')),
      );
    }

    final s = bundle.supplier;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.78,
      minChildSize: 0.5,
      maxChildSize: 0.94,
      builder: (context, scrollCtrl) {
        return ListView(
          controller: scrollCtrl,
          padding: const EdgeInsets.all(AppSpacing.gutterMobile),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.name,
                        style: t.headlineMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (s.panVat != null || s.phone != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          [
                            if (s.panVat != null) 'PAN: ${s.panVat}',
                            if (s.phone != null) s.phone!,
                          ].join(' • '),
                          style: t.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                IconButton(
                  tooltip: 'Edit Supplier',
                  onPressed: () async {
                    final updated = await showSupplierFormSheet(
                      context,
                      widget.ref,
                      existing: s,
                    );
                    if (updated != null) await _reload();
                  },
                  icon: const Icon(Icons.edit_outlined),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            PasalCard(
              color: c.surfaceContainerLow,
              child: Row(
                children: [
                  Expanded(
                    child: _LedgerMetric(
                      label: 'PURCHASED',
                      value: MoneyUtils.formatRs(s.totalPurchased),
                    ),
                  ),
                  Expanded(
                    child: _LedgerMetric(
                      label: 'PAID',
                      value: MoneyUtils.formatRs(s.totalPaid),
                    ),
                  ),
                  Expanded(
                    child: _LedgerMetric(
                      label: 'BALANCE DUE',
                      value: MoneyUtils.formatRs(s.balanceDue),
                      highlightColor: s.balanceDue > 0 ? c.error : c.primary,
                    ),
                  ),
                ],
              ),
            ),
            if (s.balanceDue > 0) ...[
              const SizedBox(height: AppSpacing.sm),
              FilledButton.icon(
                onPressed: () async {
                  final paid = await showPaySupplierSheet(
                    context,
                    widget.ref,
                    supplier: s,
                    openInvoices: bundle.invoices,
                  );
                  if (paid == true) await _reload();
                },
                icon: const Icon(Icons.payments_outlined, size: 18),
                label: const Text('Pay Supplier'),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            Text('PURCHASE INVOICES (${bundle.invoices.length})', style: t.labelMedium),
            const SizedBox(height: AppSpacing.xs),
            if (bundle.invoices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Text('No purchase invoices recorded yet.', style: t.bodySmall),
              )
            else
              ...bundle.invoices.map(
                (inv) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: PasalCard(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                inv.invoiceNo,
                                style: t.titleSmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                '${inv.invoiceDate} • Total ${MoneyUtils.formatRs(inv.totalAmount)}',
                                style: t.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            PasalStatusBadge(
                              label: inv.status,
                              backgroundColor: inv.dueAmount == 0
                                  ? c.secondaryContainer
                                  : c.surfaceContainerHigh,
                              foregroundColor: inv.dueAmount == 0
                                  ? c.onSecondaryContainer
                                  : c.error,
                            ),
                            if (inv.dueAmount > 0) ...[
                              const SizedBox(height: 2),
                              PasalTabularText(
                                'Due ${MoneyUtils.formatRs(inv.dueAmount)}',
                                style: t.labelSmall?.copyWith(color: c.error),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: AppSpacing.md),
            Text('PAYMENT HISTORY (${bundle.payments.length})', style: t.labelMedium),
            const SizedBox(height: AppSpacing.xs),
            if (bundle.payments.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Text('No payments recorded yet.', style: t.bodySmall),
              )
            else
              ...bundle.payments.map(
                (p) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: PasalCard(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                SupplierPaymentMethods.label(p.paymentMethod),
                                style: t.titleSmall,
                              ),
                              Text(
                                _dtFmt.format(p.createdAt.toLocal()) +
                                    (p.referenceNo != null
                                        ? ' • Ref: ${p.referenceNo}'
                                        : ''),
                                style: t.bodySmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        PasalTabularText(
                          MoneyUtils.formatRs(p.amount),
                          style: t.titleSmall?.copyWith(color: c.primary),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _LedgerMetric extends StatelessWidget {
  const _LedgerMetric({
    required this.label,
    required this.value,
    this.highlightColor,
  });

  final String label;
  final String value;
  final Color? highlightColor;

  @override
  Widget build(BuildContext context) {
    final t = context.textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: t.labelSmall),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: PasalTabularText(
            value,
            style: t.titleMedium?.copyWith(color: highlightColor),
          ),
        ),
      ],
    );
  }
}

