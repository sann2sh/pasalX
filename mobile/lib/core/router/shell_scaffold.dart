import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/foundation_providers.dart';
import '../security/ram_key_holder.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import '../theme/pasal_widgets.dart';

class _NavTabSpec {
  const _NavTabSpec({
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.routePath,
    this.isCenterPrimary = false,
  });

  final String label;
  final IconData icon;
  final IconData activeIcon;
  final String routePath;
  final bool isCenterPrimary;
}

const List<_NavTabSpec> _tabs = [
  _NavTabSpec(
    label: 'Home',
    icon: Icons.home_outlined,
    activeIcon: Icons.home_rounded,
    routePath: '/home',
  ),
  _NavTabSpec(
    label: 'History',
    icon: Icons.receipt_long_outlined,
    activeIcon: Icons.receipt_long_rounded,
    routePath: '/history',
  ),
  _NavTabSpec(
    label: 'Sale',
    icon: Icons.add_rounded,
    activeIcon: Icons.add_rounded,
    routePath: '/pos',
    isCenterPrimary: true,
  ),
  _NavTabSpec(
    label: 'Stock',
    icon: Icons.inventory_2_outlined,
    activeIcon: Icons.inventory_2_rounded,
    routePath: '/inventory',
  ),
  _NavTabSpec(
    label: 'Shift',
    icon: Icons.schedule_outlined,
    activeIcon: Icons.schedule_rounded,
    routePath: '/register',
  ),
];

/// Derives two-letter uppercase initials for the single topbar profile avatar.
String _profileInitials(ActiveLeaseSession? session) {
  final raw = session?.username.trim() ?? '';
  if (raw.isEmpty) return 'PX';
  final parts = raw.split(RegExp(r'[\s._-]+')).where((p) => p.isNotEmpty).toList();
  if (parts.length >= 2) {
    return '${parts.first[0]}${parts[1][0]}'.toUpperCase();
  }
  if (raw.length >= 2) {
    return raw.substring(0, 2).toUpperCase();
  }
  return raw.toUpperCase();
}

String _displayFirstName(ActiveLeaseSession? session) {
  final raw = session?.username.trim() ?? '';
  if (raw.isEmpty) return 'Today';
  final first = raw.split(RegExp(r'[\s._-]+')).first;
  if (first.isEmpty) return 'Today';
  return '${first[0].toUpperCase()}${first.substring(1)}';
}

({String title, String subtitle}) _headerMetaForTab(
  int index,
  ActiveLeaseSession? session,
) {
  switch (index) {
    case 0:
      final shiftLabel = session != null
          ? "${_displayFirstName(session)}'s Shift • Shop Open"
          : 'Today • Shop Open';
      return (title: 'PasalX', subtitle: shiftLabel);
    case 1:
      return (title: 'History', subtitle: 'Sales · Purchases · Exp');
    case 2:
      return (title: 'POS Counter', subtitle: 'Active Cart');
    case 3:
      return (title: 'Stock Catalog', subtitle: 'Products & Batches');
    case 4:
      final dev = (session?.deviceCode.trim().isNotEmpty ?? false)
          ? session!.deviceCode
          : '01';
      return (title: "Today's Shift", subtitle: 'Register #$dev');
    default:
      return (title: 'PasalX', subtitle: 'Shop Open');
  }
}

/// Shared 64px Nordic Botanical top app bar for pushed stack screens.
class PasalStackAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const PasalStackAppBar({
    super.key,
    required this.title,
    this.subtitle,
    this.showProfileAvatar = false,
    this.trailingActions = const <Widget>[],
    this.onBack,
  });

  final String title;
  final String? subtitle;
  final bool showProfileAvatar;
  final List<Widget> trailingActions;
  final VoidCallback? onBack;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.pasalColors;
    final t = context.textTheme;
    final session = ref.watch(ramKeyHolderProvider).session;

    return Container(
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.96),
        border: Border(bottom: BorderSide(color: c.hairline)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutterMobile),
          child: SizedBox(
            height: 64,
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(width: 36, height: 36),
                  icon: Icon(Icons.arrow_back_rounded, color: c.onSurface, size: 22),
                  onPressed: onBack ??
                      () {
                        if (context.canPop()) {
                          context.pop();
                        } else {
                          context.go('/home');
                        }
                      },
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.headlineSmall?.copyWith(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                          height: 1.1,
                        ),
                      ),
                      if (subtitle != null && subtitle!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.labelSmall?.copyWith(
                            color: c.outline,
                            letterSpacing: 0.9,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                ...trailingActions,
                if (showProfileAvatar) ...[
                  if (trailingActions.isNotEmpty) const SizedBox(width: 8),
                  _ProfileAvatarButton(
                    initials: _profileInitials(session),
                    onTap: () => context.push('/settings'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Persistent Stitch-calibrated 5-tab navigation shell (`/home`, `/history`,
/// `/pos`, `/inventory`, `/register`) with a single Profile Avatar opening `/settings`.
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
    final session = ref.watch(ramKeyHolderProvider).session;
    final currentIndex = navigationShell.currentIndex;
    final headerMeta = _headerMetaForTab(currentIndex, session);
    final canManageStock = session != null &&
        (session.role == 'OWNER' || session.role == 'MANAGER');

    return Scaffold(
      backgroundColor: c.surface,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(64),
        child: Container(
          decoration: BoxDecoration(
            color: c.surface.withValues(alpha: 0.96),
            border: Border(bottom: BorderSide(color: c.hairline)),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.gutterMobile,
              ),
              child: SizedBox(
                height: 64,
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            headerMeta.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.headlineSmall?.copyWith(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                              height: 1.1,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            headerMeta.subtitle.toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.labelSmall?.copyWith(
                              color: c.outline,
                              letterSpacing: 0.9,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (currentIndex == 3 && canManageStock) ...[
                      PasalPressable(
                        borderRadius: BorderRadius.circular(AppRadii.md),
                        onTap: () => context.push('/inventory/intake'),
                        child: Container(
                          key: const ValueKey<String>('topbar-intake-btn'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: c.primary,
                            borderRadius: BorderRadius.circular(AppRadii.md),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add_rounded, size: 15, color: c.onPrimary),
                              const SizedBox(width: 4),
                              Text(
                                'Intake',
                                style: t.labelMedium?.copyWith(
                                  color: c.onPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    _ProfileAvatarButton(
                      initials: _profileInitials(session),
                      onTap: () => context.push('/settings'),
                    ),
                  ],
                ),
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
            height: 68,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: List.generate(_tabs.length, (index) {
                  final tab = _tabs[index];
                  final selected = currentIndex == index;
                  return Expanded(
                    child: tab.isCenterPrimary
                        ? _CenterSaleButton(
                            tab: tab,
                            selected: selected,
                            onTap: () => navigationShell.goBranch(
                              index,
                              initialLocation: index == currentIndex,
                            ),
                          )
                        : _BottomNavButton(
                            tab: tab,
                            selected: selected,
                            onTap: () => navigationShell.goBranch(
                              index,
                              initialLocation: index == currentIndex,
                            ),
                          ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileAvatarButton extends StatelessWidget {
  const _ProfileAvatarButton({
    required this.initials,
    required this.onTap,
  });

  final String initials;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.pasalColors;
    final t = context.textTheme;
    return Semantics(
      button: true,
      label: 'Profile & Settings',
      child: PasalPressable(
        borderRadius: BorderRadius.circular(AppRadii.pill),
        onTap: onTap,
        child: Tooltip(
          message: 'Profile & Settings',
          child: Container(
            key: const ValueKey<String>('topbar-profile-btn'),
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: c.primary,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              initials,
              style: t.labelMedium?.copyWith(
                color: c.onPrimary,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CenterSaleButton extends StatelessWidget {
  const _CenterSaleButton({
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

    return PasalPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: SizedBox.expand(
        child: Center(
          child: Column(
            key: const ValueKey<String>('nav-tab-pos'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.translate(
                offset: const Offset(0, -6),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: c.primary,
                    shape: BoxShape.circle,
                    border: selected
                        ? Border.all(color: c.primaryFixed, width: 2)
                        : null,
                    boxShadow: [
                      BoxShadow(
                        color: c.primary.withValues(alpha: 0.28),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(
                    tab.icon,
                    color: c.onPrimary,
                    size: 24,
                  ),
                ),
              ),
              Text(
                tab.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.labelSmall?.copyWith(
                  color: selected ? c.primary : c.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  fontSize: 10,
                  letterSpacing: 0.3,
                  height: 1.0,
                ),
              ),
            ],
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
            Icon(
              selected ? tab.activeIcon : tab.icon,
              size: 22,
              color: fg,
            ),
            const SizedBox(height: 2),
            Text(
              tab.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.labelSmall?.copyWith(
                color: fg,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                fontSize: 10,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
