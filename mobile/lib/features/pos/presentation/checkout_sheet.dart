import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/money.dart';
import '../../../core/printer/printer_providers.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../application/pos_providers.dart';
import '../data/pos_repository.dart';
import '../domain/pos_models.dart';
import 'khata_customer_sheet.dart';

enum CheckoutTab { cash, fonepay, khata, card, split }

@immutable
class CheckoutSheetResult {
  const CheckoutSheetResult({
    required this.commit,
    required this.printRequested,
    required this.printed,
    this.printError,
  });

  final PosCheckoutCommitResult commit;
  final bool printRequested;
  final bool printed;
  final String? printError;
}

/// Opens the Checkout Sheet with Cash denomination helpers, Static Fonepay QR,
/// Khata Credit validation, and ESC/POS 80mm PAN-only receipt printing.
Future<CheckoutSheetResult?> showCheckoutSheet(
  BuildContext context, {
  CheckoutTab initialTab = CheckoutTab.cash,
}) {
  return showPasalBottomSheet<CheckoutSheetResult>(
    context: context,
    builder: (ctx) => _CheckoutSheet(initialTab: initialTab),
  );
}

class _CheckoutSheet extends ConsumerStatefulWidget {
  const _CheckoutSheet({this.initialTab = CheckoutTab.cash});

  final CheckoutTab initialTab;

  @override
  ConsumerState<_CheckoutSheet> createState() => _CheckoutSheetState();
}

class _CheckoutSheetState extends ConsumerState<_CheckoutSheet> {
  late CheckoutTab _tab;
  late final TextEditingController _cashCtrl;
  late final TextEditingController _splitCashCtrl;
  late final TextEditingController _splitDigitalCtrl;
  late final TextEditingController _qrRefCtrl;
  bool _qrConfirmed = false;
  bool _submitting = false;
  String? _error;

  static const String _staticFonepayPayload = 'FONEPAY:PASALCOSMETICS:NP';

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
    final net = ref.read(posCartProvider).netTotalPaisa;
    _cashCtrl = TextEditingController(text: MoneyUtils.toDecimalString(net));
    _splitCashCtrl = TextEditingController(text: '0.00');
    _splitDigitalCtrl = TextEditingController(
      text: MoneyUtils.toDecimalString(net),
    );
    _qrRefCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _cashCtrl.dispose();
    _splitCashCtrl.dispose();
    _splitDigitalCtrl.dispose();
    _qrRefCtrl.dispose();
    super.dispose();
  }

  int _parsePaisa(String text) {
    final clean = text.trim();
    if (clean.isEmpty) return 0;
    try {
      final p = MoneyUtils.parseToPaisa(clean);
      return p < 0 ? 0 : p;
    } on FormatException {
      return 0;
    }
  }

  void _setExactCash(int netTotalPaisa) {
    setState(() {
      _cashCtrl.text = MoneyUtils.toDecimalString(netTotalPaisa);
      _error = null;
    });
  }

  void _addDenomination(int addPaisa) {
    final current = _parsePaisa(_cashCtrl.text);
    setState(() {
      _cashCtrl.text = MoneyUtils.toDecimalString(current + addPaisa);
      _error = null;
    });
  }

  Future<void> _pickCustomer() async {
    final chosen = await showKhataCustomerSheet(
      context,
      selectionMode: true,
    );
    if (chosen != null && mounted) {
      ref.read(posCartProvider.notifier).selectCustomer(chosen);
      setState(() => _error = null);
    }
  }

  Future<void> _complete({required bool printReceipt}) async {
    if (_submitting) return;
    final cart = ref.read(posCartProvider);
    final net = cart.netTotalPaisa;
    if (cart.items.isEmpty) {
      setState(() => _error = 'Cart is empty.');
      return;
    }

    late String paymentMode;
    late List<PosPaymentLeg> legs;
    int? cashTendered;
    int? changeDue;
    String? qrPayload;

    switch (_tab) {
      case CheckoutTab.cash:
        if (net == 0) {
          paymentMode = 'CASH';
          cashTendered = 0;
          changeDue = 0;
          legs = const <PosPaymentLeg>[];
          break;
        }
        final tendered = _parsePaisa(_cashCtrl.text);
        if (tendered < net) {
          const msg = 'Cash tendered is less than net total.';
          ref.read(pasalAlertProvider.notifier).showError(msg);
          setState(() => _error = msg);
          return;
        }
        paymentMode = 'CASH';
        cashTendered = tendered;
        changeDue = tendered - net;
        legs = [PosPaymentLeg(method: 'CASH', amountPaisa: net)];
        break;
      case CheckoutTab.fonepay:
        if (net == 0) {
          paymentMode = 'CASH';
          legs = const <PosPaymentLeg>[];
          break;
        }
        if (!_qrConfirmed) {
          setState(
            () => _error = 'Please confirm Fonepay QR payment was received.',
          );
          return;
        }
        paymentMode = 'FONEPAY_QR';
        qrPayload = _staticFonepayPayload;
        legs = [
          PosPaymentLeg(
            method: 'FONEPAY_QR',
            amountPaisa: net,
            transactionRef: _qrRefCtrl.text.trim().isEmpty
                ? null
                : _qrRefCtrl.text.trim(),
          ),
        ];
        break;
      case CheckoutTab.khata:
        if (net == 0) {
          paymentMode = 'CASH';
          legs = const <PosPaymentLeg>[];
          break;
        }
        final cust = cart.selectedCustomer;
        if (cust == null) {
          setState(() => _error = 'Select a customer for Khata credit.');
          return;
        }
        if (cust.currentBalanceDue + net > cust.creditLimit) {
          setState(
            () => _error = 'Credit limit exceeded for ${cust.name}.',
          );
          return;
        }
        paymentMode = 'KHATA_CREDIT';
        legs = [PosPaymentLeg(method: 'KHATA_CREDIT', amountPaisa: net)];
        break;
      case CheckoutTab.card:
        if (net == 0) {
          paymentMode = 'CASH';
          legs = const <PosPaymentLeg>[];
          break;
        }
        paymentMode = 'CARD';
        legs = [PosPaymentLeg(method: 'CARD', amountPaisa: net)];
        break;
      case CheckoutTab.split:
        final cashPart = _parsePaisa(_splitCashCtrl.text);
        final digitalPart = _parsePaisa(_splitDigitalCtrl.text);
        if (cashPart + digitalPart != net) {
          setState(
            () => _error =
                'Split amounts must equal ${MoneyUtils.formatRs(net)}.',
          );
          return;
        }
        if (cashPart <= 0 || digitalPart <= 0) {
          setState(
            () => _error = 'Both Cash and Fonepay amounts must be > Rs. 0.',
          );
          return;
        }
        paymentMode = 'SPLIT';
        qrPayload = _staticFonepayPayload;
        legs = [
          PosPaymentLeg(method: 'CASH', amountPaisa: cashPart),
          PosPaymentLeg(method: 'FONEPAY_QR', amountPaisa: digitalPart),
        ];
        break;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final commit = await ref.read(posCartProvider.notifier).commitCheckout(
            payments: legs,
            paymentMode: paymentMode,
            cashTenderedPaisa: cashTendered,
            changeDuePaisa: changeDue,
            staticQrPayload: qrPayload,
          );

      var printed = false;
      String? printErr;
      if (printReceipt) {
        try {
          await ref
              .read(xlabPrinterDriverProvider)
              .printReceipt(commit.receiptData);
          printed = true;
        } catch (e) {
          printErr = e.toString();
        }
      }

      if (!mounted) return;
      Navigator.of(context).pop(
        CheckoutSheetResult(
          commit: commit,
          printRequested: printReceipt,
          printed: printed,
          printError: printErr,
        ),
      );
    } on PosValidationException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Checkout failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final cart = ref.watch(posCartProvider);
    final net = cart.netTotalPaisa;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return PopScope(
      canPop: !_submitting,
      child: Container(
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
                      Text('Counter Checkout', style: t.titleLarge),
                      Text(
                        '${cart.itemCount} items • Store PAN Bill • No VAT',
                        style: t.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: PasalTabularText(
                      MoneyUtils.formatRs(net),
                      style: t.headlineMedium?.copyWith(
                        color: c.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _submitting
                      ? null
                      : () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            // Customer Pill
            InkWell(
              onTap: _pickCustomer,
              borderRadius: BorderRadius.circular(AppRadii.md),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: c.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  border: Border.all(color: c.hairline),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: c.secondaryContainer,
                      child: Text(
                        cart.selectedCustomer != null
                            ? PasalTextUtils.initials(
                                cart.selectedCustomer!.name,
                                fallback: 'WI',
                              )
                            : 'WI',
                        style: t.labelSmall?.copyWith(
                          color: c.onSecondaryContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            cart.selectedCustomer?.name ?? 'Walk-in Customer',
                            style: t.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            cart.selectedCustomer != null
                                ? '${cart.selectedCustomer!.phone} • Khata Enabled'
                                : 'Tap to attach customer for Khata',
                            style: t.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Text(
                      'Change',
                      style: t.labelLarge?.copyWith(color: c.primary),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            // 3-Tab Payment Selector (Cash | Fonepay QR | Khata) with clip-path pill glide
            PasalClipSegmentedTabs<CheckoutTab>(
              selectedValue: _tab,
              onChanged: (tab) => setState(() {
                _tab = tab;
                _error = null;
              }),
              options: const [
                PasalSegmentOption(value: CheckoutTab.cash, label: 'Cash'),
                PasalSegmentOption(
                  value: CheckoutTab.fonepay,
                  label: 'Fonepay QR',
                ),
                PasalSegmentOption(value: CheckoutTab.khata, label: 'Khata'),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            AnimatedSize(
              duration: AppMotion.resolveDuration(context, AppMotion.popover),
              curve: AppMotion.easeOut,
              alignment: Alignment.topCenter,
              child: PasalBlurStateSwitcher(
                duration: const Duration(milliseconds: 150),
                child: KeyedSubtree(
                  key: ValueKey<CheckoutTab>(_tab),
                  child: switch (_tab) {
                    CheckoutTab.cash => _buildCashPanel(context, net),
                    CheckoutTab.fonepay => _buildFonepayPanel(context, net),
                    CheckoutTab.khata =>
                      _buildKhataPanel(context, net, cart.selectedCustomer),
                    CheckoutTab.card => _buildCardPanel(context, net),
                    CheckoutTab.split => _buildSplitPanel(context, net),
                  },
                ),
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
                  style: t.bodySmall?.copyWith(
                    color: c.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            PasalPressable(
              haptic: PasalHaptic.light,
              enabled: !_submitting,
              borderRadius: BorderRadius.circular(AppRadii.lg),
              onTap: _submitting ? null : () => _complete(printReceipt: true),
              child: FilledButton.icon(
                onPressed:
                    _submitting ? null : () => _complete(printReceipt: true),
                icon: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.print_rounded),
                label: PasalBlurStateSwitcher(
                  child: Text(
                    _submitting
                        ? 'Completing & Printing...'
                        : 'Complete Sale & Print Receipt',
                    key: ValueKey<bool>(_submitting),
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            PasalPressable(
              haptic: PasalHaptic.light,
              enabled: !_submitting,
              borderRadius: BorderRadius.circular(AppRadii.lg),
              onTap: _submitting ? null : () => _complete(printReceipt: false),
              child: OutlinedButton.icon(
                onPressed:
                    _submitting ? null : () => _complete(printReceipt: false),
                icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
                label: const Text('Complete Without Printing'),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildCashPanel(BuildContext context, int net) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final tendered = _parsePaisa(_cashCtrl.text);
    final diff = tendered - net;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _cashCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
          ],
          decoration: const InputDecoration(
            labelText: 'Cash Tendered (Rs.)',
            prefixText: 'Rs. ',
          ),
          onChanged: (_) => setState(() => _error = null),
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            ActionChip(
              label: const Text('Exact'),
              onPressed: () => _setExactCash(net),
            ),
            ActionChip(
              label: const Text('+Rs. 100'),
              onPressed: () => _addDenomination(10000),
            ),
            ActionChip(
              label: const Text('+Rs. 500'),
              onPressed: () => _addDenomination(50000),
            ),
            ActionChip(
              label: const Text('+Rs. 1,000'),
              onPressed: () => _addDenomination(100000),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: diff >= 0 ? c.secondaryContainer : c.errorContainer,
            borderRadius: BorderRadius.circular(AppRadii.lg),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  diff >= 0 ? 'CHANGE DUE' : 'SHORT BY',
                  style: t.labelLarge?.copyWith(
                    color: diff >= 0
                        ? c.onSecondaryContainer
                        : c.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: PasalTabularText(
                    MoneyUtils.formatRs(diff.abs()),
                    style: t.headlineMedium?.copyWith(
                      color: diff >= 0
                          ? c.onSecondaryContainer
                          : c.onErrorContainer,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFonepayPanel(BuildContext context, int net) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PasalCard(
          color: c.surfaceContainerLow,
          child: Column(
            children: [
              Container(
                width: 132,
                height: 132,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  border: Border.all(color: c.hairline),
                ),
                child: const _StaticQrGraphic(),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'STATIC FONEPAY QR • OFFLINE READY',
                style: t.labelSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              PasalTabularText(
                'Payable: ${MoneyUtils.formatRs(net)}',
                style: t.titleLarge?.copyWith(color: c.primary),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _qrRefCtrl,
          decoration: const InputDecoration(
            labelText: 'Fonepay Trace / Ref (Optional)',
            hintText: 'Last 4 digits or SMS ref',
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Material(
          type: MaterialType.transparency,
          child: SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Confirm QR Received'),
            subtitle: const Text('Verified merchant SMS / Fonepay alert'),
            value: _qrConfirmed,
            onChanged: (v) => setState(() {
              _qrConfirmed = v;
              _error = null;
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildKhataPanel(
    BuildContext context,
    int net,
    CustomerRow? customer,
  ) {
    final c = context.pasalColors;
    final t = context.textTheme;
    if (customer == null) {
      return PasalCard(
        color: c.surfaceContainerLow,
        child: Column(
          children: [
            Text('No customer attached to bill', style: t.titleMedium),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: _pickCustomer,
              icon: const Icon(Icons.person_search_rounded),
              label: const Text('Pick Khata Customer'),
            ),
          ],
        ),
      );
    }
    final projected = customer.currentBalanceDue + net;
    final withinLimit = projected <= customer.creditLimit;

    return PasalCard(
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
                    Text(customer.name, style: t.titleMedium),
                    Text(customer.phone, style: t.bodySmall),
                  ],
                ),
              ),
              TextButton(
                onPressed: _pickCustomer,
                child: const Text('Change'),
              ),
            ],
          ),
          const Divider(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Current Due', style: t.bodySmall),
              PasalTabularText(
                MoneyUtils.formatRs(customer.currentBalanceDue),
                style: t.bodyMedium,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Projected Due', style: t.bodySmall),
              PasalTabularText(
                MoneyUtils.formatRs(projected),
                style: t.titleMedium?.copyWith(
                  color: withinLimit ? c.primary : c.error,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Credit Limit', style: t.bodySmall),
              PasalTabularText(
                MoneyUtils.formatRs(customer.creditLimit),
                style: t.bodySmall,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCardPanel(BuildContext context, int net) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return PasalCard(
      color: c.surfaceContainerLow,
      child: Row(
        children: [
          Icon(Icons.credit_card_rounded, color: c.primary, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Charge ${MoneyUtils.formatRs(net)} on POS card terminal and '
              'tap Complete.',
              style: t.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSplitPanel(BuildContext context, int net) {
    return Column(
      children: [
        TextField(
          controller: _splitCashCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
          ],
          decoration: const InputDecoration(
            labelText: 'Cash Portion (Rs.)',
            prefixText: 'Rs. ',
          ),
          onChanged: (v) {
            final cashP = _parsePaisa(v).clamp(0, net);
            final rem = (net - cashP).clamp(0, net);
            _splitDigitalCtrl.text = MoneyUtils.toDecimalString(rem);
            setState(() => _error = null);
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _splitDigitalCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
          ],
          decoration: const InputDecoration(
            labelText: 'Fonepay QR Portion (Rs.)',
            prefixText: 'Rs. ',
          ),
          onChanged: (_) => setState(() => _error = null),
        ),
      ],
    );
  }
}

class _StaticQrGraphic extends StatelessWidget {
  const _StaticQrGraphic();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _QrPatternPainter(),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xFFC62828),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Text(
            'fonepay',
            style: TextStyle(
              color: Colors.white,
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
        ),
      ),
    );
  }
}

class _QrPatternPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFF161D1A);
    const grid = 11;
    final cell = size.width / grid;
    for (var r = 0; r < grid; r++) {
      for (var c = 0; c < grid; c++) {
        final inTopLeft = r < 3 && c < 3;
        final inTopRight = r < 3 && c >= grid - 3;
        final inBottomLeft = r >= grid - 3 && c < 3;
        final isFinder = inTopLeft || inTopRight || inBottomLeft;
        final isData = ((r * 7 + c * 13) % 3 == 0) &&
            !(r >= 4 && r <= 6 && c >= 3 && c <= 7);
        if (isFinder || isData) {
          canvas.drawRect(
            Rect.fromLTWH(c * cell, r * cell, cell * 0.88, cell * 0.88),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
