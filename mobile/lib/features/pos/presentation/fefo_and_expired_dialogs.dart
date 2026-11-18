import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../core/database/money.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';
import '../domain/pos_models.dart';

final DateFormat _expMonthFmt = DateFormat('MM/yyyy');

/// Hard-blocks sale of an expired batch with high-contrast error styling.
Future<void> showExpiredBatchBlockedDialog(
  BuildContext context,
  PosScannedBatch batch,
) {
  HapticFeedback.heavyImpact();
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      final c = ctx.pasalColors;
      final t = ctx.textTheme;
      final expStr = _expMonthFmt.format(batch.expiryDate);

      return AlertDialog(
        backgroundColor: c.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.xl),
          side: BorderSide(color: c.error, width: 1.5),
        ),
        icon: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: c.errorContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.block_rounded, color: c.error, size: 28),
        ),
        title: Text(
          'EXPIRED BATCH BLOCKED',
          textAlign: TextAlign.center,
          style: t.titleLarge?.copyWith(
            color: c.error,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${batch.productName} • ${batch.variantName}',
              textAlign: TextAlign.center,
              style: t.titleMedium,
            ),
            const SizedBox(height: AppSpacing.xs),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: c.errorContainer,
                borderRadius: BorderRadius.circular(AppRadii.md),
              ),
              child: Text(
                'Batch ${batch.batchCode} expired on $expStr. Sale is blocked.',
                textAlign: TextAlign.center,
                style: t.bodySmall?.copyWith(
                  color: c.onErrorContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: c.error,
              foregroundColor: c.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Acknowledge'),
          ),
        ],
      );
    },
  );
}

/// FEFO soft warning modal when an older non-expired batch of the exact same
/// variant is still on the shelf with stock > 0.
///
/// Returns [older] to switch, [scanned] to continue with customer choice, or
/// `null` if cancelled.
Future<PosScannedBatch?> showFefoWarningDialog(
  BuildContext context, {
  required PosScannedBatch scanned,
  required PosScannedBatch older,
}) {
  HapticFeedback.mediumImpact();
  return showDialog<PosScannedBatch>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      final c = ctx.pasalColors;
      final t = ctx.textTheme;
      final olderExp = _expMonthFmt.format(older.expiryDate);
      final scannedExp = _expMonthFmt.format(scanned.expiryDate);

      return AlertDialog(
        backgroundColor: c.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.xl),
          side: BorderSide(color: c.warning, width: 1.5),
        ),
        icon: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: c.warningContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.warning_amber_rounded,
            color: c.warning,
            size: 28,
          ),
        ),
        title: Text(
          'FEFO: Older Batch Available',
          textAlign: TextAlign.center,
          style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${scanned.productName} • ${scanned.variantName}',
              textAlign: TextAlign.center,
              style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: AppSpacing.sm),
            PasalCard(
              color: c.warningContainer,
              borderColor: c.warning,
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'OLDER STOCK ON SHELF (RECOMMENDED)',
                    style: t.labelSmall?.copyWith(
                      color: c.onWarningContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Batch ${older.batchCode} • Exp: $olderExp • '
                    'Stock: ${older.stockQuantity} • '
                    '${MoneyUtils.formatRs(older.sellingPricePaisa)}',
                    style: t.bodySmall?.copyWith(
                      color: c.onWarningContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Scanned batch ${scanned.batchCode} expires later ($scannedExp).',
              textAlign: TextAlign.center,
              style: t.bodySmall,
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(scanned),
            child: const Text('Customer Choice — Continue'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(older),
            child: const Text('Switch to Older'),
          ),
        ],
      );
    },
  );
}

