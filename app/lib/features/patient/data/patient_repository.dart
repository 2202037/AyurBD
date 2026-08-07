/// Patient dashboard (§5.1), my reviews (§5.6), nearby services (§5.8) and
/// emergency assistance (§5.9) — from Supabase.
///
/// Booking, payments, pharmacy and blood bank live in their own feature
/// repositories; this covers what was left over.
///
/// Public surface is unchanged: `dashboard()`, `myReviews()`, `nearby()`,
/// `hotlines()`, `sendEmergency()`.
///
/// Two notes.
///
/// **Dashboard stats.** The PHP ran seven `SELECT COUNT(*)` queries, and the
/// first port here read every appointment and tallied in Dart — which
/// downloaded unbounded rows to render a few numbers. Now the `my_stats`
/// SECURITY DEFINER function returns all the tallies in one row, computed with
/// correlated subqueries; the unread-notification count is still a real count
/// query because that table can grow without bound. Note `my_stats` reports
/// `unpaid_appointments` (booked but not paid, excluding cancelled) rather than
/// pending *submissions* — the dashboard's "action needed" number.
///
/// **Review status notes.** `reviews` has no `status_note` column; the old API
/// authored that sentence per row. [_statusNote] reproduces it so the UI still
/// explains why a pending or rejected review is not public.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show CountOption;

import '../../../core/constants/app_config.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/api_result.dart';
import '../../../core/network/supabase_service.dart';
import '../../../core/providers.dart';
import '../../../core/utils/formatters.dart';
import '../../../models/patient_models.dart';

class PatientRepository {
  PatientRepository(this._sb);

  final SupabaseService _sb;

  // -- §5.1 Dashboard ------------------------------------------------------

  Future<PatientDashboard> dashboard() async {
    return SupabaseService.guard(() async {
      final userId = _requireUser();

      // `my_stats()` is set-returning, so PostgREST hands back a one-row array.
      // A missing profile row (impossible once signed in) yields an empty array,
      // and the empty map makes every tally read 0 rather than throw.
      final statsRows = await _sb.rpc<List<dynamic>>('my_stats');
      final statsRow = statsRows.isEmpty
          ? const <String, dynamic>{}
          : (statsRows.first as Map<String, dynamic>);

      final unread = await _sb
          .db('notifications')
          .select('id')
          .eq('user_id', userId)
          .eq('is_read', false)
          .count(CountOption.exact);

      // Future, non-cancelled appointments only — a cancelled future booking is
      // not something the patient needs to prepare for.
      final upcoming = await _sb
          .db('appointments')
          .select('id, patient_id, doctor_id, appointment_date, '
              'appointment_time, type, symptoms, fee, status, payment_status, '
              'confirmation_code, created_at, '
              'doctors!left(specialization, hospital_clinic_name, '
              'chamber_address, users!left(name, profile_image))')
          .eq('patient_id', userId)
          .neq('status', 'cancelled')
          .gte('appointment_date', Fmt.apiDate(DateTime.now()))
          .order('appointment_date', ascending: true)
          .order('appointment_time', ascending: true)
          .limit(5);

      final recent = await _sb
          .db('reviews')
          .select('id, reviewable_type, reviewable_id, rating, comment, '
              'status, created_at')
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .limit(5);

      return PatientDashboard.fromJson({
        'stats': {
          'total_appointments': statsRow['appointments_total'],
          'pending_appointments': statsRow['appointments_pending'],
          'confirmed_appointments': statsRow['appointments_confirmed'],
          'completed_appointments': statsRow['appointments_completed'],
          'cancelled_appointments': statsRow['appointments_cancelled'],
          'pending_payments': statsRow['unpaid_appointments'],
          'unread_notifications': unread.count,
        },
        'upcoming_appointments': upcoming.map(_shapeAppointment).toList(),
        // The dashboard's recent_reviews deliberately skips the target-name
        // lookup, as before — MyReview.displayTarget falls back to type + id.
        'recent_reviews': recent.map((r) => _shapeReview(r, null)).toList(),
      });
    });
  }

  // -- §5.6 My reviews -----------------------------------------------------

  /// Includes the patient's pending and rejected reviews — each row carries a
  /// `status_note` explaining why it is not public.
  ///
  /// Unfiltered by design: every review this user wrote, newest first. Filter by
  /// status client-side if a screen needs tabs.
  Future<Paged<MyReview>> myReviews({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
  }) async {
    return SupabaseService.guard(() async {
      final userId = _requireUser();
      final range = PageRange(page, limit);

      final res = await _sb
          .db('reviews')
          .select('id, reviewable_type, reviewable_id, rating, comment, '
              'status, created_at')
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .range(range.from, range.to)
          .count(CountOption.exact);

      // Reviews are polymorphic with no FK, so the target name cannot be an
      // embed. Names are fetched per type in one query each — at most four for
      // the whole page, never one per row.
      final names = await _targetNames(res.data);

      return Paged(
        items: res.data
            .map((r) => MyReview.fromJson(
                  _shapeReview(r, names['${r['reviewable_type']}:${r['reviewable_id']}']),
                ))
            .toList(),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  // -- §5.8 Nearby ---------------------------------------------------------

  /// City/area text search across all four provider kinds at once.
  ///
  /// [type] is all | doctor | hospital | clinic | pharmacy. There is no radius
  /// or distance: nothing in this schema stores coordinates.
  ///
  /// Backed by the `provider_search` view, which is what makes a single paginated
  /// list across four tables possible. The view carries no phone, address or
  /// subtitle, so those are filled in by [_enrich] from the underlying tables —
  /// otherwise the call button and the specialisation line would vanish from the
  /// cards.
  Future<Paged<NearbyResult>> nearby({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String type = 'all',
    String? city,
    String? search,
  }) async {
    return SupabaseService.guard(() async {
      final range = PageRange(page, limit);

      var query = _sb
          .db('provider_search')
          .select('provider_type, id, name, city, area, rating, '
              'total_reviews, image')
          // The view does not filter on status — RLS does for anon callers, but
          // stating it here keeps the count honest for every caller.
          .eq('status', 'active')
          .eq('verification_status', 'verified');

      if (type != 'all' && type.trim().isNotEmpty) {
        query = query.eq('provider_type', type.trim());
      }
      if (_has(city)) query = query.ilike('city', '%${_escapeLike(city!.trim())}%');

      if (_has(search)) {
        final term = _escapeOr(search!.trim());
        query = query.or(
          'name.ilike.%$term%,'
          'city.ilike.%$term%,'
          'area.ilike.%$term%',
        );
      }

      final res = await query
          .order('rating', ascending: false)
          .order('name', ascending: true)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return Paged(
        items: await _enrich(res.data),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  // -- §5.9 Emergency ------------------------------------------------------

  /// Public — no session needed. Someone who needs an ambulance should not have
  /// to sign in first, so this must stay callable from a signed-out state.
  Future<List<Hotline>> hotlines() async {
    return SupabaseService.guard(() async {
      final rows = await _sb
          .db('emergency_hotlines')
          .select('id, name, phone, category, description, sort_order')
          .eq('status', 'active')
          .order('sort_order', ascending: true)
          .order('id', ascending: true);

      return rows.map(Hotline.fromJson).toList();
    });
  }

  /// Records an emergency request. It is NOT transmitted: no SMS gateway is
  /// configured, so the row stays `queued` and `delivered` is false. Keep telling
  /// the user to call the hotline as well — on this screen a false "sent!" is the
  /// one failure mode that could get somebody hurt.
  ///
  /// `emergency_sms.user_id` is nullable, so a signed-out caller can still file
  /// one. `status` is left to its `queued` default.
  ///
  /// Latitude and longitude are accepted even though no provider table stores
  /// coordinates — `emergency_sms` has its own columns, so a responder reading
  /// the record gets the caller's position.
  Future<EmergencyRequest> sendEmergency({
    required String senderPhone,
    required String recipientPhone,
    required String message,
    String? location,
    double? latitude,
    double? longitude,
  }) async {
    return SupabaseService.guard(() async {
      final userId = _sb.currentUserId;

      final row = await _sb.db('emergency_sms').insert({
        if (userId != null && userId.isNotEmpty) 'user_id': userId,
        'sender_phone': senderPhone.trim(),
        'recipient_phone': recipientPhone.trim(),
        'message': message.trim(),
        'location': _nullIfEmpty(location),
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
      }).select('id, status').single();

      return EmergencyRequest.fromJson({
        ...row,
        // Nothing was transmitted, and the model's own wording says so when
        // `delivered` is false and no message is supplied.
        'delivered': false,
      });
    });
  }

  // -------------------------------------------------------------------------
  // Shaping
  // -------------------------------------------------------------------------

  Map<String, dynamic> _shapeAppointment(Map<String, dynamic> r) {
    final doctor = r['doctors'] as Map<String, dynamic>?;
    final user = doctor?['users'] as Map<String, dynamic>?;
    return {
      ...r,
      'doctor_name': Fmt.str(user?['name'], 'Doctor'),
      'doctor_specialty': doctor?['specialization'],
      'doctor_image': _sb.storageHelper.avatar(user?['profile_image'] as String?),
      'clinic_name': doctor?['hospital_clinic_name'],
      'clinic_address': doctor?['chamber_address'],
    };
  }

  Map<String, dynamic> _shapeReview(Map<String, dynamic> r, String? targetName) => {
        ...r,
        'status_note': _statusNote(Fmt.str(r['status'], 'pending')),
        'target_name': targetName,
      };

  /// Why the review is not visible. Null when approved, as before.
  static String? _statusNote(String status) {
    switch (status) {
      case 'pending':
        return 'This review is waiting to be checked before it appears publicly.';
      case 'rejected':
        return 'This review was not published because it did not meet the '
            'community guidelines.';
      default:
        return null;
    }
  }

  /// Resolves `type:id` -> display name for a page of reviews.
  Future<Map<String, String>> _targetNames(
    List<Map<String, dynamic>> reviews,
  ) async {
    final byType = <String, Set<int>>{};
    for (final r in reviews) {
      final type = Fmt.str(r['reviewable_type']);
      final id = Fmt.toInt(r['reviewable_id']);
      if (type.isEmpty || id == 0) continue;
      byType.putIfAbsent(type, () => <int>{}).add(id);
    }

    final out = <String, String>{};

    for (final entry in byType.entries) {
      final table = _tableFor(entry.key);
      if (table == null) continue;

      // A doctor's name lives on `users`, so the directory view is used for
      // doctors and the table itself for the three place kinds.
      final isDoctor = entry.key == 'doctor';
      final rows = await _sb
          .db(isDoctor ? 'doctor_directory' : table)
          .select('id, name')
          .inFilter('id', entry.value.toList());

      for (final row in rows) {
        final name = Fmt.str(row['name']);
        if (name.isEmpty) continue;
        out['${entry.key}:${Fmt.toInt(row['id'])}'] = name;
      }
    }

    return out;
  }

  /// Fills in the fields `provider_search` does not carry.
  Future<List<NearbyResult>> _enrich(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return const [];

    final byType = <String, Set<int>>{};
    for (final r in rows) {
      final type = Fmt.str(r['provider_type']);
      final id = Fmt.toInt(r['id']);
      if (type.isEmpty || id == 0) continue;
      byType.putIfAbsent(type, () => <int>{}).add(id);
    }

    // `type:id` -> {subtitle, address, phone}
    final extra = <String, Map<String, dynamic>>{};

    for (final entry in byType.entries) {
      final ids = entry.value.toList();

      switch (entry.key) {
        case 'doctor':
          final found = await _sb
              .db('doctor_directory')
              .select('id, specialization, chamber_address, phone')
              .inFilter('id', ids);
          for (final f in found) {
            extra['doctor:${Fmt.toInt(f['id'])}'] = {
              'subtitle': f['specialization'],
              'address': f['chamber_address'],
              'phone': f['phone'],
            };
          }
        case 'hospital':
          final found = await _sb
              .db('hospitals')
              .select('id, hospital_type, address, phone')
              .inFilter('id', ids);
          for (final f in found) {
            extra['hospital:${Fmt.toInt(f['id'])}'] = {
              'subtitle': f['hospital_type'],
              'address': f['address'],
              'phone': f['phone'],
            };
          }
        case 'clinic':
          final found = await _sb
              .db('clinics')
              .select('id, clinic_type, address, phone')
              .inFilter('id', ids);
          for (final f in found) {
            extra['clinic:${Fmt.toInt(f['id'])}'] = {
              'subtitle': f['clinic_type'],
              'address': f['address'],
              'phone': f['phone'],
            };
          }
        case 'pharmacy':
          final found = await _sb
              .db('pharmacies')
              .select('id, pharmacy_type, address, phone')
              .inFilter('id', ids);
          for (final f in found) {
            extra['pharmacy:${Fmt.toInt(f['id'])}'] = {
              'subtitle': f['pharmacy_type'],
              'address': f['address'],
              'phone': f['phone'],
            };
          }
      }
    }

    return rows.map((r) {
      final type = Fmt.str(r['provider_type'], 'doctor');
      final more = extra['$type:${Fmt.toInt(r['id'])}'] ?? const {};
      return NearbyResult.fromJson({
        ...r,
        // The model reads `kind`; the view column is `provider_type`.
        'kind': type,
        'subtitle': more['subtitle'],
        'address': more['address'],
        'phone': more['phone'],
        // Only the doctor branch of the view populates `image`, and it holds an
        // avatars-bucket path.
        'image': _sb.storageHelper.avatar(r['image'] as String?),
      });
    }).toList();
  }

  static String? _tableFor(String reviewableType) {
    switch (reviewableType) {
      case 'doctor':
        return 'doctors';
      case 'hospital':
        return 'hospitals';
      case 'clinic':
        return 'clinics';
      case 'pharmacy':
        return 'pharmacies';
      default:
        return null;
    }
  }

  String _requireUser() {
    final id = _sb.currentUserId;
    if (id == null || id.isEmpty) {
      throw ApiException(
        message: 'Please sign in to continue.',
        statusCode: 401,
      );
    }
    return id;
  }

  static bool _has(String? v) => v != null && v.trim().isNotEmpty;

  static String? _nullIfEmpty(String? v) {
    final s = Fmt.str(v);
    return s.isEmpty ? null : s;
  }

  static String _escapeOr(String term) =>
      term.replaceAll(RegExp(r'[,()]'), ' ').replaceAll('*', '');

  static String _escapeLike(String term) =>
      term.replaceAll('%', '').replaceAll('_', '');
}

final patientRepositoryProvider = Provider<PatientRepository>(
  (ref) => PatientRepository(ref.watch(supabaseServiceProvider)),
);
