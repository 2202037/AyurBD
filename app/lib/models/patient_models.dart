/// Patient dashboard (§5.1), my-reviews (§5.6), emergency assistance (§5.9)
/// and nearby services (§5.8).
library;

import '../core/utils/formatters.dart';
import 'appointment_models.dart';

/// `GET /patient/dashboard`.
class PatientDashboard {
  const PatientDashboard({
    required this.stats,
    this.upcoming = const [],
    this.recentReviews = const [],
  });

  final PatientStats stats;

  /// Future, non-cancelled appointments only — a cancelled future booking is
  /// not something the patient needs to prepare for.
  final List<Appointment> upcoming;

  final List<MyReview> recentReviews;

  factory PatientDashboard.fromJson(Map<String, dynamic> json) => PatientDashboard(
        stats: PatientStats.fromJson(_map(json['stats'])),
        upcoming:
            _rows(json['upcoming_appointments']).map(Appointment.fromJson).toList(),
        recentReviews: _rows(json['recent_reviews']).map(MyReview.fromJson).toList(),
      );
}

class PatientStats {
  const PatientStats({
    this.total = 0,
    this.pending = 0,
    this.confirmed = 0,
    this.completed = 0,
    this.cancelled = 0,
    this.pendingPayments = 0,
    this.unreadNotifications = 0,
  });

  final int total;
  final int pending;
  final int confirmed;
  final int completed;
  final int cancelled;

  /// Booked but not yet paid, excluding cancelled bookings — the "action
  /// needed" number on the dashboard.
  final int pendingPayments;

  final int unreadNotifications;

  factory PatientStats.fromJson(Map<String, dynamic> j) => PatientStats(
        total: Fmt.toInt(j['total_appointments']),
        pending: Fmt.toInt(j['pending_appointments']),
        confirmed: Fmt.toInt(j['confirmed_appointments']),
        completed: Fmt.toInt(j['completed_appointments']),
        cancelled: Fmt.toInt(j['cancelled_appointments']),
        pendingPayments: Fmt.toInt(j['pending_payments']),
        unreadNotifications: Fmt.toInt(j['unread_notifications']),
      );

  bool get needsAttention => pendingPayments > 0;
}

/// The patient's own review — `GET /patient/reviews`. Carries the moderation
/// status and the server-authored explanation of it, so every client explains
/// a pending or rejected review the same way.
class MyReview {
  const MyReview({
    required this.id,
    required this.targetType,
    required this.targetId,
    required this.rating,
    required this.status,
    this.comment,
    this.statusNote,
    this.targetName,
    this.createdAt,
  });

  final int id;

  /// doctor | clinic | hospital | pharmacy | product.
  final String targetType;
  final int targetId;
  final int rating;

  /// pending | approved | rejected.
  final String status;

  final String? comment;

  /// Why the review is not visible, written by the API. Null when approved.
  final String? statusNote;

  /// Resolved display name of the reviewed entity. Null on the dashboard's
  /// `recent_reviews`, which does not run the name lookup.
  final String? targetName;

  final String? createdAt;

  factory MyReview.fromJson(Map<String, dynamic> j) => MyReview(
        id: Fmt.toInt(j['id']),
        targetType: Fmt.str(j['reviewable_type']),
        targetId: Fmt.toInt(j['reviewable_id']),
        rating: Fmt.toInt(j['rating']).clamp(1, 5),
        status: Fmt.str(j['status'], 'pending'),
        comment: _orNull(j['comment']),
        statusNote: _orNull(j['status_note']),
        targetName: _orNull(j['target_name']),
        createdAt: _orNull(j['created_at']),
      );

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';

  /// Falls back to the type and id when the name lookup was not run or the
  /// target has since been deleted.
  String get displayTarget => targetName ?? '${Fmt.label(targetType)} #$targetId';

  String get statusLabel => Fmt.label(status);
  String get dateLabel => Fmt.dayMonth(createdAt);
}

/// An emergency hotline — `GET /emergency/hotlines`. Public by design: someone
/// who needs 999 should not have to sign in first.
class Hotline {
  const Hotline({
    required this.id,
    required this.name,
    required this.phone,
    this.category = 'general',
    this.description,
  });

  final int id;
  final String name;
  final String phone;

  /// national | ambulance | fire | police | hospital | general.
  final String category;

  final String? description;

  factory Hotline.fromJson(Map<String, dynamic> j) => Hotline(
        id: Fmt.toInt(j['id']),
        name: Fmt.str(j['name'], 'Emergency'),
        phone: Fmt.str(j['phone']),
        category: Fmt.str(j['category'], 'general'),
        description: _orNull(j['description']),
      );

  bool get isDialable => phone.isNotEmpty;
  String get categoryLabel => Fmt.label(category);
}

/// The result of `POST /emergency/sms`.
///
/// [delivered] is always false in this build: no SMS gateway is configured, so
/// the request is recorded and queued, not transmitted. The flag is modelled
/// rather than assumed so the UI can keep telling the truth if a provider is
/// wired up later.
class EmergencyRequest {
  const EmergencyRequest({
    required this.id,
    required this.status,
    required this.delivered,
    this.message,
  });

  final int id;

  /// queued | sent | failed.
  final String status;

  final bool delivered;

  /// The API's own wording, which explains that nothing was actually sent.
  ///
  /// Usually null: the server puts this at the envelope's `message`, not inside
  /// `data`, and the client returns only `data`. [displayMessage] covers that.
  final String? message;

  factory EmergencyRequest.fromJson(Map<String, dynamic> j) => EmergencyRequest(
        id: Fmt.toInt(j['id']),
        status: Fmt.str(j['status'], 'queued'),
        delivered: Fmt.toBool(j['delivered']),
        message: _orNull(j['message']),
      );

  /// What to show after submitting. Never claims the message was sent while
  /// [delivered] is false — on an emergency screen a false "sent!" is the one
  /// failure mode that could get somebody hurt.
  String get displayMessage =>
      message ??
      (delivered
          ? 'Your emergency message was sent.'
          : 'Your emergency request was recorded, but it has NOT been sent — no '
              'SMS gateway is connected. Please call the hotline directly now.');
}

/// One row of `GET /nearby` — a doctor, hospital, clinic or pharmacy in a
/// single list.
///
/// There is deliberately no distance field: no table in this database stores
/// latitude or longitude, so this is a city/area text search and any "2.3 km
/// away" figure would be invented.
class NearbyResult {
  const NearbyResult({
    required this.id,
    required this.kind,
    required this.name,
    required this.rating,
    required this.reviewCount,
    this.subtitle,
    this.address,
    this.city,
    this.area,
    this.phone,
    this.image,
  });

  final int id;

  /// doctor | hospital | clinic | pharmacy — decides both the icon and which
  /// detail route a tap opens.
  final String kind;

  final String name;
  final double rating;
  final int reviewCount;

  /// Specialisation for a doctor, the type column for a place.
  final String? subtitle;

  final String? address;
  final String? city;
  final String? area;
  final String? phone;
  final String? image;

  factory NearbyResult.fromJson(Map<String, dynamic> j) => NearbyResult(
        id: Fmt.toInt(j['id']),
        kind: Fmt.str(j['kind'], 'doctor'),
        name: Fmt.str(j['name'], 'Unnamed'),
        rating: Fmt.toDouble(j['rating']),
        reviewCount: Fmt.toInt(j['total_reviews']),
        subtitle: _orNull(j['subtitle']),
        address: _orNull(j['address']),
        city: _orNull(j['city']),
        area: _orNull(j['area']),
        phone: _orNull(j['phone']),
        image: _orNull(j['image']),
      );

  String get kindLabel => Fmt.label(kind);
  String get ratingLabel => Fmt.rating(rating);

  String get locationLabel {
    final parts = [area, city].where((p) => p != null && p.isNotEmpty).toList();
    return parts.isEmpty ? (address ?? '') : parts.join(', ');
  }
}

// -- helpers ----------------------------------------------------------------

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
