/// Payment debug logger for structured logging across the payment flow.
///
/// Provides consistent log format with all required fields:
/// appointment_id, patient_id, status, payment_status, stripe_session_id,
/// stripe_payment_intent_id, error, stack_trace.
///
/// Enable by setting `PaymentDebugLogger.enabled = true` (e.g., via --dart-define).
library;

import 'package:flutter/foundation.dart';

class PaymentDebugLogger {
  PaymentDebugLogger._();

  static bool _enabled = false;

  /// Enable/disable debug logging. Can be toggled at runtime or via
  /// `--dart-define=AYUR_PAYMENT_DEBUG=true` in main.dart before initialization.
  static bool get enabled => _enabled;

  static set enabled(bool value) {
    _enabled = value;
    if (value) {
      debugPrint('[PaymentDebugLogger] Debug logging ENABLED');
    }
  }

  /// Log a payment-related event with structured fields.
  static void log({
    required String event,
    int? appointmentId,
    int? orderId,
    int? paymentId,
    String? transactionId,
    String? patientId,
    String? status,
    String? paymentStatus,
    String? stripeSessionId,
    String? stripePaymentIntentId,
    String? gatewayRef,
    String? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? details,
  }) {
    if (!_enabled && !kDebugMode) return;

    final buffer = StringBuffer();
    buffer.write('[PaymentDebugLogger] ');
    buffer.write(event);
    buffer.write(' | ');

    final fields = <String>[];
    if (appointmentId != null) fields.add('appointment_id=$appointmentId');
    if (orderId != null) fields.add('order_id=$orderId');
    if (paymentId != null) fields.add('payment_id=$paymentId');
    if (transactionId != null) fields.add('transaction_id=$transactionId');
    if (patientId != null) fields.add('patient_id=$patientId');
    if (status != null) fields.add('status=$status');
    if (paymentStatus != null) fields.add('payment_status=$paymentStatus');
    if (stripeSessionId != null) fields.add('stripe_session_id=$stripeSessionId');
    if (stripePaymentIntentId != null) fields.add('stripe_payment_intent_id=$stripePaymentIntentId');
    if (gatewayRef != null) fields.add('gateway_ref=$gatewayRef');

    buffer.write(fields.join(', '));

    if (details != null && details.isNotEmpty) {
      buffer.write(' | details=');
      buffer.write(details);
    }

    debugPrint(buffer.toString());

    if (error != null) {
      debugPrint('[PaymentDebugLogger] ERROR: $error');
      if (stackTrace != null) {
        debugPrint('[PaymentDebugLogger] STACK: $stackTrace');
      }
    }
  }

  /// Log incoming request to create-checkout-session
  static void logCreateCheckoutRequest({
    required int appointmentId,
    required String patientId,
  }) {
    log(
      event: 'CREATE_CHECKOUT_REQUEST',
      appointmentId: appointmentId,
      patientId: patientId,
    );
  }

  /// Log appointment state before payment
  static void logAppointmentState({
    required int appointmentId,
    required String patientId,
    required String status,
    required String paymentStatus,
    required double fee,
    required bool doctorExists,
    required bool doctorFeeExists,
    required bool stripeConfigured,
    required bool appUrlConfigured,
  }) {
    log(
      event: 'APPOINTMENT_STATE_CHECK',
      appointmentId: appointmentId,
      patientId: patientId,
      status: status,
      paymentStatus: paymentStatus,
      details: {
        'fee': fee,
        'doctor_exists': doctorExists,
        'doctor_fee_exists': doctorFeeExists,
        'stripe_configured': stripeConfigured,
        'app_url_configured': appUrlConfigured,
      },
    );
  }

  /// Log Stripe request
  static void logStripeRequest({
    required int appointmentId,
    required String patientId,
    required String stripeSessionId,
    required int amountInPoisha,
    required String currency,
  }) {
    log(
      event: 'STRIPE_REQUEST',
      appointmentId: appointmentId,
      patientId: patientId,
      stripeSessionId: stripeSessionId,
      details: {
        'amount_in_poisha': amountInPoisha,
        'currency': currency,
      },
    );
  }

  /// Log Stripe response
  static void logStripeResponse({
    required int appointmentId,
    required String patientId,
    required String stripeSessionId,
    required String checkoutUrl,
    required String paymentIntentId,
    String? gatewayRef,
  }) {
    log(
      event: 'STRIPE_RESPONSE',
      appointmentId: appointmentId,
      patientId: patientId,
      stripeSessionId: stripeSessionId,
      stripePaymentIntentId: paymentIntentId,
      gatewayRef: gatewayRef,
      details: {
        'checkout_url': checkoutUrl,
      },
    );
  }

  /// Log webhook event
  static void logWebhookEvent({
    required String eventType,
    required bool signatureVerified,
    int? appointmentId,
    int? orderId,
    String? patientId,
    String? stripeSessionId,
    String? stripePaymentIntentId,
    String? gatewayRef,
    Map<String, dynamic>? metadata,
  }) {
    log(
      event: 'WEBHOOK_EVENT',
      appointmentId: appointmentId,
      orderId: orderId,
      patientId: patientId,
      stripeSessionId: stripeSessionId,
      stripePaymentIntentId: stripePaymentIntentId,
      gatewayRef: gatewayRef,
      details: {
        'event_type': eventType,
        'signature_verified': signatureVerified,
        'metadata': metadata,
      },
    );
  }

  /// Log RPC call result
  static void logRpcResult({
    required String rpcName,
    int? appointmentId,
    int? orderId,
    int? paymentId,
    String? transactionId,
    String? patientId,
    required bool success,
    dynamic result,
    String? error,
    StackTrace? stackTrace,
  }) {
    log(
      event: 'RPC_RESULT',
      appointmentId: appointmentId,
      orderId: orderId,
      paymentId: paymentId,
      transactionId: transactionId,
      patientId: patientId,
      details: {
        'rpc': rpcName,
        'success': success,
        'result': result?.toString(),
      },
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// Log appointment update
  static void logAppointmentUpdate({
    required int appointmentId,
    required String patientId,
    required String oldStatus,
    required String newStatus,
    required String oldPaymentStatus,
    required String newPaymentStatus,
    String? confirmationCode,
    String? gatewayRef,
  }) {
    log(
      event: 'APPOINTMENT_UPDATE',
      appointmentId: appointmentId,
      patientId: patientId,
      status: newStatus,
      paymentStatus: newPaymentStatus,
      gatewayRef: gatewayRef,
      details: {
        'old_status': oldStatus,
        'new_status': newStatus,
        'old_payment_status': oldPaymentStatus,
        'new_payment_status': newPaymentStatus,
        'confirmation_code': confirmationCode,
      },
    );
  }

  /// Log notification result
  static void logNotification({
    required int appointmentId,
    required String recipientId,
    required String type,
    required bool success,
    String? error,
  }) {
    log(
      event: 'NOTIFICATION',
      appointmentId: appointmentId,
      patientId: recipientId,
      details: {
        'type': type,
        'success': success,
      },
      error: error,
    );
  }

  /// Log receipt generation
  static void logReceiptGeneration({
    required int appointmentId,
    required String patientId,
    required bool success,
    int? paymentId,
    String? error,
    StackTrace? stackTrace,
  }) {
    log(
      event: 'RECEIPT_GENERATION',
      appointmentId: appointmentId,
      patientId: patientId,
      details: {
        'payment_id': paymentId,
        'success': success,
      },
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// Log final appointment state after payment flow
  static void logFinalState({
    required int appointmentId,
    required String patientId,
    required String status,
    required String paymentStatus,
    String? confirmationCode,
    String? stripeSessionId,
    String? stripePaymentIntentId,
    String? gatewayRef,
  }) {
    log(
      event: 'FINAL_STATE',
      appointmentId: appointmentId,
      patientId: patientId,
      status: status,
      paymentStatus: paymentStatus,
      stripeSessionId: stripeSessionId,
      stripePaymentIntentId: stripePaymentIntentId,
      gatewayRef: gatewayRef,
      details: {
        'confirmation_code': confirmationCode,
      },
    );
  }

  /// Log error with full context
  static void logError({
    required String event,
    required int appointmentId,
    int? orderId,
    int? paymentId,
    String? transactionId,
    required String patientId,
    required String error,
    required StackTrace stackTrace,
    String? status,
    String? paymentStatus,
    String? stripeSessionId,
    String? stripePaymentIntentId,
    String? gatewayRef,
    int? statusCode,
    Map<String, dynamic>? details,
  }) {
    log(
      event: 'ERROR: $event',
      appointmentId: appointmentId,
      orderId: orderId,
      paymentId: paymentId,
      transactionId: transactionId,
      patientId: patientId,
      status: status,
      paymentStatus: paymentStatus,
      stripeSessionId: stripeSessionId,
      stripePaymentIntentId: stripePaymentIntentId,
      gatewayRef: gatewayRef,
      error: error,
      stackTrace: stackTrace,
      details: details != null
          ? {...details, if (statusCode != null) 'status_code': statusCode}
          : (statusCode != null ? {'status_code': statusCode} : null),
    );
  }
}

/// Extension to easily log from async functions with try-catch
extension PaymentDebugLogOnFuture<T> on Future<T> {
  /// Log success/error for a future, returning the result or rethrowing
  Future<T> logPayment({
    required String event,
    int? appointmentId,
    int? orderId,
    int? paymentId,
    String? transactionId,
    String? patientId,
    String? status,
    String? paymentStatus,
    String? stripeSessionId,
    String? stripePaymentIntentId,
    String? gatewayRef,
  }) async {
    try {
      final result = await this;
      PaymentDebugLogger.log(
        event: '$event.SUCCESS',
        appointmentId: appointmentId,
        orderId: orderId,
        paymentId: paymentId,
        transactionId: transactionId,
        patientId: patientId,
        status: status,
        paymentStatus: paymentStatus,
        stripeSessionId: stripeSessionId,
        stripePaymentIntentId: stripePaymentIntentId,
        gatewayRef: gatewayRef,
      );
      return result;
    } catch (e, st) {
      PaymentDebugLogger.logError(
        event: event,
        appointmentId: appointmentId ?? 0,
        orderId: orderId,
        paymentId: paymentId,
        transactionId: transactionId,
        patientId: patientId ?? '',
        error: e.toString(),
        stackTrace: st,
        status: status,
        paymentStatus: paymentStatus,
        stripeSessionId: stripeSessionId,
        stripePaymentIntentId: stripePaymentIntentId,
        gatewayRef: gatewayRef,
      );
      rethrow;
    }
  }
}
