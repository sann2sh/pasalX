import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/inventory/presentation/inventory_screen.dart';
import '../../features/pos/presentation/pos_screen.dart';
import '../../features/register/presentation/register_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import 'shell_scaffold.dart';

abstract final class AppRoutes {
  static const String pos = '/pos';
  static const String inventory = '/inventory';
  static const String register = '/register';
  static const String settings = '/settings';
}

/// Creates the application [GoRouter] configured with the 4-tab persistent
/// bottom navigation shell (`/pos`, `/inventory`, `/register`, `/settings`).
GoRouter createAppRouter({
  String initialLocation = AppRoutes.pos,
  GlobalKey<NavigatorState>? rootNavigatorKey,
}) {
  final navKey = rootNavigatorKey ?? GlobalKey<NavigatorState>();

  return GoRouter(
    navigatorKey: navKey,
    initialLocation: initialLocation,
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return PasalShellScaffold(navigationShell: navigationShell);
        },
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.pos,
                name: 'pos',
                builder: (context, state) => const PosScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.inventory,
                name: 'inventory',
                builder: (context, state) => const InventoryScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.register,
                name: 'register',
                builder: (context, state) => const RegisterScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.settings,
                name: 'settings',
                builder: (context, state) => const SettingsScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final router = createAppRouter();
  ref.onDispose(router.dispose);
  return router;
});

