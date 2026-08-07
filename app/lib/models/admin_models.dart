/// Models for the admin console — feature.md §10.
///
/// The provider moderation lists reuse [Doctor] and [Place] for the profile
/// fields and add the moderation columns the public shapers omit
/// (verification_status, licence numbers, documents).
library;

import '../core/utils/formatters.dart';
import 'app_user.dart';
import 'directory_models.dart';

/// `GET /admin/dashboard`.
class AdminDashboard {
  const AdminDashboard({
    required this.counts,
    required this.pendingByType,
    this.recentActivity = const [],
  });

  final AdminCounts counts;

  /// Pending verifications split by provider type, so the console can badge
  /// each moderation list rather than showing one lump total.
  final Map<String, int> pendingByType;

  final List<AuditEntry> recentActivity;

  factory AdminDashboard.fromJson(Map<String, dynamic> json) {
    final pending = _map(json['pending_verifications']);
    return AdminDashboard(
      counts: AdminCounts.fromJson(_map(json['counts'])),
      pendingByType: {
        for (final e in pending.entries) e.key: Fmt.toInt(e.value),
      },
      recentActivity: _rows(json['recent_activity']).map(AuditEntry.fromJson).toList(),
    );
  }
}

class AdminCounts {
  const AdminCounts({
    this.patients = 0,
    this.users = 0,
    this.doctors = 0,
    this.hospitals = 0,
    this.clinics = 0,
    this.pharmacies = 0,
    this.bloodBanks = 0,
    this.appointments = 0,
    this.revenue = 0,
    this.pendingVerifications = 0,
    this.pendingReviews = 0,
    this.pendingFeedback = 0,
    this.pendingPayments = 0,
    this.auditLogs = 0,
    this.dbAuditLogs = 0,
  });

  final int patients;
  final int users;
  final int doctors;
  final int hospitals;
  final int clinics;
  final int pharmacies;
  final int bloodBanks;
  final int appointments;

  /// Verified payments only, matching the doctor dashboard's rule.
  final double revenue;

  final int pendingVerifications;
  final int pendingReviews;
  final int pendingFeedback;
  final int pendingPayments;

  /// Rows in `app_audit_log` — what this API writes.
  final int auditLogs;

  /// Rows in `audit_log` — the trigger-written table, which is not in every
  /// database dump. 0 may mean "no such table" rather than "no activity".
  final int dbAuditLogs;

  factory AdminCounts.fromJson(Map<String, dynamic> j) => AdminCounts(
        patients: Fmt.toInt(j['total_patients']),
        users: Fmt.toInt(j['total_users']),
        doctors: Fmt.toInt(j['total_doctors']),
        hospitals: Fmt.toInt(j['total_hospitals']),
        clinics: Fmt.toInt(j['total_clinics']),
        pharmacies: Fmt.toInt(j['total_pharmacies']),
        bloodBanks: Fmt.toInt(j['total_blood_banks']),
        appointments: Fmt.toInt(j['total_appointments']),
        revenue: Fmt.toDouble(j['total_revenue']),
        pendingVerifications: Fmt.toInt(j['pending_verifications']),
        pendingReviews: Fmt.toInt(j['pending_reviews']),
        pendingFeedback: Fmt.toInt(j['pending_feedback']),
        pendingPayments: Fmt.toInt(j['pending_payments']),
        auditLogs: Fmt.toInt(j['audit_logs']),
        dbAuditLogs: Fmt.toInt(j['db_audit_logs']),
      );

  String get revenueLabel => Fmt.money(revenue);

  /// Everything waiting on a human decision — drives the "needs attention"
  /// badge on the console home.
  int get totalPending =>
      pendingVerifications + pendingReviews + pendingFeedback + pendingPayments;
}

/// A provider row in a moderation list. Wraps whichever of [Doctor] / [Place]
/// applies and carries the columns moderation needs on top.
class AdminProvider {
  const AdminProvider({
    required this.id,
    required this.name,
    required this.verification,
    required this.status,
    this.isDeleted = false,
    this.doctor,
    this.place,
    this.licenseNumber,
    this.licenseDocument,
    this.bmdcNumber,
    this.bmdcCertificate,
    this.ownerEmail,
    this.city,
    this.createdAt,
    this.commissionPercentage = 0,
  });

  final int id;
  final String name;

  /// pending | verified | rejected.
  final String verification;

  /// active | inactive | pending.
  final String status;

  /// Soft-delete flag (`is_deleted`): true hides the provider from the public
  /// directory and blocks new bookings, while keeping the history intact. It is
  /// independent of [status] — a verified+active provider can be soft-deleted.
  final bool isDeleted;

  /// Set when the row came from `/admin/providers/doctors`.
  final Doctor? doctor;

  /// Set for hospitals, clinics and pharmacies.
  final Place? place;

  final String? licenseNumber;
  final String? licenseDocument;

  /// Doctors only — the BMDC registration the admin checks before verifying.
  final String? bmdcNumber;
  final String? bmdcCertificate;

  final String? ownerEmail;
  final String? city;
  final String? createdAt;

  /// `commission_percentage` on the provider's own table — the admin-set
  /// platform cut taken out of every paid appointment fee (or paid order) at
  /// verification time. Defaults to 2.00 (see migration 0006).
  final double commissionPercentage;

  /// [type] is the path segment the list was fetched from, which decides
  /// whether the row parses as a doctor or a place.
  factory AdminProvider.fromJson(Map<String, dynamic> j, String type) {
    final isDoctor = type == 'doctors';
    final kind = switch (type) {
      'hospitals' => PlaceKind.hospital,
      'pharmacies' => PlaceKind.pharmacy,
      _ => PlaceKind.clinic,
    };

    final doctor = isDoctor ? Doctor.fromJson(j) : null;
    final place = isDoctor ? null : Place.fromJson(j, kind);

    return AdminProvider(
      id: Fmt.toInt(j['id']),
      name: doctor?.name ?? place?.name ?? Fmt.str(j['name'], 'Unnamed'),
      verification: Fmt.str(j['verification_status'], 'pending'),
      status: Fmt.str(j['status'], 'pending'),
      isDeleted: Fmt.toBool(j['is_deleted'], false),
      doctor: doctor,
      place: place,
      licenseNumber: _orNull(j['license_number']),
      licenseDocument: _orNull(j['license_document']),
      bmdcNumber: _orNull(j['bmdc_number']),
      bmdcCertificate: _orNull(j['bmdc_certificate']),
      ownerEmail: _orNull(j['owner_email'] ?? j['doctor_email']),
      city: _orNull(j['city']),
      createdAt: _orNull(j['created_at']),
      commissionPercentage: Fmt.toDouble(j['commission_percentage']),
    );
  }

  bool get isVerified => verification == 'verified';
  bool get isRejected => verification == 'rejected';
  bool get isPending => verification == 'pending';
  bool get isActive => status == 'active';

  /// The credential the admin is meant to check. Doctors are registered with
  /// the BMDC; the other three hold a trade/drug licence.
  String? get credential => bmdcNumber ?? licenseNumber;
  String? get credentialDocument => bmdcCertificate ?? licenseDocument;
}

/// What `POST /admin/providers/{type}/moderate` accepts.
enum ModerationAction {
  verify,
  reject,
  activate,
  deactivate;

  String get value => name;

  String get label => switch (this) {
        ModerationAction.verify => 'Verify',
        ModerationAction.reject => 'Reject',
        ModerationAction.activate => 'Activate',
        ModerationAction.deactivate => 'Deactivate',
      };
}

/// A review row in the moderation queue — carries the reviewer's email, which
/// the public shape deliberately does not.
class AdminReview {
  const AdminReview({
    required this.id,
    required this.targetType,
    required this.targetId,
    required this.rating,
    required this.status,
    this.comment,
    this.reviewerName,
    this.reviewerEmail,
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
  final String? reviewerName;
  final String? reviewerEmail;
  final String? createdAt;

  factory AdminReview.fromJson(Map<String, dynamic> j) => AdminReview(
        id: Fmt.toInt(j['id']),
        targetType: Fmt.str(j['reviewable_type']),
        targetId: Fmt.toInt(j['reviewable_id']),
        rating: Fmt.toInt(j['rating']).clamp(1, 5),
        status: Fmt.str(j['status'], 'pending'),
        comment: _orNull(j['comment']),
        reviewerName: _orNull(j['reviewer_name']),
        reviewerEmail: _orNull(j['reviewer_email']),
        createdAt: _orNull(j['created_at']),
      );

  bool get isPending => status == 'pending';
  String get targetLabel => '${Fmt.label(targetType)} #$targetId';
  String get dateLabel => Fmt.dayMonth(createdAt);
}

enum ReviewModeration {
  approve,
  reject,
  delete;

  String get value => name;
}

/// A contact-form submission — `GET /admin/feedback`.
class AdminFeedback {
  const AdminFeedback({
    required this.id,
    required this.type,
    required this.status,
    required this.priority,
    this.userId,
    this.name,
    this.email,
    this.phone,
    this.subject,
    this.message,
    this.adminResponse,
    this.respondedAt,
    this.createdAt,
  });

  final int id;

  /// `feedback.feedback_type` — free text server-side, so treat unknown values
  /// as 'general' rather than asserting a set.
  final String type;

  /// pending | in_progress | resolved | closed.
  final String status;

  /// low | medium | high. Added by migration_v2.sql; defaults to medium before
  /// that runs.
  final String priority;

  /// `feedback.user_id` — a uuid, and null for the public contact form. It was
  /// an int under MySQL; parsing a uuid with `Fmt.toInt` would have produced 0
  /// for every signed-in submission, which is a value the UI would then have
  /// had no way to tell apart from a real id.
  ///
  /// Only ever null-checked (`hasAccount` in admin_feedback_screen.dart), so
  /// nothing downstream had to change.
  final String? userId;

  final String? name;
  final String? email;
  final String? phone;
  final String? subject;
  final String? message;

  final String? adminResponse;
  final String? respondedAt;
  final String? createdAt;

  factory AdminFeedback.fromJson(Map<String, dynamic> j) => AdminFeedback(
        id: Fmt.toInt(j['id']),
        type: Fmt.str(j['feedback_type'], 'general'),
        status: Fmt.str(j['status'], 'pending'),
        priority: Fmt.str(j['priority'], 'medium'),
        userId: _orNull(j['user_id']),
        name: _orNull(j['name']),
        email: _orNull(j['email']),
        phone: _orNull(j['phone']),
        subject: _orNull(j['subject']),
        message: _orNull(j['message']),
        adminResponse: _orNull(j['admin_response']),
        respondedAt: _orNull(j['responded_at']),
        createdAt: _orNull(j['created_at']),
      );

  bool get isOpen => status == 'pending' || status == 'in_progress';
  bool get hasResponse => (adminResponse ?? '').isNotEmpty;
  bool get isUrgent => priority == 'high';

  String get statusLabel => Fmt.label(status);
  String get priorityLabel => Fmt.label(priority);
  String get dateLabel => Fmt.dayMonth(createdAt);

  /// Signed-in submissions carry a user id; the public contact form does not.
  String get fromLabel => name ?? email ?? 'Anonymous';
}

/// A blood bank as the admin edits it — `stock` arrives as a group→units map
/// so the client never has to know the eight column names.
class AdminBloodBank {
  const AdminBloodBank({
    required this.id,
    required this.name,
    required this.stock,
    required this.totalUnits,
    this.address,
    this.city,
    this.phone,
    this.email,
    this.status = 'active',
    this.updatedAt,
  });

  final int id;
  final String name;

  /// "A+" → units. Always all eight groups, zero-filled.
  final Map<String, int> stock;

  final int totalUnits;
  final String? address;
  final String? city;
  final String? phone;
  final String? email;
  final String status;
  final String? updatedAt;

  factory AdminBloodBank.fromJson(Map<String, dynamic> j) {
    final raw = _map(j['stock']);
    return AdminBloodBank(
      id: Fmt.toInt(j['id']),
      name: Fmt.str(j['name'], 'Unnamed'),
      stock: {for (final e in raw.entries) e.key: Fmt.toInt(e.value)},
      totalUnits: Fmt.toInt(j['total_units']),
      address: _orNull(j['address']),
      city: _orNull(j['city']),
      phone: _orNull(j['phone']),
      email: _orNull(j['email']),
      status: Fmt.str(j['status'], 'active'),
      updatedAt: _orNull(j['updated_at']),
    );
  }

  bool get isActive => status == 'active';
}

/// A blog post as the admin edits it. Distinct from the public [BlogPost]
/// because it always carries `content` and `status`, including drafts.
class AdminBlog {
  const AdminBlog({
    required this.id,
    required this.title,
    required this.status,
    this.slug,
    this.excerpt,
    this.content,
    this.category,
    this.image,
    this.createdAt,
  });

  final int id;
  final String title;

  /// published | draft. Only present once migration_v2.sql adds the column;
  /// before that everything reads as published.
  final String status;

  final String? slug;
  final String? excerpt;
  final String? content;
  final String? category;
  final String? image;
  final String? createdAt;

  factory AdminBlog.fromJson(Map<String, dynamic> j) => AdminBlog(
        id: Fmt.toInt(j['id']),
        title: Fmt.str(j['title'], 'Untitled'),
        status: Fmt.str(j['status'], 'published'),
        slug: _orNull(j['slug']),
        excerpt: _orNull(j['excerpt']),
        content: _orNull(j['content']),
        category: _orNull(j['category']),
        image: _orNull(j['image']),
        createdAt: _orNull(j['created_at']),
      );

  bool get isPublished => status == 'published';
  String get dateLabel => Fmt.dayMonth(createdAt);
}

/// One row of `app_audit_log` — §10.12.
class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.action,
    required this.entity,
    this.entityId,
    this.userId,
    this.userName,
    this.userEmail,
    this.userRole,
    this.details,
    this.ipAddress,
    this.createdAt,
  });

  final int id;

  /// create | update | delete | login | logout, and anything else a handler
  /// chose to record. Not an enum: the column is free text.
  final String action;

  /// The table or logical entity the action touched.
  final String entity;

  /// `app_audit_log.entity_id` is `text`, not a number: it holds a bigint for
  /// most tables and a uuid when the entity is a user. Kept as a String so a
  /// uuid target renders as itself instead of collapsing to `#0`.
  final String? entityId;

  /// The actor's `users.id` — a uuid, and null once that user is deleted
  /// (`app_audit_log.user_id` is ON DELETE SET NULL). See
  /// [AdminFeedback.userId] for why this is no longer an int.
  final String? userId;

  final String? userName;
  final String? userEmail;
  final String? userRole;

  /// Free-text JSON or a short sentence, written by the handler.
  final String? details;

  final String? ipAddress;
  final String? createdAt;

  factory AuditEntry.fromJson(Map<String, dynamic> j) => AuditEntry(
        id: Fmt.toInt(j['id']),
        action: Fmt.str(j['action'], 'unknown'),
        entity: Fmt.str(j['entity'], 'unknown'),
        entityId: _orNull(j['entity_id']),
        userId: _orNull(j['user_id']),
        userName: _orNull(j['user_name']),
        userEmail: _orNull(j['user_email']),
        userRole: _orNull(j['user_role']),
        details: _orNull(j['details']),
        ipAddress: _orNull(j['ip_address']),
        createdAt: _orNull(j['created_at']),
      );

  /// `user_id` is ON DELETE SET NULL, so a real entry can have no actor.
  String get actorLabel => userName ?? (userId == null ? 'System' : 'Deleted user');

  String get targetLabel => entityId == null ? entity : '$entity #$entityId';
  String get timeLabel => Fmt.relative(createdAt);
}

/// The aggregate `/admin/audit-log` returns alongside the page, computed over
/// the whole log rather than the current page.
class AuditSummary {
  const AuditSummary({
    this.inserts = 0,
    this.updates = 0,
    this.deletes = 0,
    this.trackedEntities = 0,
    this.latestActivity,
    this.entities = const [],
    this.actions = const [],
  });

  final int inserts;
  final int updates;
  final int deletes;
  final int trackedEntities;
  final String? latestActivity;

  /// Distinct values, for the filter dropdowns.
  final List<String> entities;
  final List<String> actions;

  /// Reads the whole `data` object, since the summary and the filter lists are
  /// siblings of `logs`.
  factory AuditSummary.fromEnvelope(Map<String, dynamic> data) {
    final s = _map(data['summary']);
    final f = _map(data['filters']);
    return AuditSummary(
      inserts: Fmt.toInt(s['inserts']),
      updates: Fmt.toInt(s['updates']),
      deletes: Fmt.toInt(s['deletes']),
      trackedEntities: Fmt.toInt(s['tracked_entities']),
      latestActivity: _orNull(s['latest_activity']),
      entities: _strings(f['entities']),
      actions: _strings(f['actions']),
    );
  }

  int get total => inserts + updates + deletes;
  String get latestLabel => latestActivity == null ? '—' : Fmt.relative(latestActivity);
}

/// An admin's view of a user account. [AppUser] models the same row, so this
/// just adds the fields the console filters and sorts on.
typedef AdminUser = AppUser;

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

List<String> _strings(Object? raw) {
  if (raw is! List) return const [];
  return raw.map((e) => Fmt.str(e)).where((s) => s.isNotEmpty).toList();
}

String? _orNull(Object? v) {
  final s = Fmt.str(v);
  return s.isEmpty ? null : s;
}
