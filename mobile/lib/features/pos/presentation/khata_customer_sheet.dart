import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/money.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../auth/application/auth_session_controller.dart';
import '../application/pos_providers.dart';
import '../data/pos_repository.dart';
import '../domain/pos_models.dart';

final DateFormat _txnDateFmt = DateFormat('dd MMM, HH:mm');

/// Opens the Customer Shade Profile & Khata Credit Ledger sheet.
///
/// When [selectionMode] is true, tapping "Attach to Bill" returns the chosen
/// [CustomerRow]. Staff can also tap "Add Previous Shade" on any recorded shade
/// profile to add that item directly into the POS cart.
Future<CustomerRow?> showKhataCustomerSheet(
  BuildContext context, {
  bool selectionMode = true,
  ValueChanged<PosScannedBatch>? onAddShadeBatchToCart,
}) {
  return showModalBottomSheet<CustomerRow>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _KhataCustomerSheet(
      selectionMode: selectionMode,
      onAddShadeBatchToCart: onAddShadeBatchToCart,
    ),
  );
}

class _KhataCustomerSheet extends ConsumerStatefulWidget {
  const _KhataCustomerSheet({
    required this.selectionMode,
    this.onAddShadeBatchToCart,
  });

  final bool selectionMode;
  final ValueChanged<PosScannedBatch>? onAddShadeBatchToCart;

  @override
  ConsumerState<_KhataCustomerSheet> createState() =>
      _KhataCustomerSheetState();
}

class _KhataCustomerSheetState extends ConsumerState<_KhataCustomerSheet> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  CustomerProfileBundle? _selectedBundle;
  bool _loadingBundle = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _openCustomerDetail(String customerId) async {
    final repo = ref.read(posRepositoryProvider);
    if (repo == null) return;
    setState(() => _loadingBundle = true);
    final bundle = await repo.loadCustomerBundle(customerId);
    if (!mounted) return;
    setState(() {
      _selectedBundle = bundle;
      _loadingBundle = false;
    });
  }

  Future<void> _showNewCustomerDialog() async {
    final repo = ref.read(posRepositoryProvider);
    if (repo == null) return;
    final role = ref.read(ramKeyHolderProvider).session?.role;
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    String? errorText;

    final created = await showDialog<CustomerRow>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('New Khata Customer'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Full Name *',
                        hintText: 'e.g. Sita Sharma',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextField(
                      controller: phoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone Number *',
                        hintText: '98XXXXXXXX',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextField(
                      controller: notesCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Favorite Shades (Optional)',
                        hintText: 'e.g. Fit Me #128, Ruby Woo',
                      ),
                    ),
                    if (errorText != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        errorText!,
                        style: TextStyle(color: ctx.pasalColors.error),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    try {
                      final c = await repo.createCustomer(
                        name: nameCtrl.text,
                        phone: phoneCtrl.text,
                        favoriteShadeNotes: notesCtrl.text,
                        role: role,
                      );
                      if (ctx.mounted) Navigator.of(ctx).pop(c);
                    } on PosValidationException catch (e) {
                      setLocal(() => errorText = e.message);
                    }
                  },
                  child: const Text('Save Customer'),
                ),
              ],
            );
          },
        );
      },
    );

    nameCtrl.dispose();
    phoneCtrl.dispose();
    notesCtrl.dispose();

    if (created != null && mounted) {
      await _openCustomerDetail(created.id);
    }
  }

  Future<void> _showRepaymentDialog(CustomerRow customer) async {
    final repo = ref.read(posRepositoryProvider);
    final auth = ref.read(authSessionControllerProvider).state;
    final userId =
        (ref.read(ramKeyHolderProvider).session ?? auth.session)?.userId;
    if (repo == null || userId == null) return;

    final amtCtrl = TextEditingController(
      text: customer.currentBalanceDue > 0
          ? MoneyUtils.toDecimalString(customer.currentBalanceDue)
          : '',
    );
    var method = 'CASH';
    String? errorText;

    final paid = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: Text('Record Repayment • ${customer.name}'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Current Due: ${MoneyUtils.formatRs(customer.currentBalanceDue)}',
                      style: ctx.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextField(
                      controller: amtCtrl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'^\d*\.?\d{0,2}'),
                        ),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Repayment Amount (Rs.)',
                        prefixText: 'Rs. ',
                        errorText: errorText,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'CASH', label: Text('Cash')),
                        ButtonSegment(
                          value: 'FONEPAY_QR',
                          label: Text('Fonepay QR'),
                        ),
                      ],
                      selected: {method},
                      onSelectionChanged: (s) =>
                          setLocal(() => method = s.first),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    try {
                      final paisa = MoneyUtils.parseToPaisa(amtCtrl.text);
                      await repo.recordKhataRepayment(
                        customerId: customer.id,
                        amountPaisa: paisa,
                        paymentMethod: method,
                        userId: userId,
                        shiftId: auth.activeShift?.id,
                      );
                      if (ctx.mounted) Navigator.of(ctx).pop(true);
                    } on FormatException {
                      setLocal(() => errorText = 'Enter a valid amount.');
                    } on PosValidationException catch (e) {
                      setLocal(() => errorText = e.message);
                    }
                  },
                  child: const Text('Confirm Repayment'),
                ),
              ],
            );
          },
        );
      },
    );

    amtCtrl.dispose();
    if (paid == true && mounted) {
      await _openCustomerDetail(customer.id);
    }
  }

  Future<void> _showAddShadeDialog(CustomerRow customer) async {
    final repo = ref.read(posRepositoryProvider);
    if (repo == null) return;

    final prodCtrl = TextEditingController();
    final brandCtrl = TextEditingController();
    final shadeCtrl = TextEditingController();
    String? errorText;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('Save Shade Profile'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: prodCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Product Name *',
                        hintText: 'e.g. Fit Me Matte Foundation',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextField(
                      controller: brandCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Brand',
                        hintText: 'e.g. Maybelline',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextField(
                      controller: shadeCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Shade / Variant *',
                        hintText: 'e.g. #128 Warm Nude',
                      ),
                    ),
                    if (errorText != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        errorText!,
                        style: TextStyle(color: ctx.pasalColors.error),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    try {
                      await repo.addCustomerShadeProfile(
                        customerId: customer.id,
                        productName: prodCtrl.text,
                        brand: brandCtrl.text,
                        shadeVariant: shadeCtrl.text,
                      );
                      if (ctx.mounted) Navigator.of(ctx).pop(true);
                    } on PosValidationException catch (e) {
                      setLocal(() => errorText = e.message);
                    }
                  },
                  child: const Text('Save Shade'),
                ),
              ],
            );
          },
        );
      },
    );

    prodCtrl.dispose();
    brandCtrl.dispose();
    shadeCtrl.dispose();

    if (saved == true && mounted) {
      await _openCustomerDetail(customer.id);
    }
  }

  Future<void> _addPreviousShadeToCart(CustomerShadeProfileRow profile) async {
    final repo = ref.read(posRepositoryProvider);
    final role = ref.read(ramKeyHolderProvider).session?.role;
    if (repo == null) return;

    final match = await repo.findBestBatchForShadeProfile(profile, role: role);
    if (!mounted) return;
    if (match == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'No active batch found for ${profile.productName} (${profile.shadeVariant}).',
          ),
        ),
      );
      return;
    }

    if (widget.onAddShadeBatchToCart != null) {
      widget.onAddShadeBatchToCart!(match);
    } else {
      ref.read(posCartProvider.notifier).addBatch(match);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Added ${match.productName} • ${match.variantName} to cart.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final customersAsync = ref.watch(customerListProvider(_query));

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.55,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollCtrl) {
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
          child: Column(
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
                  if (_selectedBundle != null)
                    IconButton(
                      onPressed: () => setState(() => _selectedBundle = null),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selectedBundle == null
                              ? 'Khata & Shade Lookup'
                              : _selectedBundle!.customer.name,
                          style: t.titleLarge,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          _selectedBundle == null
                              ? 'Search by phone or name'
                              : _selectedBundle!.customer.phone,
                          style: t.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (_selectedBundle == null)
                    TextButton.icon(
                      onPressed: _showNewCustomerDialog,
                      icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                      label: const Text('New'),
                    ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              if (_loadingBundle)
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_selectedBundle != null)
                Expanded(
                  child: _CustomerDetailView(
                    bundle: _selectedBundle!,
                    scrollCtrl: scrollCtrl,
                    selectionMode: widget.selectionMode,
                    onAttachToBill: () =>
                        Navigator.of(context).pop(_selectedBundle!.customer),
                    onRecordRepayment: () =>
                        _showRepaymentDialog(_selectedBundle!.customer),
                    onAddShadeProfile: () =>
                        _showAddShadeDialog(_selectedBundle!.customer),
                    onAddPreviousShade: _addPreviousShadeToCart,
                  ),
                )
              else ...[
                TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search_rounded),
                    hintText: 'Phone (98...) or customer name',
                    suffixIcon: _query.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _query = '');
                            },
                          )
                        : null,
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
                const SizedBox(height: AppSpacing.sm),
                Expanded(
                  child: customersAsync.when(
                    data: (customers) {
                      if (customers.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'No customers found',
                                style: t.titleMedium,
                              ),
                              const SizedBox(height: 6),
                              OutlinedButton.icon(
                                onPressed: _showNewCustomerDialog,
                                icon: const Icon(Icons.person_add_rounded),
                                label: const Text('Create Khata Customer'),
                              ),
                            ],
                          ),
                        );
                      }
                      return ListView.separated(
                        controller: scrollCtrl,
                        itemCount: customers.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: AppSpacing.xs),
                        itemBuilder: (context, idx) {
                          final cust = customers[idx];
                          final hasDue = cust.currentBalanceDue > 0;
                          return PasalCard(
                            color: c.surfaceContainerLow,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: InkWell(
                              onTap: () => _openCustomerDetail(cust.id),
                              child: Row(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: c.secondaryContainer,
                                    foregroundColor: c.onSecondaryContainer,
                                    child: Text(
                                      cust.name.isNotEmpty
                                          ? cust.name[0].toUpperCase()
                                          : '?',
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          cust.name,
                                          style: t.titleMedium,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Text(
                                          cust.favoriteShadeNotes?.isNotEmpty ==
                                                  true
                                              ? '${cust.phone} • ${cust.favoriteShadeNotes}'
                                              : cust.phone,
                                          style: t.bodySmall,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      PasalTabularText(
                                        MoneyUtils.formatRs(
                                          cust.currentBalanceDue,
                                        ),
                                        style: t.titleMedium?.copyWith(
                                          color:
                                              hasDue ? c.error : c.primary,
                                        ),
                                      ),
                                      Text(
                                        hasDue ? 'Due' : 'Clear',
                                        style: t.labelSmall,
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(child: Text('Error: $e')),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _CustomerDetailView extends StatelessWidget {
  const _CustomerDetailView({
    required this.bundle,
    required this.scrollCtrl,
    required this.selectionMode,
    required this.onAttachToBill,
    required this.onRecordRepayment,
    required this.onAddShadeProfile,
    required this.onAddPreviousShade,
  });

  final CustomerProfileBundle bundle;
  final ScrollController scrollCtrl;
  final bool selectionMode;
  final VoidCallback onAttachToBill;
  final VoidCallback onRecordRepayment;
  final VoidCallback onAddShadeProfile;
  final ValueChanged<CustomerShadeProfileRow> onAddPreviousShade;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final cust = bundle.customer;

    return ListView(
      controller: scrollCtrl,
      children: [
        PasalCard(
          color: c.surfaceContainerLow,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('KHATA BALANCE DUE', style: t.labelSmall),
                        const SizedBox(height: 2),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: PasalTabularText(
                            MoneyUtils.formatRs(cust.currentBalanceDue),
                            style: t.headlineMedium?.copyWith(
                              color: cust.currentBalanceDue > 0
                                  ? c.error
                                  : c.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('CREDIT LIMIT', style: t.labelSmall),
                      const SizedBox(height: 2),
                      PasalTabularText(
                        MoneyUtils.formatRs(cust.creditLimit),
                        style: t.titleMedium,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  if (selectionMode) ...[
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 10,
                          ),
                          minimumSize: const Size(0, 42),
                        ),
                        onPressed: onAttachToBill,
                        icon: const Icon(Icons.person_pin_rounded, size: 16),
                        label: const Text(
                          'Attach to Bill',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                  ],
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 10,
                        ),
                        minimumSize: const Size(0, 42),
                      ),
                      onPressed: onRecordRepayment,
                      icon: const Icon(Icons.payments_outlined, size: 16),
                      label: const Text(
                        'Repayment',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(child: Text('SHADE HISTORY', style: t.labelMedium)),
            TextButton.icon(
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: onAddShadeProfile,
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('Save Shade'),
            ),
          ],
        ),
        if (bundle.shades.isEmpty)
          PasalCard(
            color: c.surfaceContainerLow,
            child: Text(
              cust.favoriteShadeNotes?.isNotEmpty == true
                  ? 'Notes: ${cust.favoriteShadeNotes}'
                  : 'No recorded shade profiles yet.',
              style: t.bodySmall,
            ),
          )
        else
          for (final shade in bundle.shades) ...[
            PasalCard(
              color: c.surfaceContainerLow,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${shade.brand} • ${shade.productName}',
                          style: t.titleSmall,
                        ),
                        Text(
                          'Shade: ${shade.shadeVariant}',
                          style: t.bodySmall?.copyWith(
                            color: c.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      minimumSize: const Size(0, 38),
                    ),
                    onPressed: () => onAddPreviousShade(shade),
                    child: const Text('Add Previous Shade'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
        const SizedBox(height: AppSpacing.md),
        Text('KHATA LEDGER', style: t.labelMedium),
        const SizedBox(height: AppSpacing.xs),
        if (bundle.recentTransactions.isEmpty)
          PasalCard(
            color: c.surfaceContainerLow,
            child: Text('No Khata transactions yet.', style: t.bodySmall),
          )
        else
          for (final txn in bundle.recentTransactions) ...[
            PasalCard(
              color: c.surfaceContainerLow,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          txn.type == 'CREDIT_REPAYMENT'
                              ? 'Repayment (${txn.paymentMethod ?? 'CASH'})'
                              : 'Credit Purchase ${txn.referenceBillNo ?? ''}',
                          style: t.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          _txnDateFmt.format(txn.createdAt.toLocal()),
                          style: t.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      PasalTabularText(
                        '${txn.type == 'CREDIT_REPAYMENT' ? '-' : '+'}${MoneyUtils.formatRs(txn.amount)}',
                        style: t.titleMedium?.copyWith(
                          color: txn.type == 'CREDIT_REPAYMENT'
                              ? c.primary
                              : c.error,
                        ),
                      ),
                      PasalTabularText(
                        'Bal: ${MoneyUtils.formatRs(txn.balanceAfter)}',
                        style: t.labelSmall,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
      ],
    );
  }
}
