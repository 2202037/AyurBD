/// `/pharmacy/cart` — review before checkout.
///
/// Nothing on this screen is computed locally. The subtotal, delivery fee, total
/// and the per-line `issue` flags all come from `cart_payload()`, and the Place
/// Order button follows the server's `checkout_ready` verdict rather than
/// deciding for itself. If the app did its own arithmetic it could disagree with
/// the order that actually gets written (§8).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/pharmacy_models.dart';
import 'cart_controller.dart';
import 'product_detail_screen.dart';

class CartScreen extends ConsumerWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(cartControllerProvider);
    final controller = ref.read(cartControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Your cart')),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e, onRetry: controller.load),
        data: (cart) {
          if (cart.isEmpty) {
            return EmptyView(
              title: 'Your cart is empty',
              message: 'Browse the pharmacy and add something you need.',
              icon: Icons.shopping_cart_outlined,
              actionLabel: 'Go to pharmacy',
              // `go`, not `push`: cart is reachable from outside the shell, so
              // pushing the shop on top would leave a cart underneath it.
              onAction: () => context.go(Routes.shop),
            );
          }
          return Column(
            children: [
              Expanded(
                child: RefreshIndicator(
                  onRefresh: controller.refresh,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                        AppTheme.gap, AppTheme.gap, AppTheme.gap, AppTheme.gap),
                    children: [
                      if (cart.summary.hasIssues) ...[
                        const _IssuesBanner(),
                        const SizedBox(height: 12),
                      ],
                      for (final line in cart.lines) ...[
                        _CartLineCard(line: line),
                        const SizedBox(height: 10),
                      ],
                    ],
                  ),
                ),
              ),
              _SummaryBar(summary: cart.summary),
            ],
          );
        },
      ),
    );
  }
}

class _IssuesBanner extends StatelessWidget {
  const _IssuesBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.error;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: AppSemantic.of(context).tintAlpha),
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: color.withValues(alpha: AppSemantic.of(context).tintBorderAlpha)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              // Flagged lines are excluded from the payable subtotal server-side,
              // so this is not advisory — checkout stays blocked until they go.
              'Some items need attention. Fix or remove them to place your order.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _CartLineCard extends ConsumerStatefulWidget {
  const _CartLineCard({required this.line});

  final CartLine line;

  @override
  ConsumerState<_CartLineCard> createState() => _CartLineCardState();
}

class _CartLineCardState extends ConsumerState<_CartLineCard> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() op) async {
    setState(() => _busy = true);
    try {
      await op();
    } on ApiException catch (e) {
      if (!mounted) return;
      showToast(context, e.message, error: true);
    } catch (e) {
      if (!mounted) return;
      showToast(context, e.toString(), error: true);
    } finally {
      // The card may have been rebuilt away by the new cart payload — a removed
      // line's State is disposed before this runs.
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final line = widget.line;
    final controller = ref.read(cartControllerProvider.notifier);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Opacity(
        opacity: _busy ? 0.55 : 1,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: () => context.push(Routes.productDetail(line.productId)),
                    child: RemoteImage(
                      path: line.image,
                      width: 60,
                      height: 60,
                      radius: AppTheme.radius - 2,
                      fallbackIcon: Icons.medication_outlined,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          line.name,
                          style: theme.textTheme.titleSmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          // `unit_price`, not `price` — the cart renames the key,
                          // and reading the wrong one silently shows ৳0.
                          '${line.unitPriceLabel} each',
                          style: theme.textTheme.bodySmall?.copyWith(color: muted),
                        ),
                        if (line.pharmacyName != null)
                          Text(
                            line.pharmacyName!,
                            style: theme.textTheme.bodySmall?.copyWith(color: muted),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    onPressed: _busy ? null : () => _run(() => controller.remove(line.productId)),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
              if (line.hasIssue) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.error_outline, size: 15, color: theme.colorScheme.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        line.issueLabel,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.error),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  QuantityStepper(
                    value: line.quantity,
                    // 0 is a valid target: the update endpoint treats it as a
                    // remove, which is exactly what tapping "−" at 1 should do.
                    min: 0,
                    max: line.maxQuantity < 1 ? line.quantity : line.maxQuantity,
                    enabled: !_busy,
                    onChanged: (q) =>
                        _run(() => controller.setQuantity(line.productId, q)),
                  ),
                  const Spacer(),
                  Text(
                    line.lineTotalLabel,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: theme.colorScheme.primary),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Server-computed totals plus the checkout button.
class _SummaryBar extends StatelessWidget {
  const _SummaryBar({required this.summary});

  final CartSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(AppTheme.gap, 12, AppTheme.gap, 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(top: BorderSide(color: theme.dividerColor)),
        ),
        child: Column(
          children: [
            _Total(label: 'Subtotal', value: summary.subtotalLabel),
            const SizedBox(height: 4),
            _Total(label: 'Delivery', value: summary.deliveryLabel),
            const Divider(height: 18),
            _Total(label: 'Total', value: summary.totalLabel, emphasise: true),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                // `checkout_ready` is the server's verdict: subtotal > 0 and no
                // flagged lines. The button does not re-derive it.
                onPressed: summary.checkoutReady ? () => context.push(Routes.checkout) : null,
                child: Text(
                  summary.checkoutReady
                      ? 'Checkout · ${summary.totalLabel}'
                      : 'Resolve items to checkout',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.label, required this.value, this.emphasise = false});

  final String label;
  final String value;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = emphasise
        ? theme.textTheme.titleMedium
        : theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Row(
      children: [
        Text(label, style: style),
        const Spacer(),
        Text(
          value,
          style: emphasise
              ? theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary)
              : style,
        ),
      ],
    );
  }
}
