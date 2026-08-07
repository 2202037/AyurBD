/// Payment history — a read-only ledger of everything the patient has paid for.
///
/// `/appointments/payments` takes no filters at all (the handler reads only
/// `page` and `limit`), so there are deliberately no filter chips here: adding
/// a `status` param would be silently ignored rather than honoured, which is
/// worse than not offering it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/paged_controller.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/appointment_models.dart';
import '../data/appointment_repository.dart';

final paymentsProvider =
    StateNotifierProvider<PagedController<Payment>, PagedState<Payment>>((ref) {
  final repo = ref.watch(appointmentRepositoryProvider);
  return PagedController<Payment>((page) => repo.payments(page: page));
});

class PaymentsScreen extends ConsumerWidget {
  const PaymentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(paymentsProvider);
    final controller = ref.read(paymentsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Payments')),
      body: PagedListView<Payment>(
        state: state,
        onRefresh: controller.refresh,
        onLoadMore: controller.loadMore,
        onRetry: controller.reload,
        emptyTitle: 'No payments yet',
        emptyIcon: Icons.receipt_long_outlined,
        emptyMessage: 'Payments you make for appointments are listed here.',
        itemBuilder: (context, p, _) => _PaymentCard(payment: p),
      ),
    );
  }
}

class _PaymentCard extends StatelessWidget {
  const _PaymentCard({required this.payment});

  final Payment payment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final p = payment;

    // `paid_at` is only set once the row actually settles, so fall back to the
    // creation timestamp for pending/failed rows rather than printing a dash.
    final stamp = p.paidAt ?? p.createdAt;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(21),
                  ),
                  child: Icon(_iconFor(p.method), size: 20, color: muted),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.doctorName ?? 'Appointment payment',
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        p.methodLabel,
                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(Fmt.money(p.amount), style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    StatusPill(status: p.status, dense: true),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            Divider(height: 1, color: theme.dividerColor),
            const SizedBox(height: 10),
            _MetaLine(
              icon: Icons.event_outlined,
              // A payment can exist without a visit date if the appointment row
              // was removed, so this is not assumed present.
              text: p.appointmentDate == null
                  ? 'Appointment date unavailable'
                  : 'Visit ${Fmt.dayMonth(p.appointmentDate)}',
            ),
            if (stamp != null) ...[
              const SizedBox(height: 4),
              _MetaLine(icon: Icons.schedule_outlined, text: Fmt.dateTime(stamp)),
            ],
            if (p.transactionId != null) ...[
              const SizedBox(height: 4),
              _MetaLine(
                icon: Icons.confirmation_number_outlined,
                text: 'Ref ${p.transactionId}',
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The cases are the live `payments.payment_method` enum verbatim, casing and
  /// all. The previous version matched lowercase 'bkash'/'card'/'cash', which no
  /// row can ever contain — every payment fell through to the wallet icon.
  static IconData _iconFor(String? method) => switch (method) {
        'bKash' || 'Nagad' || 'Rocket' => Icons.phone_android_outlined,
        'Credit/Debit Card' => Icons.credit_card_outlined,
        'Bank Transfer' => Icons.account_balance_outlined,
        'Cash' => Icons.payments_outlined,
        _ => Icons.account_balance_wallet_outlined,
      };
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      children: [
        Icon(icon, size: 14, color: muted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
