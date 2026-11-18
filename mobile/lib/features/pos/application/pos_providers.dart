import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/providers/foundation_providers.dart';
import '../../auth/application/auth_session_controller.dart';
import '../data/pos_repository.dart';
import '../domain/pos_models.dart';

/// Provides [PosRepository] bound to the currently unlocked SQLCipher database,
/// returning `null` while the vault is locked.
final posRepositoryProvider = Provider<PosRepository?>((ref) {
  final db = ref.watch(activeDatabaseProvider);
  if (db == null) return null;
  final syncWorker = ref.read(syncOutboxWorkerProvider);
  return PosRepository(
    db: db,
    onMutationCommitted: () => syncWorker.scheduleImmediateSync(),
  );
});

/// Watches up to 9 Generic items for the 3x3 Quick-Pad.
final quickPadItemsProvider =
    StreamProvider.autoDispose<List<PosScannedBatch>>((ref) {
  final repo = ref.watch(posRepositoryProvider);
  if (repo == null) {
    return Stream<List<PosScannedBatch>>.value(const <PosScannedBatch>[]);
  }
  final role = ref.watch(ramKeyHolderProvider).session?.role;
  return repo.watchQuickPadItems(role: role);
});

/// Watches Khata customers filtered by [query].
final customerListProvider =
    StreamProvider.autoDispose.family<List<CustomerRow>, String>((ref, query) {
  final repo = ref.watch(posRepositoryProvider);
  if (repo == null) {
    return Stream<List<CustomerRow>>.value(const <CustomerRow>[]);
  }
  return repo.watchCustomers(query: query);
});

/// Active POS Cart state controller.
class PosCartController extends Notifier<PosCartState> {
  @override
  PosCartState build() {
    // Clear volatile cart state if the vault locks or wipes.
    ref.listen<AppDatabase?>(activeDatabaseProvider, (_, next) {
      if (next == null) {
        state = const PosCartState();
      }
    });
    return const PosCartState();
  }

  /// Adds a non-expired [batch] (or increments quantity if already in cart).
  void addBatch(
    PosScannedBatch batch, {
    int? overrideUnitPricePaisa,
    int quantity = 1,
  }) {
    if (quantity <= 0) return;
    final unitPrice = overrideUnitPricePaisa ?? batch.sellingPricePaisa;
    final lineKey = overrideUnitPricePaisa != null
        ? '${batch.batchId}#$unitPrice'
        : batch.batchId;

    final existingIdx =
        state.items.indexWhere((element) => element.lineKey == lineKey);
    final updated = List<PosCartItem>.of(state.items);
    if (existingIdx >= 0) {
      final current = updated[existingIdx];
      updated[existingIdx] = current.copyWith(
        quantity: current.quantity + quantity,
      );
    } else {
      updated.add(
        PosCartItem(
          lineKey: lineKey,
          batchId: batch.batchId,
          productId: batch.productId,
          variantId: batch.variantId,
          productName: batch.productName,
          variantName: batch.variantName,
          batchCode: batch.batchCode,
          stickerBarcode: batch.stickerBarcode,
          isGeneric: batch.isGeneric,
          unitPricePaisa: unitPrice,
          mrpPaisa: batch.sellingPricePaisa,
          costPricePaisa: batch.costPricePaisa,
          quantity: quantity,
          availableStock: batch.stockQuantity,
          expiryDate: batch.expiryDate,
          colorHex: batch.colorHex,
          sizeVolume: batch.sizeVolume,
        ),
      );
    }
    state = state.copyWith(items: updated);
  }

  void incrementQty(String lineKey) {
    final updated = state.items
        .map(
          (i) => i.lineKey == lineKey ? i.copyWith(quantity: i.quantity + 1) : i,
        )
        .toList(growable: false);
    state = state.copyWith(items: updated);
  }

  void decrementQty(String lineKey) {
    final updated = <PosCartItem>[];
    for (final item in state.items) {
      if (item.lineKey != lineKey) {
        updated.add(item);
      } else if (item.quantity > 1) {
        updated.add(item.copyWith(quantity: item.quantity - 1));
      }
    }
    state = state.copyWith(items: updated);
  }

  void removeItem(String lineKey) {
    final updated =
        state.items.where((i) => i.lineKey != lineKey).toList(growable: false);
    state = state.copyWith(items: updated);
  }

  void updateItem(
    String lineKey, {
    required int unitPricePaisa,
    required int quantity,
    int itemDiscountPaisa = 0,
  }) {
    if (quantity <= 0) {
      removeItem(lineKey);
      return;
    }
    final updated = state.items
        .map(
          (i) => i.lineKey == lineKey
              ? i.copyWith(
                  unitPricePaisa: unitPricePaisa < 0 ? 0 : unitPricePaisa,
                  quantity: quantity,
                  itemDiscountPaisa:
                      itemDiscountPaisa < 0 ? 0 : itemDiscountPaisa,
                )
              : i,
        )
        .toList(growable: false);
    state = state.copyWith(items: updated);
  }

  void applyDiscount(PosDiscount discount) {
    state = state.copyWith(discount: discount);
  }

  void clearDiscount() {
    state = state.copyWith(discount: const PosDiscount.none());
  }

  void selectCustomer(CustomerRow? customer) {
    state = customer == null
        ? state.copyWith(clearCustomer: true)
        : state.copyWith(selectedCustomer: customer);
  }

  void clearCart() {
    state = PosCartState(lastReceipt: state.lastReceipt);
  }

  /// Commits the current cart to encrypted SQLite + `sync_outbox` and clears
  /// the cart while retaining `lastReceipt` for printing/reprint.
  Future<PosCheckoutCommitResult> commitCheckout({
    required List<PosPaymentLeg> payments,
    required String paymentMode,
    int? cashTenderedPaisa,
    int? changeDuePaisa,
    String? staticQrPayload,
  }) async {
    final repo = ref.read(posRepositoryProvider);
    if (repo == null) {
      throw const PosValidationException('Database vault is locked.');
    }
    final auth = ref.read(authSessionControllerProvider).state;
    final session = ref.read(ramKeyHolderProvider).session ?? auth.session;
    if (session == null) {
      throw const PosValidationException('No active staff session.');
    }

    state = state.copyWith(isCheckingOut: true);
    try {
      final result = await repo.completeCheckout(
        items: state.items,
        discount: state.discount,
        payments: payments,
        paymentMode: paymentMode,
        cashierUserId: session.userId,
        cashierName: auth.displayName ?? session.username,
        role: session.role,
        deviceCode: session.deviceCode,
        shiftId: auth.activeShift?.id,
        customer: state.selectedCustomer,
        cashTenderedPaisa: cashTenderedPaisa,
        changeDuePaisa: changeDuePaisa,
        staticQrPayload: staticQrPayload,
      );

      state = PosCartState(lastReceipt: result.receiptData);
      return result;
    } catch (_) {
      state = state.copyWith(isCheckingOut: false);
      rethrow;
    }
  }
}

final posCartProvider = NotifierProvider<PosCartController, PosCartState>(
  PosCartController.new,
);
