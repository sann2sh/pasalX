import 'package:flutter/material.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';

/// Step 5 foundation placeholder for `/register` (Single-Galla Cash Register,
/// Petty Expenses, Staff Punch-Out & Z-Report to be built in Step 10).
class RegisterScreen extends StatelessWidget {
  const RegisterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutterMobile),
      children: [
        Text('Register & Shift', style: t.headlineLarge),
        const SizedBox(height: 4),
        Text(
          'Single-Galla Cash Drawer & Z-Report Reconciliation',
          style: t.bodySmall,
        ),
        const SizedBox(height: AppSpacing.md),
        PasalCard(
          color: c.surfaceContainerLow,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('EXPECTED DRAWER CASH', style: t.labelSmall),
              const SizedBox(height: 4),
              PasalTabularText('Rs. 0.00', style: t.displayLarge),
              const SizedBox(height: AppSpacing.sm),
              PasalStatusBadge(
                label: 'Shift Not Opened',
                backgroundColor: c.surfaceContainerHigh,
                foregroundColor: c.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

