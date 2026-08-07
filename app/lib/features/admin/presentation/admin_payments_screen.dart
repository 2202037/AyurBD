/// §10.13 — payment verification.
///
/// This is the ADMIN's decision. The patient pays the platform's account and
/// submits a reference; the admin checks it against the platform statement and
/// verifies. The `payments_apply_verification` trigger then keeps the platform
/// commission (`admin_share`, the provider's `commission_percentage`), credits
/// the provider's `provider_share` as a pending payout, and marks the
/// appointment paid — but does NOT confirm it. The provider confirms the
/// booking once their share is in (see §6.3/§6.2), which is what keeps the
/// escrow flow honest.
///
/// Rejecting requires a reason — the server 422s without one, and the patient
/// is shown the text.
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
  (value: 'pending', label: 'Awaiting'),
  (value: 'verified', label: 'Verified'),
  (value: 'rejected', label: 'Rejected'),
];

class AdminPaymentsScreen extends ConsumerStatefulWidget {
  const AdminPaymentsScreen({super.key});

  @override
  ConsumerState<AdminPaymentsScreen> createState() =>
      _AdminPaymentsScreenState();
}

class _AdminPaymentsScreenState extends ConsumerState<AdminPaymentsScreen> {
  bool _busy = false;

  PagedController<ProviderPayment> get _controller =>
      ref.read(adminPaymentsProvider.notifier);

  Future<void> _decide(ProviderPayment p, {required bool approve}) async {
    String? reason;
    if (approve) {
      final yes = await _confirmVerify(p);
      if (yes != true) return;
    } else {
      reason = await _askReason(p);
      if (reason == null || reason.isEmpty) return;
    }

    setState(() => _busy = true);
    try {
      await ref.read(adminRepositoryProvider).verifyPayment(
            paymentId: p.id,
            approve: approve,
            rejectionReason: reason,
          );

      final filter = ref.read(adminPaymentStatusProvider);
      // In the awaiting queue a decided row no longer belongs; under 'all' or a
      // matching filter it stays, so refetch the page it came from.
      if (filter == 'pending') {
        _controller.removeWhere((row) => row.id == p.id);
      } else {
        await _controller.reload();
      }
      ref.invalidate(adminDashboardProvider);

      if (mounted) {
        showToast(
          context,
          approve
              ? 'Payment verified. The commission is kept and the rest goes to '
                  'the provider.'
              : 'Payment rejected. The patient can submit again.',
        );
      }
    } on ApiException catch (e) {
      if (mounted && !e.isUnauthorized) showToast(context, e.message, error: true);
    } catch (_) {
      if (mounted) showToast(context, 'Something went wrong.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirmVerify(ProviderPayment p) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Verify this payment?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${p.patientName ?? 'Patient'} · ${p.amountLabel}'),
            const SizedBox(height: 8),
            if (p.hasReference)
              Text('Reference: ${p.transactionId}',
                  style: Theme.of(ctx).textTheme.bodySmall),
            if (p.senderNumber != null)
              Text('From: ${p.senderNumber}',
                  style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 12),
            Text(
              'Check this reference against the platform statement first. '
              'Verifying keeps the platform commission out of this amount, '
              'credits the rest to the provider, and marks the appointment '
              'paid — the provider then confirms the booking.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Verify'),
          ),
        ],
      ),
    );
  }

  Future<String?> _askReason(ProviderPayment p) {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject this payment'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The patient sees this reason, so say what they should fix.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: controller,
                maxLines: 3,
                maxLength: 500,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Reason',
                  hintText: 'e.g. no payment found with that transaction ID',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => (v ?? '').trim().length < 5
                    ? 'Please give a reason of at least 5 characters.'
                    : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              Navigator.of(ctx).pop(controller.text.trim());
            },
            child: const Text('Reject payment'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(adminPaymentsProvider);
    final controller = ref.read(adminPaymentsProvider.notifier);
    final status = ref.watch(adminPaymentStatusProvider);

    final bar = AdminFilterBar(
      options: _statusFilters,
      selected: status,
      onSelected: (v) => ref.read(adminPaymentStatusProvider.notifier).state = v,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Payments'),
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(bar.height),
          child: bar,
        ),
      ),
      body: BlockingOverlay(
        busy: _busy,
        message: 'Saving decision…',
        child: Column(
          children: [
            // Say once, at the top, what verifying does with the money — this is
            // the escrow flow's admin half.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: AppSemantic.of(context)
                  .primary
                  .withValues(alpha: AppSemantic.of(context).tintAlpha),
              child: Row(
                children: [
                  Icon(Icons.account_balance_outlined,
                      size: 16, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'The patient pays the platform. Verifying keeps the '
                      'commission and credits the provider, who then confirms '
                      'the booking.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PagedListView<ProviderPayment>(
                state: state,
                onRefresh: controller.refresh,
                onLoadMore: controller.loadMore,
                onRetry: controller.reload,
                emptyTitle: 'No payments',
                emptyIcon: Icons.payments_outlined,
                emptyMessage: 'Nothing matches those filters.',
                itemBuilder: (context, p, _) => _PaymentRow(
                  payment: p,
                  onVerify: p.isPending ? () => _decide(p, approve: true) : null,
                  onReject: p.isPending ? () => _decide(p, approve: false) : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PaymentRow extends StatelessWidget {
  const _PaymentRow({required this.payment, this.onVerify, this.onReject});

  final ProviderPayment payment;
  final VoidCallback? onVerify;
  final VoidCallback? onReject;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = payment;
    final muted = theme.colorScheme.onSurfaceVariant;

    // How long a pending submission has been waiting is what the admin watches.
    final stale = p.isPending && p.createdAt != null;

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
                        p.patientName ?? 'Patient',
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'Appointment ${p.whenLabel}',
                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
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
            _Line(label: 'Method', value: p.method ?? '—'),
            _Line(
              label: 'Reference',
              value: p.hasReference
                  ? p.transactionId!
                  : (p.method == 'Cash' ? 'Not needed for cash' : 'Not provided'),
            ),
            if (p.senderNumber != null)
              _Line(label: 'Sender', value: p.senderNumber!),
            if (p.createdAt != null)
              _Line(
                label: 'Submitted',
                value: Fmt.relative(p.createdAt),
                warn: stale,
              ),
            // The split the verification computed — the whole reason this screen
            // exists as the platform's money gate.
            if (p.isVerified && p.adminShare != null && p.providerShare != null) ...[
              const Divider(height: 18),
              _Line(label: 'Platform (${_commissionHint(p)})', value: Fmt.money(p.adminShare!)),
              _Line(
                label: 'To provider',
                value: Fmt.money(p.providerShare!),
                accent: true,
              ),
              if (p.verifiedAt != null)
                _Line(label: 'Verified', value: Fmt.dateTime(p.verifiedAt)),
            ],
            if (p.isRejected && p.rejectionReason != null)
              _Line(label: 'Reason', value: p.rejectionReason!, warn: true),
            if (p.confirmationCode != null)
              _Line(label: 'Code', value: p.confirmationCode!),
            if (onVerify != null || onReject != null) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (onReject != null)
                    TextButton(
                      onPressed: onReject,
                      style: AppTheme.destructiveText(context),
                      child: const Text('Reject'),
                    ),
                  if (onVerify != null) ...[
                    const SizedBox(width: 4),
                    FilledButton(
                      onPressed: onVerify,
                      style: AppTheme.rowAction,
                      child: const Text('Verify'),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _commissionHint(ProviderPayment p) {
    final provider = p.providerShare ?? 0;
    if (provider <= 0) return '';
    return '${((p.amount - provider) / p.amount * 100).toStringAsFixed(1)}%';
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
