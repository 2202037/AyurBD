/// The one place appointment payments are started, submitted and judged.
///
/// ## Why this class exists
///
/// Payment logic used to be spread across three layers that each held a piece
/// of the truth and none of the whole:
///
///   * `AppointmentRepository.pay()` inserted straight into `payments`,
///     reading the fee itself and trusting that a trigger would police the
///     rest.
///   * `create-checkout-session` (Edge Function) decided on its own whether an
///     appointment could be paid, by comparing `status` to a hard-coded
///     `'pending_payment'`. That comparison produced the reported
///     "Appointment is not awaiting payment".
///   * The screens each re-derived "can this be paid" from model getters.
///
/// Three opinions about one rule is two too many, and they disagreed. The rule
/// now lives in the database as `appointment_payability()`, and this class is
/// the only Dart code that talks to the payment RPCs. Everything above it —
/// `AppointmentRepository`, the sheets, the success screen — goes through here.
///
/// ## What it does not do
///
/// It does not decide whether a payment is allowed. It asks. Every method here
/// can be refused by the server, and the refusal carries both the sentence to
/// show and a [PaymentFailure] code to branch on. A check performed here would
/// be a convenience for the UI at best; it is never the protection.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_config.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/supabase_service.dart';
import '../../../core/providers.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/payment_debug_logger.dart';
import '../../../models/appointment_models.dart';

/// Why a payment cannot proceed, as decided by the database.
///
/// These mirror the codes `appointment_payability()` returns and the Edge
/// Function forwards. Branch on these, never on the message text.
enum PaymentFailure {
  /// Nothing is wrong — used as the "no failure" value.
  none,

  /// The appointment does not exist, or is not this patient's.
  notFound,

  /// Cancelled, expired, or otherwise past the point of paying.
  notPayable,

  /// A verified payment already exists. Not an error the user caused.
  alreadyPaid,

  /// Refunded; a second payment would be wrong.
  alreadyRefunded,

  /// A free appointment. There is nothing to charge.
  noFee,

  /// A submission for this appointment is already sitting with an admin.
  awaitingVerification,

  /// The signed-in user may not act on this appointment.
  forbidden,

  /// The gateway is not configured, or the call to it failed.
  gatewayUnavailable,

  /// Lost connection, timeout — safe to retry with the same intent.
  network,

  /// Anything we did not recognise.
  unknown;

  /// True when retrying the very same action could plausibly succeed.
  ///
  /// Used to decide whether to keep an idempotency key (retryable) or mint a
  /// fresh one (terminal).
  bool get isRetryable =>
      this == PaymentFailure.network ||
      this == PaymentFailure.gatewayUnavailable ||
      this == PaymentFailure.unknown;

  /// True when the user's payment is in fact fine and the screen should just
  /// refresh rather than shout.
  bool get isBenign =>
      this == PaymentFailure.alreadyPaid ||
      this == PaymentFailure.awaitingVerification;
}

/// A refusal, carrying both halves: what to show, and what to do.
class PaymentException extends ApiException {
  PaymentException({
    required super.message,
    required this.failure,
    super.statusCode,
    super.code,
    super.kind,
    super.errors,
  });

  final PaymentFailure failure;

  @override
  String toString() => 'PaymentException($failure): $message';
}

/// The database's verdict on whether an appointment can be paid right now.
class Payability {
  const Payability({
    required this.payable,
    required this.code,
    required this.message,
    this.status,
    this.amount,
  });

  final bool payable;
  final String code;
  final String message;
  final String? status;
  final double? amount;

  PaymentFailure get failure =>
      payable ? PaymentFailure.none : PaymentService.failureForCode(code);

  factory Payability.fromJson(Map<String, dynamic> json) => Payability(
        payable: json['payable'] == true,
        code: Fmt.str(json['code'], 'UNKNOWN'),
        message: Fmt.str(json['message'], 'This appointment cannot be paid.'),
        status: json['status'] == null ? null : Fmt.str(json['status']),
        amount: json['amount'] == null ? null : Fmt.toDouble(json['amount']),
      );
}

class PaymentService {
  PaymentService(this._sb);

  final SupabaseService _sb;

  // -------------------------------------------------------------------
  // Reads
  // -------------------------------------------------------------------

  /// Asks the server whether this appointment can be paid, and why not.
  ///
  /// Cheap and side-effect free. Useful for enabling a button honestly rather
  /// than letting the user tap into a refusal — but note the button state is
  /// a courtesy: the write paths re-check regardless.
  Future<Payability> payability(int appointmentId) async {
    return _mapErrors(appointmentId, 'payability', () async {
      final row = await _sb.rpc<Map<String, dynamic>>(
        'appointment_payability',
        params: {'p_appointment_id': appointmentId},
      );
      return Payability.fromJson(row);
    });
  }

  // -------------------------------------------------------------------
  // Manual payment (bKash / Nagad / Rocket / card / bank / cash)
  // -------------------------------------------------------------------

  /// Records that the patient says they have sent the money.
  ///
  /// This writes a `payments` row with `payment_status = 'pending'` and
  /// changes nothing else. It does not mark the appointment paid: only an
  /// admin, having checked the reference against a statement, can do that.
  /// Anything else would let a typed-in transaction id book revenue that never
  /// arrived.
  ///
  /// ### Idempotency
  ///
  /// `submit_manual_payment()` takes an advisory lock on the appointment and,
  /// if a pending submission already exists, returns that row instead of
  /// writing a second one. So a double tap, a retry after a dropped response,
  /// or a return to the screen all end with exactly one submission — and the
  /// caller cannot tell the difference, which is the point.
  ///
  /// The amount is never sent. The function reads it from the appointment.
  Future<Map<String, dynamic>> submitManualPayment({
    required int appointmentId,
    required PaymentMethod method,
    String? transactionRef,
    String? senderNumber,
    String? notes,
  }) async {
    if (method.isGateway) {
      // A gateway payment is created by the webhook from what Stripe actually
      // charged. Letting the client claim one would be a self-service receipt.
      throw PaymentException(
        message: 'Please use the online checkout for card payments.',
        failure: PaymentFailure.forbidden,
        statusCode: 400,
        code: 'GATEWAY_METHOD_NOT_MANUAL',
      );
    }

    return _mapErrors(appointmentId, 'submit_manual_payment', () async {
      final row = await _sb.rpc<Map<String, dynamic>>(
        'submit_manual_payment',
        params: {
          'p_appointment_id': appointmentId,
          'p_payment_method': method.value,
          if (_clean(transactionRef) != null)
            'p_transaction_id': _clean(transactionRef),
          if (_clean(senderNumber) != null)
            'p_sender_number': _clean(senderNumber),
          if (_clean(notes) != null) 'p_notes': _clean(notes),
        },
      );
      return row;
    });
  }

  // -------------------------------------------------------------------
  // Card payment (Stripe Checkout)
  // -------------------------------------------------------------------

  /// Opens — or re-opens — the hosted checkout page for an appointment.
  ///
  /// The Edge Function calls `gateway_payment_begin()`, which reuses a live
  /// `payment_sessions` row when one exists. That is what makes repeated taps
  /// safe: the second one lands on the same Stripe page rather than creating a
  /// second customer, a second session and a second chance to be charged.
  Future<StripeCheckoutSession> startCardCheckout({
    required int appointmentId,
  }) async {
    final patientId = _sb.currentUserId;

    PaymentDebugLogger.logCreateCheckoutRequest(
      appointmentId: appointmentId,
      patientId: patientId ?? '',
    );

    return _mapErrors(appointmentId, 'create-checkout-session', () async {
      final result = await _sb.functionsInvoke<Map<String, dynamic>>(
        'create-checkout-session',
        body: {
          'appointment_id': appointmentId,
          // Where Stripe should return this particular client to. A single
          // server-side APP_URL cannot be right for both platforms at once: a
          // web dev origin (`http://localhost:62095`) opens the phone's own
          // localhost on Android, and the `ayurbd://` scheme is not something a
          // browser can navigate to. The client is the only party that knows
          // which it is, so it says — and the function validates the answer
          // against its allowlist rather than trusting it.
          'return_target': AppConfig.paymentReturnTarget,
        },
      );

      if (result['success'] == false) {
        final code = Fmt.str(result['code'], 'UNKNOWN_ERROR');
        final message = Fmt.str(
          result['message'],
          'We could not start the payment. Please try again.',
        );
        final details = result['details'] as Map<String, dynamic>?;

        PaymentDebugLogger.logError(
          event: 'CREATE_CHECKOUT_SESSION_FAILED',
          appointmentId: appointmentId,
          patientId: patientId ?? '',
          error: '$code: $message',
          stackTrace: StackTrace.current,
          details: details,
        );

        throw PaymentException(
          message: message,
          failure: failureForCode(code),
          statusCode: statusForCode(code),
          code: code,
        );
      }

      final data = result['data'];
      if (data is! Map<String, dynamic>) {
        throw PaymentException(
          message: 'We could not start the payment. Please try again.',
          failure: PaymentFailure.gatewayUnavailable,
          statusCode: 500,
          code: 'MALFORMED_CHECKOUT_RESPONSE',
          kind: ApiErrorKind.malformed,
        );
      }

      final session = StripeCheckoutSession.fromJson(data);

      if (!session.isUsable) {
        throw PaymentException(
          message: 'We could not start the payment. Please try again.',
          failure: PaymentFailure.gatewayUnavailable,
          statusCode: 502,
          code: 'MISSING_CHECKOUT_URL',
        );
      }

      PaymentDebugLogger.logStripeResponse(
        appointmentId: appointmentId,
        patientId: patientId ?? '',
        stripeSessionId: session.sessionId,
        checkoutUrl: session.checkoutUrl,
        paymentIntentId: '', // Only known once the webhook arrives.
      );

      return session;
    });
  }

  // -------------------------------------------------------------------
  // Error translation
  // -------------------------------------------------------------------

  /// Maps a server code — from a PL/pgSQL DETAIL or an Edge Function envelope
  /// — onto the reason the UI reacts to.
  static PaymentFailure failureForCode(String? code) {
    switch (code) {
      case 'PAYABLE':
        return PaymentFailure.none;
      case 'APPOINTMENT_NOT_FOUND':
        return PaymentFailure.notFound;
      case 'APPOINTMENT_NOT_PAYABLE':
      case 'INVALID_APPOINTMENT_STATUS':
        return PaymentFailure.notPayable;
      case 'ALREADY_PAID':
      case 'PAYMENT_ALREADY_PROCESSED':
        return PaymentFailure.alreadyPaid;
      case 'ALREADY_REFUNDED':
        return PaymentFailure.alreadyRefunded;
      case 'NO_FEE':
      case 'INVALID_AMOUNT':
        return PaymentFailure.noFee;
      case 'PAYMENT_PENDING_VERIFICATION':
        return PaymentFailure.awaitingVerification;
      case 'FORBIDDEN':
      case 'UNAUTHORIZED':
      case 'GATEWAY_METHOD_NOT_MANUAL':
        return PaymentFailure.forbidden;
      case 'STRIPE_NOT_CONFIGURED':
      case 'APP_URL_NOT_CONFIGURED':
      case 'MISSING_CHECKOUT_URL':
      case 'MALFORMED_CHECKOUT_RESPONSE':
      case 'UNEXPECTED_SERVER_ERROR':
        return PaymentFailure.gatewayUnavailable;
      default:
        return PaymentFailure.unknown;
    }
  }

  /// The HTTP status an Edge Function code stands for, so `ApiException`
  /// helpers such as `isConflict` keep working.
  static int statusForCode(String? code) {
    switch (code) {
      case 'UNAUTHORIZED':
        return 401;
      case 'FORBIDDEN':
        return 403;
      case 'APPOINTMENT_NOT_FOUND':
        return 404;
      case 'INVALID_APPOINTMENT_STATUS':
      case 'PAYMENT_ALREADY_PROCESSED':
        return 409;
      case 'VALIDATION_ERROR':
      case 'INVALID_AMOUNT':
      case 'DOCTOR_NOT_FOUND':
      case 'DOCTOR_FEE_MISSING':
      case 'PAYMENT_START_FAILED':
        return 400;
      case 'STRIPE_NOT_CONFIGURED':
      case 'APP_URL_NOT_CONFIGURED':
      case 'UNEXPECTED_SERVER_ERROR':
        return 500;
      default:
        return 400;
    }
  }

  /// Wording for a failure we could not attribute to a known rule.
  ///
  /// Raw database text — "new row violates row-level security policy for
  /// table \"payments\"" — is never shown. It tells a patient nothing, and it
  /// describes our schema to anyone who asks for it rudely. The detail stays
  /// in the log; the user gets a sentence they can act on.
  static const String _genericFailure =
      'We could not process that payment. Please try again.';

  /// Text that betrays a raw Postgres or PostgREST error rather than one of
  /// our own sentences.
  static final RegExp _rawDatabaseText = RegExp(
    r'row-level security|violates|constraint|relation "|column "|'
    r'permission denied|SQLSTATE|pg_|null value in column|'
    r'JSON object requested|function public\.|duplicate key',
    caseSensitive: false,
  );

  /// Runs [body], turning anything it throws into a [PaymentException] whose
  /// message is safe to show and whose [PaymentFailure] says what to do.
  Future<T> _mapErrors<T>(
    int appointmentId,
    String operation,
    Future<T> Function() body, {
    int? orderId,
    int? paymentId,
    String? transactionId,
  }) async {
    try {
      return await SupabaseService.guard(body);
    } on PaymentException {
      rethrow;
    } on ApiException catch (e) {
      final failure = _failureFor(e);
      final safeMessage = _safeMessage(e, failure);

      // The full text is kept for debugging; only the sanitised sentence
      // leaves this method.
      PaymentDebugLogger.logError(
        event: 'PAYMENT_OPERATION_FAILED',
        appointmentId: appointmentId,
        orderId: orderId,
        paymentId: paymentId,
        transactionId: transactionId,
        patientId: _sb.currentUserId ?? '',
        error: '$operation failed: [${e.code ?? e.statusCode}] ${e.message}',
        stackTrace: StackTrace.current,
        details: {
          'operation': operation,
          'status_code': e.statusCode,
          'server_code': e.code,
          'failure': failure.name,
          'kind': e.kind.name,
        },
      );

      throw PaymentException(
        message: safeMessage,
        failure: failure,
        statusCode: e.statusCode,
        code: e.code,
        kind: e.kind,
        errors: e.errors,
      );
    }
  }

  PaymentFailure _failureFor(ApiException e) {
    if (e.kind == ApiErrorKind.network) return PaymentFailure.network;
    if (e.isUnauthorized) return PaymentFailure.forbidden;

    final byCode = failureForCode(e.code);
    if (byCode != PaymentFailure.unknown) return byCode;

    // No code: fall back on the status. 403 from RLS is still a refusal the
    // user should be told about in plain words.
    switch (e.statusCode) {
      case 403:
        return PaymentFailure.forbidden;
      case 404:
        return PaymentFailure.notFound;
      default:
        return PaymentFailure.unknown;
    }
  }

  /// Keeps a message the server wrote for people; replaces anything that
  /// looks like it was written for a DBA.
  String _safeMessage(ApiException e, PaymentFailure failure) {
    final raw = e.message.trim();

    // Special case: the Edge Function may return this exact message when the
    // appointment status is no longer awaiting payment. The UX wants a clearer
    // sentence than the raw DB text.
    if (raw == 'Appointment is not awaiting payment') {
      return 'This appointment has already been paid for or cannot be processed at this time.';
    }

    if (failure == PaymentFailure.network) {
      return 'No connection. Your payment was not sent — please try again.';
    }
    if (raw.isEmpty || _rawDatabaseText.hasMatch(raw)) {
      return switch (failure) {
        PaymentFailure.forbidden =>
          'You cannot pay for this appointment.',
        PaymentFailure.notFound =>
          'This appointment could not be found.',
        PaymentFailure.notPayable =>
          'This appointment is no longer available for payment.',
        PaymentFailure.alreadyPaid =>
          'You have already paid for this appointment.',
        PaymentFailure.gatewayUnavailable =>
          'Online payment is temporarily unavailable. Please try again shortly.',
        _ => _genericFailure,
      };
    }
    return raw;
  }

  static String? _clean(String? v) {
    final t = v?.trim() ?? '';
    return t.isEmpty ? null : t;
  }
}

final paymentServiceProvider = Provider<PaymentService>(
  (ref) => PaymentService(ref.watch(supabaseServiceProvider)),
);
