import 'package:flutter/material.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';

/// Step 5 foundation placeholder for `/pos` (Active Cart, Barcode Scanner,
/// 4-Tier Negotiation & Quick-Pad to be built in Step 9).
class PosScreen extends StatelessWidget {
  const PosScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutterMobile),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('POS Counter', style: t.headlineLarge),
                  Text(
                    'Nordic Botanical Shell • Ready for Barcode & Billing',
                    style: t.bodySmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            PasalStatusBadge(
              label: 'FEFO Active',
              icon: Icons.qr_code_scanner_rounded,
              backgroundColor: c.secondaryContainer,
              foregroundColor: c.onSecondaryContainer,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        PasalCard(
          color: c.surfaceContainerLow,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('CURRENT CART TOTAL', style: t.labelSmall),
                    const SizedBox(height: 4),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: PasalTabularText('Rs. 0.00', style: t.displayLarge),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              PasalPressable(
                onTap: () {},
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: c.primary,
                    borderRadius: BorderRadius.circular(AppRadii.lg),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.qr_code_scanner, color: c.onPrimary, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'Scan Item',
                        style: t.labelLarge?.copyWith(color: c.onPrimary),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

