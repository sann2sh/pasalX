import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/foundation_providers.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import '../theme/pasal_widgets.dart';

class _NavTabSpec {
  const _NavTabSpec({
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.routePath,
  });

  final String label;
  final IconData icon;
  final IconData activeIcon;
  final String routePath;
}

const List<_NavTabSpec> _tabs = [
  _NavTabSpec(
    label: 'POS',
    icon: Icons.point_of_sale_outlined,
    activeIcon: Icons.point_of_sale_rounded,
    routePath: '/pos',
  ),
  _NavTabSpec(
    label: 'Inventory',
    icon: Icons.inventory_2_outlined,
    activeIcon: Icons.inventory_2_rounded,
    routePath: '/inventory',
  ),
  _NavTabSpec(
    label: 'Register',
    icon: Icons.account_balance_wallet_outlined,
    activeIcon: Icons.account_balance_wallet_rounded,
    routePath: '/register',
  ),
  _NavTabSpec(
    label: 'Settings',
    icon: Icons.tune_outlined,
    activeIcon: Icons.tune_rounded,
    routePath: '/settings',
  ),
];

/// Persistent Stitch-calibrated 4-tab navigation shell (`/pos`, `/inventory`,
/// `/register`, `/settings`) using [StatefulNavigationShell].
class PasalShellScaffold extends ConsumerWidget {
  const PasalShellScaffold({
    super.key,
    required this.navigationShell,
  });

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final keyHolder = ref.watch(ramKeyHolderProvider);
    final session = keyHolder.session;
    final vaultUnlocked = keyHolder.isUnlocked;

    return Scaffold(
      backgroundColor: c.surface,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(64),
        child: Container(
          decoration: BoxDecoration(
            color: c.surface.withValues(alpha: 0.94),
            border: Border(bottom: BorderSide(color: c.hairline)),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.gutterMobile,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'PasalX',
                              style: t.headlineSmall?.copyWith(
                                height: 1.0,
                                letterSpacing: -0.3,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'APOTHECARY & POS',
                              style: t.labelSmall?.copyWith(
                                color: c.onSurfaceVariant,
                                letterSpacing: 1.1,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: PasalStatusBadge(
                              label: vaultUnlocked
                                  ? 'Terminal ${session?.deviceCode ?? '--'}'
                                  : 'Vault Locked',
                              dotColor: vaultUnlocked ? c.primary : c.secondary,
                              backgroundColor: c.secondaryContainer,
                              foregroundColor: c.onSecondaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (session != null)
                        Padding(
                          padding: const EdgeInsets.only(right: AppSpacing.sm),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                session.role.toUpperCase(),
                                style: t.labelSmall,
                              ),
                              Text(
                                session.username,
                                style: t.labelMedium?.copyWith(
                                  color: c.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: c.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          vaultUnlocked
                              ? Icons.verified_user_rounded
                              : Icons.person_outline_rounded,
                          color: c.onPrimary,
                          size: 18,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: navigationShell,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: c.surfaceContainerLowest.withValues(alpha: 0.96),
          border: Border(top: BorderSide(color: c.hairline)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 64,
            child: Row(
              children: List.generate(_tabs.length, (index) {
                final tab = _tabs[index];
                final selected = navigationShell.currentIndex == index;
                return Expanded(
                  child: _BottomNavButton(
                    tab: tab,
                    selected: selected,
                    onTap: () => navigationShell.goBranch(
                      index,
                      initialLocation: index == navigationShell.currentIndex,
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomNavButton extends StatelessWidget {
  const _BottomNavButton({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final _NavTabSpec tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final fg = selected ? c.primary : c.onSurfaceVariant;

    return PasalPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: AppMotion.popover,
              curve: AppMotion.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
              decoration: BoxDecoration(
                color: selected ? c.secondaryContainer : Colors.transparent,
                borderRadius: BorderRadius.circular(AppRadii.pill),
              ),
              child: Icon(
                selected ? tab.activeIcon : tab.icon,
                size: 22,
                color: fg,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              tab.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.labelSmall?.copyWith(
                color: fg,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

