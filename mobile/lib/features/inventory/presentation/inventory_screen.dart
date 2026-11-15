import 'package:flutter/material.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';

/// Step 5 foundation placeholder for `/inventory` (3-Tier Catalog, Smart Intake
/// & Dual Barcode Sticker Print to be built in Step 8).
class InventoryScreen extends StatelessWidget {
  const InventoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutterMobile),
      children: [
        Text('Inventory & Catalog', style: t.headlineLarge),
        const SizedBox(height: 4),
        Text(
          '3-Tier Product → Variant → Batch Vault',
          style: t.bodySmall,
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: PasalCard(
                color: c.surfaceContainerLow,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ACTIVE SKUS', style: t.labelSmall),
                    const SizedBox(height: 4),
                    PasalTabularText('0', style: t.headlineLarge),
                  ],
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: PasalCard(
                color: c.errorContainer,
                borderColor: c.error.withValues(alpha: 0.2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'LOW RESERVE',
                      style: t.labelSmall?.copyWith(color: c.onErrorContainer),
                    ),
                    const SizedBox(height: 4),
                    PasalTabularText(
                      '0',
                      style: t.headlineLarge?.copyWith(color: c.error),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

