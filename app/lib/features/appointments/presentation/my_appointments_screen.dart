/// My appointments — the patient's own bookings, with cancel, pay and review
/// actions.
///
/// The status filter values are not free text: the old `appointments_my()`
/// whitelisted exactly pending/confirmed/completed/cancelled and answered 400
/// on anything else. The chips below send those spellings — note `cancelled`
/// with two Ls, even though [Appointment.isCancelled] tolerantly accepts
/// `canceled` on the way in. `expired` (a past unpaid slot) is included too:
/// Postgrest filters it like any other value, and it is worth being able to see
/// at a glance which bookings lapsed without being marked cancelled.
///
/// ## Paying
///
/// Nothing on this screen decides whether an appointment may be paid.
/// [PaymentService] asks the database (`appointment_payability`) and the write
/// paths re-check, so a refusal arrives as a [PaymentFailure] with a sentence
/// already fit to show. Two of those refusals are not errors at all —
/// ALREADY_PAID and PAYMENT_PENDING_VERIFICATION mean the patient's money is
/// fine and this screen is simply stale — so they refresh the row instead of
/// raising a red toast that would invite a second payment.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException;

import '../../../app/router.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/paged_controller.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/appointment_models.dart';
import '../../../models/content_models.dart';
import '../../patient/presentation/review_sheet.dart';
import '../../payment/data/payment_service.dart';
import '../../../core/utils/payment_debug_logger.dart';
import '../data/appointment_repository.dart';

/// `null` means "no filter" — the parameter is then omitted entirely rather
/// than sent as an empty string, which the whitelist would reject.
final appointmentFilterProvider = StateProvider<String?>((ref) => null);

/// Watches the filter so Riverpod disposes and rebuilds the controller when it
/// changes; pagination resets for free instead of by hand.
final myAppointmentsProvider =
    StateNotifierProvider<PagedController<Appointment>, PagedState<Appointment>>(
        (ref) {
  final status = ref.watch(appointmentFilterProvider);
  final repo = ref.watch(appointmentRepositoryProvider);
  return PagedController<Appointment>(
    (page) => repo.mine(page: page, status: status),
  );
});

const _filters = <({String? value, String label})>[
  (value: null, label: 'All'),
  // A booking now opens at `pending_payment` and only reaches `pending` once
  // the money is verified. Without a chip for it, the most urgent thing a
  // patient owns — a held slot on a clock — was reachable only under "All".
  (value: 'pending_payment', label: 'To pay'),
  (value: 'pending', label: 'Pending'),
  (value: 'confirmed', label: 'Confirmed'),
  (value: 'completed', label: 'Completed'),
  (value: 'expired', label: 'Expired'),
  (value: 'cancelled', label: 'Cancelled'),
];

class MyAppointmentsScreen extends ConsumerStatefulWidget {
  const MyAppointmentsScreen({super.key});

  @override
  ConsumerState<MyAppointmentsScreen> createState() =>
      _MyAppointmentsScreenState();
}

class _MyAppointmentsScreenState extends ConsumerState<MyAppointmentsScreen> {
  bool _busy = false;

  PagedController<Appointment> get _controller =>
      ref.read(myAppointmentsProvider.notifier);

  /// Both actions answer with the updated appointment, so the row is patched in
  /// place — no full reload, no scroll jump. Returns false if the call failed, so
  /// a caller cannot follow a rejected payment with a success message.
  Future<bool> _run(Future<Appointment> Function() action) async {
    setState(() => _busy = true);
    try {
      final updated = await action();
      _controller.replaceWhere((a) => a.id == updated.id, updated);
      return true;
    } on ApiException catch (e) {
      // §10: a 401 is a normal logout handled by the router, not an error toast.
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

  /// No reason field on purpose: `appointments_cancel()` validates
  /// `appointment_id` and nothing else, and `validate()` returns only the
  /// rule-listed fields — a typed reason would be dropped without a word.
  Future<void> _confirmCancel(Appointment a) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this appointment?'),
        content: Text(
          '${a.doctorName}\n${a.whenLabel}\n\n'
          'The slot goes back into the pool straight away. '
          'Any payment already made is marked for refund.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Cancel appointment'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await _run(() => ref
        .read(appointmentRepositoryProvider)
        .cancel(appointmentId: a.id));
  }

  Future<void> _openPay(Appointment a) async {
    final choice = await showModalBottomSheet<PaymentSubmission>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _MethodSheet(
        amount: a.fee,
        appointmentId: a.id,
        onStripeCheckout: (session) async {
          final uri = Uri.tryParse(session.checkoutUrl);
          if (uri == null ||
              !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
            // Previously a failed launch did nothing at all, leaving the user
            // looking at a sheet that had apparently ignored them.
            if (mounted) {
              showToast(
                context,
                'Could not open the payment page. Please try again.',
                error: true,
              );
            }
          }
        },
      ),
    );
    if (choice == null) return;

    setState(() => _busy = true);
    try {
      final updated = await ref.read(appointmentRepositoryProvider).pay(
            appointmentId: a.id,
            method: choice.method,
            transactionRef: choice.transactionRef,
            senderNumber: choice.senderNumber,
          );
      _controller.replaceWhere((x) => x.id == updated.id, updated);
      if (mounted) {
        showToast(
          context,
          'Payment submitted. It will show as paid once verified.',
        );
      }
    } on PaymentException catch (e) {
      // The money is already accounted for; the row on screen is just behind.
      // Telling the patient "that failed" here is how people pay twice.
      if (e.failure.isBenign) {
        await _refreshRow(a.id);
        if (mounted) showToast(context, e.message);
        return;
      }
      if (mounted && !e.isUnauthorized) {
        showToast(context, e.message, error: true);
      }
      // A refusal about state — expired, cancelled, refunded — means this row is
      // out of date whatever else happened, so re-read it and let the buttons
      // settle to the truth.
      if (e.failure == PaymentFailure.notPayable ||
          e.failure == PaymentFailure.alreadyRefunded) {
        await _refreshRow(a.id);
      }
    } on ApiException catch (e) {
      if (mounted && !e.isUnauthorized) {
        showToast(context, e.message, error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Re-reads one appointment and patches it in place.
  ///
  /// Used after a refusal that proves the list is stale. Failures are swallowed
  /// on purpose: this runs while a message is already being shown, and a second
  /// toast about a failed background refresh would only bury the first.
  Future<void> _refreshRow(int id) async {
    try {
      final fresh = await ref.read(appointmentRepositoryProvider).byId(id);
      if (!mounted) return;
      _controller.replaceWhere((x) => x.id == fresh.id, fresh);
    } catch (_) {
      // Ignored deliberately — see above.
    }
  }

  /// Reviews the doctor against this appointment: `POST /reviews` keys on
  /// (target_type, target_id, user), and the appointment id is what the server
  /// uses to prove the patient consulted this doctor (one review per
  /// appointment, no "must be completed" rule). No refresh afterwards — a new
  /// review is created at `pending` and stays invisible until an admin approves
  /// it, so reloading would show exactly the same list and read as a failed
  /// submit.
  Future<void> _openReview(Appointment a) async {
    await showReviewSheet(
      context,
      target: ReviewTarget.doctor,
      targetId: a.doctorId,
      targetName: a.doctorName,
      appointmentId: a.id,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(myAppointmentsProvider);
    final active = ref.watch(appointmentFilterProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('My appointments'),
        actions: [
          IconButton(
            tooltip: 'Payments',
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () => context.push(Routes.payments),
          ),
        ],
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
                      selected: active == f.value,
                      onSelected: (_) => ref
                          .read(appointmentFilterProvider.notifier)
                          .state = f.value,
                    ),
                  ),
              ],
            ),
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
          emptyIcon: Icons.event_available_outlined,
          emptyMessage: active == null
              ? 'When you book a doctor, it shows up here.'
              : 'Nothing with that status right now.',
          itemBuilder: (context, a, _) => _AppointmentCard(
            appointment: a,
            onCancel: a.canCancel ? () => _confirmCancel(a) : null,
            onPay: a.canPay ? () => _openPay(a) : null,
            onReview: a.canReview ? () => _openReview(a) : null,
          ),
        ),
      ),
    );
  }
}

class _AppointmentCard extends StatelessWidget {
  const _AppointmentCard({
    required this.appointment,
    this.onCancel,
    this.onPay,
    this.onReview,
  });

  final Appointment appointment;
  final VoidCallback? onCancel;
  final VoidCallback? onPay;

  /// Null unless the appointment can be reviewed (any non-cancelled one — there
  /// is no "must be completed" rule), so the button simply does not exist on a
  /// booking that was cancelled.
  final VoidCallback? onReview;

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
                RemoteImage(
                  path: a.doctorImage,
                  width: 54,
                  height: 54,
                  radius: 27,
                  fallbackIcon: Icons.person_outline,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(a.doctorName,
                          style: theme.textTheme.titleSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      if (a.specialty != null && a.specialty!.isNotEmpty)
                        Text(a.specialty!,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: muted),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Text(a.whenLabel, style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
                StatusPill(status: a.status, dense: true),
              ],
            ),
            if (a.clinicName != null && a.clinicName!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.place_outlined, size: 14, color: muted),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      [a.clinicName, a.clinicAddress]
                          .where((s) => s != null && s.isNotEmpty)
                          .join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Text(Fmt.money(a.fee), style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                // `paymentStatus` is non-nullable and defaults to 'pending' —
                // the live enum is pending|paid|refunded and has no 'unpaid'.
                // [paymentLabel] folds in the separate `payments` verification
                // state, so a submitted-but-unverified payment reads as
                // "Awaiting verification" rather than a flat "Pending".
                StatusPill(
                  status: a.paymentStatus,
                  label: a.paymentLabel,
                  dense: true,
                ),
                const Spacer(),
                if (onCancel != null)
                  TextButton(onPressed: onCancel, child: const Text('Cancel')),
                if (onReview != null) ...[
                  const SizedBox(width: 4),
                  // Same explicit size as 'Pay now' below, and for the same
                  // reason: an unbounded Row cannot satisfy an infinite
                  // minimumSize.width and throws during layout.
                  OutlinedButton.icon(
                    onPressed: onReview,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(64, 40),
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.rate_review_outlined, size: 16),
                    label: const Text('Review'),
                  ),
                ],
                if (onPay != null) ...[
                  const SizedBox(width: 4),
                  // Sized explicitly because this sits in a Row, which offers
                  // unbounded width. A button whose minimumSize.width is
                  // infinite cannot satisfy that and throws during layout.
                  FilledButton.tonal(
                    onPressed: onPay,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(64, 40),
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('Pay now'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What the payment sheet collects. A record rather than four positional
/// returns, so adding a field later cannot silently reorder the call site.
typedef PaymentSubmission = ({
  PaymentMethod method,
  String? transactionRef,
  String? senderNumber,
});

/// The six methods the *appointments* endpoint accepts — the live
/// `payments.payment_method` enum. Deliberately not the pharmacy list even
/// though the values currently match: they are two independent whitelists, and
/// merging them would mean a change to one silently sends unaccepted values to
/// the other.
///
/// The sheet collects a transaction reference too, because the server 422s any
/// method except Cash that arrives without one. Picking a method alone used to
/// be enough here, which meant every mobile-banking payment bounced.
class _MethodSheet extends ConsumerStatefulWidget {
  const _MethodSheet({
    required this.amount,
    required this.appointmentId,
    required this.onStripeCheckout,
  });

  final double amount;
  final int appointmentId;
  final Future<void> Function(StripeCheckoutSession) onStripeCheckout;

  @override
  ConsumerState<_MethodSheet> createState() => _MethodSheetState();
}

class _MethodSheetState extends ConsumerState<_MethodSheet> {
  final _form = GlobalKey<FormState>();
  final _ref = TextEditingController();
  final _sender = TextEditingController();

  PaymentMethod? _method;
  bool _stripeLoading = false;

  @override
  void dispose() {
    _ref.dispose();
    _sender.dispose();
    super.dispose();
  }

  void _submit() {
    final m = _method;
    if (m == null) return;
    if (m.requiresTransactionId && !(_form.currentState?.validate() ?? false)) {
      return;
    }
    Navigator.of(context).pop((
      method: m,
      transactionRef: _ref.text.trim().isEmpty ? null : _ref.text.trim(),
      senderNumber: _sender.text.trim().isEmpty ? null : _sender.text.trim(),
    ));
  }

  /// Opens the hosted Stripe page.
  ///
  /// Tapping twice is safe and is not defended against beyond the in-flight
  /// guard: `gateway_payment_begin()` hands back the checkout session that is
  /// already open rather than creating a second one, so the second tap lands on
  /// the same page — and on the same single charge — as the first.
  Future<void> _payWithStripe() async {
    if (_stripeLoading) return;
    setState(() => _stripeLoading = true);
    try {
      final repo = ref.read(appointmentRepositoryProvider);
      final session = await repo.createStripeCheckoutSession(
        appointmentId: widget.appointmentId,
      );
      if (mounted) {
        await widget.onStripeCheckout(session);
      }
    } on PaymentException catch (e) {
      if (!mounted) return;
      // Already paid, or already awaiting verification: close the sheet and let
      // the list refresh rather than leaving a pay button under the message.
      if (e.failure.isBenign) {
        showToast(context, e.message);
        Navigator.of(context).pop();
        return;
      }
      // Log the full error context for debugging during development.
      PaymentDebugLogger.logError(
        event: 'STRIPE_CHECKOUT_PAYMENT_EXCEPTION',
        appointmentId: widget.appointmentId,
        patientId: '', // not available here
        error: e.toString(),
        stackTrace: StackTrace.current,
        details: {
          'failure': e.failure.name,
          'code': e.code,
          'status_code': e.statusCode,
        },
      );
      showToast(context, e.message, error: true);
    } on ApiException catch (e) {
      if (mounted) {
        // Log the full error context for debugging during development.
        PaymentDebugLogger.logError(
          event: 'STRIPE_CHECKOUT_API_EXCEPTION',
          appointmentId: widget.appointmentId,
          patientId: '',
          error: e.toString(),
          stackTrace: StackTrace.current,
          details: {
            'code': e.code,
            'status_code': e.statusCode,
            'kind': e.kind.name,
          },
        );
        showToast(context, e.message, error: true);
      }
    } on FunctionException catch (e) {
      // Handle Edge Function errors that bypass the service layer translation.
      // The create-checkout-session function returns 400 with
      // {error: "Appointment is not awaiting payment"} when the appointment
      // status is no longer payable.
      if (e.status == 400) {
        final details = e.details;
        final errorMessage = details is Map ? details['error']?.toString() : null;
        if (errorMessage != null &&
            errorMessage.contains('Appointment is not awaiting payment')) {
          if (mounted) {
            PaymentDebugLogger.logError(
              event: 'STRIPE_CHECKOUT_APPOINTMENT_NOT_AWAITING_PAYMENT',
              appointmentId: widget.appointmentId,
              patientId: '',
              error: e.toString(),
              stackTrace: StackTrace.current,
            );
            showToast(
              context,
              'This appointment has already been paid for or cannot be processed at this time.',
              error: true,
            );
          }
          return;
        }
      }
      // Fall through to generic handler for other FunctionExceptions.
      throw e;
    } catch (e, st) {
      // Unexpected error: log full details for debugging, show safe message.
      PaymentDebugLogger.logError(
        event: 'STRIPE_CHECKOUT_UNEXPECTED_ERROR',
        appointmentId: widget.appointmentId,
        patientId: '',
        error: e.toString(),
        stackTrace: st,
      );
      if (mounted) {
        showToast(
          context,
          'Online payment is temporarily unavailable. Please try again shortly.',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _stripeLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = _method;

    return SafeArea(
      child: Padding(
        // Lift the sheet clear of the keyboard when the reference field is open.
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppTheme.gap, 0, AppTheme.gap, 4),
                  child: Text('Pay ${Fmt.money(widget.amount)}',
                      style: theme.textTheme.titleMedium),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppTheme.gap, 0, AppTheme.gap, 12),
                  child: Text(
                    // Say plainly that this is a claim awaiting review. The app
                    // cannot mark an appointment paid, and implying otherwise
                    // would have people turn up to an unpaid booking. Money
                    // goes to the platform account; the admin verifies it.
                    'Send the money first, then record it here. You are paying '
                    'the AyurBD platform account — a platform admin verifies '
                    'your payment, then the chamber confirms your booking.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
                // Stripe online payment option
                ListTile(
                  leading: Icon(Icons.credit_card, color: theme.colorScheme.primary),
                  title: Text(
                    'Pay online (Card / bKash / Mobile Banking)',
                    style: theme.textTheme.bodyLarge,
                  ),
                  subtitle: Text(
                    'Secure checkout via Stripe',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: _stripeLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.arrow_forward_ios, size: 16, color: theme.colorScheme.primary),
                  onTap: _stripeLoading ? null : _payWithStripe,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.3)),
                  ),
                  tileColor: theme.colorScheme.primaryContainer.withOpacity(0.1),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppTheme.gap),
                  child: Text(
                    'Or pay manually:',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                // `sslcommerz` is the online-gateway flow and is launched from
                // its own checkout, not this manual sheet — the server refuses
                // a client-written gateway payment row (42501), so offering it
                // here would be a dead end. The other values are the six
                // manual methods the server whitelists.
                for (final option in PaymentMethod.values)
                  if (!option.isGateway)
                    RadioListTile<PaymentMethod>(
                    value: option,
                    groupValue: _method,
                    onChanged: (v) => setState(() => _method = v),
                    secondary: Icon(_iconFor(option)),
                    title: Text(option.label),
                    dense: true,
                  ),
                if (m != null && m.requiresTransactionId) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(AppTheme.gap, 8, AppTheme.gap, 0),
                    child: TextFormField(
                      controller: _ref,
                      maxLength: 100,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(
                        labelText: 'Transaction ID',
                        prefixIcon: const Icon(Icons.confirmation_number_outlined),
                        helperText: 'From your ${m.label} receipt.',
                      ),
                      // Required by the server for every non-Cash method.
                      validator: (v) => Validators.text(
                        v,
                        field: 'Transaction ID',
                        min: 4,
                        max: 100,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(AppTheme.gap, 0, AppTheme.gap, 0),
                    child: TextFormField(
                      controller: _sender,
                      keyboardType: TextInputType.phone,
                      maxLength: 20,
                      decoration: const InputDecoration(
                        labelText: 'Sender number (optional)',
                        prefixIcon: Icon(Icons.call_outlined),
                        helperText: 'The number you paid from.',
                      ),
                      validator: (v) => Validators.phone(v, optional: true),
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppTheme.gap, 12, AppTheme.gap, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: m == null ? null : _submit,
                      child: Text(m != null && m.requiresTransactionId
                          ? 'Submit for verification'
                          : 'Confirm'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(PaymentMethod m) => switch (m) {
        PaymentMethod.bkash => Icons.phone_android_outlined,
        PaymentMethod.nagad => Icons.phone_android_outlined,
        PaymentMethod.rocket => Icons.phone_android_outlined,
        PaymentMethod.card => Icons.credit_card_outlined,
        PaymentMethod.bankTransfer => Icons.account_balance_outlined,
        PaymentMethod.cash => Icons.payments_outlined,
        PaymentMethod.sslcommerz => Icons.public_outlined,
      };
}
