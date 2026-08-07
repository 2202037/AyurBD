/// `POST /pharmacy/checkout` — place the order.
///
/// Three things this screen is careful about:
///
/// 1. The payable total is the server's, shown but never recomputed.
/// 2. `payment_method` comes from [PaymentMethodOption], whose values are the
///    `in:` whitelist verbatim — a hand-typed string would be a 400, and the
///    casing is part of the value ('bKash', not 'bkash').
/// 3. A 409 means stock moved while the order was being written (the guarded
///    decrement in pharmacy.php refused). The cart is reloaded so the user sees
///    the new reality instead of retrying into the same failure.
///
/// The recipient name, phone, city and notes are all real columns on `orders`
/// and are all persisted — `delivery_name`, `delivery_phone` and
/// `delivery_address` are NOT NULL, which is why the first two are required here
/// rather than optional. (An earlier version of this file warned that the phone
/// was validated but discarded; that is no longer the case.)
///
/// Nothing here marks the order paid. Every order is written with
/// `payment_status = 'pending'` and only the admin panel can change that, so the
/// copy under each method promises a confirmation, never a receipt.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/pharmacy_models.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/pharmacy_repository.dart';
import 'cart_controller.dart';
import 'orders_screen.dart';

class CheckoutScreen extends ConsumerStatefulWidget {
  const CheckoutScreen({super.key});

  @override
  ConsumerState<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends ConsumerState<CheckoutScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _address;
  late final TextEditingController _city;
  late final TextEditingController _phone;
  late final TextEditingController _notes;

  /// Cash on delivery is the default because it is the only method that needs no
  /// action outside the app.
  PaymentMethodOption _method = PaymentMethodOption.cash;
  bool _busy = false;
  Map<String, String> _serverErrors = const {};

  @override
  void initState() {
    super.initState();
    // Prefill from the profile — the address is the one field a returning
    // customer should never have to retype.
    final user = ref.read(currentUserProvider);
    _name = TextEditingController(text: user?.name ?? '');
    _address = TextEditingController(text: user?.address ?? '');
    _city = TextEditingController();
    _phone = TextEditingController(text: user?.phone ?? '');
    _notes = TextEditingController();
  }

  @override
  void dispose() {
    for (final c in [_name, _address, _city, _phone, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _placeOrder() async {
    setState(() => _serverErrors = const {});
    if (!(_form.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();

    setState(() => _busy = true);
    try {
      final order = await ref.read(pharmacyRepositoryProvider).checkout(
            address: _address.text,
            paymentMethod: _method,
            phone: _phone.text,
            name: _name.text,
            city: _city.text,
            notes: _notes.text,
          );
      if (!mounted) return;
      // The server already deleted the cart rows in the same transaction.
      ref.read(cartControllerProvider.notifier).clearLocally();
      ref.invalidate(ordersProvider);
      // Replace, not push: backing up into a checkout form for an order that
      // has already been placed invites a double submission.
      context.pushReplacement(Routes.orderDetail(order.id));
      showToast(context, 'Order ${order.orderNumber} placed.');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _serverErrors = e.errors;
      });
      _form.currentState?.validate();

      if (e.isConflict || e.statusCode == 422) {
        // Stock moved under us. Refresh so the cart shows the new issue flags,
        // then send the user back to deal with them.
        await ref.read(cartControllerProvider.notifier).refresh().catchError((_) {});
        if (!mounted) return;
        showToast(context, e.message, error: true);
        context.pop();
        return;
      }
      showToast(context, e.message, error: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, e.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cart = ref.watch(cartControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: BlockingOverlay(
        busy: _busy,
        message: 'Placing your order…',
        child: cart.when(
          loading: () => const LoadingView(),
          error: (e, _) => ErrorView(
            error: e,
            onRetry: ref.read(cartControllerProvider.notifier).load,
          ),
          data: (c) {
            // Getting here with an unready cart means it changed in another tab
            // or on another device. Bounce rather than let a doomed submit run.
            if (!c.summary.checkoutReady) {
              return EmptyView(
                title: 'Cart is not ready',
                message: c.isEmpty
                    ? 'There is nothing to order.'
                    : 'Some items need attention before you can check out.',
                icon: Icons.remove_shopping_cart_outlined,
                actionLabel: 'Back to cart',
                onAction: () => context.pop(),
              );
            }

            return Column(
              children: [
                Expanded(
                  child: Form(
                    key: _form,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(
                          AppTheme.gap, AppTheme.gap, AppTheme.gap, 24),
                      children: [
                        Text('Delivery details', style: theme.textTheme.titleSmall),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _name,
                          textCapitalization: TextCapitalization.words,
                          textInputAction: TextInputAction.next,
                          maxLength: 100,
                          decoration: const InputDecoration(
                            labelText: 'Recipient name',
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                          // NOT NULL server-side, prefilled from the account.
                          validator: (v) =>
                              _serverErrors['name'] ??
                              Validators.text(v, field: 'Recipient name', min: 2, max: 100),
                        ),
                        TextFormField(
                          controller: _address,
                          maxLines: 3,
                          maxLength: 255,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(
                            labelText: 'Delivery address',
                            hintText: 'House, road, area',
                            alignLabelWithHint: true,
                          ),
                          // 5..255 is the server's own rule, not a guess.
                          validator: (v) {
                            final server = _serverErrors['address'];
                            if (server != null) return server;
                            final r = Validators.required(v, 'Address');
                            if (r != null) return r;
                            if (v!.trim().length < 5) {
                              return 'Please write a fuller address.';
                            }
                            return null;
                          },
                        ),
                        TextFormField(
                          controller: _city,
                          textCapitalization: TextCapitalization.words,
                          textInputAction: TextInputAction.next,
                          maxLength: 50,
                          decoration: const InputDecoration(
                            labelText: 'City (optional)',
                            prefixIcon: Icon(Icons.location_city_outlined),
                          ),
                          validator: (v) =>
                              _serverErrors['city'] ?? Validators.notes(v, max: 50),
                        ),
                        TextFormField(
                          controller: _phone,
                          keyboardType: TextInputType.phone,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'Contact number',
                            prefixIcon: Icon(Icons.call_outlined),
                            helperText: 'The rider will call this number.',
                          ),
                          // Required, not optional: `delivery_phone` is NOT NULL,
                          // and the server 422s if the account has no phone to
                          // fall back to.
                          validator: (v) =>
                              _serverErrors['phone'] ?? Validators.phone(v),
                        ),
                        TextFormField(
                          controller: _notes,
                          maxLines: 2,
                          maxLength: 500,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(
                            labelText: 'Delivery notes (optional)',
                            alignLabelWithHint: true,
                            helperText: 'Landmark, floor, best time to deliver…',
                          ),
                          validator: (v) => _serverErrors['notes'] ?? Validators.notes(v),
                        ),
                        const SizedBox(height: AppTheme.gap),
                        Text('Payment method', style: theme.textTheme.titleSmall),
                        const SizedBox(height: 4),
                        for (final m in PaymentMethodOption.values)
                          RadioListTile<PaymentMethodOption>(
                            value: m,
                            groupValue: _method,
                            onChanged: (v) => setState(() => _method = v ?? _method),
                            title: Text(m.label),
                            subtitle: Text(
                              // Every order starts `payment_status = 'pending'`
                              // and only an admin can mark it paid, so neither
                              // branch may imply the money has arrived.
                              m.isOffline
                                  ? 'Pay the rider when the order arrives.'
                                  : 'The pharmacy will contact you with payment '
                                      'details after confirming.',
                            ),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                        if (_serverErrors['payment_method'] != null)
                          Text(
                            _serverErrors['payment_method']!,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.error),
                          ),
                        const SizedBox(height: AppTheme.gap),
                        Text('Order summary', style: theme.textTheme.titleSmall),
                        const SizedBox(height: 8),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              children: [
                                for (final line in c.lines)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            '${line.quantity} × ${line.name}',
                                            style: theme.textTheme.bodyMedium,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Text(line.lineTotalLabel,
                                            style: theme.textTheme.bodyMedium),
                                      ],
                                    ),
                                  ),
                                const Divider(height: 18),
                                _Line(label: 'Subtotal', value: c.summary.subtotalLabel),
                                _Line(label: 'Delivery', value: c.summary.deliveryLabel),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(AppTheme.gap, 12, AppTheme.gap, 12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      border: Border(top: BorderSide(color: theme.dividerColor)),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Text('Total to pay', style: theme.textTheme.titleMedium),
                            const Spacer(),
                            Text(
                              c.summary.totalLabel,
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(color: theme.colorScheme.primary),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: _busy ? null : _placeOrder,
                            child: const Text('Place order'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(label, style: muted),
          const Spacer(),
          Text(value, style: muted),
        ],
      ),
    );
  }
}
