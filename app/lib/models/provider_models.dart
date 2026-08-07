/// Models for the provider workspaces — feature.md §6 (doctor), §7 (hospital),
/// §8 (clinic), §9 (pharmacy).
///
/// [Doctor] and [Place] already model the profile itself, so nothing here
/// re-declares those fields; these are the dashboard wrappers, the payment
/// verification row and the provider's view of a review.
library;

import '../core/utils/formatters.dart';
import 'appointment_models.dart';
import 'directory_models.dart';

/// The three-state verification badge every provider dashboard leads with.
///
/// Kept distinct from a bool because §6.1 is explicit that "not reviewed yet"
/// must read differently from "rejected" — collapsing them to
/// `isVerified == false` is what makes a rejected provider think their
/// paperwork is still in a queue.
enum VerificationStatus {
  pending,
  verified,
  rejected;

  static VerificationStatus fromString(Object? value) {
    final s = Fmt.str(value).toLowerCase();
    return VerificationStatus.values.firstWhere(
      (v) => v.name == s,
      orElse: () => VerificationStatus.pending,
    );
  }

  String get label => switch (this) {
        VerificationStatus.pending => 'Verification pending',
        VerificationStatus.verified => 'Verified',
        VerificationStatus.rejected => 'Verification rejected',
      };

  /// What the provider should do next. Null when there is nothing to say.
  String? get note => switch (this) {
        VerificationStatus.pending =>
          'An administrator is reviewing your documents. Patients cannot find '
              'you in the directory until this completes.',
        VerificationStatus.rejected =>
          'Your submission was not approved. Update your profile details and '
              'documents, then contact support to request another review.',
        VerificationStatus.verified => null,
      };

  bool get isVerified => this == VerificationStatus.verified;
}

/// `GET /provider/doctor/dashboard`.
class DoctorDashboard {
  const DoctorDashboard({
    required this.stats,
    required this.verification,
    required this.accountStatus,
    this.doctor,
    this.recentAppointments = const [],
  });

  final DoctorStats stats;
  final VerificationStatus verification;

  /// `doctors.status`: active | inactive | pending. Separate from
  /// [verification] — an admin can deactivate an already-verified doctor.
  final String accountStatus;

  final Doctor? doctor;
  final List<Appointment> recentAppointments;

  factory DoctorDashboard.fromJson(Map<String, dynamic> json) {
    final doc = json['doctor'];
    return DoctorDashboard(
      stats: DoctorStats.fromJson(_map(json['stats'])),
      verification: VerificationStatus.fromString(json['verification_status']),
      accountStatus: Fmt.str(json['status'], 'pending'),
      doctor: doc is Map ? Doctor.fromJson(_map(doc)) : null,
      recentAppointments:
          _rows(json['recent_appointments']).map(Appointment.fromJson).toList(),
    );
  }

  bool get isActive => accountStatus == 'active';
}

class DoctorStats {
  const DoctorStats({
    this.total = 0,
    this.pending = 0,
    this.confirmed = 0,
    this.completed = 0,
    this.cancelled = 0,
    this.today = 0,
    this.upcoming = 0,
    this.pendingPayments = 0,
    this.totalEarnings = 0,
    this.pendingPayout = 0,
    this.platformFee = 0,
  });

  final int total;
  final int pending;
  final int confirmed;
  final int completed;
  final int cancelled;
  final int today;
  final int upcoming;

  /// Payments submitted against this doctor's appointments that are still
  /// waiting on the admin's verify/reject decision.
  final int pendingPayments;

  /// The doctor's share (amount minus the platform commission) of verified
  /// payments. A submitted transaction id is not money until an admin has
  /// checked it, and showing it as earnings would overstate.
  final double totalEarnings;

  /// What the platform currently owes the doctor — the sum of `pending`
  /// `provider_payouts`. This is the "money account" balance of the escrow
  /// flow: credited at verification, marked paid by the admin offline.
  final double pendingPayout;

  /// The platform's retained commission on this doctor's verified payments
  /// (their `commission_percentage` of the amount).
  final double platformFee;

  factory DoctorStats.fromJson(Map<String, dynamic> j) => DoctorStats(
        total: Fmt.toInt(j['total_appointments']),
        pending: Fmt.toInt(j['pending_appointments']),
        confirmed: Fmt.toInt(j['confirmed_appointments']),
        completed: Fmt.toInt(j['completed_appointments']),
        cancelled: Fmt.toInt(j['cancelled_appointments']),
        today: Fmt.toInt(j['today_appointments']),
        upcoming: Fmt.toInt(j['upcoming_appointments']),
        pendingPayments: Fmt.toInt(j['pending_payments']),
        totalEarnings: Fmt.toDouble(j['total_earnings']),
        pendingPayout: Fmt.toDouble(j['pending_payout']),
        platformFee: Fmt.toDouble(j['platform_fee']),
      );

  String get earningsLabel => Fmt.money(totalEarnings);
  String get payoutLabel => Fmt.money(pendingPayout);
  String get platformFeeLabel => Fmt.money(platformFee);
}

/// `GET /provider/place/dashboard` — one shape for hospital, clinic and
/// pharmacy. The backend picks the table from the caller's role, so the client
/// does not send a kind and reads it back from `type`.
class PlaceDashboard {
  const PlaceDashboard({
    required this.kind,
    required this.verification,
    required this.accountStatus,
    required this.stats,
    this.profile,
    this.ownerName,
    this.ownerEmail,
  });

  final PlaceKind kind;
  final VerificationStatus verification;
  final String accountStatus;
  final PlaceStats stats;
  final Place? profile;
  final String? ownerName;
  final String? ownerEmail;

  factory PlaceDashboard.fromJson(Map<String, dynamic> json) {
    final kind = _kindFromString(json['type']);
    final prof = json['profile'];
    final owner = _map(json['owner']);
    return PlaceDashboard(
      kind: kind,
      verification: VerificationStatus.fromString(json['verification_status']),
      accountStatus: Fmt.str(json['status'], 'pending'),
      stats: PlaceStats.fromJson(_map(json['stats'])),
      profile: prof is Map ? Place.fromJson(_map(prof), kind) : null,
      ownerName: _orNull(owner['name']),
      ownerEmail: _orNull(owner['email']),
    );
  }

  bool get isActive => accountStatus == 'active';
}

/// Hospital/clinic get `linked_doctors`; a pharmacy gets product, order and
/// revenue counts instead. The unused fields stay null rather than 0 so a
/// screen can tell "not applicable to this role" from "none yet".
class PlaceStats {
  const PlaceStats({
    this.totalReviews = 0,
    this.pendingReviews = 0,
    this.approvedReviews = 0,
    this.rating = 0,
    this.linkedDoctors,
    this.totalProducts,
    this.totalOrders,
    this.totalRevenue,
  });

  final int totalReviews;
  final int pendingReviews;
  final int approvedReviews;
  final double rating;

  /// Hospital / clinic only. Doctors link to a workplace by free-text name in
  /// this schema, not a foreign key, so 0 means "no doctor lists this name" —
  /// which is not quite the same as "no doctors here".
  final int? linkedDoctors;

  final int? totalProducts;
  final int? totalOrders;
  final double? totalRevenue;

  factory PlaceStats.fromJson(Map<String, dynamic> j) => PlaceStats(
        totalReviews: Fmt.toInt(j['total_reviews']),
        pendingReviews: Fmt.toInt(j['pending_reviews']),
        approvedReviews: Fmt.toInt(j['approved_reviews']),
        rating: Fmt.toDouble(j['rating']),
        linkedDoctors:
            j.containsKey('linked_doctors') ? Fmt.toInt(j['linked_doctors']) : null,
        totalProducts:
            j.containsKey('total_products') ? Fmt.toInt(j['total_products']) : null,
        totalOrders: j.containsKey('total_orders') ? Fmt.toInt(j['total_orders']) : null,
        totalRevenue:
            j.containsKey('total_revenue') ? Fmt.toDouble(j['total_revenue']) : null,
      );

  String get ratingLabel => Fmt.rating(rating);
}

/// A payment submission as the provider and the admin see it — richer than the
/// patient's [Payment] because it carries the patient's identity and the
/// appointment it belongs to, which is what a verification decision needs.
///
/// Served by both `/provider/doctor/payments` and `/admin/payments`; the two
/// share one PHP shaper, so one model is correct for both.
class ProviderPayment {
  const ProviderPayment({
    required this.id,
    required this.appointmentId,
    required this.amount,
    required this.status,
    this.method,
    this.transactionId,
    this.senderNumber,
    this.notes,
    this.rejectionReason,
    this.verifiedAt,
    this.createdAt,
    this.appointmentDate,
    this.appointmentTime,
    this.appointmentStatus,
    this.confirmationCode,
    this.patientName,
    this.patientPhone,
    this.adminShare,
    this.providerShare,
  });

  final int id;
  final int appointmentId;
  final double amount;

  /// pending | verified | rejected — `payments.payment_status`.
  final String status;

  final String? method;
  final String? transactionId;
  final String? senderNumber;
  final String? notes;
  final String? rejectionReason;
  final String? verifiedAt;
  final String? createdAt;

  final String? appointmentDate;
  final String? appointmentTime;
  final String? appointmentStatus;
  final String? confirmationCode;
  final String? patientName;
  final String? patientPhone;

  /// The platform commission cut of [amount] (`admin_share`), set by the
  /// verification trigger. Null while unverified.
  final double? adminShare;

  /// What the provider is owed from [amount] (`provider_share`) — amount minus
  /// the platform commission. Null while unverified.
  final double? providerShare;

  factory ProviderPayment.fromJson(Map<String, dynamic> j) => ProviderPayment(
        id: Fmt.toInt(j['id']),
        appointmentId: Fmt.toInt(j['appointment_id']),
        amount: Fmt.toDouble(j['amount']),
        status: Fmt.str(j['payment_status'], 'pending'),
        method: _orNull(j['payment_method']),
        transactionId: _orNull(j['transaction_id']),
        senderNumber: _orNull(j['sender_number']),
        notes: _orNull(j['notes']),
        rejectionReason: _orNull(j['rejection_reason']),
        verifiedAt: _orNull(j['verified_at']),
        createdAt: _orNull(j['created_at']),
        appointmentDate: _orNull(j['appointment_date']),
        appointmentTime: _orNull(j['appointment_time']),
        appointmentStatus: _orNull(j['appointment_status']),
        confirmationCode: _orNull(j['confirmation_code']),
        patientName: _orNull(j['patient_name']),
        patientPhone: _orNull(j['patient_phone']),
        adminShare: _numOrNull(j['admin_share']),
        providerShare: _numOrNull(j['provider_share']),
      );

  bool get isPending => status == 'pending';
  bool get isVerified => status == 'verified';
  bool get isRejected => status == 'rejected';

  String get amountLabel => Fmt.money(amount);
  String get statusLabel => Fmt.label(status);

  /// Cash needs no reference, so its absence is not a red flag there.
  bool get hasReference => (transactionId ?? '').isNotEmpty;

  String get whenLabel => appointmentDate == null
      ? '—'
      : '${Fmt.dayMonth(appointmentDate)} · ${Fmt.time(appointmentTime)}';
}

/// A payout row from `provider_payouts` — the ledger of what the platform owes
/// a provider. This is the visible "money account" of the escrow flow: written
/// by the verification triggers (the provider's share of each verified payment
/// or paid order), shown to the provider as their balance, and marked `paid` by
/// the admin when the offline transfer happens.
class Payout {
  const Payout({
    required this.id,
    required this.amount,
    required this.status,
    this.commissionPercentage = 0,
    this.paymentId,
    this.orderId,
    this.providerName,
    this.appointmentDate,
    this.appointmentTime,
    this.appointmentDoctor,
    this.orderNumber,
    this.orderTotal,
    this.paidAt,
    this.createdAt,
  });

  final int id;

  /// `provider_payouts.amount` — the provider's share already minus commission.
  final double amount;

  /// pending | paid | reversed.
  final String status;

  /// The commission this payout was split with, for the ledger line.
  final double commissionPercentage;

  /// Exactly one of these is set: a payout comes from a verified appointment
  /// payment or a paid pharmacy order.
  final int? paymentId;
  final int? orderId;

  /// The provider this payout belongs to. The admin settlement screen reads it
  /// from the embedded `users` row; the provider's own ledger omits the embed
  /// (it filters on the column instead), so this is null there.
  final String? providerName;

  final String? appointmentDate;
  final String? appointmentTime;
  final String? appointmentDoctor;
  final String? orderNumber;
  final double? orderTotal;
  final String? paidAt;
  final String? createdAt;

  factory Payout.fromJson(Map<String, dynamic> j) {
    final payment = j['payments'] as Map<String, dynamic>?;
    final appointment = payment?['appointments'] as Map<String, dynamic>?;
    final order = j['orders'] as Map<String, dynamic>?;
    final owner = j['users'] as Map<String, dynamic>?;
    return Payout(
      id: Fmt.toInt(j['id']),
      amount: Fmt.toDouble(j['amount']),
      status: Fmt.str(j['status'], 'pending'),
      commissionPercentage: Fmt.toDouble(j['commission_percentage']),
      paymentId: Fmt.toInt(j['payment_id']) == 0 ? null : Fmt.toInt(j['payment_id']),
      orderId: Fmt.toInt(j['order_id']) == 0 ? null : Fmt.toInt(j['order_id']),
      providerName: _orNull(owner?['name']),
      appointmentDate: _orNull(appointment?['appointment_date']),
      appointmentTime: _orNull(appointment?['appointment_time']),
      appointmentDoctor: _orNull(appointment?['doctor_name']),
      orderNumber: _orNull(order?['order_number']),
      orderTotal: _numOrNull(order?['total']),
      paidAt: _orNull(j['paid_at']),
      createdAt: _orNull(j['created_at']),
    );
  }

  bool get isPending => status == 'pending';
  bool get isPaid => status == 'paid';
  bool get isReversed => status == 'reversed';

  String get amountLabel => Fmt.money(amount);
  String get statusLabel => Fmt.label(status);

  /// One-line description of where the money came from.
  String get sourceLabel {
    if (orderNumber != null && orderNumber!.isNotEmpty) {
      return 'Pharmacy order $orderNumber';
    }
    if (appointmentDoctor != null && appointmentDoctor!.isNotEmpty) {
      return '$appointmentDoctor · ${Fmt.dayMonth(appointmentDate)}';
    }
    return 'Appointment payment';
  }

  String get createdLabel => Fmt.dayMonth(createdAt);
}

/// A review as its subject sees it — `GET /provider/reviews`. Includes pending
/// rows so a provider knows what is about to appear publicly.
class ProviderReview {
  const ProviderReview({
    required this.id,
    required this.rating,
    required this.status,
    this.comment,
    this.reviewerName,
    this.reviewerImage,
    this.createdAt,
  });

  final int id;
  final int rating;

  /// pending | approved | rejected.
  final String status;

  final String? comment;
  final String? reviewerName;
  final String? reviewerImage;
  final String? createdAt;

  factory ProviderReview.fromJson(Map<String, dynamic> j) => ProviderReview(
        id: Fmt.toInt(j['id']),
        rating: Fmt.toInt(j['rating']).clamp(1, 5),
        status: Fmt.str(j['status'], 'pending'),
        comment: _orNull(j['comment']),
        reviewerName: _orNull(j['reviewer_name']),
        reviewerImage: _orNull(j['reviewer_image']),
        createdAt: _orNull(j['created_at']),
      );

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';

  /// Only approved reviews count toward the public average, so a provider
  /// looking at a 1-star pending row should know it is not live yet.
  bool get affectsRating => isApproved;

  String get dateLabel => Fmt.dayMonth(createdAt);
}

// -- shared helpers ---------------------------------------------------------

PlaceKind _kindFromString(Object? value) {
  final s = Fmt.str(value).toLowerCase();
  return PlaceKind.values.firstWhere(
    (k) => k.name == s,
    orElse: () => PlaceKind.clinic,
  );
}

Map<String, dynamic> _map(Object? v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return v.map((k, val) => MapEntry(k.toString(), val));
  return const {};
}

List<Map<String, dynamic>> _rows(Object? raw) {
  if (raw is! List) return const [];
  return raw.whereType<Map>().map((e) => _map(e)).toList();
}

String? _orNull(Object? v) {
  final s = Fmt.str(v);
  return s.isEmpty ? null : s;
}

double? _numOrNull(Object? v) {
  final s = Fmt.str(v);
  return s.isEmpty ? null : Fmt.toDouble(s);
}
