/// Appointments, bookable slots and payments.
library;

import '../core/utils/formatters.dart';

/// One bookable time from `/appointments/slots`. The backend generates these
/// from the doctor's available_days/from/to/slot_minutes and marks the ones
/// already taken, so the UI never has to compute availability itself.
///
/// The wire shape is `{time, label, available}`. Note the field is `available`,
/// not `is_booked`: the server folds two separate reasons into it — the time is
/// already taken, *or* it is earlier today — so there is no "booked" flag to
/// read, and naming it that way would misdescribe half the disabled slots.
class Slot {
  const Slot({required this.time, required this.isAvailable, this.serverLabel});

  /// `HH:MM:SS` as the API sends it — pass back verbatim when booking.
  final String time;

  /// The server's verdict, which the UI must not second-guess: it accounts for
  /// existing bookings and for slots that have already passed today.
  final bool isAvailable;

  /// The server's own `g:i A` rendering, e.g. "9:00 AM". Preferred over
  /// reformatting [time] so the grid reads the same as any server-side listing.
  final String? serverLabel;

  bool get isFree => isAvailable;
  String get label =>
      serverLabel != null && serverLabel!.isNotEmpty ? serverLabel! : Fmt.time(time);

  /// Defaults to unavailable when the key is missing. A greyed-out grid is a
  /// visible bug; a grid of enabled phantom slots is an invisible one that only
  /// surfaces as 409s after the user has committed.
  factory Slot.fromJson(Map<String, dynamic> json) => Slot(
        time: Fmt.str(json['time'] ?? json['appointment_time']),
        isAvailable: Fmt.toBool(json['available'], false),
        serverLabel: _orNull(json['label']),
      );
}

class Appointment {
  const Appointment({
    required this.id,
    required this.doctorId,
    required this.doctorName,
    required this.date,
    required this.time,
    required this.status,
    this.specialty,
    this.doctorImage,
    this.clinicName,
    this.clinicAddress,
    this.patientId,
    this.patientName,
    this.patientPhone,
    this.fee = 0,
    this.paymentStatus = 'pending',
    this.paymentReview,
    this.type,
    this.confirmationCode,
    this.notes,
    this.createdAt,
  });

  final int id;
  final int doctorId;
  final String doctorName;

  /// `YYYY-MM-DD`
  final String date;

  /// `HH:MM:SS`
  final String time;

  /// pending | confirmed | completed | cancelled
  final String status;

  final String? specialty;
  final String? doctorImage;
  final String? clinicName;
  final String? clinicAddress;

  /// `appointments.patient_id` — a uuid, matching `users.id`. It was an int
  /// under MySQL; `Fmt.toInt` on a uuid returns 0, which would have made every
  /// patient look like the same person to any code comparing this field.
  ///
  /// Only ever set and passed through today, never compared, so no screen
  /// changed.
  final String? patientId;

  final String? patientName;
  final String? patientPhone;

  final double fee;

  /// `appointments.payment_status`: pending | paid | refunded.
  ///
  /// There is no 'unpaid' — the unpaid state is 'pending'. Only an admin moves
  /// this to 'paid', after checking the patient's transaction reference, so an
  /// appointment can sit at 'pending' long after the patient has submitted
  /// payment details.
  final String paymentStatus;

  /// `payments.payment_status` for the latest submission: pending | verified |
  /// rejected, or null when nothing has been submitted. This is the field that
  /// distinguishes "not paid yet" from "paid, awaiting verification" — the
  /// appointment's own [paymentStatus] reads 'pending' in both cases.
  final String? paymentReview;

  /// new | followup | online
  final String? type;

  /// Short code the patient quotes at the chamber desk.
  final String? confirmationCode;

  final String? notes;
  final String? createdAt;

  factory Appointment.fromJson(Map<String, dynamic> json) => Appointment(
        id: Fmt.toInt(json['id']),
        doctorId: Fmt.toInt(json['doctor_id']),
        doctorName: Fmt.str(json['doctor_name'], 'Doctor'),
        date: Fmt.str(json['appointment_date'] ?? json['date']),
        time: Fmt.str(json['appointment_time'] ?? json['time']),
        status: Fmt.str(json['status'], 'pending'),
        // `appointment_public()` sends this as `doctor_specialty`, and the
        // payment-history rows send the raw column name `specialization`.
        // Reading only `specialty` meant this was null on every appointment in
        // the app — the doctor's field never once appeared under their name.
        specialty: _orNull(
          json['doctor_specialty'] ?? json['specialty'] ?? json['specialization'],
        ),
        doctorImage: _orNull(json['doctor_image'] ?? json['image']),
        clinicName: _orNull(json['clinic_name']),
        clinicAddress: _orNull(json['clinic_address']),
        patientId: _orNull(json['patient_id']),
        patientName: _orNull(json['patient_name']),
        patientPhone: _orNull(json['patient_phone']),
        fee: Fmt.toDouble(json['fee'] ?? json['consultation_fee']),
        paymentStatus: Fmt.str(json['payment_status'], 'pending'),
        paymentReview: _orNull(json['payment_review']),
        type: _orNull(json['type']),
        confirmationCode: _orNull(json['confirmation_code']),
        // The column is `symptoms`; the API sends it under both keys.
        notes: _orNull(json['symptoms'] ?? json['reason'] ?? json['notes']),
        createdAt: _orNull(json['created_at']),
      );

  DateTime? get startsAt {
    final d = Fmt.date(date);
    if (d == null) return null;
    final parts = time.split(':');
    final h = parts.isNotEmpty ? int.tryParse(parts[0]) ?? 0 : 0;
    final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    return DateTime(d.year, d.month, d.day, h, m);
  }

  bool get isUpcoming {
    final at = startsAt;
    if (at == null) return false;
    return at.isAfter(DateTime.now()) && !isCancelled && status != 'completed';
  }

  bool get isCancelled => status == 'cancelled' || status == 'canceled';
  bool get isPaid => paymentStatus == 'paid';

  /// A payment has been submitted and is waiting for an admin to check it. The
  /// UI should say so rather than inviting the patient to pay a second time.
  bool get isPaymentUnderReview => !isPaid && paymentReview == 'pending';

  /// The last submission was turned down, so paying again is the right action.
  bool get isPaymentRejected => !isPaid && paymentReview == 'rejected';

  /// §6 lets a patient cancel only while the appointment is still ahead of them
  /// and not already finished. The server re-checks this (422 if it disagrees).
  bool get canCancel => isUpcoming && !isCancelled;

  /// A doctor review may be left against any non-cancelled appointment the
  /// patient owns — there is deliberately no "must be completed" requirement.
  /// The backend enforces one review per appointment and one per target (409),
  /// so there is no need to track whether a review was already submitted here.
  bool get canReview => !isCancelled;

  /// Excludes appointments with a submission already in review — the server
  /// returns 409 for those, so offering the button would be a dead end.
  bool get canPay =>
      !isPaid &&
      !isPaymentUnderReview &&
      !isCancelled &&
      status != 'completed' &&
      fee > 0;

  /// One line covering all four money states, so screens do not each invent
  /// their own wording.
  String get paymentLabel {
    if (isPaid) return 'Paid';
    if (paymentStatus == 'refunded') return 'Refunded';
    if (isPaymentUnderReview) return 'Awaiting verification';
    if (isPaymentRejected) return 'Payment rejected';
    return 'Unpaid';
  }

  String get whenLabel => '${Fmt.dayFull(date)} · ${Fmt.time(time)}';
}

class Payment {
  const Payment({
    required this.id,
    required this.amount,
    required this.status,
    this.appointmentId,
    this.method,
    this.transactionId,
    this.senderNumber,
    this.rejectionReason,
    this.doctorName,
    this.appointmentDate,
    this.paidAt,
    this.createdAt,
  });

  final int id;
  final double amount;

  /// pending | verified | rejected — the `payments.payment_status` enum.
  ///
  /// Note this is NOT the same vocabulary as [Appointment.paymentStatus], which
  /// is pending | paid | refunded. One tracks the review of a submission, the
  /// other tracks the appointment's own money state. A submission sits at
  /// `pending` until an admin checks the transaction id against the merchant
  /// statement; nothing the app does moves it.
  final String status;

  final int? appointmentId;

  /// The exact `payments.payment_method` enum value: bKash | Nagad | Rocket |
  /// Credit/Debit Card | Bank Transfer | Cash. Casing is significant.
  final String? method;
  final String? transactionId;

  /// The number the patient sent the money from, for the admin to cross-check.
  final String? senderNumber;

  /// Set only if the submission was turned down, and worth showing: it tells the
  /// patient what to fix before trying again.
  final String? rejectionReason;

  final String? doctorName;
  final String? appointmentDate;

  /// When an admin verified the payment (`payments.verified_at`). Null while the
  /// submission is still pending — no money is confirmed before then.
  final String? paidAt;
  final String? createdAt;

  factory Payment.fromJson(Map<String, dynamic> json) => Payment(
        id: Fmt.toInt(json['id']),
        amount: Fmt.toDouble(json['amount']),
        status: Fmt.str(json['status'], 'pending'),
        appointmentId:
            Fmt.toInt(json['appointment_id']) == 0 ? null : Fmt.toInt(json['appointment_id']),
        method: _orNull(json['method'] ?? json['payment_method']),
        // The API sends `transaction_ref`; `transaction_id` is read too because
        // that is the column name and the two are easy to mix up.
        transactionId: _orNull(json['transaction_ref'] ?? json['transaction_id']),
        senderNumber: _orNull(json['sender_number']),
        rejectionReason: _orNull(json['rejection_reason']),
        doctorName: _orNull(json['doctor_name']),
        appointmentDate: _orNull(json['appointment_date']),
        paidAt: _orNull(json['paid_at']),
        createdAt: _orNull(json['created_at']),
      );

  bool get isVerified => status == 'verified';
  bool get isRejected => status == 'rejected';
  bool get isAwaitingReview => status == 'pending';

  String get methodLabel => method ?? 'Unknown';
}

/// The payment options the app offers.
///
/// These are the `payments.payment_method` enum values EXACTLY as the schema
/// stores them — lowercase 'b' in bKash, a slash in 'Credit/Debit Card'. The
/// server whitelist in appointments_payment() matches character for character,
/// so a prettier label here would be rejected as a 422. Put display text in
/// [label]; never touch [value].
///
/// `sslcommerz` is the online gateway flow (card / bKash / mobile banking via
/// SSLCommerz). It is written to `payments` only by the SSLCommerz Edge
/// Functions, never by a client insert, so no manual transaction reference is
/// collected for it.
enum PaymentMethod {
  bkash('bKash', 'bKash'),
  nagad('Nagad', 'Nagad'),
  rocket('Rocket', 'Rocket'),
  card('Credit/Debit Card', 'Credit / debit card'),
  bankTransfer('Bank Transfer', 'Bank transfer'),
  cash('Cash', 'Cash at chamber'),
  sslcommerz('sslcommerz', 'Pay online (card / bKash / mobile banking)');

  const PaymentMethod(this.value, this.label);

  final String value;
  final String label;

  /// Cash and the gateway need no reference number; everything else does
  /// (enforced server-side too, which is the authority — this only drives the
  /// form).
  bool get requiresTransactionId =>
      this != PaymentMethod.cash && this != PaymentMethod.sslcommerz;

  bool get isGateway => this == PaymentMethod.sslcommerz;
}

String? _orNull(Object? v) {
  final s = Fmt.str(v);
  return s.isEmpty ? null : s;
}

/// Stripe Checkout Session response from the Edge Function.
class StripeCheckoutSession {
  const StripeCheckoutSession({
    required this.checkoutUrl,
    required this.sessionId,
  });

  final String checkoutUrl;
  final String sessionId;

  factory StripeCheckoutSession.fromJson(Map<String, dynamic> json) =>
      StripeCheckoutSession(
        checkoutUrl: json['checkout_url'] as String,
        sessionId: json['session_id'] as String,
      );
}

/// Payment receipt generated after successful payment.
class PaymentReceipt {
  const PaymentReceipt({
    required this.id,
    required this.appointmentId,
    required this.amount,
    required this.paymentMethod,
    required this.transactionId,
    required this.stripeTransactionId,
    required this.gatewayReference,
    required this.paidAt,
    required this.patientName,
    required this.doctorName,
    required this.appointmentDate,
    required this.appointmentTime,
    required this.clinicName,
    required this.clinicAddress,
    required this.fee,
    required this.platformFee,
    required this.doctorShare,
  });

  final int id;
  final int appointmentId;
  final double amount;
  final String paymentMethod;
  final String? transactionId;
  final String stripeTransactionId;
  final String gatewayReference;
  final DateTime paidAt;
  final String patientName;
  final String doctorName;
  final String appointmentDate;
  final String appointmentTime;
  final String? clinicName;
  final String? clinicAddress;
  final double fee;
  final double platformFee;
  final double doctorShare;

  factory PaymentReceipt.fromJson(Map<String, dynamic> json) => PaymentReceipt(
        id: json['id'] as int,
        appointmentId: json['appointment_id'] as int,
        amount: (json['amount'] as num).toDouble(),
        paymentMethod: json['payment_method'] as String,
        transactionId: json['transaction_id'] as String?,
        stripeTransactionId: json['stripe_payment_intent_id'] as String? ?? '',
        gatewayReference: json['gateway_transaction_id'] as String? ?? '',
        paidAt: DateTime.parse(json['paid_at'] as String),
        patientName: json['patient_name'] as String,
        doctorName: json['doctor_name'] as String,
        appointmentDate: json['appointment_date'] as String,
        appointmentTime: json['appointment_time'] as String,
        clinicName: json['clinic_name'] as String?,
        clinicAddress: json['clinic_address'] as String?,
        fee: (json['fee'] as num).toDouble(),
        platformFee: (json['admin_share'] as num).toDouble(),
        doctorShare: (json['provider_share'] as num).toDouble(),
      );
}

/// Individual health check result.
class HealthCheck {
  const HealthCheck({
    required this.check,
    required this.status,
    required this.message,
    this.details,
  });

  final String check;
  final String status; // pass | fail | warn
  final String message;
  final Map<String, dynamic>? details;

  factory HealthCheck.fromJson(Map<String, dynamic> json) => HealthCheck(
        check: json['check'] as String,
        status: json['status'] as String,
        message: json['message'] as String,
        details: json['details'] as Map<String, dynamic>?,
      );

  Map<String, dynamic> toJson() => {
        'check': check,
        'status': status,
        'message': message,
        if (details != null) 'details': details,
      };

  bool get isPass => status == 'pass';
  bool get isFail => status == 'fail';
  bool get isWarn => status == 'warn';
}

/// Payment health check report.
class PaymentHealthReport {
  const PaymentHealthReport({
    required this.overallStatus,
    required this.timestamp,
    required this.checks,
    this.appointmentId,
    this.patientId,
  });

  final String overallStatus; // healthy | unhealthy
  final DateTime timestamp;
  final List<HealthCheck> checks;
  final int? appointmentId;
  final String? patientId;

  factory PaymentHealthReport.fromJson(Map<String, dynamic> json) => PaymentHealthReport(
        overallStatus: json['overall_status'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        checks: (json['checks'] as List)
            .map((c) => HealthCheck.fromJson(c as Map<String, dynamic>))
            .toList(),
        appointmentId: json['appointment_id'] as int?,
        patientId: json['patient_id'] as String?,
      );

  bool get isHealthy => overallStatus == 'healthy';
  List<HealthCheck> get failures => checks.where((c) => c.isFail).toList();
  List<HealthCheck> get warnings => checks.where((c) => c.isWarn).toList();
  List<HealthCheck> get passes => checks.where((c) => c.isPass).toList();
}
