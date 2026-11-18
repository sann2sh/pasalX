import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/application/auth_session_controller.dart';
import '../../features/auth/presentation/shift_open_login_screen.dart';
import '../../features/history/presentation/history_screen.dart';
import '../../features/history/presentation/sale_detail_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/inventory/presentation/barcode_scanner_sheet.dart';
import '../../features/inventory/presentation/inventory_screen.dart';
import '../../features/inventory/presentation/product_detail_screen.dart';
import '../../features/inventory/presentation/smart_intake_screen.dart';
import '../../features/pos/presentation/khata_ledger_screen.dart';
import '../../features/pos/presentation/pos_screen.dart';
import '../../features/pos/presentation/quick_pad_sheet.dart';
import '../../features/register/presentation/register_screen.dart';
import '../../features/settings/presentation/backup_settings_screen.dart';
import '../../features/settings/presentation/printer_settings_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/suppliers/presentation/purchase_detail_screen.dart';
import '../../features/suppliers/presentation/suppliers_screen.dart';
import 'shell_scaffold.dart';

abstract final class AppRoutes {
  static const String login = '/login';
  static const String home = '/home';
  static const String history = '/history';
  static const String historySaleDetail = '/history/sale/:id';
  static const String historyPurchaseDetail = '/history/purchase/:id';
  static const String pos = '/pos';
  static const String posScanner = '/pos/scanner';
  static const String posQuickPad = '/pos/quickpad';
  static const String inventory = '/inventory';
  static const String inventoryIntake = '/inventory/intake';
  static const String inventoryProductDetail = '/inventory/product/:id';
  static const String register = '/register';
  static const String khata = '/khata';
  static const String suppliers = '/suppliers';
  static const String settings = '/settings';
  static const String settingsPrinter = '/settings/printer';
  static const String settingsBackup = '/settings/backup';

  static String saleDetail(String id) => '/history/sale/$id';
  static String purchaseDetail(String id) => '/history/purchase/$id';
  static String productDetail(String id) => '/inventory/product/$id';
}

/// Creates the application [GoRouter] configured with the 5-tab persistent
/// bottom navigation shell (`/home`, `/history`, `/pos`, `/inventory`, `/register`)
/// plus stack routes and optional [authGate] protection enforcing `/login` when locked.
GoRouter createAppRouter({
  String? initialLocation,
  GlobalKey<NavigatorState>? rootNavigatorKey,
  AuthSessionController? authGate,
}) {
  final navKey = rootNavigatorKey ?? GlobalKey<NavigatorState>();
  final start =
      initialLocation ?? (authGate == null ? AppRoutes.home : AppRoutes.login);

  return GoRouter(
    navigatorKey: navKey,
    initialLocation: start,
    refreshListenable: authGate,
    redirect: authGate == null
        ? null
        : (context, state) {
            final ready = authGate.state.isReady;
            final onLogin = state.matchedLocation == AppRoutes.login;
            if (!ready && !onLogin) {
              return AppRoutes.login;
            }
            if (ready && onLogin) {
              return AppRoutes.home;
            }
            return null;
          },
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.login,
        name: 'login',
        builder: (context, state) => const ShiftOpenLoginScreen(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return PasalShellScaffold(navigationShell: navigationShell);
        },
        branches: <StatefulShellBranch>[
          // Branch 0: Home Dashboard
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.home,
                name: 'home',
                builder: (context, state) => const HomeScreen(),
              ),
            ],
          ),
          // Branch 1: History
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.history,
                name: 'history',
                builder: (context, state) => const HistoryScreen(),
                routes: [
                  GoRoute(
                    path: 'sale/:id',
                    name: 'history-sale-detail',
                    parentNavigatorKey: navKey,
                    builder: (context, state) => SaleDetailScreen(
                      saleId: state.pathParameters['id']!,
                    ),
                  ),
                  GoRoute(
                    path: 'purchase/:id',
                    name: 'history-purchase-detail',
                    parentNavigatorKey: navKey,
                    builder: (context, state) => PurchaseDetailScreen(
                      purchaseId: state.pathParameters['id']!,
                    ),
                  ),
                ],
              ),
            ],
          ),
          // Branch 2: Sale (+) POS Counter
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.pos,
                name: 'pos',
                builder: (context, state) => const PosScreen(),
                routes: [
                  GoRoute(
                    path: 'scanner',
                    name: 'pos-scanner',
                    parentNavigatorKey: navKey,
                    builder: (context, state) => const BarcodeScannerScreen(),
                  ),
                  GoRoute(
                    path: 'quickpad',
                    name: 'pos-quickpad',
                    parentNavigatorKey: navKey,
                    builder: (context, state) => const QuickPadScreen(),
                  ),
                ],
              ),
            ],
          ),
          // Branch 3: Stock Catalog
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.inventory,
                name: 'inventory',
                builder: (context, state) => const InventoryScreen(),
                routes: [
                  GoRoute(
                    path: 'intake',
                    name: 'inventory-intake',
                    parentNavigatorKey: navKey,
                    builder: (context, state) => SmartIntakeScreen(
                      initialProductId: state.uri.queryParameters['productId'],
                      initialVariantId: state.uri.queryParameters['variantId'],
                    ),
                  ),
                  GoRoute(
                    path: 'product/:id',
                    name: 'inventory-product-detail',
                    parentNavigatorKey: navKey,
                    builder: (context, state) => ProductDetailScreen(
                      productId: state.pathParameters['id']!,
                    ),
                  ),
                ],
              ),
            ],
          ),
          // Branch 4: Today's Shift & Cash Drawer
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.register,
                name: 'register',
                builder: (context, state) => const RegisterScreen(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.khata,
        name: 'khata',
        parentNavigatorKey: navKey,
        builder: (context, state) => KhataLedgerScreen(
          initialCustomerId: state.uri.queryParameters['customerId'],
        ),
      ),
      GoRoute(
        path: AppRoutes.suppliers,
        name: 'suppliers',
        parentNavigatorKey: navKey,
        builder: (context, state) => const SuppliersScreen(),
      ),
      GoRoute(
        path: AppRoutes.settings,
        name: 'settings',
        parentNavigatorKey: navKey,
        builder: (context, state) => const SettingsScreen(),
        routes: [
          GoRoute(
            path: 'printer',
            name: 'settings-printer',
            parentNavigatorKey: navKey,
            builder: (context, state) => const PrinterSettingsScreen(),
          ),
          GoRoute(
            path: 'backup',
            name: 'settings-backup',
            parentNavigatorKey: navKey,
            builder: (context, state) => const BackupSettingsScreen(),
          ),
        ],
      ),
    ],
  );
}

final appRouterProvider = Provider<GoRouter>((ref) {
  // Read rather than watch: GoRouter subscribes via refreshListenable and must
  // keep a single router instance across AuthSessionController notifications.
  final authGate = ref.read(authSessionControllerProvider);
  final router = createAppRouter(authGate: authGate);
  ref.onDispose(router.dispose);
  return router;
});
