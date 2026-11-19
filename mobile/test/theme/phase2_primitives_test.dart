import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pasalx_mobile/core/theme/app_spacing.dart';
import 'package:pasalx_mobile/core/theme/app_theme.dart';
import 'package:pasalx_mobile/core/theme/pasal_widgets.dart';

void main() {
  group('Phase 2 Emil Kowalski Primitives', () {
    testWidgets(
      'PasalPressable scales to 0.97 on pointerDown and enforces 44x44 min hitbox',
      (tester) async {
        var tapped = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: Center(
                child: PasalPressable(
                  ensureMinTouchTarget: true,
                  onTap: () => tapped++,
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.add, size: 16),
                  ),
                ),
              ),
            ),
          ),
        );

        final hitbox = tester.getSize(find.byType(PasalPressable));
        expect(hitbox.width, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
        expect(hitbox.height, greaterThanOrEqualTo(AppSpacing.minTouchTarget));

        final center = tester.getCenter(find.byType(PasalPressable));
        final gesture = await tester.startGesture(center);
        await tester.pump(AppMotion.buttonPress);
        await tester.pump(const Duration(milliseconds: 20));

        final animatedScale = tester.widget<AnimatedScale>(
          find.byType(AnimatedScale),
        );
        expect(animatedScale.scale, AppMotion.pressScale);

        await gesture.up();
        await tester.pumpAndSettle();

        final releasedScale = tester.widget<AnimatedScale>(
          find.byType(AnimatedScale),
        );
        expect(releasedScale.scale, 1.0);
        expect(tapped, 1);
      },
    );

    testWidgets(
      'PasalPressable suppresses scale transform under disableAnimations',
      (tester) async {
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: MaterialApp(
              theme: AppTheme.light(),
              home: Scaffold(
                body: PasalPressable(
                  onTap: () {},
                  child: const Text('Tap Me'),
                ),
              ),
            ),
          ),
        );

        final gesture = await tester.startGesture(
          tester.getCenter(find.text('Tap Me')),
        );
        await tester.pump();

        final animatedScale = tester.widget<AnimatedScale>(
          find.byType(AnimatedScale),
        );
        expect(animatedScale.scale, 1.0);
        expect(animatedScale.duration, Duration.zero);

        await gesture.up();
        await tester.pump();
      },
    );

    testWidgets(
      'PasalClipSegmentedTabs renders single Text per tab and transitions cleanly',
      (tester) async {
        String selected = 'sales';
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: SizedBox(
                width: 320,
                child: StatefulBuilder(
                  builder: (context, setState) {
                    return PasalClipSegmentedTabs<String>(
                      selectedValue: selected,
                      onChanged: (v) => setState(() => selected = v),
                      options: const [
                        PasalSegmentOption(value: 'sales', label: 'Sales (12)'),
                        PasalSegmentOption(
                          value: 'purchases',
                          label: 'Purchases (4)',
                        ),
                        PasalSegmentOption(
                          value: 'expenses',
                          label: 'Expenses (3)',
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );

        expect(find.text('Sales (12)'), findsOneWidget);
        expect(find.text('Purchases (4)'), findsOneWidget);
        expect(find.text('Expenses (3)'), findsOneWidget);

        await tester.tap(find.text('Expenses (3)'));
        await tester.pumpAndSettle();
        expect(selected, 'expenses');
      },
    );

    testWidgets(
      'PasalHoldToConfirmButton ignores short tap and fires after 2000ms hold',
      (tester) async {
        var confirmedCount = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: Center(
                child: PasalHoldToConfirmButton(
                  label: 'Hold to Revoke Device',
                  holdingLabel: 'Keep holding to revoke...',
                  onConfirmed: () => confirmedCount++,
                ),
              ),
            ),
          ),
        );

        final center = tester.getCenter(find.byType(PasalHoldToConfirmButton));

        // 1. Short 400ms tap must NOT confirm and should snap back.
        final shortHold = await tester.startGesture(center);
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Keep holding to revoke...'), findsOneWidget);
        await shortHold.up();
        await tester.pumpAndSettle();
        expect(confirmedCount, 0);
        expect(find.text('Hold to Revoke Device'), findsOneWidget);

        // 2. Full 2000ms hold MUST confirm once.
        final fullHold = await tester.startGesture(center);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 2050));
        expect(confirmedCount, 1);
        await fullHold.up();
        await tester.pumpAndSettle();
        expect(confirmedCount, 1);
      },
    );

    testWidgets(
      'PasalBlurStateSwitcher crossfades keyed states cleanly',
      (tester) async {
        String state = 'idle';
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  return Column(
                    children: [
                      PasalBlurStateSwitcher(
                        child: Text(
                          state == 'idle' ? 'Sync Now' : 'Syncing...',
                          key: ValueKey<String>(state),
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() => state = 'busy'),
                        child: const Text('Go'),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );

        expect(find.text('Sync Now'), findsOneWidget);
        await tester.tap(find.text('Go'));
        await tester.pump(const Duration(milliseconds: 90));
        await tester.pumpAndSettle();
        expect(find.text('Syncing...'), findsOneWidget);
      },
    );

    testWidgets(
      'showPasalDialog and showPasalBottomSheet open and close cleanly',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: Builder(
                builder: (context) => Column(
                  children: [
                    TextButton(
                      onPressed: () => showPasalDialog<void>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Custom Dialog'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(ctx).pop(),
                              child: const Text('Close Dialog'),
                            ),
                          ],
                        ),
                      ),
                      child: const Text('Open Dialog'),
                    ),
                    TextButton(
                      onPressed: () => showPasalBottomSheet<void>(
                        context: context,
                        builder: (ctx) => Container(
                          color: Colors.white,
                          height: 200,
                          child: Center(
                            child: TextButton(
                              onPressed: () => Navigator.of(ctx).pop(),
                              child: const Text('Close Sheet'),
                            ),
                          ),
                        ),
                      ),
                      child: const Text('Open Sheet'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open Dialog'));
        await tester.pumpAndSettle();
        expect(find.text('Custom Dialog'), findsOneWidget);
        await tester.tap(find.text('Close Dialog'));
        await tester.pumpAndSettle();
        expect(find.text('Custom Dialog'), findsNothing);

        await tester.tap(find.text('Open Sheet'));
        await tester.pumpAndSettle();
        expect(find.text('Close Sheet'), findsOneWidget);
        await tester.tap(find.text('Close Sheet'));
        await tester.pumpAndSettle();
        expect(find.text('Close Sheet'), findsNothing);
      },
    );

    testWidgets(
      'PasalAlertOverlay pauses auto-dismiss on touch and has >=44px close hitbox',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(),
              home: const PasalAlertOverlay(
                child: Scaffold(body: SizedBox.expand()),
              ),
            ),
          ),
        );

        container.read(pasalAlertProvider).showSuccess(
              'Synced 12 bills',
              duration: const Duration(milliseconds: 500),
            );
        await tester.pumpAndSettle();

        final closeSize = tester.getSize(
          find.byKey(const ValueKey<String>('pasal-alert-dismiss-btn')),
        );
        expect(closeSize.width, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
        expect(closeSize.height, greaterThanOrEqualTo(AppSpacing.minTouchTarget));

        // Hold pointer down on banner longer than 500ms -> should NOT auto-dismiss.
        final hold = await tester.startGesture(
          tester.getCenter(find.text('Synced 12 bills')),
        );
        await tester.pump(const Duration(milliseconds: 700));
        expect(find.text('Synced 12 bills'), findsOneWidget);

        // Release pointer -> resumes remaining timer and dismisses.
        await hold.up();
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();
        expect(find.text('Synced 12 bills'), findsNothing);
      },
    );
  });
}
