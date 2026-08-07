/// `/pharmacy/orders/{id}` — one order, with its line items.
///
/// This is the only endpoint that returns `items`, so the detail screen always
/// fetches rather than reusing the list row it was tapped from.
///
/// The `orders` table stores a single `total_amount` with no subtotal or
/// delivery-fee split, so this screen shows the line items and the one total —
/// it deliberately does not reconstruct the cart's fee breakdown, which would
/// mean inventing numbers. Flagged for reconciliation against the real AYUR
/// schema: if `orders` there stores the split, add it to [Order] and show it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/pharmacy_models.dart';
import '../data/pharmacy_repository.dart';

final orderDetailProvider = FutureProvider.family<Order, int>((ref, id) {
  return ref.watch(pharmacyRepositoryProvider).order(id);
});

class OrderDetailScreen extends ConsumerWidget {
  const OrderDetailScreen({super.key, required this.orderId});

  final int orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(orderDetailProvider(orderId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Order'),
        actions: [
          IconButton(
            tooltip: 'All orders',
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () => context.go(Routes.orders),
          ),
        ],
      ),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          error: e,
          onRetry: () => ref.invalidate(orderDetailProvider(orderId)),
        ),
        data: (o) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(orderDetailProvider(orderId)),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
                AppTheme.gap, AppTheme.gap, AppTheme.gap, 32),
            children: [
              _Header(order: o),
              const SizedBox(height: AppTheme.gap),
              _Items(order: o),
              const SizedBox(height: AppTheme.gap),
              _Delivery(order: o),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final o = order;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gap),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(o.orderNumber, style: theme.textTheme.headlineSmall),
                ),
                StatusPill(status: o.status),
              ],
            ),
            const SizedBox(height: 6),
            Text('Placed ${o.placedLabel}',
                style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            const Divider(height: 22),
            Row(
              children: [
                Text('Total', style: theme.textTheme.titleMedium),
                const Spacer(),
                Text(
                  o.totalLabel,
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.account_balance_wallet_outlined, size: 15, color: muted),
                const SizedBox(width: 6),
                Text(o.paymentMethodLabel,
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
                const Spacer(),
                StatusPill(
                  status: o.paymentStatus,
                  label: Fmt.label(o.paymentStatus),
                  dense: true,
                ),
              ],
            ),
            if (!o.isPaid && !o.isCancelled) ...[
              const SizedBox(height: 8),
              Text(
                // No online gateway is wired up in this build, and the offline
                // methods genuinely settle on delivery — so this is accurate
                // rather than a placeholder.
                'Payment is collected when the order reaches you.',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Items extends StatelessWidget {
  const _Items({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    // Defensive: `isSummaryOnly` is true when a row arrived from the list
    // endpoint. The detail fetch should always populate `items`, but a
    // reconciled backend that omits them shouldn't render a blank card.
    if (order.lines.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.gap),
          child: Text(
            order.isSummaryOnly
                ? '${order.itemCountLabel} — details unavailable.'
                : 'No items on this order.',
            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Text(order.itemCountLabel, style: theme.textTheme.titleSmall),
            ),
            for (final line in order.lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    RemoteImage(
                      path: line.image,
                      width: 48,
                      height: 48,
                      radius: AppTheme.radius - 4,
                      fallbackIcon: Icons.medication_outlined,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            line.name,
                            style: theme.textTheme.bodyLarge,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            // `unit_price` is the price as charged at order
                            // time, which may differ from today's catalogue
                            // price. Never re-read from the product.
                            '${line.quantity} × ${line.unitPriceLabel}'
                            '${line.unit == null ? '' : ' · ${line.unit}'}',
                            style: theme.textTheme.bodySmall?.copyWith(color: muted),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(line.lineTotalLabel, style: theme.textTheme.titleSmall),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Delivery extends StatelessWidget {
  const _Delivery({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gap),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Delivery', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.place_outlined, size: 16, color: muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    order.address ?? 'No address recorded.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
