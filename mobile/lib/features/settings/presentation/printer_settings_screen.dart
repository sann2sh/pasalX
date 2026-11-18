import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/printer/esc_pos_receipt_builder.dart';
import '../../../core/printer/printer_config.dart';
import '../../../core/printer/printer_providers.dart';
import '../../../core/printer/tspl_label_builder.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../../core/router/shell_scaffold.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';

/// Screen 19: Dedicated Printer Settings & Active Paper Roll Mode switcher.
class PrinterSettingsScreen extends ConsumerStatefulWidget {
  const PrinterSettingsScreen({super.key});

  @override
  ConsumerState<PrinterSettingsScreen> createState() =>
      _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends ConsumerState<PrinterSettingsScreen> {
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;

  bool _busy = false;
  bool? _isOnline;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(printerConfigProvider);
    _hostCtrl = TextEditingController(text: cfg.host);
    _portCtrl = TextEditingController(text: cfg.port.toString());
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    super.dispose();
  }

  bool _saveNetworkAddress({bool showSuccessAlert = true}) {
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim());
    if (host.isEmpty || port == null || port <= 0 || port > 65535) {
      ref
          .read(pasalAlertProvider)
          .showError('Enter a valid printer IP address and port (1–65535).');
      return false;
    }

    final current = ref.read(printerConfigProvider);
    ref.read(printerConfigProvider.notifier).updateConfig(
          current.copyWith(host: host, port: port),
        );

    if (showSuccessAlert) {
      ref.read(pasalAlertProvider).showSuccess('Saved printer address $host:$port.');
    }
    return true;
  }

  Future<void> _checkPrinterStatus() async {
    if (!_saveNetworkAddress(showSuccessAlert: false)) return;
    setState(() {
      _busy = true;
      _statusMessage = null;
    });

    try {
      final status = await ref.read(xlabPrinterDriverProvider).probeStatus();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _isOnline = status.isReady;
        _statusMessage = status.message;
      });
      if (status.isReady) {
        ref.read(pasalAlertProvider).showSuccess('Printer is online and ready.');
      } else {
        ref.read(pasalAlertProvider).showWarning(status.message);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _isOnline = false;
        _statusMessage = 'Printer offline. Check Wi-Fi or IP.';
      });
      ref
          .read(pasalAlertProvider)
          .showError('Printer offline. Check Wi-Fi or IP.');
    }
  }

  Future<void> _selectMode(PrinterMode mode) async {
    final current = ref.read(printerConfigProvider);
    ref.read(printerConfigProvider.notifier).updateConfig(
          current.copyWith(preferredMode: mode),
        );

    setState(() => _busy = true);
    try {
      await ref.read(xlabPrinterDriverProvider).switchMode(mode);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _isOnline = true;
      });
      final label = mode == PrinterMode.receipt
          ? 'Switched to Receipt Mode (80mm).'
          : 'Switched to Label Mode (62×20mm).';
      ref.read(pasalAlertProvider).showSuccess(label);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _isOnline = false;
      });
      ref.read(pasalAlertProvider).showWarning(
            'Saved ${mode == PrinterMode.receipt ? 'Receipt' : 'Label'} Mode locally. Printer is currently offline.',
          );
    }
  }

  Future<void> _testPrint(PrinterMode targetMode) async {
    if (!_saveNetworkAddress(showSuccessAlert: false)) return;
    final cfg = ref.read(printerConfigProvider);

    final hasModeMismatch = cfg.preferredMode != targetMode;
    if (hasModeMismatch) {
      final expectedLabel =
          targetMode == PrinterMode.receipt ? 'Receipt Mode' : 'Label Mode';
      final activeLabel = cfg.preferredMode == PrinterMode.receipt
          ? 'Receipt Mode'
          : 'Label Mode';
      ref.read(pasalAlertProvider).showWarning(
            'Printer is set to $activeLabel — switch to $expectedLabel or load the matching paper roll.',
          );
    }

    setState(() => _busy = true);
    try {
      final driver = ref.read(xlabPrinterDriverProvider);
      if (targetMode == PrinterMode.receipt) {
        final session = ref.read(ramKeyHolderProvider).session;
        await driver.printReceipt(
          ReceiptPrintData(
            billNo: 'TEST-0001',
            printedAt: DateTime.now(),
            cashierName: session?.username ?? 'Owner',
            items: const <ReceiptLineItem>[
              ReceiptLineItem(
                productName: 'Xlab 365T Test Item',
                variantName: '80mm PAN Receipt',
                quantity: 1,
                unitPricePaisa: 10000,
                lineTotalPaisa: 10000,
              ),
            ],
            subtotalPaisa: 10000,
            discountPaisa: 0,
            totalPaisa: 10000,
            paymentMode: 'CASH',
            payments: const <ReceiptPaymentLine>[
              ReceiptPaymentLine(method: 'CASH', amountPaisa: 10000),
            ],
            cashTenderedPaisa: 10000,
            changeDuePaisa: 0,
          ),
        );
      } else {
        await driver.printBatchCopies(
          BatchLabelData(
            productName: 'Fit Me Matte #128',
            variantName: 'Warm Nude',
            stickerBarcode: '8901234567890',
            sellingPricePaisa: 95000,
            batchCode: 'LOT-26A',
            expiryDate: DateTime(2028, 12, 1),
          ),
          quantity: 2,
        );
      }

      if (!mounted) return;
      setState(() {
        _busy = false;
        _isOnline = true;
      });
      if (!hasModeMismatch) {
        ref.read(pasalAlertProvider).showSuccess(
              targetMode == PrinterMode.receipt
                  ? 'Test receipt sent to Xlab 365T.'
                  : 'Test barcode labels sent to Xlab 365T.',
            );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _isOnline = false;
      });
      ref
          .read(pasalAlertProvider)
          .showError('Printer offline. Check Wi-Fi or IP.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final cfg = ref.watch(printerConfigProvider);

    final statusLabel = _busy
        ? 'Checking...'
        : _isOnline == null
            ? 'Standby'
            : (_isOnline! ? 'Online' : 'Offline');
    final statusBg = _isOnline == false
        ? c.errorContainer
        : (_isOnline == true ? c.secondaryContainer : c.surfaceContainerHigh);
    final statusFg = _isOnline == false
        ? c.onErrorContainer
        : (_isOnline == true ? c.onSecondaryContainer : c.onSurfaceVariant);
    final statusDot = _isOnline == false
        ? c.error
        : (_isOnline == true ? c.primary : c.outline);

    return Scaffold(
      backgroundColor: c.surface,
      appBar: const PasalStackAppBar(
        title: 'Printer Settings',
        subtitle: 'Xlab 365T • Mode & IP',
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutterMobile,
          AppSpacing.gutterMobile,
          AppSpacing.gutterMobile,
          AppSpacing.xl,
        ),
        children: [
          // 1. Live Status Card
          PasalCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: c.surfaceContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.print_rounded, color: c.primary),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Xlab 365T Printer', style: t.titleMedium),
                          Text('Wi-Fi Counter Printer', style: t.bodySmall),
                        ],
                      ),
                    ),
                    PasalStatusBadge(
                      label: statusLabel,
                      backgroundColor: statusBg,
                      foregroundColor: statusFg,
                      dotColor: statusDot,
                    ),
                  ],
                ),
                if (_statusMessage != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    _statusMessage!,
                    style: t.bodySmall?.copyWith(
                      color: _isOnline == false ? c.error : c.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.sm),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    onPressed: _busy ? null : _checkPrinterStatus,
                    icon: const Icon(Icons.network_check_rounded, size: 18),
                    label: const Text('Check Printer Status'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // 2. Active Paper Mode Switcher
          PasalCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'ACTIVE PAPER MODE',
                        style: t.labelMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      cfg.preferredMode == PrinterMode.receipt
                          ? 'Receipt Mode'
                          : 'Label Mode',
                      style: t.labelMedium?.copyWith(color: c.primary),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                _ModeOptionCard(
                  icon: Icons.receipt_long_rounded,
                  title: 'Receipt Mode (80mm Paper Roll)',
                  subtitle: 'For customer bills & daily Z-Report',
                  selected: cfg.preferredMode == PrinterMode.receipt,
                  onTap: _busy ? null : () => _selectMode(PrinterMode.receipt),
                ),
                const SizedBox(height: AppSpacing.xs),
                _ModeOptionCard(
                  icon: Icons.qr_code_2_rounded,
                  title: 'Label Mode (Barcode Stickers)',
                  subtitle: 'For 62×20mm product price stickers',
                  selected: cfg.preferredMode == PrinterMode.label,
                  onTap: _busy ? null : () => _selectMode(PrinterMode.label),
                ),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Auto-Switch Paper Mode Before Print',
                        style: t.bodySmall,
                      ),
                    ),
                    Switch.adaptive(
                      value: cfg.autoSwitchMode,
                      onChanged: (v) {
                        ref
                            .read(printerConfigProvider.notifier)
                            .updateConfig(cfg.copyWith(autoSwitchMode: v));
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // 3. IP & Port Settings
          PasalCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('PRINTER NETWORK ADDRESS', style: t.labelMedium),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _hostCtrl,
                        decoration: const InputDecoration(
                          labelText: 'IP Address',
                          hintText: '192.168.1.100',
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: TextField(
                        controller: _portCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Port',
                          hintText: '9100',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy ? null : () => _saveNetworkAddress(),
                    child: const Text('Save IP & Port'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // 4. Test Print Buttons
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed:
                      _busy ? null : () => _testPrint(PrinterMode.receipt),
                  icon: const Icon(Icons.receipt_outlined, size: 18),
                  label: const Text('Test Receipt'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _busy ? null : () => _testPrint(PrinterMode.label),
                  icon: const Icon(Icons.qr_code_rounded, size: 18),
                  label: const Text('Test Label'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ModeOptionCard extends StatelessWidget {
  const _ModeOptionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: selected
              ? c.surfaceContainerLow
              : c.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? c.primary : c.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: selected ? c.primary : c.onSurfaceVariant,
              size: 22,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: t.titleSmall),
                  Text(subtitle, style: t.bodySmall),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_circle_rounded, color: c.primary, size: 20),
          ],
        ),
      ),
    );
  }
}
