/// The moderation console (feature.md §10) — from Supabase.
///
/// Public surface is unchanged: `dashboard()`, `users()`, `deleteUser()`,
/// `providers()`, `moderateProvider()`, `appointments()`, `reviews()`,
/// `moderateReview()`, `feedback()`, `updateFeedback()`, `deleteFeedback()`,
/// `bloodBanks()`, `saveBloodBank()`, `deleteBloodBank()`, `blogs()`,
/// `saveBlog()`, `deleteBlog()`, `auditLog()`, `payments()`,
/// `payouts()`, `settlePayout()`.
///
/// Every table here has an `*_admin` policy gated on `public.is_admin()`, so a
/// non-admin session gets an empty list on reads and a 42501 on writes, which
/// [SupabaseService.guard] surfaces as a 403 — the same [ApiException] the PHP
/// `require_role(['admin'])` produced. The router keeps these screens
/// unreachable in the first place.
///
/// Five things differ from the PHP and are worth knowing.
///
/// **`deleteUser` takes a String.** `users.id` is a uuid now, so the old
/// `int` parameter could not compile against `AppUser.id`. See the method for
/// what it can and cannot delete.
///
/// **Feedback vocabulary is translated at this boundary.** The database enums
/// are `feedback_status ('new', …)` and `feedback_priority ('low','normal',…)`,
/// while every screen says `pending` and `medium`. [_statusToDb] / [_statusToUi]
/// and [_priorityToDb] / [_priorityToUi] convert both ways, so no widget and no
/// filter constant changed.
///
/// **Blog slugs are minted here.** The PHP derived the slug from the title and
/// de-duplicated it; there is no trigger doing that in schema.sql, and
/// `uq_blog_slug` is a hard unique constraint, so [_uniqueSlug] reproduces it.
///
/// **The audit filter dropdowns read a capped sample.** PostgREST cannot
/// `GROUP BY`, and there is no view over `app_audit_log`, so the distinct
/// action/entity values come from the most recent [_auditSampleSize] rows. A
/// value that has not occurred recently will not appear in the dropdown; the
/// counts beside it are still exact, because those are real count queries.
///
/// **Provider rejection reasons are stored and delivered.** They land on the
/// provider row's `rejection_reason` column and are echoed into the
/// notification by `providers_notify`. See [moderateProvider].
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show CountOption, PostgrestList, PostgrestTransformBuilder;

import '../../../core/constants/app_config.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/api_result.dart';
import '../../../core/network/supabase_service.dart';
import '../../../core/providers.dart';
import '../../../core/utils/formatters.dart';
import '../../../models/admin_models.dart';
import '../../../models/app_user.dart';
import '../../../models/appointment_models.dart';
import '../../../models/provider_models.dart';

/// The audit log answers `logs` plus a whole-log `summary` and the distinct
/// values for the filter dropdowns, so a page alone would lose two thirds of
/// the response.
class AuditPage {
  const AuditPage({required this.page, required this.summary});

  final Paged<AuditEntry> page;
  final AuditSummary summary;
}

class AdminRepository {
  AdminRepository(this._sb);

  final SupabaseService _sb;

  /// How many recent audit rows feed the filter dropdowns. See the library doc.
  static const _auditSampleSize = 500;

  /// `blood_banks` stores one column per group; the UI speaks a group→units map.
  static const _bloodColumns = {
    'A+': 'blood_a_positive',
    'A-': 'blood_a_negative',
    'B+': 'blood_b_positive',
    'B-': 'blood_b_negative',
    'AB+': 'blood_ab_positive',
    'AB-': 'blood_ab_negative',
    'O+': 'blood_o_positive',
    'O-': 'blood_o_negative',
  };

  /// `users` has no `status` column — a profile exists or it does not, and the
  /// per-provider `status` enum lives on the four provider tables instead.
  static const _userColumns =
      'id, name, email, phone, address, city, profile_image, blood_group, '
      'role, gender, created_at';

  static const _placeColumns = '*, users!left(email)';

  static const _doctorColumns = 'id, user_id, bmdc_registration_number, '
      'bmdc_certificate, specialization, qualifications, medical_school, '
      'graduation_year, experience_years, doctor_type, hospital_clinic_name, '
      'chamber_address, city, area, consultation_fee, bio, rating, '
      'total_reviews, verification_status, status, is_deleted, available_days, '
      'available_from, available_to, slot_minutes, commission_percentage, '
      'created_at, '
      'users!inner(name, phone, email, profile_image)';

  // -- §10.1 Dashboard -----------------------------------------------------

  /// One call to the `admin_dashboard_stats` function, which computes every
  /// figure server-side in correlated subqueries. The old implementation fired
  /// ~21 count queries serially per page load; this is one round trip plus the
  /// recent-activity list.
  ///
  /// The function is SECURITY DEFINER and refuses anyone who is not an admin
  /// (42501), so a non-admin never sees a row of zeros — they get the 403
  /// below, the same answer the PHP admin guard produced. PostgREST returns a
  /// one-row array because the function is set-returning.
  Future<AdminDashboard> dashboard() async {
    return SupabaseService.guard(() async {
      final rows = await _sb.rpc<List<dynamic>>('admin_dashboard_stats');
      final row = rows.isEmpty ? null : (rows.first as Map<String, dynamic>);

      final recent = await _sb
          .db('app_audit_log')
          .select('id, user_id, action, entity, entity_id, details, '
              'ip_address, created_at, users!left(name, email, role)')
          .order('created_at', ascending: false)
          .limit(8);

      // A non-admin session is refused by the function itself, and an empty
      // result here is indistinguishable from a fresh database; either way
      // treat it as the 403 the PHP admin guard produced rather than a
      // dashboard of zeros.
      if (row == null) {
        throw ApiException(
          message: 'You do not have permission to view the dashboard.',
          statusCode: 403,
        );
      }

      final r = row;
      return AdminDashboard.fromJson({
        'counts': {
          'total_patients': r['total_patients'],
          'total_users': r['total_users'],
          'total_doctors': r['total_doctors_rows'],
          'total_hospitals': r['total_hospitals'],
          'total_clinics': r['total_clinics'],
          'total_pharmacies': r['total_pharmacies'],
          'total_blood_banks': r['total_blood_banks'],
          'total_appointments': r['total_appointments'],
          'total_revenue': r['revenue'],
          'pending_verifications': Fmt.toInt(r['pending_doctors']) +
              Fmt.toInt(r['pending_hospitals']) +
              Fmt.toInt(r['pending_clinics']) +
              Fmt.toInt(r['pending_pharmacies']),
          'pending_reviews': r['pending_reviews'],
          'pending_feedback': r['pending_feedback'],
          'pending_payments': r['payments_pending'],
          'audit_logs': r['audit_logs'],
          'db_audit_logs': r['db_audit_logs'],
        },
        'pending_verifications': {
          'doctors': r['pending_doctors'],
          'hospitals': r['pending_hospitals'],
          'clinics': r['pending_clinics'],
          'pharmacies': r['pending_pharmacies'],
        },
        'recent_activity': recent.map(_shapeAudit).toList(),
      });
    });
  }

  // -- §10.2 Users ---------------------------------------------------------

  /// [role] must be one of patient | doctor | clinic | pharmacy | hospital |
  /// admin. [search] matches name, email or phone.
  Future<Paged<AdminUser>> users({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String? role,
    String? search,
  }) async {
    return SupabaseService.guard(() async {
      final range = PageRange(page, limit);

      var query = _sb.db('users').select(_userColumns);

      if (_has(role)) query = query.eq('role', role!.trim());
      if (_has(search)) {
        final term = _escapeOr(search!.trim());
        query = query.or(
          'name.ilike.%$term%,email.ilike.%$term%,phone.ilike.%$term%',
        );
      }

      final res = await query
          .order('created_at', ascending: false)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return Paged(
        items: res.data.map((r) => AppUser.fromJson(_shapeUser(r))).toList(),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  /// Deletes the caller-visible profile row.
  ///
  /// [userId] is a String because `users.id` is a uuid — the old `int` could not
  /// hold one, and every call site already passes `AppUser.id`.
  ///
  /// **This removes `public.users`, not `auth.users`.** Deleting an auth account
  /// requires the service-role key, which must never ship in a mobile binary, so
  /// it cannot be done from this client. The profile row and everything cascading
  /// from it (appointments, reviews, cart, …) do go, and without a profile the
  /// account can no longer resolve a role, so it cannot use the app. Removing the
  /// login itself is a Supabase dashboard or Edge Function action.
  ///
  /// Refuses to delete the calling admin's own account, as the server did — a
  /// console session deleting itself leaves a signed-in client with no profile.
  Future<void> deleteUser(String userId) async {
    return SupabaseService.guard(() async {
      final me = _sb.currentUserId;
      if (me != null && me == userId) {
        throw ApiException(
          message: 'You cannot delete your own account.',
          statusCode: 422,
        );
      }
      await _sb.db('users').delete().eq('id', userId);
    });
  }

  // -- §10.3–10.6 Provider moderation --------------------------------------

  /// [type] is one of doctors | hospitals | clinics | pharmacies — it selects
  /// both the table and whether each row parses as a [Doctor] or a [Place].
  Future<Paged<AdminProvider>> providers({
    required String type,
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String? verification,
    String? status,
    String? search,
  }) async {
    return SupabaseService.guard(() async {
      final table = _providerTable(type);
      final isDoctor = table == 'doctors';
      final range = PageRange(page, limit);

      var query = _sb
          .db(table)
          .select(isDoctor ? _doctorColumns : _placeColumns);

      if (_has(verification)) {
        query = query.eq('verification_status', verification!.trim());
      }
      if (_has(status)) query = query.eq('status', status!.trim());

      if (_has(search)) {
        final term = _escapeOr(search!.trim());
        if (isDoctor) {
          // A doctor's name lives on `users`. The embed is `!inner`, and every
          // doctor has a NOT NULL user_id, so filtering the embed restricts the
          // parent rows without dropping any.
          query = query.or(
            'name.ilike.%$term%,email.ilike.%$term%,phone.ilike.%$term%',
            referencedTable: 'users',
          );
        } else {
          query = query.or(
            'name.ilike.%$term%,city.ilike.%$term%,address.ilike.%$term%',
          );
        }
      }

      final res = await query
          .order('created_at', ascending: false)
          .range(range.from, range.to)
          .count(CountOption.exact);

      // Sequential rather than Future.wait: each row signs at most one document
      // and a page is 20 rows, so this is 20 short storage calls at worst. Firing
      // them all at once is what makes the storage API rate-limit and fail the
      // whole page instead of one card's document link.
      final items = <AdminProvider>[];
      for (final r in res.data) {
        final shaped =
            isDoctor ? await _shapeAdminDoctor(r) : await _shapeAdminPlace(r);
        items.add(AdminProvider.fromJson(shaped, type));
      }

      return Paged(
        items: items,
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  /// Verify / reject / activate / deactivate.
  ///
  /// Verifying also activates, because the public directory gates on both
  /// columns and a verified-but-inactive provider would stay invisible.
  ///
  /// The `aa_guard_*` triggers block these columns for everyone else, but
  /// `guard_admin_only_columns` returns early when `is_admin()`, so an admin
  /// writes them directly. The `*_notify_trg` triggers then write the
  /// provider's notification.
  ///
  /// On reject, [reason] is stored on the provider row's `rejection_reason`
  /// column; `providers_notify` appends it to the notification the provider
  /// receives, so the "why" is no longer dropped.
  Future<void> moderateProvider({
    required String type,
    required int id,
    required ModerationAction action,
    String? reason,
  }) async {
    return SupabaseService.guard(() async {
      final table = _providerTable(type);

      final patch = switch (action) {
        ModerationAction.verify => {
            'verification_status': 'verified',
            'status': 'active',
          },
        ModerationAction.reject => {
            'verification_status': 'rejected',
            'rejection_reason': _nullIfEmpty(reason),
          },
        ModerationAction.activate => {'status': 'active'},
        ModerationAction.deactivate => {'status': 'inactive'},
      };

      final rows =
          await _sb.db(table).update(patch).eq('id', id).select('id');

      if (rows.isEmpty) {
        throw ApiException(message: 'Provider not found.', statusCode: 404);
      }
    });
  }

  /// DB-stored, admin-editable consultation fee (`doctors.consultation_fee`).
  ///
  /// Bookings read the *current* fee at booking time (the `appointments_book`
  /// RPC stamps `d.consultation_fee`), so the change applies from the next
  /// booking; appointments already booked keep the fee captured when they were
  /// created.
  Future<void> updateConsultationFee({
    required int doctorId,
    required double fee,
  }) async {
    return SupabaseService.guard(() async {
      final rows = await _sb
          .db('doctors')
          .update({'consultation_fee': fee})
          .eq('id', doctorId)
          .select('id');

      if (rows.isEmpty) {
        throw ApiException(message: 'Doctor not found.', statusCode: 404);
      }
    });
  }

  /// Soft-deletes or restores a provider's listing (`is_deleted`).
  ///
  /// Deleting hides the provider from the public directory and blocks new
  /// bookings, while leaving every appointment/payment/review row intact —
  /// that is the whole point of the flag. `available_slots` and
  /// `appointments_book` both refuse a deleted doctor, so the "hidden" state is
  /// enforced server-side, not just by the select filters.
  Future<void> setProviderDeleted({
    required String type,
    required int id,
    required bool deleted,
  }) async {
    return SupabaseService.guard(() async {
      final rows = await _sb
          .db(_providerTable(type))
          .update({'is_deleted': deleted})
          .eq('id', id)
          .select('id');

      if (rows.isEmpty) {
        throw ApiException(message: 'Provider not found.', statusCode: 404);
      }
    });
  }

  /// Bans (`is_active = false`) or un-bans a user.
  ///
  /// Banning fires `users_ban_enforce`: the user's future pending/confirmed
  /// appointments are cancelled (paid ones move to 'refunded' via
  /// `appointments_refund_on_cancel`) and the user is notified. Every guarded
  /// RPC also refuses an inactive account outright, so a banned session cannot
  /// book, order or pay even if the client UI still shows the buttons.
  Future<void> setUserActive({
    required String userId,
    required bool active,
  }) async {
    return SupabaseService.guard(() async {
      final rows = await _sb
          .db('users')
          .update({'is_active': active})
          .eq('id', userId)
          .select('id');

      if (rows.isEmpty) {
        throw ApiException(message: 'User not found.', statusCode: 404);
      }
    });
  }

  // -- §10.7 Appointments (read-only oversight) ----------------------------

  /// [date] is a single day (yyyy-MM-dd), not a range. [search] matches either
  /// the patient's or the doctor's name.
  Future<Paged<Appointment>> appointments({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String? status,
    String? date,
    String? search,
  }) async {
    return SupabaseService.guard(() async {
      final range = PageRange(page, limit);

      // No `users` embed: `appointments` has two FKs to `users` (`patient_id`
      // and `payment_verified_by`), so a bare `users(...)` is ambiguous and
      // PostgREST refuses it. The doctor comes through `doctors`, which has
      // exactly one; the patient is batched afterwards.
      var query = _sb.db('appointments').select(
            'id, patient_id, doctor_id, appointment_date, appointment_time, '
            'type, symptoms, notes, fee, status, payment_status, '
            'confirmation_code, created_at, '
            'doctors!left(specialization, hospital_clinic_name, '
            'chamber_address, users!inner(name, profile_image))',
          );

      if (_has(status)) query = query.eq('status', status!.trim());
      if (_has(date)) query = query.eq('appointment_date', date!.trim());

      if (_has(search)) {
        // Name lives on `users` for both sides, and one filter cannot span two
        // different relationships. So the names are resolved to ids first and
        // the appointment query filters on those.
        final ids = await _appointmentSearchIds(search!.trim());
        if (ids.patients.isEmpty && ids.doctors.isEmpty) {
          return Paged<Appointment>(
            items: const [],
            meta: PageMeta(page: page, limit: limit, total: 0),
          );
        }

        final clauses = <String>[
          if (ids.patients.isNotEmpty) 'patient_id.in.(${ids.patients.join(',')})',
          if (ids.doctors.isNotEmpty) 'doctor_id.in.(${ids.doctors.join(',')})',
        ];
        query = query.or(clauses.join(','));
      }

      final res = await query
          .order('appointment_date', ascending: false)
          .order('appointment_time', ascending: false)
          .range(range.from, range.to)
          .count(CountOption.exact);

      final patients = await _patients(res.data.map((r) => r['patient_id']));

      return Paged(
        items: res.data
            .map((r) => Appointment.fromJson(_shapeAppointment(r, patients)))
            .toList(),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  // -- §10.8 Reviews -------------------------------------------------------

  /// Defaults to the pending queue — the only list an admin has to act on.
  /// `all` means no status clause. [targetType] filters `reviewable_type`.
  Future<Paged<AdminReview>> reviews({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String status = 'pending',
    String? targetType,
  }) async {
    return SupabaseService.guard(() async {
      final range = PageRange(page, limit);

      // `reviews` has one FK to `users`, so this embed is unambiguous.
      var query = _sb.db('reviews').select(
            'id, user_id, reviewable_type, reviewable_id, rating, comment, '
            'status, created_at, users!left(name, email)',
          );

      if (status != 'all' && status.trim().isNotEmpty) {
        query = query.eq('status', status.trim());
      }
      if (_has(targetType)) {
        query = query.eq('reviewable_type', targetType!.trim());
      }

      final res = await query
          .order('created_at', ascending: false)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return Paged(
        items: res.data.map((r) {
          final author = r['users'] as Map<String, dynamic>?;
          return AdminReview.fromJson({
            ...r,
            'reviewer_name': author?['name'],
            'reviewer_email': author?['email'],
          });
        }).toList(),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  /// Approving or rejecting fires `reviews_recalc_rating`, which recomputes the
  /// target's cached `rating` and `total_reviews`; deleting removes the row and
  /// fires the same trigger. Nothing is returned, so callers refetch.
  Future<void> moderateReview({
    required int reviewId,
    required ReviewModeration action,
  }) async {
    return SupabaseService.guard(() async {
      if (action == ReviewModeration.delete) {
        await _sb.db('reviews').delete().eq('id', reviewId);
        return;
      }

      final rows = await _sb
          .db('reviews')
          .update({
            'status':
                action == ReviewModeration.approve ? 'approved' : 'rejected',
          })
          .eq('id', reviewId)
          .select('id');

      if (rows.isEmpty) {
        throw ApiException(message: 'Review not found.', statusCode: 404);
      }
    });
  }

  // -- §10.9 Feedback ------------------------------------------------------

  /// [status] and [priority] are the console's vocabulary (`pending`,
  /// `medium`); they are translated to this schema's enums on the way in.
  Future<Paged<AdminFeedback>> feedback({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String? status,
    String? type,
    String? priority,
  }) async {
    return SupabaseService.guard(() async {
      final range = PageRange(page, limit);

      var query = _sb.db('feedback').select(
            'id, user_id, name, email, phone, feedback_type, subject, message, '
            'admin_response, status, priority, created_at, updated_at',
          );

      if (_has(status)) query = query.eq('status', _statusToDb(status!.trim()));
      if (_has(type)) query = query.eq('feedback_type', type!.trim());
      if (_has(priority)) {
        query = query.eq('priority', _priorityToDb(priority!.trim()));
      }

      final res = await query
          .order('created_at', ascending: false)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return Paged(
        items:
            res.data.map((r) => AdminFeedback.fromJson(_shapeFeedback(r))).toList(),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  /// Writing a [response] fires `feedback_notify_trg`, which notifies the
  /// submitter when the row has a user account behind it.
  ///
  /// [status] is pending | in_progress | resolved | closed and [priority] is
  /// low | medium | high | urgent, both in the console's vocabulary. A value
  /// outside this schema's enums comes back as a 422 naming the column.
  ///
  /// At least one of the three must be supplied.
  Future<void> updateFeedback({
    required int feedbackId,
    String? status,
    String? response,
    String? priority,
  }) async {
    final patch = <String, dynamic>{
      if (status != null) 'status': _statusToDb(status),
      if (response != null && response.trim().isNotEmpty)
        'admin_response': response.trim(),
      if (priority != null) 'priority': _priorityToDb(priority),
    };

    if (patch.isEmpty) {
      throw ApiException(message: 'No fields to update.', statusCode: 400);
    }

    return SupabaseService.guard(() async {
      final rows = await _sb
          .db('feedback')
          .update(patch)
          .eq('id', feedbackId)
          .select('id');

      if (rows.isEmpty) {
        throw ApiException(message: 'Feedback not found.', statusCode: 404);
      }
    });
  }

  Future<void> deleteFeedback(int feedbackId) async {
    return SupabaseService.guard(() async {
      await _sb.db('feedback').delete().eq('id', feedbackId);
    });
  }

  // -- §10.10 Blood banks --------------------------------------------------

  /// [search] matches name, address or city — there is no separate city filter.
  Future<Paged<AdminBloodBank>> bloodBanks({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String? search,
  }) async {
    return SupabaseService.guard(() async {
      final range = PageRange(page, limit);

      var query = _sb.db('blood_banks').select();

      if (_has(search)) {
        final term = _escapeOr(search!.trim());
        query = query.or(
          'name.ilike.%$term%,address.ilike.%$term%,city.ilike.%$term%',
        );
      }

      final res = await query
          .order('name', ascending: true)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return Paged(
        items: res.data.map((r) => AdminBloodBank.fromJson(_shapeBank(r))).toList(),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  /// Create when [id] is null, update otherwise.
  ///
  /// [stock] is a group→units map ("A+" → 12), mapped onto the eight columns
  /// here so no screen has to know their names. Groups outside the eight are
  /// ignored rather than erroring, and negative counts are clamped to zero —
  /// `blood_banks_stock_non_negative` would otherwise reject the whole save.
  Future<AdminBloodBank> saveBloodBank({
    int? id,
    required String name,
    String? address,
    String? city,
    String? phone,
    String? email,
    String? status,
    Map<String, int>? stock,
  }) async {
    return SupabaseService.guard(() async {
      final patch = <String, dynamic>{
        'name': name.trim(),
        if (address != null) 'address': address.trim(),
        if (city != null) 'city': city.trim(),
        if (phone != null) 'phone': _nullIfEmpty(phone),
        if (email != null) 'email': _nullIfEmpty(email),
        if (status != null) 'status': status,
      };

      if (stock != null) {
        stock.forEach((group, units) {
          final column = _bloodColumns[group.trim().toUpperCase()];
          if (column != null) patch[column] = units < 0 ? 0 : units;
        });
      }

      final Map<String, dynamic> row;
      if (id == null) {
        // `address` and `city` are NOT NULL with no default, so a create must
        // carry them even though the update path treats them as optional.
        patch.putIfAbsent('address', () => '');
        patch.putIfAbsent('city', () => '');
        row = await _sb.db('blood_banks').insert(patch).select().single();
      } else {
        row = await _sb
            .db('blood_banks')
            .update(patch)
            .eq('id', id)
            .select()
            .single();
      }

      return AdminBloodBank.fromJson(_shapeBank(row));
    });
  }

  Future<void> deleteBloodBank(int id) async {
    return SupabaseService.guard(() async {
      await _sb.db('blood_banks').delete().eq('id', id);
    });
  }

  // -- §10.11 Blog ---------------------------------------------------------

  /// Unlike the public `/blog`, this returns drafts too — `blogs_select_admin`
  /// is what makes them visible.
  Future<Paged<AdminBlog>> blogs({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String? status,
    String? category,
    String? search,
  }) async {
    return SupabaseService.guard(() async {
      final range = PageRange(page, limit);

      var query = _sb.db('blogs').select(
            'id, slug, title, excerpt, content, cover_image, category, tags, '
            'status, published_at, views, created_at',
          );

      if (_has(status)) query = query.eq('status', status!.trim());

      final term = search ?? category;
      if (_has(term)) {
        final t = _escapeOr(term!.trim());
        query = query.or('title.ilike.%$t%,category.ilike.%$t%');
      }

      final res = await query
          .order('created_at', ascending: false)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return Paged(
        items: res.data.map((r) => AdminBlog.fromJson(_shapeBlog(r))).toList(),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  /// Create when [id] is null, update otherwise.
  ///
  /// Returns the id and the slug that was actually stored: it is derived from
  /// the title and de-duplicated, so it can differ from anything the caller
  /// expected. Not a full [AdminBlog] — callers refetch the list.
  ///
  /// Publishing stamps `published_at`, because `blogs_select_published` orders
  /// on it and a published post with a null timestamp sorts last forever.
  Future<({int id, String slug})> saveBlog({
    int? id,
    required String title,
    required String content,
    String? excerpt,
    String? category,
    String? image,
    String? status,
  }) async {
    return SupabaseService.guard(() async {
      final trimmedTitle = title.trim();
      final state = status?.trim();

      final patch = <String, dynamic>{
        'title': trimmedTitle,
        'content': content,
        if (excerpt != null) 'excerpt': _nullIfEmpty(excerpt),
        if (category != null) 'category': _nullIfEmpty(category),
        if (image != null) 'cover_image': _nullIfEmpty(image),
        if (state != null && state.isNotEmpty) 'status': state,
        if (state == 'published') 'published_at': DateTime.now().toIso8601String(),
      };

      final Map<String, dynamic> row;
      if (id == null) {
        patch['slug'] = await _uniqueSlug(trimmedTitle, excludeId: null);
        // `author_id` is ON DELETE SET NULL and nullable, so a post outlives its
        // author; it is stamped here so "who wrote this" survives at all.
        final me = _sb.currentUserId;
        if (me != null && me.isNotEmpty) patch['author_id'] = me;

        row = await _sb.db('blogs').insert(patch).select('id, slug').single();
      } else {
        // Retitling re-slugs, as the PHP did. Excluding this row stops a
        // no-op save from appending "-2" to its own slug every time.
        patch['slug'] = await _uniqueSlug(trimmedTitle, excludeId: id);
        row = await _sb
            .db('blogs')
            .update(patch)
            .eq('id', id)
            .select('id, slug')
            .single();
      }

      return (id: Fmt.toInt(row['id']), slug: Fmt.str(row['slug']));
    });
  }

  Future<void> deleteBlog(int id) async {
    return SupabaseService.guard(() async {
      await _sb.db('blogs').delete().eq('id', id);
    });
  }

  // -- §10.12 Audit log ----------------------------------------------------

  /// Returns the page and the whole-log summary together, since the summary and
  /// the filter dropdown values are siblings of `logs` in the old response.
  Future<AuditPage> auditLog({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String? action,
    String? entity,
    String? dateFrom,
    String? dateTo,
    String? search,
  }) async {
    return SupabaseService.guard(() async {
      final range = PageRange(page, limit);

      // `app_audit_log` has one FK to `users`, so this embed is unambiguous.
      var query = _sb.db('app_audit_log').select(
            'id, user_id, action, entity, entity_id, details, ip_address, '
            'created_at, users!left(name, email, role)',
          );

      if (_has(action)) query = query.eq('action', action!.trim());
      if (_has(entity)) query = query.eq('entity', entity!.trim());
      if (_has(dateFrom)) query = query.gte('created_at', dateFrom!.trim());
      // Inclusive of the whole end day: the column is a timestamptz, so a bare
      // date would otherwise cut the day off at midnight.
      if (_has(dateTo)) query = query.lt('created_at', _endOfDay(dateTo!.trim()));

      if (_has(search)) {
        // The actor's name/email live on `users`, so they are resolved to ids
        // first; `details` is jsonb and is matched as text.
        final term = _escapeOr(search!.trim());
        final actors = await _sb
            .db('users')
            .select('id')
            .or('name.ilike.%$term%,email.ilike.%$term%')
            .limit(200);

        final ids = actors.map((r) => Fmt.str(r['id'])).where((s) => s.isNotEmpty);
        final clauses = <String>[
          // `details` is jsonb; ilike cannot be applied to a jsonb column, so
          // the filter targets its text rendering. PostgREST resolves the
          // `::text` cast inside the column name.
          'details::text.ilike.%$term%',
          if (ids.isNotEmpty) 'user_id.in.(${ids.join(',')})',
        ];
        query = query.or(clauses.join(','));
      }

      final res = await query
          .order('created_at', ascending: false)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return AuditPage(
        page: Paged(
          items: res.data.map((r) => AuditEntry.fromJson(_shapeAudit(r))).toList(),
          meta: PageMeta(page: page, limit: limit, total: res.count),
        ),
        summary: await _auditSummary(),
      );
    });
  }

  // -- §10.13 Payments -----------------------------------------------------

  /// Payment verification and the money split.
  ///
  /// The admin is the ONLY verifier (the `payments_update_doctor` policy no
  /// longer exists). On verify the `payments_apply_verification` trigger:
  /// splits the amount into the platform's `admin_share` (the provider's
  /// `commission_percentage`) and the provider's `provider_share`, writes the
  /// provider_payouts ledger, and marks the appointment paid — but does NOT
  /// confirm it. The provider confirms the booking after their share is
  /// credited. Rejecting requires a reason the patient is shown.
  ///
  /// Only `payment_status` (and `rejection_reason` on a reject) is written;
  /// `verified_by`/`verified_at` and the split are computed by the trigger.
  Future<void> verifyPayment({
    required int paymentId,
    required bool approve,
    String? rejectionReason,
  }) async {
    return SupabaseService.guard(() async {
      if (!approve && (rejectionReason == null || rejectionReason.trim().isEmpty)) {
        throw ApiException(
          message: 'Please give a reason for rejecting this payment.',
          statusCode: 422,
          errors: const {'rejection_reason': 'A reason is required.'},
        );
      }

      final rows = await _sb
          .db('payments')
          .update({
            'payment_status': approve ? 'verified' : 'rejected',
            if (!approve) 'rejection_reason': rejectionReason!.trim(),
          })
          .eq('id', paymentId)
          .select('id');

      if (rows.isEmpty) {
        throw ApiException(message: 'Payment not found.', statusCode: 404);
      }
    });
  }

  /// The admin-settable platform cut (`commission_percentage`) on any provider
  /// table — the percentage of every future paid appointment fee (or paid
  /// order) that is retained by the platform. Blood banks have none.
  Future<void> updateCommission({
    required String type,
    required int id,
    required double percent,
  }) async {
    return SupabaseService.guard(() async {
      final rows = await _sb
          .db(_providerTable(type))
          .update({'commission_percentage': percent})
          .eq('id', id)
          .select('id');

      if (rows.isEmpty) {
        throw ApiException(message: 'Provider not found.', statusCode: 404);
      }
    });
  }

  /// Read-only oversight: verifying is the provider's decision, not the
  /// admin's, so there is no moderation call here.
  Future<Paged<ProviderPayment>> payments({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String? status,
  }) async {
    return SupabaseService.guard(() async {
      final range = PageRange(page, limit);

      // As in the provider workspace: `payments` has two FKs to `users`
      // (`user_id`, `verified_by`), so the payer is batched rather than
      // embedded. The `appointments` embed itself is unambiguous.
      var query = _sb.db('payments').select(
            'id, appointment_id, user_id, amount, payment_method, '
            'transaction_id, sender_number, payment_status, rejection_reason, '
            'notes, verified_at, admin_share, provider_share, created_at, '
            'appointments!left(appointment_date, appointment_time, status, '
            'confirmation_code)',
          );

      if (_has(status)) query = query.eq('payment_status', status!.trim());

      final res = await query
          .order('created_at', ascending: false)
          .range(range.from, range.to)
          .count(CountOption.exact);

      final payers = await _patients(res.data.map((r) => r['user_id']));

      return Paged(
        items: res.data.map((r) {
          final appointment = r['appointments'] as Map<String, dynamic>?;
          final payer = payers[Fmt.str(r['user_id'])];
          return ProviderPayment.fromJson({
            ...r,
            'appointment_date': appointment?['appointment_date'],
            'appointment_time': appointment?['appointment_time'],
            'appointment_status': appointment?['status'],
            'confirmation_code': appointment?['confirmation_code'],
            'patient_name': payer?['name'],
            'patient_phone': payer?['phone'],
          });
        }).toList(),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  // -- §10.14 Payouts --------------------------------------------------------

  /// The provider payout ledger — what the platform owes each provider after
  /// the commission was cut at verification time. This is the settlement list:
  /// the admin reads `pending` rows, transfers the money offline (bKash/Nagad),
  /// then marks each one paid with [settlePayout]. Written rows are never
  /// edited or deleted — a reversal happens by refunding the appointment.
  Future<Paged<Payout>> payouts({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String? status,
  }) async {
    return SupabaseService.guard(() async {
      final range = PageRange(page, limit);

      // As in the provider workspace, the money source is polymorphic:
      // `payments` (-> appointment) or `orders`, at most one set. The admin
      // also wants the provider's name, so `users` is embedded by its
      // `provider_user_id` FK.
      var query = _sb.db('provider_payouts').select(
            'id, payment_id, order_id, amount, commission_percentage, status, '
            'paid_at, payout_note, created_at, '
            'users!provider_user_id(name), '
            'payments!left(appointment_id, '
            'appointments!left(doctor_name, appointment_date, appointment_time)), '
            'orders!left(order_number, total)',
          );

      if (_has(status)) query = query.eq('status', status!.trim());

      final res = await query
          .order('created_at', ascending: false)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return Paged(
        items: res.data.map((r) => Payout.fromJson(r)).toList(),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  /// Marks a pending payout `paid` — the offline-transfer step. `paid_by` is
  /// the acting admin and `paid_at` the moment they hit the button; `note` is
  /// optional admin text (the provider sees the ledger, not the note). The
  /// `provider_payouts_update_admin` policy and `paid_at`/`paid_by` columns
  /// exist already; this is the first caller.
  Future<void> settlePayout({required int payoutId, String? note}) async {
    return SupabaseService.guard(() async {
      final rows = await _sb
          .db('provider_payouts')
          .update({
            'status': 'paid',
            'paid_at': DateTime.now().toUtc().toIso8601String(),
            'paid_by': _sb.currentUserId,
            if (note != null && note.trim().isNotEmpty)
              'payout_note': note.trim(),
          })
          .eq('id', payoutId)
          .eq('status', 'pending')
          .select('id');

      if (rows.isEmpty) {
        throw ApiException(
          message: 'Payout is no longer pending.',
          statusCode: 409,
        );
      }
    });
  }

  // -------------------------------------------------------------------------
  // Shaping
  // -------------------------------------------------------------------------

  Map<String, dynamic> _shapeUser(Map<String, dynamic> r) => {
        ...r,
        'profile_image':
            _sb.storageHelper.avatar(r['profile_image'] as String?),
      };

  /// Merges a `doctors` row with its owning user into the shape
  /// [AdminProvider.fromJson] and `Doctor.fromJson` read.
  ///
  /// Async only because the credential document has to be signed — see
  /// [_signDocument].
  Future<Map<String, dynamic>> _shapeAdminDoctor(Map<String, dynamic> r) async {
    final user = r['users'] as Map<String, dynamic>?;
    return {
      ...r,
      'name': user?['name'],
      'phone': user?['phone'],
      'email': user?['email'],
      'profile_image':
          _sb.storageHelper.avatar(user?['profile_image'] as String?),
      'specialty': r['specialization'],
      'workplace': r['hospital_clinic_name'],
      // The model reads `bmdc_number`; the column is `bmdc_registration_number`.
      'bmdc_number': r['bmdc_registration_number'],
      'bmdc_certificate': await _signDocument(r['bmdc_certificate']),
      'doctor_email': user?['email'],
    };
  }

  Future<Map<String, dynamic>> _shapeAdminPlace(Map<String, dynamic> r) async {
    final owner = r['users'] as Map<String, dynamic>?;
    return {
      ...r,
      'hours': _hours(r),
      'beds_total': r['total_beds'],
      'is_24h': r['open_24_hours'],
      'owner_email': owner?['email'],
      'license_document': await _signDocument(r['license_document']),
    };
  }

  /// Time-limited URL for a licence or certificate in the PRIVATE
  /// `provider-documents` bucket.
  ///
  /// The bucket is not public, so `getPublicUrl` would hand back a URL that
  /// 400s; signing is the only way the admin sees the credential they are being
  /// asked to check. Five minutes rather than the default minute, because an
  /// admin reads a page of these before deciding.
  ///
  /// Returns '' — the placeholder path — rather than throwing when the object is
  /// missing or the path is a PHP-era relative one. A single stale
  /// `license_document` must not empty the whole moderation queue, which is the
  /// one screen that unblocks every new provider.
  Future<String> _signDocument(Object? path) async {
    final p = Fmt.str(path).trim();
    if (p.isEmpty || p.startsWith('uploads/')) return '';
    if (p.startsWith('http://') || p.startsWith('https://')) return p;

    try {
      return await _sb.storageHelper.signedUrl(
        AppConfig.bucketProviderDocuments,
        p,
        expiresInSeconds: 300,
      );
    } on ApiException {
      return '';
    }
  }

  String? _hours(Map<String, dynamic> r) {
    if (Fmt.toBool(r['open_24_hours'])) return 'Open 24 hours';
    final from = Fmt.str(r['opening_time']);
    final to = Fmt.str(r['closing_time']);
    if (from.isEmpty || to.isEmpty) return null;
    return '${Fmt.time(from)} – ${Fmt.time(to)}';
  }

  Map<String, dynamic> _shapeAppointment(
    Map<String, dynamic> r,
    Map<String, Map<String, dynamic>> patients,
  ) {
    final doctor = r['doctors'] as Map<String, dynamic>?;
    final doctorUser = doctor?['users'] as Map<String, dynamic>?;
    final patient = patients[Fmt.str(r['patient_id'])];
    return {
      ...r,
      'doctor_name': Fmt.str(doctorUser?['name'], 'Doctor'),
      'doctor_specialty': doctor?['specialization'],
      'doctor_image':
          _sb.storageHelper.avatar(doctorUser?['profile_image'] as String?),
      'clinic_name': doctor?['hospital_clinic_name'],
      'clinic_address': doctor?['chamber_address'],
      'patient_name': patient?['name'],
      'patient_phone': patient?['phone'],
    };
  }

  /// Translates the row into the console's vocabulary and synthesises
  /// `responded_at`, which this schema does not store.
  Map<String, dynamic> _shapeFeedback(Map<String, dynamic> r) {
    final hasResponse = Fmt.str(r['admin_response']).isNotEmpty;
    return {
      ...r,
      'status': _statusToUi(Fmt.str(r['status'], 'new')),
      'priority': _priorityToUi(Fmt.str(r['priority'], 'normal')),
      // The nearest true value: `feedback_set_updated_at` stamps `updated_at`
      // on the write that added the response. Null when there is no response,
      // so the UI never shows a reply time for an unanswered ticket.
      'responded_at': hasResponse ? r['updated_at'] : null,
    };
  }

  /// Unpivots the eight stock columns into the group→units map the UI edits.
  Map<String, dynamic> _shapeBank(Map<String, dynamic> r) {
    final stock = <String, int>{};
    var total = 0;
    _bloodColumns.forEach((group, column) {
      final units = Fmt.toInt(r[column]);
      stock[group] = units;
      total += units;
    });
    return {...r, 'stock': stock, 'total_units': total};
  }

  Map<String, dynamic> _shapeBlog(Map<String, dynamic> r) => {
        ...r,
        // The model reads `image`; the column is `cover_image` and holds an
        // object path in the public `blog-covers` bucket.
        'image': _sb.storageHelper.blogCover(r['cover_image'] as String?),
      };

  Map<String, dynamic> _shapeAudit(Map<String, dynamic> r) {
    final actor = r['users'] as Map<String, dynamic>?;
    final details = r['details'];
    return {
      ...r,
      'user_name': actor?['name'],
      'user_email': actor?['email'],
      'user_role': actor?['role'],
      // `details` is jsonb. Encoding it keeps the rendered text valid JSON
      // rather than Dart's Map.toString(), which is not parseable.
      'details': details == null
          ? null
          : (details is String ? details : jsonEncode(details)),
    };
  }

  // -------------------------------------------------------------------------
  // Audit summary
  // -------------------------------------------------------------------------

  /// Whole-log aggregates. The three counts are exact; the dropdown values come
  /// from a capped recent sample (see the library doc).
  Future<AuditSummary> _auditSummary() async {
    final inserts = await _total(_sb
        .db('app_audit_log')
        .select('id')
        .inFilter('action', ['create', 'insert', 'register']));
    final updates = await _total(_sb
        .db('app_audit_log')
        .select('id')
        .inFilter('action', ['update', 'edit']));
    final deletes = await _total(_sb
        .db('app_audit_log')
        .select('id')
        .inFilter('action', ['delete', 'remove']));

    final sample = await _sb
        .db('app_audit_log')
        .select('action, entity, created_at')
        .order('created_at', ascending: false)
        .limit(_auditSampleSize);

    final entities = <String>{};
    final actions = <String>{};
    for (final r in sample) {
      final e = Fmt.str(r['entity']);
      final a = Fmt.str(r['action']);
      if (e.isNotEmpty) entities.add(e);
      if (a.isNotEmpty) actions.add(a);
    }

    final sortedEntities = entities.toList()..sort();
    final sortedActions = actions.toList()..sort();

    return AuditSummary.fromEnvelope({
      'summary': {
        'inserts': inserts,
        'updates': updates,
        'deletes': deletes,
        'tracked_entities': sortedEntities.length,
        'latest_activity': sample.isEmpty ? null : sample.first['created_at'],
      },
      'filters': {'entities': sortedEntities, 'actions': sortedActions},
    });
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// An exact count without pulling the rows: `limit(1)` keeps the payload to a
  /// single row while `CountOption.exact` still reports the full total.
  ///
  /// Takes the already-filtered query rather than a table name and a callback,
  /// so each call site reads as the query it is counting.
  static Future<int> _total(
    PostgrestTransformBuilder<PostgrestList> query,
  ) async {
    final res = await query.limit(1).count(CountOption.exact);
    return res.count;
  }

  /// uuid -> `users` row, for a page of appointments or payments. Admins may
  /// read every user through `users_select_admin`.
  Future<Map<String, Map<String, dynamic>>> _patients(
    Iterable<Object?> ids,
  ) async {
    final unique = <String>{
      for (final id in ids)
        if (Fmt.str(id).isNotEmpty) Fmt.str(id),
    }.toList();

    if (unique.isEmpty) return const {};

    final rows =
        await _sb.db('users').select('id, name, phone').inFilter('id', unique);

    return {for (final r in rows) Fmt.str(r['id']): r};
  }

  /// Resolves a name search to patient uuids and doctor ids.
  ///
  /// Capped at 200 matching users: a one-letter search would otherwise put every
  /// user id in the URL and blow past the request-line limit. A name specific
  /// enough to be worth searching for lands well inside that.
  Future<({List<String> patients, List<int> doctors})> _appointmentSearchIds(
    String search,
  ) async {
    final matched = await _sb
        .db('users')
        .select('id')
        .ilike('name', '%${_escapeLike(search)}%')
        .limit(200);

    final userIds =
        matched.map((r) => Fmt.str(r['id'])).where((s) => s.isNotEmpty).toList();

    if (userIds.isEmpty) return (patients: <String>[], doctors: <int>[]);

    // Which of those users are doctors — those match on the doctor side.
    final doctors =
        await _sb.db('doctors').select('id').inFilter('user_id', userIds);

    return (
      patients: userIds,
      doctors: doctors.map((r) => Fmt.toInt(r['id'])).toList(),
    );
  }

  /// A URL-safe slug that no other post holds.
  ///
  /// `uq_blog_slug` is a hard constraint, so a collision would surface as a 409
  /// on save; this appends `-2`, `-3`, … exactly as the PHP did.
  Future<String> _uniqueSlug(String title, {int? excludeId}) async {
    final base = _slugify(title);
    var candidate = base;
    var suffix = 1;

    // Bounded: a title with 50 collisions is pathological, and looping forever
    // on a misbehaving query would hang the save.
    while (suffix < 50) {
      var query = _sb.db('blogs').select('id').eq('slug', candidate);
      if (excludeId != null) query = query.neq('id', excludeId);

      final clash = await query.limit(1).maybeSingle();
      if (clash == null) return candidate;

      suffix++;
      candidate = '$base-$suffix';
    }

    // Fall back to something certainly unique rather than failing the save.
    return '$base-${DateTime.now().millisecondsSinceEpoch}';
  }

  static String _slugify(String title) {
    final slug = title
        .toLowerCase()
        .replaceAll(RegExp(r"['’]"), '')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    // `slug` is NOT NULL varchar(200); an all-punctuation or non-Latin title
    // would otherwise reduce to an empty string and violate the constraint.
    if (slug.isEmpty) return 'post-${DateTime.now().millisecondsSinceEpoch}';
    return slug.length > 180 ? slug.substring(0, 180) : slug;
  }

  static String _providerTable(String type) {
    switch (type) {
      case 'doctors':
      case 'hospitals':
      case 'clinics':
      case 'pharmacies':
        return type;
      default:
        throw ApiException(
          message: 'Unknown provider type "$type".',
          statusCode: 400,
        );
    }
  }

  // -- feedback vocabulary ---------------------------------------------------

  /// Console word -> `feedback_status` enum value.
  static String _statusToDb(String status) =>
      status.trim() == 'pending' ? 'new' : status.trim();

  /// `feedback_status` enum value -> console word.
  static String _statusToUi(String status) =>
      status == 'new' ? 'pending' : status;

  /// Console word -> `feedback_priority` enum value.
  static String _priorityToDb(String priority) =>
      priority.trim() == 'medium' ? 'normal' : priority.trim();

  /// `feedback_priority` enum value -> console word.
  static String _priorityToUi(String priority) =>
      priority == 'normal' ? 'medium' : priority;

  // -- misc ------------------------------------------------------------------

  /// Start of the following day, so a `date_to` filter includes that whole day.
  static String _endOfDay(String date) {
    final parsed = DateTime.tryParse(date);
    if (parsed == null) return date;
    return DateTime(parsed.year, parsed.month, parsed.day)
        .add(const Duration(days: 1))
        .toIso8601String();
  }

  static bool _has(String? v) => v != null && v.trim().isNotEmpty;

  static String? _nullIfEmpty(String? v) {
    final s = Fmt.str(v).trim();
    return s.isEmpty ? null : s;
  }

  /// Commas and parentheses are the `or=` grammar's own delimiters, so they must
  /// not reach it from user input.
  static String _escapeOr(String term) =>
      term.replaceAll(RegExp(r'[,()]'), ' ').replaceAll('*', '');

  static String _escapeLike(String term) =>
      term.replaceAll('%', '').replaceAll('_', '');
}

final adminRepositoryProvider = Provider<AdminRepository>(
  (ref) => AdminRepository(ref.watch(supabaseServiceProvider)),
);
