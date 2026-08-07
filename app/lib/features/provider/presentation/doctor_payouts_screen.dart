/// §6.3 — the provider's payout ledger / "money account".
///
/// Payment verification no longer lives here: the patient pays the PLATFORM
/// and the admin verifies (admin console §10.13), which splits the fee — the
/// platform commission is kept, and the provider's share is written here as a
/// `pending` payout. This screen is the provider's side of that flow: it shows
/// what the platform currently owes them, what the platform kept, and the
/// ledger of individual payouts. The booking is confirmed from the
/// appointments screen once the money is in (see §6.2).
///
/// Payouts are marked `paid` by the admin offline (the real-world transfer);
/// this is a showcase ledger — no real money is stored or moved.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/provider_models.dart';
import 'provider_controllers.dart';

const _filters = <({String value, String label})>[
  (value: 'pending', label: 'Pending'),
  (value: 'paid', label: 'Paid'),
  (value: 'all', label: 'All'),
];

class DoctorPayoutsScreen extends ConsumerWidget {
  const DoctorPayoutsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(doctorPayoutsProvider);
    final controller = ref.read(doctorPayoutsProvider.notifier);
    final filter = ref.watch(doctorPayoutStatusProvider);
    final stats = ref.watch(doctorDashboardProvider).valueOrNull?.stats;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Payouts & balance'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(AppTheme.gap, 0, AppTheme.gap, 8),
            child: Row(
              children: [
                for (final f in _filters)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f.label),
                      selected: filter == f.value,
                      onSelected: (_) => ref
                          .read(doctorPayoutStatusProvider.notifier)
                          .state = f.value,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          if (stats != null) _BalanceHeader(stats: stats),
          Expanded(
            child: PagedListView<Payout>(
              state: state,
              onRefresh: controller.refresh,
              onLoadMore: controller.loadMore,
              onRetry: controller.reload,
              emptyTitle: filter == 'pending' ? 'Nothing pending' : 'No payouts',
              emptyIcon: Icons.account_balance_wallet_outlined,
              emptyMessage: filter == 'pending'
                  ? 'Verified payments appear here as payouts once the admin '
                      'verifies them.'
                  : 'Nothing with that status.',
              itemBuilder: (context, p, _) => _PayoutCard(payout: p),
            ),
          ),
        ],
      ),
    );
  }
}

/// The "money account" summary — what the platform owes the provider, what it
/// kept, and what it has paid out. Read straight from `doctor_stats`.
class _BalanceHeader extends StatelessWidget {
  const _BalanceHeader({required this.stats});

  final DoctorStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(AppTheme.gap, 4, AppTheme.gap, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.account_balance_wallet_outlined,
                  size: 20, color: theme.colorScheme.onPrimaryContainer),
              const SizedBox(width: 8),
              Text(
                'Available balance',
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: theme.colorScheme.onPrimaryContainer),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            stats.payoutLabel,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Pending payouts. Marked paid by the admin when the money is '
            'transferred.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onPrimaryContainer),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _Pill(
                label: 'Earned ${stats.earningsLabel}',
                color: AppSemantic.of(context).success,
              ),
              const SizedBox(width: 8),
              _Pill(
                label: 'Platform kept ${stats.platformFeeLabel}',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _PayoutCard extends StatelessWidget {
  const _PayoutCard({required this.payout});

  final Payout payout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = payout;
    final muted = theme.colorScheme.onSurfaceVariant;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(21),
                  ),
                  child: Icon(
                    p.orderId != null
                        ? Icons.shopping_bag_outlined
                        : Icons.medical_services_outlined,
                    size: 20,
                    color: muted,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.sourceLabel,
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${p.createdLabel} · '
                        '${p.commissionPercentage.toStringAsFixed(1)}% fee',
                        style:
                            theme.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(p.amountLabel, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    StatusPill(status: p.status, label: p.statusLabel, dense: true),
                  ],
                ),
              ],
            ),
            if (p.isPaid && p.paidAt != null) ...[
              const SizedBox(height: 8),
              Text(
                'Paid ${Fmt.dateTime(p.paidAt)}',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
