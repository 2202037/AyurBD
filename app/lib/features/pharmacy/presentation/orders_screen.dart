/// `/pharmacy/orders` — order history.
///
/// The status filter is real here: `pharmacy_orders()` reads `q('status')` and
/// puts it straight into the WHERE clause. It is *not* whitelisted server-side,
/// so an unrecognised value returns zero rows rather than a 400 — which is why
/// the chips are built from the fixed list of the six statuses the schema's enum
/// allows, never free text.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/paged_controller.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/pharmacy_models.dart';
import '../data/pharmacy_repository.dart';

/// `orders.status` enum, in lifecycle order.
const List<String> kOrderStatuses = [
  'pending',
  'confirmed',
  'processing',
  'shipped',
  'delivered',
  'cancelled',
];

final orderStatusFilterProvider = StateProvider<String?>((ref) => null);

final ordersProvider =
    StateNotifierProvider<PagedController<Order>, PagedState<Order>>((ref) {
  final repo = ref.watch(pharmacyRepositoryProvider);
  final status = ref.watch(orderStatusFilterProvider);
  return PagedController<Order>((page) => repo.orders(page: page, status: status));
});

class OrdersScreen extends ConsumerWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(ordersProvider);
    final controller = ref.read(ordersProvider.notifier);
    final status = ref.watch(orderStatusFilterProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('My orders')),
      body: Column(
        children: [
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppTheme.gap),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8, top: 8, bottom: 4),
                  child: ChoiceChip(
                    label: const Text('All'),
                    selected: status == null,
                    onSelected: (_) =>
                        ref.read(orderStatusFilterProvider.notifier).state = null,
                  ),
                ),
                for (final s in kOrderStatuses)
                  Padding(
                    padding: const EdgeInsets.only(right: 8, top: 8, bottom: 4),
                    child: ChoiceChip(
                      label: Text(Fmt.label(s)),
                      selected: status == s,
                      onSelected: (on) =>
                          ref.read(orderStatusFilterProvider.notifier).state = on ? s : null,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: PagedListView<Order>(
              state: state,
              onRefresh: controller.refresh,
              onLoadMore: controller.loadMore,
              onRetry: controller.reload,
              emptyTitle: status == null ? 'No orders yet' : 'Nothing here',
              emptyMessage: status == null
                  ? 'Medicines you order from the pharmacy will show up here.'
                  : 'You have no ${Fmt.label(status).toLowerCase()} orders.',
              emptyIcon: Icons.receipt_long_outlined,
              itemBuilder: (context, order, _) => OrderCard(order: order),
            ),
          ),
        ],
      ),
    );
  }
}

/// One history row. Line items are deliberately absent — the list endpoint sends
/// `item_count` but never `items`, so the card shows the count and the detail
/// screen fetches the rest.
class OrderCard extends StatelessWidget {
  const OrderCard({super.key, required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final o = order;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(Routes.orderDetail(o.id)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(o.orderNumber, style: theme.textTheme.titleSmall),
                  ),
                  StatusPill(status: o.status, dense: true),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.inventory_2_outlined, size: 14, color: muted),
                  const SizedBox(width: 5),
                  Text(o.itemCountLabel,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                  const SizedBox(width: 12),
                  Icon(Icons.schedule_outlined, size: 14, color: muted),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      o.placedLabel,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const Divider(height: 18),
              Row(
                children: [
                  StatusPill(
                    status: o.paymentStatus,
                    label: '${o.paymentMethodLabel} · ${Fmt.label(o.paymentStatus)}',
                    dense: true,
                  ),
                  const Spacer(),
                  Text(
                    o.totalLabel,
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
