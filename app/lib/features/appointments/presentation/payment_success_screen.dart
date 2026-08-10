/// Post-Stripe redirect screen.
///
/// Stripe Checkout lands here on success (and on [PaymentCancelledScreen] on
/// cancel), through either a web URL — `APP_URL/#/payment-success?...` — or a
/// deep link — `ayurbd://payment-success?...`. Both carry `appointment_id` and
/// `session_id`; neither of them is trusted on its own, so this screen re-reads
/// the appointment from Supabase and only claims success once the webhook's
/// `record_payment_split()` / `confirm_appointment()` have landed and
/// `payment_status` reads `paid`.
///
/// The webhook and the browser redirect race: the redirect fires the moment
/// Stripe accepts the card, which can be a beat before the webhook has written
/// the row. So the refresh is not a single shot — it polls a few times before
/// giving up, so a slow-but-healthy webhook still reads as success instead of a
/// scary error.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/payment_debug_logger.dart';
import '../../../models/appointment_models.dart';
import '../data/appointment_repository.dart';
import 'my_appointments_screen.dart' show myAppointmentsProvider;

/// Polling budget for the webhook to catch up with the redirect.
///
/// Stripe delivers `checkout.session.completed` moments after the browser
/// redirects, but "moments" is not "instantly" — give the server up to
/// [_verifyAttempts] chances, spaced [_verifyGap] apart, before calling it.
const _verifyAttempts = 8;
const _verifyGap = Duration(seconds: 1);

class PaymentSuccessScreen extends ConsumerStatefulWidget {
  const PaymentSuccessScreen({super.key, this.appointmentId, this.sessionId});

  /// Taken from the redirect query string. Null when someone landed here by
  /// hand; the screen then has nothing to verify.
  final int? appointmentId;

  /// The Stripe Checkout `cs_...` id, passed back by `{CHECKOUT_SESSION_ID}`.
  final String? sessionId;

  @override
  ConsumerState<PaymentSuccessScreen> createState() =>
      _PaymentSuccessScreenState();
}

class _PaymentSuccessScreenState extends ConsumerState<PaymentSuccessScreen> {
  /// pending | paid | failed
  _VerifyStatus _status = _VerifyStatus.checking;
  Appointment? _appointment;
  String? _error;

  int get _id => widget.appointmentId ?? 0;

  @override
  void initState() {
    super.initState();
    if (_id <= 0) {
      // Landed without the query string — no appointment to verify. The screen
      // explains the dead end instead of pretending success.
      _status = _VerifyStatus.missing;
      return;
    }
    _verify();
  }

  Future<void> _verify() async {
    setState(() {
      _status = _VerifyStatus.checking;
      _error = null;
    });

    final repo = ref.read(appointmentRepositoryProvider);

    for (var attempt = 0; attempt < _verifyAttempts; attempt++) {
      try {
        final appointment = await repo.byId(_id);
        if (appointment.isPaid) {
          // The list behind this screen still holds the pre-payment row. Drop
          // it so returning to "My appointments" shows a paid, confirmed
          // booking rather than a stale one with a Pay button on it.
          ref.invalidate(myAppointmentsProvider);

          if (mounted) {
            setState(() {
              _appointment = appointment;
              _status = _VerifyStatus.paid;
            });
          }

          PaymentDebugLogger.logAppointmentUpdate(
            appointmentId: appointment.id,
            patientId: appointment.patientId ?? '',
            oldStatus: 'pending_payment',
            newStatus: appointment.status,
            oldPaymentStatus: 'pending',
            newPaymentStatus: appointment.paymentStatus,
            confirmationCode: appointment.confirmationCode,
          );

          PaymentDebugLogger.logFinalState(
            appointmentId: appointment.id,
            patientId: appointment.patientId ?? '',
            status: appointment.status,
            paymentStatus: appointment.paymentStatus,
            confirmationCode: appointment.confirmationCode,
          );

          return;
        }
        // Still pending: give the webhook a moment, then re-read.
      } on ApiException catch (e) {
        PaymentDebugLogger.logError(
          event: 'VERIFY_PAYMENT_FAILED',
          appointmentId: _id,
          patientId: '', // We don't have it here
          error: e.message,
          stackTrace: StackTrace.current,
          statusCode: e.statusCode,
        );

        // 404 here means the appointment is not readable — it was cancelled, or
        // this is not the patient who booked it. More polling cannot change
        // that, so stop rather than spend eight seconds on it.
        if (e.statusCode == 404) {
          if (mounted) {
            setState(() {
              _error = e.message;
              _status = _VerifyStatus.failed;
            });
          }
          return;
        }
        // Network blip during polling — keep trying until the budget runs out.
        // The message is not shown while polling: the user is looking at
        // "Verifying payment…", and flashing an error under it during a retry
        // that may well succeed reads as a failure that has not happened.
      } catch (e, st) {
        PaymentDebugLogger.logError(
          event: 'VERIFY_PAYMENT_ERROR',
          appointmentId: _id,
          patientId: '',
          error: e.toString(),
          stackTrace: st,
        );
        // Deliberately not surfaced verbatim — `e.toString()` here is a Dart
        // type name or a raw driver sentence, which tells a patient nothing
        // about their money.
      }

      if (!mounted) return;
      await Future<void>.delayed(_verifyGap);
    }

    if (mounted) {
      setState(() => _status = _VerifyStatus.failed);
    }
  }

  void _openReceipt() {
    if (_appointment == null) return;
    context.push(Routes.receiptFor(_appointment!.id));
  }

  void _goToAppointment() {
    if (_appointment == null) return;
    context.go(Routes.appointments);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Payment'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.gap),
          child: switch (_status) {
            _VerifyStatus.checking => _CenteredColumn(
                icon: Icons.verified_outlined,
                color: theme.colorScheme.primary,
                title: 'Verifying payment…',
                message: _error ?? 'Confirming your payment with the server.',
              ),
            _VerifyStatus.missing => _CenteredColumn(
                icon: Icons.help_outline,
                color: theme.colorScheme.onSurfaceVariant,
                title: 'Nothing to verify',
                message:
                    'This page needs the appointment id from the checkout '
                    'redirect. Head back to your appointments and try again.',
                actions: [
                  FilledButton(
                    onPressed: () => context.go(Routes.appointments),
                    child: const Text('My appointments'),
                  ),
                ],
              ),
            _VerifyStatus.paid => _PaidBody(
                appointment: _appointment!,
                onReceipt: _openReceipt,
                onAppointment: _goToAppointment,
              ),
            _VerifyStatus.failed => _CenteredColumn(
                icon: Icons.error_outline,
                color: theme.colorScheme.error,
                title: 'Payment could not be confirmed',
                message: _error ??
                    'We could not confirm your payment just now. It may still '
                        'be processing — check your appointments before paying '
                        'again.',
                actions: [
                  FilledButton(
                    onPressed: _verify,
                    child: const Text('Try again'),
                  ),
                  TextButton(
                    onPressed: () => context.go(Routes.appointments),
                    child: const Text('My appointments'),
                  ),
                ],
              ),
          },
        ),
      ),
    );
  }
}

/// The success state: confirmation message plus the three escapes the flow
/// promises (receipt, appointment, home).
class _PaidBody extends StatelessWidget {
  const _PaidBody({
    required this.appointment,
    required this.onReceipt,
    required this.onAppointment,
  });

  final Appointment appointment;
  final VoidCallback onReceipt;
  final VoidCallback onAppointment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle,
                size: 96, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('Payment Successful',
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('Appointment Confirmed',
                style: theme.textTheme.titleMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            if (appointment.confirmationCode != null) ...[
              Text('Confirmation code',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
              Text(
                appointment.confirmationCode!,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onReceipt,
                icon: const Icon(Icons.receipt_long_outlined),
                label: const Text('View Receipt'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onAppointment,
                icon: const Icon(Icons.event_outlined),
                label: const Text('Go to Appointment'),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => context.go(Routes.home),
              child: const Text('Home'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CenteredColumn extends StatelessWidget {
  const _CenteredColumn({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
    this.actions = const [],
  });

  final IconData icon;
  final Color color;
  final String title;
  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 72, color: color),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              actions[i],
            ],
          ],
        ),
      ),
    );
  }
}

enum _VerifyStatus { checking, paid, failed, missing }
