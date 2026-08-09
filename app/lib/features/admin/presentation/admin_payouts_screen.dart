/// §10.14 — payout settlement.
///
/// The platform's "money out" step, and the escrow flow's final admin action.
/// The patient pays the platform; verifying a payment keeps the commission and
/// credits the provider's share as a `pending` payout (see
/// admin_payments_screen.dart). This screen is where the admin transfers that
/// share offline (bKash/Nagad) and marks the payout `paid` — the provider's
/// "available balance" then clears and they confirm the booking.
///
/// A marked-paid payout is not edited or deleted here (nor by the server): the
/// only reversal is refunding the appointment, which flips the payout to
/// `reversed`. The whole ledger is audited (audit_row_change on
/// provider_payouts).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/paged_controller.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/provider_models.dart';
import '../data/admin_repository.dart';
import 'admin_controllers.dart';
import 'widgets/admin_filter_bar.dart';

const _statusFilters = <FilterOption>[
  (value: null, label: 'All'),
  (value: 'pending', label: 'Pending'),
  (value: 'paid', label: 'Paid'),
  (value: 'reversed', label: 'Reversed'),
];

class AdminPayoutsScreen extends ConsumerStatefulWidget {
  const AdminPayoutsScreen({super.key});

  @override
  ConsumerState<AdminPayoutsScreen> createState() => _AdminPayoutsScreenState();
}

class _AdminPayoutsScreenState extends ConsumerState<AdminPayoutsScreen> {
  bool _busy = false;

  PagedController<Payout> get _controller =>
      ref.read(adminPayoutsProvider.notifier);

  Future<void> _settle(Payout p) async {
    final note = await _confirmSettle(p);
    if (note == null) return; // cancelled

    setState(() => _busy = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .settlePayout(payoutId: p.id, note: note);

      // Under the default 'pending' filter the row no longer belongs; under
      // 'all' it stays, so refetch the page it came from.
      if (ref.read(adminPayoutStatusProvider) == 'pending') {
        _controller.removeWhere((row) => row.id == p.id);
      } else {
        await _controller.reload();
      }
      ref.invalidate(adminDashboardProvider);

      if (mounted) {
        showToast(
          context,
          'Payout marked paid. The provider can now confirm the booking.',
        );
      }
    } on ApiException catch (e) {
      if (mounted && !e.isUnauthorized) showToast(context, e.message, error: true);
    } catch (e) {
      if (mounted) showToast(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Returns the note text, or null when the admin backs out. A settled payout
  /// is irreversible (the DB rejects rewriting a `paid` row's money fields), so
  /// the dialog says what "mark paid" means before the button is offered.
  Future<String?> _confirmSettle(Payout p) {
    final note = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark this payout paid?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${p.providerName ?? 'Provider'} · ${p.amountLabel}'),
            const SizedBox(height: 4),
            Text(p.sourceLabel,
                style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 12),
            Text(
              'Confirm only after the transfer has actually gone through '
              '(bKash/Nagad/bank). This is irreversible and the provider is '
              'then owed nothing more for it.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: note,
              maxLines: 2,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: 'Note (optional)',
                hintText: 'e.g. sent via bKash to 01XXXXXXXXX',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(note.text.trim()),
            child: const Text('Mark paid'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(adminPayoutsProvider);
    final controller = ref.read(adminPayoutsProvider.notifier);
    final status = ref.watch(adminPayoutStatusProvider);

    final bar = AdminFilterBar(
      options: _statusFilters,
      selected: status,
      onSelected: (v) => ref.read(adminPayoutStatusProvider.notifier).state = v,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Payouts'),
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(bar.height),
          child: bar,
        ),
      ),
      body: BlockingOverlay(
        busy: _busy,
        message: 'Recording transfer…',
        child: Column(
          children: [
            // Say once what this screen is for — the payout is the escrow
            // flow's closing step, so a row that lingers here is money the
            // provider is waiting on.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: AppSemantic.of(context)
                  .primary
                  .withValues(alpha: AppSemantic.of(context).tintAlpha),
              child: Row(
                children: [
                  Icon(Icons.payments_outlined,
                      size: 16, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Transfer each pending amount offline, then mark it paid. '
                      'The provider confirms the booking after this clears.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PagedListView<Payout>(
                state: state,
                onRefresh: controller.refresh,
                onLoadMore: controller.loadMore,
                onRetry: controller.reload,
                emptyTitle: 'No payouts',
                emptyIcon: Icons.payments_outlined,
                emptyMessage: 'Nothing matches those filters.',
                itemBuilder: (context, p, _) => _PayoutRow(
                  payout: p,
                  onSettle: p.isPending ? () => _settle(p) : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PayoutRow extends StatelessWidget {
  const _PayoutRow({required this.payout, this.onSettle});

  final Payout payout;
  final VoidCallback? onSettle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = payout;
    final muted = theme.colorScheme.onSurfaceVariant;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.providerName ?? 'Provider',
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        p.sourceLabel,
                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(p.amountLabel, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    StatusPill(status: p.status, label: p.statusLabel, dense: true),
                  ],
                ),
              ],
            ),
            const Divider(height: 18),
            _Line(
              label: 'Created',
              value: p.createdLabel,
            ),
            _Line(
              label: 'Platform fee',
              value: '${p.commissionPercentage.toStringAsFixed(1)}%',
            ),
            if (p.isPaid && p.paidAt != null)
              _Line(
                label: 'Paid',
                value: Fmt.dateTime(p.paidAt),
                accent: true,
              ),
            if (p.isReversed)
              const _Line(
                label: 'Reversed',
                value: 'Refunded — nothing owed',
                warn: true,
              ),
            if (onSettle != null) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton(
                    onPressed: onSettle,
                    style: AppTheme.rowAction,
                    child: const Text('Mark paid'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    required this.label,
    required this.value,
    this.warn = false,
    this.accent = false,
  });

  final String label;
  final String value;
  final bool warn;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 128,
            child: Text(
              label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: accent ? FontWeight.w700 : (warn ? FontWeight.w600 : FontWeight.w500),
                color: accent
                    ? AppSemantic.of(context).success
                    : (warn ? AppSemantic.of(context).warning : null),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
