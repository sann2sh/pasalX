import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/money.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../../core/router/shell_scaffold.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../application/pos_providers.dart';
import '../domain/pos_models.dart';

/// Screen 16: Dedicated Customer Khata & Shade Book screen (`/khata`).
class KhataLedgerScreen extends ConsumerStatefulWidget {
  const KhataLedgerScreen({super.key, this.initialCustomerId});

  final String? initialCustomerId;

  @override
  ConsumerState<KhataLedgerScreen> createState() => _KhataLedgerScreenState();
}

class _KhataLedgerScreenState extends ConsumerState<KhataLedgerScreen> {
  static final DateFormat _dateFmt = DateFormat('MMM dd, hh:mm a');
  final TextEditingController _searchCtrl = TextEditingController();

  String _query = '';
  String? _selectedCustomerId;
  CustomerProfileBundle? _bundle;
  bool _loadingBundle = false;

  @override
  void initState() {
    super.initState();
    _selectedCustomerId = widget.initialCustomerId;
    if (_selectedCustomerId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadBundle(_selectedCustomerId!);
      });
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadBundle(String customerId) async {
    final repo = ref.read(posRepositoryProvider);
    if (repo == null) return;
    setState(() {
      _selectedCustomerId = customerId;
      _loadingBundle = true;
    });
    final loaded = await repo.loadCustomerBundle(customerId);
    if (!mounted) return;
    setState(() {
      _bundle = loaded;
      _loadingBundle = false;
    });
  }

  Future<void> _showNewCustomerDialog() async {
    final repo = ref.read(posRepositoryProvider);
    if (repo == null) return;
    final role = ref.read(ramKeyHolderProvider).session?.role;

    final created = await showDialog<CustomerRow>(
      context: context,
      builder: (ctx) => _NewCustomerDialog(
        onSave: ({
          required String name,
          required String phone,
          required int creditLimitPaisa,
          required String favoriteShadeNotes,
        }) {
          return repo.createCustomer(
            name: name,
            phone: phone,
            favoriteShadeNotes: favoriteShadeNotes,
            creditLimitPaisa: creditLimitPaisa,
            role: role,
          );
        },
      ),
    );

    if (created != null && mounted) {
      ref.read(pasalAlertProvider).showSuccess('Added ${created.name} to Khata.');
      await _loadBundle(created.id);
    }
  }

  Future<void> _showReceivePaymentDialog(CustomerRow customer) async {
    final repo = ref.read(posRepositoryProvider);
    final session = ref.read(ramKeyHolderProvider).session;
    if (repo == null || session == null) return;

    final paid = await showDialog<bool>(
      context: context,
      builder: (ctx) => _ReceivePaymentDialog(
        customer: customer,
        onConfirm: ({required int amountPaisa, required String method}) {
          return repo.recordKhataRepayment(
            customerId: customer.id,
            amountPaisa: amountPaisa,
            paymentMethod: method,
            userId: session.userId,
          );
        },
      ),
    );

    if (paid == true && mounted) {
      ref.read(pasalAlertProvider).showSuccess('Khata payment recorded.');
      await _loadBundle(customer.id);
    }
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return 'KH';
    if (parts.length == 1) return parts[0].substring(0, parts[0].length >= 2 ? 2 : 1).toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final customersAsync = ref.watch(customerListProvider(_query));
    final customers = customersAsync.value ?? const <CustomerRow>[];

    // Auto-select first customer if none selected yet.
    if (_selectedCustomerId == null && customers.isNotEmpty && !_loadingBundle) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedCustomerId == null && customers.isNotEmpty) {
          _loadBundle(customers.first.id);
        }
      });
    }

    final bundle = _bundle;
    final customer = bundle?.customer;

    return Scaffold(
      backgroundColor: c.surface,
      appBar: const PasalStackAppBar(
        title: 'Customer Khata',
        subtitle: 'Credit & Shades',
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutterMobile,
          AppSpacing.gutterMobile,
          AppSpacing.gutterMobile,
          AppSpacing.xl,
        ),
        children: [
          // Search + New Customer
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _query = v.trim()),
                  decoration: const InputDecoration(
                    hintText: 'Search phone or name...',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              FilledButton.tonalIcon(
                onPressed: _showNewCustomerDialog,
                icon: const Icon(Icons.person_add_outlined, size: 18),
                label: const Text('New'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),

          // Customer Switcher Pills
          if (customers.isNotEmpty)
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: customers.length,
                separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.xs),
                itemBuilder: (ctx, i) {
                  final cust = customers[i];
                  final selected = cust.id == _selectedCustomerId;
                  return ChoiceChip(
                    label: Text(cust.name),
                    selected: selected,
                    onSelected: (_) => _loadBundle(cust.id),
                  );
                },
              ),
            ),
          const SizedBox(height: AppSpacing.md),

          if (customersAsync.isLoading && customers.isEmpty)
            const Center(child: CircularProgressIndicator())
          else if (customers.isEmpty)
            PasalCard(
              child: Column(
                children: [
                  Icon(Icons.menu_book_rounded, size: 36, color: c.outline),
                  const SizedBox(height: AppSpacing.xs),
                  Text('No Khata Customers Found', style: t.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Tap "New" to create a customer Khata & shade profile.',
                    style: t.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            )
          else if (_loadingBundle && customer == null)
            const Center(child: CircularProgressIndicator())
          else if (customer != null && bundle != null) ...[
            // Hero Customer Profile Card
            PasalCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: c.primary,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          _initials(customer.name),
                          style: t.titleSmall?.copyWith(color: c.onPrimary),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(customer.name, style: t.titleMedium),
                            PasalTabularText(
                              customer.phone,
                              style: t.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      PasalStatusBadge(
                        label: customer.currentBalanceDue > 0
                            ? 'Khata Active'
                            : 'Settled',
                        backgroundColor: c.secondaryContainer,
                        foregroundColor: c.onSecondaryContainer,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),

                  // Saved Shade History
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: c.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'SAVED SHADE HISTORY',
                          style: t.labelSmall?.copyWith(color: c.primary),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        if (bundle.shades.isEmpty &&
                            (customer.favoriteShadeNotes?.isEmpty ?? true))
                          Text(
                            'No shades saved yet.',
                            style: t.bodySmall,
                          )
                        else
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              if (customer.favoriteShadeNotes != null &&
                                  customer.favoriteShadeNotes!.trim().isNotEmpty)
                                Chip(
                                  label: Text(customer.favoriteShadeNotes!),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ...bundle.shades.map(
                                (s) => Chip(
                                  label: Text(
                                    '${s.productName} • ${s.shadeVariant}',
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  const Divider(height: 1),
                  const SizedBox(height: AppSpacing.sm),

                  // Outstanding Due + Receive Payment
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('OUTSTANDING KHATA DUE', style: t.labelSmall),
                            PasalTabularText(
                              MoneyUtils.formatRs(customer.currentBalanceDue),
                              style: t.titleLarge?.copyWith(
                                color: customer.currentBalanceDue > 0
                                    ? c.error
                                    : c.primary,
                              ),
                            ),
                            PasalTabularText(
                              'Limit ${MoneyUtils.formatRs(customer.creditLimit)}',
                              style: t.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: customer.currentBalanceDue > 0
                            ? () => _showReceivePaymentDialog(customer)
                            : null,
                        icon: const Icon(Icons.payments_outlined, size: 18),
                        label: const Text('Receive Payment'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),

            // Ledger History
            Text('LEDGER HISTORY', style: t.labelMedium),
            const SizedBox(height: AppSpacing.xs),
            if (bundle.recentTransactions.isEmpty)
              PasalCard(
                child: Text(
                  'No Khata transactions recorded yet.',
                  style: t.bodySmall,
                ),
              )
            else
              ...bundle.recentTransactions.map((txn) {
                final isDebit = txn.type == 'DEBIT_PURCHASE';
                final title = isDebit
                    ? 'Credit Purchase${txn.referenceBillNo != null ? ' • ${txn.referenceBillNo}' : ''}'
                    : 'Khata Payment${txn.paymentMethod != null ? ' (${txn.paymentMethod})' : ''}';
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: PasalCard(
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title, style: t.titleSmall),
                              Text(
                                [
                                  _dateFmt.format(txn.createdAt.toLocal()),
                                  if (txn.notes != null &&
                                      txn.notes!.trim().isNotEmpty)
                                    txn.notes!,
                                ].join(' • '),
                                style: t.bodySmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        PasalTabularText(
                          '${isDebit ? '+' : '-'} ${MoneyUtils.formatRs(txn.amount)}',
                          style: t.titleSmall?.copyWith(
                            color: isDebit ? c.error : c.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
          ],
        ],
      ),
    );
  }
}

class _NewCustomerDialog extends StatefulWidget {
  const _NewCustomerDialog({required this.onSave});

  final Future<CustomerRow> Function({
    required String name,
    required String phone,
    required int creditLimitPaisa,
    required String favoriteShadeNotes,
  }) onSave;

  @override
  State<_NewCustomerDialog> createState() => _NewCustomerDialogState();
}

class _NewCustomerDialogState extends State<_NewCustomerDialog> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  final _limitCtrl = TextEditingController(text: '10000');
  String? _errorText;
  bool _saving = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _notesCtrl.dispose();
    _limitCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New Khata Customer'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Full Name *',
                hintText: 'e.g. Sita Sharma',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone Number *',
                hintText: '98XXXXXXXX',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _limitCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Credit Limit (Rs.)',
                hintText: '10000',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _notesCtrl,
              decoration: const InputDecoration(
                labelText: 'Favorite Shades (Optional)',
                hintText: 'e.g. Fit Me #128, Ruby Woo',
              ),
            ),
            if (_errorText != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                _errorText!,
                style: TextStyle(color: context.pasalColors.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving
              ? null
              : () async {
                  setState(() {
                    _saving = true;
                    _errorText = null;
                  });
                  try {
                    final limitRs =
                        int.tryParse(_limitCtrl.text.trim()) ?? 10000;
                    final row = await widget.onSave(
                      name: _nameCtrl.text,
                      phone: _phoneCtrl.text,
                      creditLimitPaisa: limitRs * 100,
                      favoriteShadeNotes: _notesCtrl.text,
                    );
                    if (context.mounted) Navigator.of(context).pop(row);
                  } catch (e) {
                    if (mounted) {
                      setState(() {
                        _saving = false;
                        _errorText = e.toString();
                      });
                    }
                  }
                },
          child: Text(_saving ? 'Saving...' : 'Save Customer'),
        ),
      ],
    );
  }
}

class _ReceivePaymentDialog extends StatefulWidget {
  const _ReceivePaymentDialog({
    required this.customer,
    required this.onConfirm,
  });

  final CustomerRow customer;
  final Future<CustomerTransactionRow> Function({
    required int amountPaisa,
    required String method,
  }) onConfirm;

  @override
  State<_ReceivePaymentDialog> createState() => _ReceivePaymentDialogState();
}

class _ReceivePaymentDialogState extends State<_ReceivePaymentDialog> {
  late final TextEditingController _amountCtrl;
  String _method = 'CASH';
  String? _errorText;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _amountCtrl = TextEditingController(
      text: (widget.customer.currentBalanceDue / 100).toStringAsFixed(0),
    );
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Receive Khata Payment • ${widget.customer.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Outstanding Due: ${MoneyUtils.formatRs(widget.customer.currentBalanceDue)}',
            style: context.textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _amountCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Amount Received (Rs.)',
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'CASH', label: Text('Cash')),
              ButtonSegment(value: 'FONEPAY_QR', label: Text('Fonepay QR')),
            ],
            selected: {_method},
            onSelectionChanged: (v) => setState(() => _method = v.first),
          ),
          if (_errorText != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              _errorText!,
              style: TextStyle(color: context.pasalColors.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed:
              _submitting ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submitting
              ? null
              : () async {
                  final paisa = MoneyUtils.tryParseToPaisa(_amountCtrl.text);
                  if (paisa == null || paisa <= 0) {
                    setState(() => _errorText = 'Enter a valid amount.');
                    return;
                  }
                  setState(() {
                    _submitting = true;
                    _errorText = null;
                  });
                  try {
                    await widget.onConfirm(
                      amountPaisa: paisa,
                      method: _method,
                    );
                    if (context.mounted) Navigator.of(context).pop(true);
                  } catch (e) {
                    if (mounted) {
                      setState(() {
                        _submitting = false;
                        _errorText = e.toString();
                      });
                    }
                  }
                },
          child: Text(_submitting ? 'Saving...' : 'Confirm Payment'),
        ),
      ],
    );
  }
}
