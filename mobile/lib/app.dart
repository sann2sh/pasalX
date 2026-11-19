import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/providers/foundation_providers.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/pasal_alert.dart';

/// Root PasalX Mobile Application widget wired with Nordic Botanical theme tokens,
/// lifecycle lease enforcement on OS sleep resume, subtle alert overlays, and `go_router` 5-tab navigation.
class PasalXApp extends ConsumerStatefulWidget {
  const PasalXApp({
    super.key,
    this.routerOverride,
  });

  final GoRouter? routerOverride;

  @override
  ConsumerState<PasalXApp> createState() => _PasalXAppState();
}

class _PasalXAppState extends ConsumerState<PasalXApp> {
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(
      onResume: _enforceLeaseOnResume,
    );
  }

  void _enforceLeaseOnResume() {
    ref.read(ramKeyHolderProvider).enforceLeaseValidity();
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = widget.routerOverride ?? ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'PasalX',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      routerConfig: router,
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
          systemNavigationBarColor: PasalColors.light.surfaceContainerLowest,
          systemNavigationBarIconBrightness: Brightness.dark,
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          child: PasalAlertOverlay(
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

