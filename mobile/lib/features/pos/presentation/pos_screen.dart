import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/database/money.dart';
import '../../../core/printer/esc_pos_receipt_builder.dart';
import '../../../core/printer/printer_providers.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../../inventory/presentation/barcode_scanner_sheet.dart';
import '../application/pos_providers.dart';
import '../domain/pos_models.dart';
import 'checkout_sheet.dart';
import 'fefo_and_expired_dialogs.dart';
import 'hid_barcode_listener.dart';
import 'khata_customer_sheet.dart';
import 'negotiation_sheet.dart';
import 'quick_pad_sheet.dart';

/// Screen 5: POS Terminal & Active Cart with Bottom-Right Thumb Stack
/// (Quick-Pad stacked vertically on top of Scan) + Cash / QR Pay / Khata dock.
class PosScreen extends ConsumerStatefulWidget {
  const PosScreen({super.key});

  @override
  ConsumerState<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends ConsumerState<PosScreen> {
  static final DateFormat _expFmt = DateFormat('MM/yy');
  final TextEditingController _searchCtrl = TextEditingController();
  List<PosScannedBatch> _searchResults = const <PosScannedBatch>[];
  bool _searching = false;
  bool _handlingScan = false;
  int _searchEpoch = 0;
  ReceiptPrintData? _pendingReprint;
  String? _lastPrintError;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleBarcodeScanned(String rawCode) async {
    final code = rawCode.trim();
    if (code.isEmpty || _handlingScan) return;

    final repo = ref.read(posRepositoryProvider);
    final role = ref.read(ramKeyHolderProvider).session?.role;
    if (repo == null) return;

    _handlingScan = true;
    try {
      final cartItems = ref.read(posCartProvider).items;
      final inCartByBatch = <String, int>{};
      for (final item in cartItems) {
        inCartByBatch[item.batchId] =
            (inCartByBatch[item.batchId] ?? 0) + item.quantity;
      }

      final lookup = await repo.lookupByBarcode(
        code,
        role: role,
        inCartQtyByBatchId: inCartByBatch,
      );
      if (!mounted) return;

      switch (lookup.status) {
        case PosBatchScanStatus.ok:
          final batch = lookup.scannedBatch!;
          HapticFeedback.lightImpact();
          ref.read(posCartProvider.notifier).addBatch(batch);
          break;

        case PosBatchScanStatus.expiredBlocked:
          await showExpiredBatchBlockedDialog(context, lookup.scannedBatch!);
          break;

        case PosBatchScanStatus.fefoOlderExists:
          final chosen = await showFefoWarningDialog(
            context,
            scanned: lookup.scannedBatch!,
            older: lookup.olderFefoBatch!,
          );
          if (chosen != null && mounted) {
            ref.read(posCartProvider.notifier).addBatch(chosen);
          }
          break;

        case PosBatchScanStatus.notFound:
        case PosBatchScanStatus.outOfStock:
          HapticFeedback.vibrate();
          ref.read(pasalAlertProvider.notifier).showError(
                'No active batch found for "$code".',
              );
          break;
      }
    } finally {
      _handlingScan = false;
    }
  }

  void _openScanner() {
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.push(AppRoutes.posScanner);
    } else {
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const BarcodeScannerScreen(),
        ),
      );
    }
  }

  void _openQuickPad() {
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.push(AppRoutes.posQuickPad);
    } else {
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const QuickPadScreen(),
        ),
      );
    }
  }

  Future<void> _onSearchChanged(String query) async {
    final epoch = ++_searchEpoch;
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _searchResults = const <PosScannedBatch>[];
        _searching = false;
      });
      return;
    }
    final repo = ref.read(posRepositoryProvider);
    final role = ref.read(ramKeyHolderProvider).session?.role;
    if (repo == null) return;

    setState(() => _searching = true);
    final results = await repo.searchSellableBatches(trimmed, role: role);
    if (!mounted || epoch != _searchEpoch) return;
    setState(() {
      _searchResults = results;
      _searching = false;
    });
  }

  Future<void> _onSearchItemTapped(PosScannedBatch batch) async {
    _searchCtrl.clear();
    setState(() => _searchResults = const <PosScannedBatch>[]);
    await _handleBarcodeScanned(batch.stickerBarcode);
  }

  Future<void> _openItemNegotiation(PosCartItem item) async {
    final res = await showItemNegotiationSheet(context, item: item);
    if (res == null || !mounted) return;
    final notifier = ref.read(posCartProvider.notifier);
    if (res.removed) {
      notifier.removeItem(item.lineKey);
    } else {
      notifier.updateItem(
        item.lineKey,
        unitPricePaisa: res.unitPricePaisa,
        quantity: res.quantity,
        itemDiscountPaisa: res.itemDiscountPaisa,
      );
    }
  }

  Future<void> _openCartDiscount() async {
    final cart = ref.read(posCartProvider);
    if (cart.items.isEmpty) return;
    final discount = await showNegotiationSheet(
      context,
      subtotalPaisa: cart.subtotalPaisa,
      initialDiscount: cart.discount,
    );
    if (discount != null && mounted) {
      ref.read(posCartProvider.notifier).applyDiscount(discount);
    }
  }

  Future<void> _openKhataLookup() async {
    final chosen = await showKhataCustomerSheet(
      context,
      selectionMode: true,
      onAddShadeBatchToCart: (batch) async {
        await _handleBarcodeScanned(batch.stickerBarcode);
      },
    );
    if (chosen != null && mounted) {
      ref.read(posCartProvider.notifier).selectCustomer(chosen);
    }
  }

  Future<void> _openCheckout(CheckoutTab initialTab) async {
    final cart = ref.read(posCartProvider);
    if (cart.items.isEmpty) return;
    final res = await showCheckoutSheet(context, initialTab: initialTab);
    if (res == null || !mounted) return;

    if (res.printRequested && !res.printed) {
      setState(() {
        _pendingReprint = res.commit.receiptData;
        _lastPrintError = res.printError ?? 'Printer unreachable';
      });
      ref.read(pasalAlertProvider.notifier).showWarning(
            'Bill ${res.commit.billNo} saved! Printer offline.',
          );
    } else {
      setState(() {
        _pendingReprint = null;
        _lastPrintError = null;
      });
      ref.read(pasalAlertProvider.notifier).showSuccess(
            res.printed
                ? 'Bill ${res.commit.billNo} completed & printed.'
                : 'Bill ${res.commit.billNo} completed.',
          );
    }
  }

  Future<void> _retryPrint() async {
    final receipt = _pendingReprint;
    if (receipt == null) return;
    try {
      await ref.read(xlabPrinterDriverProvider).printReceipt(receipt);
      if (!mounted) return;
      setState(() {
        _pendingReprint = null;
        _lastPrintError = null;
      });
      ref.read(pasalAlertProvider.notifier).showSuccess(
            'Receipt ${receipt.billNo} printed.',
          );
    } catch (e) {
      if (!mounted) return;
      setState(() => _lastPrintError = e.toString());
      ref.read(pasalAlertProvider.notifier).showError(
            'Printer still unreachable.',
          );
    }
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return 'WI';
    return parts
        .take(2)
        .map((w) => w.isEmpty ? '' : w[0].toUpperCase())
        .join();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final cart = ref.watch(posCartProvider);
    final customer = cart.selectedCustomer;

    return HidBarcodeListener(
      onBarcodeScanned: _handleBarcodeScanned,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.gutterMobile),
              children: [
                // Full-width Customer Pill
                Material(
                  color: c.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  child: InkWell(
                    onTap: _openKhataLookup,
                    borderRadius: BorderRadius.circular(AppRadii.md),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(AppRadii.md),
                        border: Border.all(color: c.hairline),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 15,
                            backgroundColor: c.secondaryContainer,
                            child: Text(
                              customer != null ? _initials(customer.name) : 'WI',
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
                                  customer?.name ?? 'Walk-in Customer',
                                  style: t.titleSmall,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  customer != null
                                      ? '${customer.favoriteShadeNotes?.isNotEmpty == true ? 'Last shade: ${customer.favoriteShadeNotes} • ' : ''}'
                                          'Khata ${MoneyUtils.formatRs(customer.currentBalanceDue)}'
                                      : 'Tap to attach Khata / Shades',
                                  style: t.bodySmall?.copyWith(
                                    color: customer != null
                                        ? c.primary
                                        : c.onSurfaceVariant,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          Text(
                            customer != null ? 'Change' : 'Khata / Shades',
                            style: t.labelMedium?.copyWith(
                              color: c.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (customer != null)
                            IconButton(
                              tooltip: 'Detach customer',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => ref
                                  .read(posCartProvider.notifier)
                                  .selectCustomer(null),
                              icon: const Icon(Icons.close_rounded, size: 16),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),

                // Printer Retry Banner (if saved bill failed to print)
                if (_pendingReprint != null) ...[
                  PasalCard(
                    color: c.warningContainer,
                    borderColor: c.warning,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.print_disabled_rounded, color: c.warning),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Bill ${_pendingReprint!.billNo} saved (Print failed)',
                                style: t.labelLarge?.copyWith(
                                  color: c.onWarningContainer,
                                ),
                              ),
                              if (_lastPrintError != null)
                                Text(
                                  _lastPrintError!,
                                  style: t.bodySmall,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                        ),
                        FilledButton.tonal(
                          onPressed: _retryPrint,
                          child: const Text('Retry Print'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],

                // Full-width Search Bar
                TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search_rounded),
                    hintText: 'Search product, shade or barcode...',
                    isDense: true,
                    suffixIcon: _searchCtrl.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded),
                            onPressed: () {
                              _searchCtrl.clear();
                              _onSearchChanged('');
                            },
                          )
                        : null,
                  ),
                  onChanged: _onSearchChanged,
                  onSubmitted: (v) {
                    if (v.trim().isNotEmpty) {
                      _searchCtrl.clear();
                      setState(() => _searchResults = const <PosScannedBatch>[]);
                      _handleBarcodeScanned(v);
                    }
                  },
                ),

                // Inline Search Results Dropdown
                if (_searching)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_searchResults.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  PasalCard(
                    color: c.surfaceContainerLowest,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Material(
                      type: MaterialType.transparency,
                      child: Column(
                        children: [
                          for (final item in _searchResults.take(6))
                            ListTile(
                              dense: true,
                              title: Text(
                                '${item.productName} • ${item.variantName}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${item.stickerBarcode} • ${item.stockQuantity} left'
                                '${item.isNonPerishable ? '' : ' • Exp ${_expFmt.format(item.expiryDate)}'}',
                              ),
                              trailing: PasalTabularText(
                                '+ ${MoneyUtils.formatRs(item.sellingPricePaisa)}',
                                style: t.titleSmall?.copyWith(color: c.primary),
                              ),
                              onTap: () => _onSearchItemTapped(item),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.md),

                // Active Cart Header
                Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            'ACTIVE CART',
                            style: t.labelLarge?.copyWith(
                              color: c.onSurfaceVariant,
                              letterSpacing: 0.6,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: c.secondaryContainer,
                              borderRadius:
                                  BorderRadius.circular(AppRadii.pill),
                            ),
                            child: Text(
                              '${cart.itemCount} '
                              '${cart.itemCount == 1 ? 'Item' : 'Items'}',
                              style: t.labelSmall?.copyWith(
                                color: c.onSecondaryContainer,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (cart.items.isNotEmpty) ...[
                      TextButton(
                        onPressed: _openCartDiscount,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                        ),
                        child: Text(
                          cart.discountPaisa > 0 ? 'Edit Disc.' : 'Discount',
                        ),
                      ),
                      TextButton(
                        onPressed: () =>
                            ref.read(posCartProvider.notifier).clearCart(),
                        style: TextButton.styleFrom(
                          foregroundColor: c.error,
                          visualDensity: VisualDensity.compact,
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                        ),
                        child: const Text('Clear All'),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),

                // Scrollable Cart Stream
                if (cart.items.isEmpty)
                  PasalCard(
                    color: c.surfaceContainerLow,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.lg,
                        horizontal: AppSpacing.md,
                      ),
                      child: Column(
                        children: [
                          Icon(
                            Icons.point_of_sale_rounded,
                            size: 40,
                            color: c.outline,
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text('Cart is Empty', style: t.titleMedium),
                          const SizedBox(height: 4),
                          Text(
                            'Tap Scan or Quick-Pad on the bottom right, '
                            'use a Bluetooth laser gun, or search above.',
                            style: t.bodySmall,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  )
                else ...[
                  for (final item in cart.items) ...[
                    _CartLineTile(
                      item: item,
                      onTap: () => _openItemNegotiation(item),
                      onIncrement: () => ref
                          .read(posCartProvider.notifier)
                          .incrementQty(item.lineKey),
                      onDecrement: () => ref
                          .read(posCartProvider.notifier)
                          .decrementQty(item.lineKey),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                  ],
                  const SizedBox(height: AppSpacing.xs),
                  // Cart Breakdown Card
                  PasalCard(
                    color: c.surfaceContainerLowest,
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Subtotal', style: t.bodySmall),
                            PasalTabularText(
                              MoneyUtils.formatRs(cart.subtotalPaisa),
                              style: t.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        if (cart.discountPaisa > 0) ...[
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  'Discount (${cart.discount.label})',
                                  style: t.bodySmall?.copyWith(
                                    color: c.primary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              PasalTabularText(
                                '- ${MoneyUtils.formatRs(cart.discountPaisa)}',
                                style: t.bodyMedium?.copyWith(
                                  color: c.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

          // BOTTOM-RIGHT THUMB STACK (Quick-Pad stacked on top of Scan) + CHECKOUT DOCK
          Container(
            decoration: BoxDecoration(
              color: c.surfaceContainerLowest,
              border: Border(top: BorderSide(color: c.hairline)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 12,
                  offset: const Offset(0, -3),
                ),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutterMobile,
              10,
              AppSpacing.gutterMobile,
              10,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Row 1: Net Payable on Left | Vertical Stack (Quick-Pad over Scan) on Right
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'NET PAYABLE',
                            style: t.labelSmall?.copyWith(
                              color: c.outline,
                              letterSpacing: 0.6,
                            ),
                          ),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: PasalTabularText(
                              MoneyUtils.formatRs(cart.netTotalPaisa),
                              style: t.headlineMedium?.copyWith(
                                color: c.primary,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          Text(
                            'Tap any cart item to edit price',
                            style: t.bodySmall?.copyWith(fontSize: 10),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 134,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            height: 38,
                            child: FilledButton.tonalIcon(
                              onPressed: _openQuickPad,
                              style: FilledButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 10),
                                shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(AppRadii.md),
                                ),
                              ),
                              icon: const Icon(Icons.grid_view_rounded, size: 17),
                              label: const Text('Quick-Pad'),
                            ),
                          ),
                          const SizedBox(height: 6),
                          SizedBox(
                            height: 44,
                            child: FilledButton.icon(
                              onPressed: _openScanner,
                              style: FilledButton.styleFrom(
                                backgroundColor: c.onSurface,
                                foregroundColor: c.surface,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(AppRadii.md),
                                ),
                              ),
                              icon: const Icon(
                                Icons.qr_code_scanner_rounded,
                                size: 19,
                              ),
                              label: const Text('Scan'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // Row 2: Direct Tender Settlement Buttons (Cash | QR Pay | Khata)
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: cart.items.isEmpty
                            ? null
                            : () => _openCheckout(CheckoutTab.cash),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 11,
                          ),
                          minimumSize: const Size(0, 42),
                        ),
                        icon: const Icon(Icons.payments_rounded, size: 17),
                        label: const Text('Cash'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: cart.items.isEmpty
                            ? null
                            : () => _openCheckout(CheckoutTab.fonepay),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 11,
                          ),
                          minimumSize: const Size(0, 42),
                        ),
                        icon: const Icon(Icons.qr_code_2_rounded, size: 17),
                        label: const Text('QR Pay'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: cart.items.isEmpty
                            ? null
                            : () => _openCheckout(CheckoutTab.khata),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 11,
                          ),
                          minimumSize: const Size(0, 42),
                        ),
                        icon: const Icon(Icons.menu_book_rounded, size: 17),
                        label: const Text('Khata'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CartLineTile extends StatelessWidget {
  const _CartLineTile({
    required this.item,
    required this.onTap,
    required this.onIncrement,
    required this.onDecrement,
  });

  final PosCartItem item;
  final VoidCallback onTap;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;

  Color? _parseHex(String? hex) {
    if (hex == null || hex.trim().isEmpty) return null;
    final clean = hex.trim().replaceFirst('#', '');
    if (clean.length != 6) return null;
    final val = int.tryParse(clean, radix: 16);
    if (val == null) return null;
    return Color(0xFF000000 | val);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final swatch = _parseHex(item.colorHex);

    return Material(
      color: c.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(AppRadii.lg),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.lg),
            border: Border.all(color: c.hairline),
          ),
          child: Row(
            children: [
              if (swatch != null) ...[
                Container(
                  width: 14,
                  height: 32,
                  decoration: BoxDecoration(
                    color: swatch,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: c.hairline),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.productName,
                      style: t.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${item.variantName} • ${MoneyUtils.formatRs(item.unitPricePaisa)}'
                      '${item.itemDiscountPaisa > 0 ? ' (-${MoneyUtils.formatRs(item.itemDiscountPaisa)})' : ''}',
                      style: t.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: onDecrement,
                    icon: Icon(
                      item.quantity > 1
                          ? Icons.remove_circle_outline_rounded
                          : Icons.delete_outline_rounded,
                      size: 20,
                    ),
                  ),
                  PasalTabularText(
                    '${item.quantity}',
                    style: t.titleMedium,
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: onIncrement,
                    icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
                  ),
                ],
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 74,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: PasalTabularText(
                    MoneyUtils.formatRs(item.lineTotalPaisa),
                    textAlign: TextAlign.right,
                    style: t.titleSmall?.copyWith(
                      color: c.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
