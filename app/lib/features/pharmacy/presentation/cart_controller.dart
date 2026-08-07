/// The one cart in the app.
///
/// Every mutation endpoint returns the whole `cart_payload()`, so this controller
/// never patches a line locally — it swaps its state for whatever the server just
/// said. That is what keeps the subtotal, the delivery fee and the per-line
/// `issue` flags in agreement with the order that would actually be written (§8).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/pharmacy_models.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/pharmacy_repository.dart';

class CartController extends StateNotifier<AsyncValue<Cart>> {
  CartController(this._repo, {required bool signedIn})
      : super(signedIn ? const AsyncValue.loading() : const AsyncValue.data(Cart())) {
    if (signedIn) load();
  }

  final PharmacyRepository _repo;

  /// True while a mutation is in flight. Kept out of [state] so the list does
  /// not flicker back to a spinner every time a quantity stepper is tapped.
  bool get busy => _busy;
  bool _busy = false;

  Future<void> load() async {
    state = await AsyncValue.guard(_repo.cart);
  }

  /// Silent refresh — keeps the current rows on screen while re-fetching, so
  /// pull-to-refresh does not blank a list the user is looking at.
  ///
  /// Does not rethrow: `RefreshIndicator.onRefresh` awaits the returned future
  /// and an error here would surface as an unhandled async exception. A failed
  /// refresh only replaces the state when there is nothing on screen to keep.
  Future<void> refresh() async {
    try {
      state = AsyncValue.data(await _repo.cart());
    } catch (e, st) {
      if (!state.hasValue) state = AsyncValue.error(e, st);
    }
  }

  /// Throws [ApiException] on a 422 ("Only 3 in stock") so the caller can show
  /// the server's message on the widget that caused it.
  Future<void> add(int productId, {int quantity = 1}) =>
      _mutate(() => _repo.addToCart(productId: productId, quantity: quantity));

  /// Quantity 0 is how the API removes a line — `pharmacy_cart_update()` allows
  /// `min:0` for exactly that, so the stepper needs no special-case at 1.
  Future<void> setQuantity(int productId, int quantity) =>
      _mutate(() => _repo.updateQuantity(productId: productId, quantity: quantity));

  Future<void> remove(int productId) => _mutate(() => _repo.removeFromCart(productId));

  /// The tail of the mutation chain. Each mutation waits for the one before it.
  Future<void> Function()? _tail;

  /// Mutations are serialised, not dropped: two fast taps on a stepper must
  /// both land, in order, instead of the second being silently discarded — and
  /// a stale response can never arrive after a fresher one, because only one
  /// request is in flight at a time.
  Future<void> _mutate(Future<Cart> Function() op) async {
    final previous = _tail;
    final next = _tail = () async {
      if (previous != null) {
        try {
          await previous();
        } on Object {
          // The earlier mutation failed, but this is a distinct user action —
          // let it run against the server's current state rather than aborting
          // on a 422 the user is already fixing.
        }
      }
      _busy = true;
      try {
        state = AsyncValue.data(await op());
      } finally {
        _busy = false;
      }
    };
    await next();
    if (identical(_tail, next)) _tail = null;
  }

  /// After a successful checkout the server has already emptied the cart rows,
  /// so re-fetching would cost a round trip just to learn that.
  void clearLocally() => state = const AsyncValue.data(Cart());
}

final cartControllerProvider =
    StateNotifierProvider<CartController, AsyncValue<Cart>>((ref) {
  // Guests have no server-side cart — `/pharmacy/cart` sits behind require_auth()
  // — so signing out must yield an empty cart rather than a 401 loop. Watching
  // the auth state also rebuilds the controller on sign-in, which loads the cart
  // the user left behind on another device.
  final signedIn = ref.watch(authControllerProvider).isAuthenticated;
  return CartController(ref.watch(pharmacyRepositoryProvider), signedIn: signedIn);
});

/// The number on the cart badge. 0 while loading or errored — a badge is
/// decoration, and a stale count is worse than none.
final cartCountProvider = Provider<int>(
  (ref) => ref.watch(cartControllerProvider).maybeWhen(
        data: (c) => c.badgeCount,
        orElse: () => 0,
      ),
);
