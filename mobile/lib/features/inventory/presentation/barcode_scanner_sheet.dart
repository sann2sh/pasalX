import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/database/money.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../../pos/application/pos_beep.dart';
import '../../pos/application/pos_providers.dart';
import '../../pos/domain/pos_models.dart';
import '../../pos/presentation/fefo_and_expired_dialogs.dart';
import '../../pos/presentation/hid_barcode_listener.dart';

/// Opens a compact camera + manual barcode scanner modal sheet returning
/// the scanned or entered barcode string, or `null` when dismissed.
Future<String?> showBarcodeScannerSheet(
  BuildContext context, {
  String title = 'Scan Sticker or Manufacturer Barcode',
  String hintText = 'Enter barcode manually (e.g. 01100024)',
}) {
  return showPasalBottomSheet<String>(
    context: context,
    builder: (ctx) => _BarcodeScannerSheet(title: title, hintText: hintText),
  );
}

/// Full-screen continuous POS Barcode Scanner (Screen 8):
/// - Torch toggle, dark viewfinder with alignment frame
/// - Continuous session queue
/// - FEFO older-batch warning & Expired hard-block dialogs
/// - Manual barcode input + HID Bluetooth laser listener
/// - Done Scanning • Back to Cart button
class BarcodeScannerScreen extends ConsumerStatefulWidget {
  const BarcodeScannerScreen({super.key});

  @override
  ConsumerState<BarcodeScannerScreen> createState() =>
      _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends ConsumerState<BarcodeScannerScreen> {
  static const Duration _sameBarcodeCooldown = Duration(seconds: 2);

  final TextEditingController _manualCtrl = TextEditingController();
  MobileScannerController? _scannerController;
  bool _torchOn = false;
  bool _handlingScan = false;
  final Map<String, DateTime> _lastCameraScanAt = <String, DateTime>{};
  final List<PosScannedBatch> _sessionQueue = <PosScannedBatch>[];

  @override
  void initState() {
    super.initState();
    try {
      _scannerController = MobileScannerController(
        detectionSpeed: DetectionSpeed.normal,
      );
    } catch (_) {
      _scannerController = null;
    }
  }

  @override
  void dispose() {
    _manualCtrl.dispose();
    _scannerController?.dispose();
    super.dispose();
  }

  Future<void> _toggleTorch() async {
    final ctrl = _scannerController;
    if (ctrl == null) return;
    try {
      await ctrl.toggleTorch();
      if (mounted) {
        setState(() => _torchOn = !_torchOn);
      }
    } catch (_) {
      if (mounted) {
        ref.read(pasalAlertProvider.notifier).showWarning(
              'Flash not available on this device.',
            );
      }
    }
  }

  void _handleCameraDetect(BarcodeCapture capture) {
    if (_handlingScan) return;
    final now = DateTime.now();
    for (final barcode in capture.barcodes) {
      final code = barcode.rawValue?.trim();
      if (code == null || code.isEmpty) continue;
      final lastAt = _lastCameraScanAt[code];
      if (lastAt != null && now.difference(lastAt) < _sameBarcodeCooldown) {
        continue;
      }
      _recordCameraScan(code, now);
      _processBarcode(code, fromCamera: true);
      return;
    }
  }

  void _recordCameraScan(String code, DateTime now) {
    if (_lastCameraScanAt.length > 32) {
      _lastCameraScanAt.removeWhere(
        (_, ts) => now.difference(ts) >= _sameBarcodeCooldown,
      );
    }
    _lastCameraScanAt[code] = now;
  }

  Future<void> _processBarcode(
    String rawCode, {
    bool fromCamera = false,
  }) async {
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
          unawaited(PosBeep.playSuccess());
          ref.read(posCartProvider.notifier).addBatch(batch);
          setState(() => _sessionQueue.insert(0, batch));
          ref.read(pasalAlertProvider.notifier).showSuccess(
                'Added ${batch.productName}',
              );
          break;

        case PosBatchScanStatus.expiredBlocked:
          HapticFeedback.heavyImpact();
          await showExpiredBatchBlockedDialog(context, lookup.scannedBatch!);
          break;

        case PosBatchScanStatus.fefoOlderExists:
          final chosen = await showFefoWarningDialog(
            context,
            scanned: lookup.scannedBatch!,
            older: lookup.olderFefoBatch!,
          );
          if (chosen != null && mounted) {
            HapticFeedback.lightImpact();
            unawaited(PosBeep.playSuccess());
            ref.read(posCartProvider.notifier).addBatch(chosen);
            setState(() => _sessionQueue.insert(0, chosen));
            ref.read(pasalAlertProvider.notifier).showSuccess(
                  'Added ${chosen.productName} (${chosen.batchCode})',
                );
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
      if (fromCamera) {
        _recordCameraScan(code, DateTime.now());
      }
      _handlingScan = false;
    }
  }

  void _submitManual() {
    final code = _manualCtrl.text.trim();
    if (code.isEmpty) return;
    _manualCtrl.clear();
    _processBarcode(code);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;

    return HidBarcodeListener(
      onBarcodeScanned: _processBarcode,
      child: Scaffold(
        backgroundColor: c.surface,
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Barcode Scanner'),
              Text(
                'Continuous Scan Active',
                style: t.bodySmall?.copyWith(color: c.primary),
              ),
            ],
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: FilledButton.tonalIcon(
                onPressed: _toggleTorch,
                icon: Icon(
                  _torchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                  size: 16,
                ),
                label: Text(_torchOn ? 'Flash On' : 'Flash'),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.gutterMobile),
                children: [
                  // Camera Viewfinder
                  AspectRatio(
                    aspectRatio: 4 / 3,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadii.xl),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Container(
                            color: const Color(0xFF161D1A),
                            child: _scannerController == null
                                ? _CameraFallbackBox(
                                    color: const Color(0xFF161D1A),
                                    darkSurface: true,
                                  )
                                : MobileScanner(
                                    controller: _scannerController,
                                    onDetect: _handleCameraDetect,
                                    errorBuilder: (context, error, child) {
                                      return const _CameraFallbackBox(
                                        color: Color(0xFF161D1A),
                                        darkSurface: true,
                                        message:
                                            'Camera preview unavailable. Use '
                                            'laser scanner or enter barcode below.',
                                      );
                                    },
                                  ),
                          ),
                          // Alignment Frame Overlay
                          Center(
                            child: Container(
                              width: 240,
                              height: 120,
                              decoration: BoxDecoration(
                                borderRadius:
                                    BorderRadius.circular(AppRadii.lg),
                                border: Border.all(
                                  color: c.primaryFixed.withValues(alpha: 0.8),
                                  width: 1.5,
                                ),
                              ),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Positioned(
                                    left: 10,
                                    right: 10,
                                    child: Container(
                                      height: 2,
                                      decoration: BoxDecoration(
                                        color: c.primaryFixed,
                                        boxShadow: [
                                          BoxShadow(
                                            color: c.primaryFixed
                                                .withValues(alpha: 0.7),
                                            blurRadius: 8,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(alpha: 0.7),
                                      borderRadius:
                                          BorderRadius.circular(AppRadii.sm),
                                    ),
                                    child: Text(
                                      'Align product barcode inside frame',
                                      style: t.labelSmall?.copyWith(
                                        color: c.primaryFixed,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),

                  // Session Queue
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
                                'SCANNED THIS SESSION',
                                style: t.labelLarge?.copyWith(
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            Text(
                              '${_sessionQueue.length} '
                              '${_sessionQueue.length == 1 ? 'item' : 'items'}',
                              style: t.labelLarge?.copyWith(color: c.primary),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        if (_sessionQueue.isEmpty)
                          Container(
                            padding: const EdgeInsets.all(AppSpacing.md),
                            decoration: BoxDecoration(
                              color: c.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(AppRadii.md),
                            ),
                            child: Text(
                              'Scan a product sticker or enter a barcode below '
                              'to add directly to your cart.',
                              style: t.bodySmall,
                              textAlign: TextAlign.center,
                            ),
                          )
                        else
                          Column(
                            children: [
                              for (final item in _sessionQueue.take(6)) ...[
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: c.surfaceContainerLow,
                                    borderRadius:
                                        BorderRadius.circular(AppRadii.md),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '${item.productName} • ${item.variantName}',
                                          style: t.bodySmall?.copyWith(
                                            color: c.onSurface,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      PasalTabularText(
                                        MoneyUtils.formatRs(
                                          item.sellingPricePaisa,
                                        ),
                                        style: t.labelLarge?.copyWith(
                                          color: c.primary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 6),
                              ],
                            ],
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),

                  // Manual Code Entry
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _manualCtrl,
                          textInputAction: TextInputAction.done,
                          decoration: const InputDecoration(
                            hintText: 'Type barcode manually (e.g. 01100024)',
                            isDense: true,
                          ),
                          onSubmitted: (_) => _submitManual(),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      FilledButton.tonal(
                        onPressed: _submitManual,
                        child: const Text('Add'),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Bottom Done CTA
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutterMobile,
                  AppSpacing.xs,
                  AppSpacing.gutterMobile,
                  AppSpacing.md,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                    label: const Text('Done Scanning • Back to Cart'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BarcodeScannerSheet extends StatefulWidget {
  const _BarcodeScannerSheet({
    required this.title,
    required this.hintText,
  });

  final String title;
  final String hintText;

  @override
  State<_BarcodeScannerSheet> createState() => _BarcodeScannerSheetState();
}

class _BarcodeScannerSheetState extends State<_BarcodeScannerSheet> {
  final TextEditingController _manualController = TextEditingController();
  MobileScannerController? _scannerController;
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    try {
      _scannerController = MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
      );
    } catch (_) {
      _scannerController = null;
    }
  }

  @override
  void dispose() {
    _manualController.dispose();
    _scannerController?.dispose();
    super.dispose();
  }

  void _completeWithBarcode(String value) {
    final trimmed = value.trim();
    if (_resolved || trimmed.isEmpty) return;
    _resolved = true;
    Navigator.of(context).pop(trimmed);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

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
                child: Text(widget.title, style: t.titleLarge),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.lg),
            child: SizedBox(
              height: 170,
              child: _scannerController == null
                  ? _CameraFallbackBox(color: c.surfaceContainerLow)
                  : MobileScanner(
                      controller: _scannerController,
                      onDetect: (capture) {
                        for (final barcode in capture.barcodes) {
                          final raw = barcode.rawValue;
                          if (raw != null && raw.trim().isNotEmpty) {
                            _completeWithBarcode(raw);
                            return;
                          }
                        }
                      },
                      errorBuilder: (context, error, child) {
                        return _CameraFallbackBox(
                          color: c.surfaceContainerLow,
                          message: 'Camera preview unavailable on this device. '
                              'Use a Bluetooth/USB scanner gun or type below.',
                        );
                      },
                    ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _manualController,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: 'Barcode / Lot Code',
                    hintText: widget.hintText,
                  ),
                  onSubmitted: _completeWithBarcode,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              FilledButton(
                onPressed: () => _completeWithBarcode(_manualController.text),
                child: const Text('Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CameraFallbackBox extends StatelessWidget {
  const _CameraFallbackBox({
    required this.color,
    this.darkSurface = false,
    this.message =
        'Aim camera at batch sticker or enter barcode manually below.',
  });

  final Color color;
  final bool darkSurface;
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return Container(
      color: color,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.qr_code_scanner_rounded,
            size: 34,
            color: darkSurface ? c.primaryFixed : c.primary,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            message,
            textAlign: TextAlign.center,
            style: t.bodySmall?.copyWith(
              color: darkSurface ? Colors.white70 : c.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
