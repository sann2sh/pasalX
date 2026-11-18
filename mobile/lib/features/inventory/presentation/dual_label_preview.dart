import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/database/money.dart';
import '../../../core/printer/printer_config.dart';
import '../../../core/printer/tspl_label_builder.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';

/// Scaled visual representation of the Xlab 365T 62x20mm dual-column thermal
/// sticker sheet (`Column 1: X=0..215`, `Column 2: X=238..460`).
class DualThermalLabelPreview extends StatelessWidget {
  const DualThermalLabelPreview({
    super.key,
    required this.productName,
    required this.variantName,
    required this.stickerBarcode,
    required this.sellingPricePaisa,
    required this.expiryLabel,
    this.deviceCode = '01',
    this.style = TsplLabelStyle.barcode128,
  });

  final String productName;
  final String variantName;
  final String stickerBarcode;
  final int sellingPricePaisa;
  final String expiryLabel;
  final String deviceCode;
  final TsplLabelStyle style;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final trimmedBarcode = stickerBarcode.trim();

    TsplBarcodeFit? fit;
    String? fitError;
    if (trimmedBarcode.isEmpty) {
      fitError = 'Barcode required';
    } else if (style == TsplLabelStyle.qrSideBySide &&
        trimmedBarcode.length > 53) {
      fitError = 'QR max 53 chars';
    } else {
      try {
        fit = TsplLabelBuilder.fitBarcode(trimmedBarcode);
      } on PrinterPayloadException catch (e) {
        fitError = e.message;
      }
    }

    final fitBadgeLabel = fitError != null
        ? 'Fit Error'
        : style == TsplLabelStyle.qrSideBySide
            ? 'QR Side · <=120 dots'
            : '${fit!.widthDots}/${TsplGeometry.col1MaxX} dots · '
                '${fit.isAllDigitSubsetC ? "Subset C" : "Subset B"}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.qr_code_2_rounded, size: 17, color: c.tertiary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'DUAL 62×20MM LABEL PREVIEW',
                style: t.labelMedium?.copyWith(color: c.onSurface),
              ),
            ),
            PasalStatusBadge(
              label: fitBadgeLabel,
              backgroundColor:
                  fitError != null ? c.errorContainer : c.secondaryContainer,
              foregroundColor:
                  fitError != null ? c.onErrorContainer : c.onSecondaryContainer,
            ),
          ],
        ),
        if (fitError != null) ...[
          const SizedBox(height: 6),
          Text(
            fitError,
            style: t.bodySmall?.copyWith(color: c.error),
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: c.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppRadii.lg),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _SingleLabelCard(
                  columnTag: 'COL 1 · X:0–215',
                  deviceCode: deviceCode,
                  productName: productName,
                  variantName: variantName,
                  stickerBarcode: trimmedBarcode,
                  sellingPricePaisa: sellingPricePaisa,
                  expiryLabel: expiryLabel,
                  style: style,
                ),
                const SizedBox(width: 10),
                _SingleLabelCard(
                  columnTag: 'COL 2 · X:238–460',
                  deviceCode: deviceCode,
                  productName: productName,
                  variantName: variantName,
                  stickerBarcode: trimmedBarcode,
                  sellingPricePaisa: sellingPricePaisa,
                  expiryLabel: expiryLabel,
                  style: style,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SingleLabelCard extends StatelessWidget {
  const _SingleLabelCard({
    required this.columnTag,
    required this.deviceCode,
    required this.productName,
    required this.variantName,
    required this.stickerBarcode,
    required this.sellingPricePaisa,
    required this.expiryLabel,
    required this.style,
  });

  final String columnTag;
  final String deviceCode;
  final String productName;
  final String variantName;
  final String stickerBarcode;
  final int sellingPricePaisa;
  final String expiryLabel;
  final TsplLabelStyle style;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final prodText =
        productName.trim().isEmpty ? 'Product Name' : productName.trim();
    final varText =
        variantName.trim().isEmpty ? 'Standard Variant' : variantName.trim();
    final mrpText = MoneyUtils.formatRs(sellingPricePaisa);
    final codeText = stickerBarcode.isEmpty ? '01100001' : stickerBarcode;

    return Container(
      width: 214,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: c.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: c.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  'PASALX · $deviceCode',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: c.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  columnTag,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: 7.5,
                    color: c.outline,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            prodText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: c.onSurface,
            ),
          ),
          Text(
            varText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 9.5,
              color: c.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          if (style == TsplLabelStyle.barcode128) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: PasalTabularText(
                    mrpText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: c.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: PasalTabularText(
                    'Exp:$expiryLabel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w600,
                      color: c.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 22,
              width: double.infinity,
              child: CustomPaint(
                painter: _BarcodeBarsPainter(
                  seed: codeText,
                  color: c.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Center(
              child: PasalTabularText(
                codeText,
                style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                  color: c.onSurface,
                ),
              ),
            ),
          ] else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      PasalTabularText(
                        mrpText,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: c.primary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      PasalTabularText(
                        'Exp:$expiryLabel',
                        style: TextStyle(
                          fontSize: 8.5,
                          color: c.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      PasalTabularText(
                        codeText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 8,
                          color: c.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  width: 36,
                  height: 36,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    border: Border.all(color: c.onSurface, width: 1),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Icon(
                    Icons.qr_code_2_rounded,
                    size: 28,
                    color: c.onSurface,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _BarcodeBarsPainter extends CustomPainter {
  _BarcodeBarsPainter({required this.seed, required this.color});

  final String seed;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const barCount = 34;
    final unitWidth = size.width / (barCount * 2);
    var x = 0.0;
    final runes = seed.codeUnits;

    for (var i = 0; i < barCount; i++) {
      final remaining = size.width - x;
      if (remaining <= 0.5) break;
      final code = runes.isEmpty ? 65 : runes[i % runes.length];
      final widthFactor = ((code + i * 3) % 3) == 0 ? 1.55 : 0.85;
      final gapFactor = ((code + i) % 2) == 0 ? 1.1 : 0.75;
      final barW = math.min(math.max(1.0, unitWidth * widthFactor), remaining);
      canvas.drawRect(Rect.fromLTWH(x, 0, barW, size.height), paint);
      x += barW + unitWidth * gapFactor;
    }
  }

  @override
  bool shouldRepaint(covariant _BarcodeBarsPainter oldDelegate) {
    return oldDelegate.seed != seed || oldDelegate.color != color;
  }
}
