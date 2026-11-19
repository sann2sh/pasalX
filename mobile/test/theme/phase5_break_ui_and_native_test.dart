import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pasalx_mobile/core/database/app_database.dart';
import 'package:pasalx_mobile/core/providers/foundation_providers.dart';
import 'package:pasalx_mobile/core/security/ram_key_holder.dart';
import 'package:pasalx_mobile/core/theme/app_theme.dart';
import 'package:pasalx_mobile/core/theme/break_ui_harness.dart';
import 'package:pasalx_mobile/core/theme/pasal_widgets.dart';
import 'package:pasalx_mobile/features/inventory/application/inventory_providers.dart';
import 'package:pasalx_mobile/features/inventory/presentation/inventory_screen.dart';
import 'package:pasalx_mobile/features/pos/application/pos_providers.dart';
import 'package:pasalx_mobile/features/pos/presentation/khata_ledger_screen.dart';
import 'package:pasalx_mobile/features/pos/presentation/pos_screen.dart';

void main() {
  group('Phase 5 Mobile-Native & break-ui Stress Suite', () {
    test('PasalTextUtils handles grapheme clusters, 1-char names & singular plurals', () {
      expect(
        PasalTextUtils.initials(BreakUiWorstCaseFixtures.longCustomerName),
        'AC',
      );
      expect(
        PasalTextUtils.initials(BreakUiWorstCaseFixtures.emojiDevanagariName),
        '🙏श्रे',
      );
      expect(PasalTextUtils.initials('Jo'), 'JO');
      expect(PasalTextUtils.initials('J'), 'J');
      expect(PasalTextUtils.initials('   '), 'PX');

      expect(PasalTextUtils.plural(0, 'SKU'), '0 SKUs');
      expect(PasalTextUtils.plural(1, 'SKU'), '1 SKU');
      expect(PasalTextUtils.plural(2, 'SKU'), '2 SKUs');
      expect(PasalTextUtils.plural(1, 'unit'), '1 unit');
      expect(PasalTextUtils.plural(1, 'Alert'), '1 Alert');
    });

    testWidgets(
      'PosScreen renders worst-case names and DECIMAL(10,2) ceiling at 320x640 and 2.0x text scale without overflow',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final now = DateTime.now().toUtc();
        final holder = RamKeyHolder()
          ..unlock(
            dekBytes: Uint8List(32),
            session: ActiveLeaseSession(
              userId: 'u1',
              username: 'sita',
              role: 'STAFF',
              deviceId: 'd1',
              deviceCode: '01',
              leaseId: 'l1',
              issuedAt: now,
              expiresAt: now.add(const Duration(hours: 12)),
            ),
          );

        final container = ProviderContainer(
          overrides: [ramKeyHolderProvider.overrideWith((ref) => holder)],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2.0),
                ),
                child: PasalAlertOverlay(
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
              home: const Scaffold(body: PosScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final cart = container.read(posCartProvider.notifier);
        for (final batch in BreakUiWorstCaseFixtures.posBatchesFor(
          BreakUiDatasetMode.worstCase,
        )) {
          cart.addBatch(batch);
        }
        cart.selectCustomer(
          CustomerRow(
            id: 'cust-emoji',
            name: BreakUiWorstCaseFixtures.emojiDevanagariName,
            phone: '9800000000',
            creditLimit: 500000,
            currentBalanceDue: 125000,
            favoriteShadeNotes: BreakUiWorstCaseFixtures.longVariantName,
            createdAt: now,
            updatedAt: now,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('🙏श्रे'), findsOneWidget);
        expect(find.text(BreakUiWorstCaseFixtures.emojiDevanagariName), findsAtLeastNWidgets(1));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'InventoryScreen BreakUiOverlayToggle cycles Singular / Worst case / Empty / 1,000 rows cleanly at 320x640',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final now = DateTime.now().toUtc();
        final holder = RamKeyHolder()
          ..unlock(
            dekBytes: Uint8List(32),
            session: ActiveLeaseSession(
              userId: 'u1',
              username: 'owner',
              role: 'OWNER',
              deviceId: 'd1',
              deviceCode: '01',
              leaseId: 'l1',
              issuedAt: now,
              expiresAt: now.add(const Duration(hours: 12)),
            ),
          );

        final modeProvider = StateProvider<BreakUiDatasetMode>(
          (ref) => BreakUiDatasetMode.singular,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ramKeyHolderProvider.overrideWith((ref) => holder),
              catalogNodesProvider.overrideWith((ref) {
                final m = ref.watch(modeProvider);
                return Stream.value(
                  BreakUiWorstCaseFixtures.catalogNodesFor(m),
                );
              }),
              inventorySuppliersProvider.overrideWith(
                (ref) => Stream.value(const <SupplierRow>[]),
              ),
            ],
            child: Consumer(
              builder: (context, ref, _) {
                final mode = ref.watch(modeProvider);
                return MaterialApp(
                  theme: AppTheme.light(),
                  home: Scaffold(
                    body: BreakUiOverlayToggle(
                      mode: mode,
                      enabled: true,
                      onChanged: (next) =>
                          ref.read(modeProvider.notifier).state = next,
                      child: const InventoryScreen(),
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Singular mode checks pluralization fixes: "1 SKU", "1 unit", "1 Alert".
        expect(find.text('1 SKU'), findsOneWidget);
        expect(find.text('1 unit'), findsOneWidget);
        expect(find.text('1 Alert'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Flip toggle -> Worst case.
        await tester.tap(find.text('Worst case'));
        await tester.pumpAndSettle();
        expect(
          find.text(BreakUiWorstCaseFixtures.longProductName),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);

        // Flip toggle -> Empty.
        await tester.tap(find.text('Empty'));
        await tester.pumpAndSettle();
        expect(find.text('0 SKUs'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Flip toggle -> 1,000 rows.
        await tester.tap(find.text('1,000 rows'));
        await tester.pumpAndSettle();
        expect(find.text('1000 SKUs'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'KhataLedgerScreen handles long/emoji customers at 320x640 and 2.0x text scale without overflow',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final now = DateTime.now().toUtc();
        final customers = <CustomerRow>[
          CustomerRow(
            id: 'c-worst',
            name: BreakUiWorstCaseFixtures.longCustomerName,
            phone: '9800000001',
            creditLimit: 500000,
            currentBalanceDue: 250000,
            favoriteShadeNotes: BreakUiWorstCaseFixtures.longVariantName,
            createdAt: now,
            updatedAt: now,
          ),
        ];

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              customerListProvider('').overrideWith(
                (ref) => Stream.value(customers),
              ),
            ],
            child: MaterialApp(
              theme: AppTheme.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2.0),
                ),
                child: child ?? const SizedBox.shrink(),
              ),
              home: const KhataLedgerScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(BreakUiWorstCaseFixtures.longCustomerName),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  });
}
