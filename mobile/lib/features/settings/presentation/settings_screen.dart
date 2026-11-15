import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/pasal_widgets.dart';

/// Step 5 foundation placeholder for `/settings` (Xlab 365T Printer TCP `9100`,
/// Encrypted SQLCipher Vault Status & Device Kill-Switch Controls).
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final keyHolder = ref.watch(ramKeyHolderProvider);

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutterMobile),
      children: [
        Text('Settings & Security', style: t.headlineLarge),
        const SizedBox(height: 4),
        Text(
          'SQLCipher AES-256 Vault, Hardware Keystore & Xlab 365T Printer',
          style: t.bodySmall,
        ),
        const SizedBox(height: AppSpacing.md),
        PasalCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text('ENCRYPTION VAULT', style: t.labelMedium),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  PasalStatusBadge(
                    label: keyHolder.isUnlocked ? 'RAM DEK Loaded' : 'Locked',
                    backgroundColor: keyHolder.isUnlocked
                        ? c.secondaryContainer
                        : c.surfaceContainerHigh,
                    foregroundColor: keyHolder.isUnlocked
                        ? c.onSecondaryContainer
                        : c.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              PasalTabularText(
                'AES-256-CBC SQLCipher + Hardware Keystore (12h TTL)',
                style: t.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

