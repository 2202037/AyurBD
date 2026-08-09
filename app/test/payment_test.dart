/// Tests for payment health check and appointment repository payment flow.
///
/// These tests verify the structured error handling and logging in the payment system.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ayur/core/utils/payment_debug_logger.dart';
import 'package:ayur/models/appointment_models.dart';

class MockSupabaseClient extends Mock implements SupabaseClient {}
class MockGoTrueClient extends Mock implements GoTrueClient {}
class MockSession extends Mock implements Session {}
class MockUser extends Mock implements User {}

void main() {
  group('PaymentDebugLogger', () {
    test('logs structured data when enabled', () {
      PaymentDebugLogger.enabled = true;

      // This test just verifies the logger doesn't crash
      PaymentDebugLogger.log(
        event: 'TEST_EVENT',
        appointmentId: 123,
        patientId: 'patient-uuid',
        status: 'pending_payment',
        paymentStatus: 'pending',
        stripeSessionId: 'cs_test_123',
        stripePaymentIntentId: 'pi_test_123',
        details: {'test': 'data'},
      );

      PaymentDebugLogger.logError(
        event: 'TEST_ERROR',
        appointmentId: 123,
        patientId: 'patient-uuid',
        error: 'Test error message',
        stackTrace: StackTrace.current,
        statusCode: 400,
      );

      PaymentDebugLogger.logCreateCheckoutRequest(
        appointmentId: 123,
        patientId: 'patient-uuid',
      );

      PaymentDebugLogger.logAppointmentState(
        appointmentId: 123,
        patientId: 'patient-uuid',
        status: 'pending_payment',
        paymentStatus: 'pending',
        fee: 500.0,
        doctorExists: true,
        doctorFeeExists: true,
        stripeConfigured: true,
        appUrlConfigured: true,
      );

      PaymentDebugLogger.logStripeRequest(
        appointmentId: 123,
        patientId: 'patient-uuid',
        stripeSessionId: 'cs_test_123',
        amountInPoisha: 50000,
        currency: 'bdt',
      );

      PaymentDebugLogger.logStripeResponse(
        appointmentId: 123,
        patientId: 'patient-uuid',
        stripeSessionId: 'cs_test_123',
        checkoutUrl: 'https://checkout.stripe.com/pay/cs_test_123',
        paymentIntentId: 'pi_test_123',
      );

      PaymentDebugLogger.logWebhookEvent(
        eventType: 'checkout.session.completed',
        signatureVerified: true,
        appointmentId: 123,
        patientId: 'patient-uuid',
        stripeSessionId: 'cs_test_123',
        stripePaymentIntentId: 'pi_test_123',
        metadata: {'appointment_id': '123'},
      );

      PaymentDebugLogger.logRpcResult(
        rpcName: 'record_payment_split',
        appointmentId: 123,
        patientId: 'patient-uuid',
        success: true,
        result: {'id': 1},
      );

      PaymentDebugLogger.logAppointmentUpdate(
        appointmentId: 123,
        patientId: 'patient-uuid',
        oldStatus: 'pending_payment',
        newStatus: 'confirmed',
        oldPaymentStatus: 'pending',
        newPaymentStatus: 'paid',
        confirmationCode: 'ABC123',
      );

      PaymentDebugLogger.logNotification(
        appointmentId: 123,
        recipientId: 'patient-uuid',
        type: 'appointment_confirmed',
        success: true,
      );

      PaymentDebugLogger.logReceiptGeneration(
        appointmentId: 123,
        patientId: 'patient-uuid',
        success: true,
        paymentId: 1,
      );

      PaymentDebugLogger.logFinalState(
        appointmentId: 123,
        patientId: 'patient-uuid',
        status: 'confirmed',
        paymentStatus: 'paid',
        confirmationCode: 'ABC123',
        stripeSessionId: 'cs_test_123',
        stripePaymentIntentId: 'pi_test_123',
      );

      PaymentDebugLogger.enabled = false;
    });

    test('does not log when disabled', () {
      PaymentDebugLogger.enabled = false;
      // Should not crash
      PaymentDebugLogger.log(
        event: 'TEST_EVENT',
        appointmentId: 123,
        patientId: 'patient-uuid',
      );
    });
  });

  group('PaymentHealthReport', () {
    test('parses healthy report correctly', () {
      final json = {
        'overall_status': 'healthy',
        'timestamp': '2024-01-15T10:30:00.000Z',
        'checks': [
          {
            'check': 'appointment_exists',
            'status': 'pass',
            'message': 'Appointment found',
          },
          {
            'check': 'appointment_status_valid',
            'status': 'pass',
            'message': 'Appointment is awaiting payment',
          },
        ],
        'appointment_id': 123,
        'patient_id': 'patient-uuid',
      };

      final report = PaymentHealthReport.fromJson(json);

      expect(report.isHealthy, true);
      expect(report.overallStatus, 'healthy');
      expect(report.appointmentId, 123);
      expect(report.patientId, 'patient-uuid');
      expect(report.checks.length, 2);
      expect(report.passes.length, 2);
      expect(report.failures.length, 0);
      expect(report.warnings.length, 0);
    });

    test('parses unhealthy report with failures correctly', () {
      final json = {
        'overall_status': 'unhealthy',
        'timestamp': '2024-01-15T10:30:00.000Z',
        'checks': [
          {
            'check': 'appointment_exists',
            'status': 'fail',
            'message': 'Appointment not found',
          },
          {
            'check': 'stripe_secret_configured',
            'status': 'fail',
            'message': 'Stripe secret key is missing',
          },
          {
            'check': 'doctor_commission_valid',
            'status': 'warn',
            'message': 'Doctor commission percentage not set',
          },
        ],
      };

      final report = PaymentHealthReport.fromJson(json);

      expect(report.isHealthy, false);
      expect(report.overallStatus, 'unhealthy');
      expect(report.failures.length, 2);
      expect(report.warnings.length, 1);
      expect(report.passes.length, 0);
    });
  });

  group('HealthCheck', () {
    test('parses check correctly', () {
      final json = {
        'check': 'appointment_status_valid',
        'status': 'fail',
        'message': 'Appointment is not awaiting payment',
        'details': {
          'current_status': 'confirmed',
          'expected_status': 'pending_payment',
        },
      };

      final check = HealthCheck.fromJson(json);

      expect(check.check, 'appointment_status_valid');
      expect(check.status, 'fail');
      expect(check.message, 'Appointment is not awaiting payment');
      expect(check.details?['current_status'], 'confirmed');
      expect(check.isFail, true);
      expect(check.isPass, false);
      expect(check.isWarn, false);
    });

    test('toJson works correctly', () {
      final check = HealthCheck(
        check: 'test_check',
        status: 'pass',
        message: 'Test message',
        details: {'key': 'value'},
      );

      final json = check.toJson();

      expect(json['check'], 'test_check');
      expect(json['status'], 'pass');
      expect(json['message'], 'Test message');
      expect(json['details'], {'key': 'value'});
    });
  });

  group('StripeCheckoutSession', () {
    test('parses from JSON correctly', () {
      final json = {
        'checkout_url': 'https://checkout.stripe.com/pay/cs_test_123',
        'session_id': 'cs_test_123',
      };

      final session = StripeCheckoutSession.fromJson(json);

      expect(session.checkoutUrl, 'https://checkout.stripe.com/pay/cs_test_123');
      expect(session.sessionId, 'cs_test_123');
    });
  });

  group('Appointment payment states', () {
    test('isPaid returns true when payment_status is paid', () {
      final appointment = Appointment(
        id: 1,
        doctorId: 1,
        doctorName: 'Dr. Test',
        date: '2024-01-15',
        time: '10:00:00',
        status: 'confirmed',
        paymentStatus: 'paid',
        fee: 500,
      );

      expect(appointment.isPaid, true);
    });

    test('isPaid returns false when payment_status is pending', () {
      final appointment = Appointment(
        id: 1,
        doctorId: 1,
        doctorName: 'Dr. Test',
        date: '2024-01-15',
        time: '10:00:00',
        status: 'pending_payment',
        paymentStatus: 'pending',
        fee: 500,
      );

      expect(appointment.isPaid, false);
    });

    test('canPay returns true for valid unpaid appointment', () {
      final appointment = Appointment(
        id: 1,
        doctorId: 1,
        doctorName: 'Dr. Test',
        date: '2024-01-20', // Future date
        time: '10:00:00',
        status: 'pending_payment',
        paymentStatus: 'pending',
        fee: 500,
      );

      expect(appointment.canPay, true);
    });

    test('canPay returns false for paid appointment', () {
      final appointment = Appointment(
        id: 1,
        doctorId: 1,
        doctorName: 'Dr. Test',
        date: '2024-01-20',
        time: '10:00:00',
        status: 'confirmed',
        paymentStatus: 'paid',
        fee: 500,
      );

      expect(appointment.canPay, false);
    });

    test('canPay returns false for cancelled appointment', () {
      final appointment = Appointment(
        id: 1,
        doctorId: 1,
        doctorName: 'Dr. Test',
        date: '2024-01-20',
        time: '10:00:00',
        status: 'cancelled',
        paymentStatus: 'pending',
        fee: 500,
      );

      expect(appointment.canPay, false);
    });

    test('canPay returns false for zero fee', () {
      final appointment = Appointment(
        id: 1,
        doctorId: 1,
        doctorName: 'Dr. Test',
        date: '2024-01-20',
        time: '10:00:00',
        status: 'pending_payment',
        paymentStatus: 'pending',
        fee: 0,
      );

      expect(appointment.canPay, false);
    });

    test('paymentLabel returns correct labels', () {
      final paid = Appointment(
        id: 1,
        doctorId: 1,
        doctorName: 'Dr. Test',
        date: '2024-01-15',
        time: '10:00:00',
        status: 'confirmed',
        paymentStatus: 'paid',
        fee: 500,
      );
      expect(paid.paymentLabel, 'Paid');

      final pending = Appointment(
        id: 1,
        doctorId: 1,
        doctorName: 'Dr. Test',
        date: '2024-01-15',
        time: '10:00:00',
        status: 'pending_payment',
        paymentStatus: 'pending',
        fee: 500,
      );
      expect(pending.paymentLabel, 'Unpaid');

      final refunded = Appointment(
        id: 1,
        doctorId: 1,
        doctorName: 'Dr. Test',
        date: '2024-01-15',
        time: '10:00:00',
        status: 'cancelled',
        paymentStatus: 'refunded',
        fee: 500,
      );
      expect(refunded.paymentLabel, 'Refunded');
    });
  });
}