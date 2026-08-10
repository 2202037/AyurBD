/// §6.2 — the doctor's appointment queue, with confirm / complete / cancel.
///
/// The status values are the same four the server whitelists (`pending`,
/// `confirmed`, `completed`, `cancelled` — two Ls), so the chips send them
/// verbatim. The date filter is a single day in `yyyy-MM-dd`: the handler 400s on
/// any other format rather than guessing, so it goes through [Fmt.apiDate].
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
import '../../../models/appointment_models.dart';
import '../data/provider_repository.dart';
import 'provider_controllers.dart';

const _filters = <({String? value, String label})>[
  (value: null, label: 'All'),
  // Bookings whose slot is held but unpaid. They sit under "All" otherwise,
  // and a doctor filtering to "Pending" would not see them at all — which
  // reads as bookings quietly disappearing.
  (value: 'pending_payment', label: 'Unpaid'),
  (value: 'pending', label: 'Pending'),
  (value: 'confirmed', label: 'Confirmed'),
  (value: 'completed', label: 'Completed'),
  (value: 'cancelled', label: 'Cancelled'),
];

class DoctorAppointmentsScreen extends ConsumerStatefulWidget {
  const DoctorAppointmentsScreen({super.key});

  @override
  ConsumerState<DoctorAppointmentsScreen> createState() =>
      _DoctorAppointmentsScreenState();
}

class _DoctorAppointmentsScreenState
    extends ConsumerState<DoctorAppointmentsScreen> {
  bool _busy = false;

  PagedController<Appointment> get _controller =>
      ref.read(doctorAppointmentsProvider.notifier);

  /// The status call answers with the updated appointment, so the row is patched
  /// in place rather than refetching the page and losing scroll position.
  Future<bool> _run(Future<Appointment> Function() action) async {
    setState(() => _busy = true);
    try {
      final updated = await action();
      _controller.replaceWhere((a) => a.id == updated.id, updated);
      return true;
    } on ApiException catch (e) {
      if (mounted && !e.isUnauthorized) {
        showToast(context, e.message, error: true);
      }
      return false;
    } catch (e) {
      if (mounted) showToast(context, e.toString(), error: true);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setStatus(Appointment a, String status) async {
    final notes = await _askNotes(a, status);
    // Null means the dialog was dismissed. An empty string is a deliberate
    // "no note", which is fine — the repository drops it.
    if (notes == null) return;

    final ok = await _run(() => ref
        .read(providerRepositoryProvider)
        .setAppointmentStatus(
          appointmentId: a.id,
          status: status,
          notes: notes.isEmpty ? null : notes,
        ));
    if (ok && mounted) {
      showToast(
        context,
        switch (status) {
          // Confirming is what mints the confirmation code server-side.
          'confirmed' => 'Confirmed. The patient can now see their code.',
          'completed' => 'Marked as completed.',
          _ => 'Appointment cancelled.',
        },
      );
    }
  }

  Future<String?> _askNotes(Appointment a, String status) {
    final controller = TextEditingController();
    final (title, body, cta) = switch (status) {
      'confirmed' => (
          'Confirm this appointment?',
          'The patient is notified and gets a confirmation code to quote at '
              'your chamber.',
          'Confirm',
        ),
      'completed' => (
          'Mark as completed?',
          'Use this after the patient has been seen.',
          'Mark completed',
        ),
      _ => (
          'Cancel this appointment?',
          'The slot is released immediately and the patient is notified. Any '
              'verified payment is marked for refund.',
          'Cancel appointment',
        ),
    };

    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${a.patientName ?? 'Patient'}\n${a.whenLabel}'),
            const SizedBox(height: 12),
            Text(body, style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 2,
              maxLength: 500,
              decoration: const InputDecoration(
                labelText: 'Note for the patient (optional)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(cta),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final current = Fmt.date(ref.read(doctorApptDateProvider));
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      // A doctor needs last month's list as often as next month's.
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null) return;
    ref.read(doctorApptDateProvider.notifier).state = Fmt.apiDate(picked);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(doctorAppointmentsProvider);
    final status = ref.watch(doctorApptStatusProvider);
    final date = ref.watch(doctorApptDateProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Appointments'),
        actions: [
          IconButton(
            tooltip: date == null ? 'Filter by date' : 'Change date',
            icon: Icon(date == null
                ? Icons.calendar_today_outlined
                : Icons.event_busy_outlined),
            onPressed: _pickDate,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(date == null ? 52 : 92),
          child: Column(
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding:
                    const EdgeInsets.fromLTRB(AppTheme.gap, 0, AppTheme.gap, 8),
                child: Row(
                  children: [
                    for (final f in _filters)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(f.label),
                          selected: status == f.value,
                          onSelected: (_) => ref
                              .read(doctorApptStatusProvider.notifier)
                              .state = f.value,
                        ),
                      ),
                  ],
                ),
              ),
              if (date != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppTheme.gap, 0, AppTheme.gap, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: InputChip(
                      avatar: const Icon(Icons.event, size: 18),
                      label: Text(Fmt.dayFull(date)),
                      onDeleted: () =>
                          ref.read(doctorApptDateProvider.notifier).state = null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      body: BlockingOverlay(
        busy: _busy,
        message: 'Updating…',
        child: PagedListView<Appointment>(
          state: state,
          onRefresh: _controller.refresh,
          onLoadMore: _controller.loadMore,
          onRetry: _controller.reload,
          emptyTitle: 'No appointments',
          emptyIcon: Icons.event_note_outlined,
          emptyMessage: status == null && date == null
              ? 'Bookings from patients will appear here.'
              : 'Nothing matches those filters.',
          itemBuilder: (context, a, _) {
            // A booking opens at `pending_payment` and only becomes `pending`
            // once the money is verified. Gating on `pending` alone left the
            // doctor looking at a card with no buttons at all for the state
            // most new bookings are actually in — including no way to decline
            // one. Both states are treated the same here, which is what the
            // screen did before `pending_payment` existed.
            final isOpen =
                a.status == 'pending' || a.status == 'pending_payment';

            // The escrow gate: a paid booking (fee > 0) is only confirmable
            // once the admin has verified the payment, which credits the
            // payout. Before that the button is shown disabled with the reason
            // — the server enforces this too (`aa_guard_confirm`).
            final awaitingPayment =
                isOpen && a.fee > 0 && a.paymentStatus != 'paid';
            return _PatientCard(
              appointment: a,
              awaitingPayment: awaitingPayment,
              onConfirm: isOpen ? () => _setStatus(a, 'confirmed') : null,
              onComplete: a.status == 'confirmed'
                  ? () => _setStatus(a, 'completed')
                  : null,
              onCancel: (isOpen || a.status == 'confirmed')
                  ? () => _setStatus(a, 'cancelled')
                  : null,
            );
          },
        ),
      ),
    );
  }
}

class _PatientCard extends StatelessWidget {
  const _PatientCard({
    required this.appointment,
    this.awaitingPayment = false,
    this.onConfirm,
    this.onComplete,
    this.onCancel,
  });

  final Appointment appointment;
  final bool awaitingPayment;
  final VoidCallback? onConfirm;
  final VoidCallback? onComplete;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = appointment;
    final muted = theme.colorScheme.onSurfaceVariant;

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
                AvatarCircle(name: a.patientName, size: 46),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        a.patientName ?? 'Patient',
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(a.whenLabel, style: theme.textTheme.bodyMedium),
                      if (a.patientPhone != null)
                        Text(
                          a.patientPhone!,
                          style: theme.textTheme.bodySmall?.copyWith(color: muted),
                        ),
                    ],
                  ),
                ),
                StatusPill(status: a.status, dense: true),
              ],
            ),
            if (a.notes != null && a.notes!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                a.notes!,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Text(Fmt.money(a.fee), style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                StatusPill(
                  status: a.paymentStatus,
                  label: a.paymentLabel,
                  dense: true,
                ),
                if (a.confirmationCode != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    a.confirmationCode!,
                    style: theme.textTheme.labelSmall?.copyWith(color: muted),
                  ),
                ],
              ],
            ),
            if (awaitingPayment) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: AppSemantic.of(context).warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.hourglass_top_outlined,
                        size: 16,
                        color: AppSemantic.of(context).warning),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Waiting for the payment to be verified. This booking '
                        'can be confirmed once the fee reaches your account.',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                                color: AppSemantic.of(context).warning),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (onConfirm != null || onComplete != null || onCancel != null) ...[
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (onCancel != null)
                    TextButton(onPressed: onCancel, child: const Text('Cancel')),
                  if (onComplete != null) ...[
                    const SizedBox(width: 4),
                    FilledButton.tonal(
                      onPressed: onComplete,
                      style: AppTheme.rowAction,
                      child: const Text('Complete'),
                    ),
                  ],
                  if (onConfirm != null) ...[
                    const SizedBox(width: 4),
                    FilledButton(
                      onPressed: awaitingPayment ? null : onConfirm,
                      style: AppTheme.rowAction,
                      child: Text(awaitingPayment ? 'Awaiting payment' : 'Confirm'),
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
}
