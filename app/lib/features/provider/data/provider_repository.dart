/// The doctor, hospital, clinic and pharmacy workspaces (feature.md §6–§9) —
/// from Supabase.
///
/// Public surface is unchanged except for one removal: `verifyPayment()` is
/// gone because payment verification is the ADMIN's job, not the provider's
/// (the `payments_update_doctor` policy no longer exists). The provider's
/// money lives in `provider_payouts` — read by [payouts] — and the booking is
/// confirmed via [setAppointmentStatus] once the payout is credited.
///
/// One repository for all four roles, as before. Nothing here passes a provider
/// id: the row is resolved from `auth.uid()` via the schema's
/// `current_doctor_id()` / `current_pharmacy_id()` helpers and the owner
/// policies, so a doctor calling a place method simply finds no row and gets a
/// 403 — the same outcome the PHP role check produced.
///
/// Three things are worth knowing.
///
/// **The escrow money flow.** The patient pays the platform; the admin
/// verifies the payment (`payments_apply_verification` splits it into the
/// platform commission + the provider's share and writes a `provider_payouts`
/// row); the provider confirms the appointment once their share is credited.
/// [payouts] is the provider's side of that ledger.
///
/// **Profile updates span two tables.** The forms post `name`/`phone`/`gender`
/// (which live on `users`) together with the provider's own columns in one map.
/// [_split] routes each key to the right table and both updates are issued.
///
/// **The forms post strings and 0/1.** Text fields yield `'12'` for an integer
/// column and the 24-hour switch yields `1` for a boolean, both of which
/// Postgres rejects over JSON where the PHP validator coerced them. [_coerce]
/// converts them by column name.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show CountOption;

import '../../../core/constants/app_config.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/api_result.dart';
import '../../../core/network/supabase_service.dart';
import '../../../core/providers.dart';
import '../../../core/utils/formatters.dart';
import '../../../models/appointment_models.dart';
import '../../../models/directory_models.dart';
import '../../../models/provider_models.dart';

class ProviderRepository {
  ProviderRepository(this._sb);

  final SupabaseService _sb;

  /// Columns on `users` rather than on the provider's own table. Everything in a
  /// profile payload that is not in this set belongs to the provider table.
  static const _userColumns = {
    'name',
    'phone',
    'gender',
    'address',
    'profile_image',
  };

  /// Form key -> column, where the two differ.
  static const _fieldAliases = {
    'bmdc_number': 'bmdc_registration_number',
  };

  /// Columns that must be sent as integers.
  static const _intColumns = {
    'graduation_year',
    'experience_years',
    'slot_minutes',
    'total_beds',
    'icu_beds',
    'established_year',
    'delivery_radius_km',
  };

  /// Columns that must be sent as numerics.
  static const _numColumns = {'consultation_fee'};

  /// Columns that must be sent as booleans.
  static const _boolColumns = {
    'open_24_hours',
    'delivery_available',
    'prescription_required',
  };

  /// Never writable by the owner — `aa_guard_*` raises 42501 on any change.
  static const _guardedColumns = {
    'verification_status',
    'status',
    'rating',
    'total_reviews',
    'role',
    'email',
  };

  /// No `users` embed here on purpose. `appointments` has TWO foreign keys to
  /// `users` — `patient_id` and `payment_verified_by` — so `users(...)` is
  /// ambiguous and PostgREST refuses the request rather than guessing. The
  /// patient's name is attached by [_patients] in a second, batched query
  /// instead, which is unambiguous and costs one round trip per page.
  static const _appointmentColumns = 'id, patient_id, doctor_id, '
      'appointment_date, appointment_time, type, symptoms, notes, fee, status, '
      'payment_status, confirmation_code, created_at';

  static const _doctorColumns = 'id, user_id, bmdc_registration_number, '
      'bmdc_certificate, specialization, qualifications, medical_school, '
      'graduation_year, experience_years, doctor_type, hospital_clinic_name, '
      'chamber_address, city, area, consultation_fee, bio, rating, '
      'total_reviews, verification_status, status, available_days, '
      'available_from, available_to, slot_minutes';

  // -- §6 Doctor -----------------------------------------------------------

  Future<DoctorDashboard> doctorDashboard() async {
    return SupabaseService.guard(() async {
      final doctor = await _requireDoctor();
      final doctorId = Fmt.toInt(doctor['id']);

      // The doctor's own user row, for the name/phone the profile form seeds.
      final user = await _sb
          .db('users')
          .select('name, phone, email, profile_image, gender, address')
          .eq('id', doctor['user_id'])
          .maybeSingle();

      // `doctor_stats()` is set-returning, so PostgREST hands back a one-row
      // array. It returns the appointment tallies, payment counts and revenue
      // in one row — no more downloading every appointment to count it.
      final statsRows = await _sb.rpc<List<dynamic>>('doctor_stats');
      final s = statsRows.isEmpty
          ? const <String, dynamic>{}
          : (statsRows.first as Map<String, dynamic>);

      final today = Fmt.apiDate(DateTime.now());

      // The two figures doctor_stats cannot express need date arithmetic, so
      // they are real (bounded) count queries over the same filters the old
      // loop applied: today's non-cancelled appointments, and future
      // non-cancelled ones.
      final todayRes = await _sb
          .db('appointments')
          .select('id')
          .eq('doctor_id', doctorId)
          .neq('status', 'cancelled')
          .eq('appointment_date', today)
          .count(CountOption.exact);

      final upcomingRes = await _sb
          .db('appointments')
          .select('id')
          .eq('doctor_id', doctorId)
          .neq('status', 'cancelled')
          .gt('appointment_date', today)
          .count(CountOption.exact);

      final recent = await _sb
          .db('appointments')
          .select(_appointmentColumns)
          .eq('doctor_id', doctorId)
          .order('created_at', ascending: false)
          .limit(5);

      final patients = await _patients(recent.map((r) => r['patient_id']));

      return DoctorDashboard.fromJson({
        'stats': {
          'total_appointments': s['appointments_total'],
          'pending_appointments': s['appointments_pending'],
          'confirmed_appointments': s['appointments_confirmed'],
          'completed_appointments': s['appointments_completed'],
          'cancelled_appointments': s['appointments_cancelled'],
          'today_appointments': todayRes.count,
          'upcoming_appointments': upcomingRes.count,
          // Revenue counts PAID appointments (doctor_stats), which is subtly
          // different from summing verified payment rows: a refund moves the
          // appointment off 'paid', so refunded money stops counting here.
          'total_earnings': s['revenue'],
          'pending_payments': s['payments_pending'],
          // The escrow balance: what the platform owes the doctor right now,
          // and the platform's own retained fee on their verified payments.
          'pending_payout': s['pending_payout'],
          'platform_fee': s['platform_fee'],
        },
        'verification_status': doctor['verification_status'],
        'status': doctor['status'],
        'doctor': _shapeDoctor(doctor, user),
        'recent_appointments':
            recent.map((r) => _shapeAppointment(r, patients)).toList(),
      });
    });
  }

  /// [status] is pending | confirmed | completed | cancelled; [date] is a single
  /// day, `yyyy-MM-dd`. Both optional, and they combine.
  Future<Paged<Appointment>> doctorAppointments({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String? status,
    String? date,
  }) async {
    return SupabaseService.guard(() async {
      final doctorId = Fmt.toInt((await _requireDoctor())['id']);
      final range = PageRange(page, limit);

      var query = _sb
          .db('appointments')
          .select(_appointmentColumns)
          .eq('doctor_id', doctorId);

      if (_has(status)) query = query.eq('status', status!.trim());
      if (_has(date)) query = query.eq('appointment_date', date!.trim());

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

  /// Confirm / complete / cancel. Returns the updated row so a list can replace
  /// one item instead of refetching the page.
  ///
  /// Confirming is what mints the confirmation code — the
  /// `appointments_set_confirmation_code` trigger fires on the transition — so
  /// the returned row can carry a code the caller did not have before.
  ///
  /// `notes` is the doctor's own field; `fee` and the payment columns are
  /// deliberately never sent, because `aa_guard_appointments` rejects them.
  Future<Appointment> setAppointmentStatus({
    required int appointmentId,
    required String status,
    String? notes,
  }) async {
    return SupabaseService.guard(() async {
      final doctorId = Fmt.toInt((await _requireDoctor())['id']);

      final row = await _sb
          .db('appointments')
          .update({
            'status': status,
            if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
          })
          .eq('id', appointmentId)
          .eq('doctor_id', doctorId)
          .select(_appointmentColumns)
          .maybeSingle();

      if (row == null) {
        throw ApiException(message: 'Appointment not found.', statusCode: 404);
      }

      final patients = await _patients([row['patient_id']]);
      return Appointment.fromJson(_shapeAppointment(row, patients));
    });
  }

  /// The provider's payout ledger (`provider_payouts`) — the "money account"
  /// of the escrow flow. Rows are written by the verification triggers when a
  /// payment is verified (or a paid order settles): the amount is the
  /// provider's share, after the platform commission was cut.
  ///
  /// Defaults to `pending` because that is the balance the provider acts on;
  /// pass `'all'` for the full history.
  Future<Paged<Payout>> payouts({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String status = 'pending',
  }) async {
    return SupabaseService.guard(() async {
      final providerUserId = _requireUser();
      final range = PageRange(page, limit);

      // `provider_payouts` links to `payments` (-> appointment) and `orders`
      // (-> pharmacy), at most one of which is set. The embeds are
      // unambiguous: `payments` -> `appointments` is the only FK, and
      // `orders` has a single FK to `users` which is not embedded.
      var query = _sb.db('provider_payouts').select(
            'id, payment_id, order_id, amount, commission_percentage, status, '
            'paid_at, payout_note, created_at, '
            'payments!left(appointment_id, '
            'appointments!left(doctor_name, appointment_date, appointment_time)), '
            'orders!left(order_number, total)',
          )
          .eq('provider_user_id', providerUserId);

      if (status != 'all' && status.trim().isNotEmpty) {
        query = query.eq('status', status.trim());
      }

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

  /// Partial update: only the keys present are written. Callers pass a map so
  /// one method serves the whole multi-section profile form without a
  /// twenty-argument signature.
  ///
  /// Spans both `users` (name, phone, gender, address, profile_image) and
  /// `doctors` (BMDC details, specialisation, fees, chamber, schedule).
  /// Admin-only columns are dropped rather than sent, so a stray
  /// `verification_status` in a payload cannot turn every save into a 403.
  Future<Doctor> updateDoctorProfile(Map<String, Object?> fields) async {
    return SupabaseService.guard(() async {
      final doctor = await _requireDoctor();
      final userId = doctor['user_id'] as String;

      final split = _split(_clean(fields));

      if (split.user.isNotEmpty) {
        await _sb.db('users').update(split.user).eq('id', userId);
      }

      Map<String, dynamic> updated;
      if (split.own.isNotEmpty) {
        updated = await _sb
            .db('doctors')
            .update(split.own)
            .eq('user_id', userId)
            .select(_doctorColumns)
            .single();
      } else {
        updated = await _sb
            .db('doctors')
            .select(_doctorColumns)
            .eq('user_id', userId)
            .single();
      }

      final user = await _sb
          .db('users')
          .select('name, phone, email, profile_image, gender, address')
          .eq('id', userId)
          .maybeSingle();

      return Doctor.fromJson(_shapeDoctor(updated, user));
    });
  }

  // -- §7–9 Hospital / clinic / pharmacy -----------------------------------

  Future<PlaceDashboard> placeDashboard() async {
    return SupabaseService.guard(() async {
      final place = await _requirePlace();
      final kind = place.kind;
      final row = place.row;
      final id = Fmt.toInt(row['id']);

      final owner = await _sb
          .db('users')
          .select('name, email')
          .eq('id', row['user_id'])
          .maybeSingle();

      // Reviews about this place. `reviews_select_target_owner` makes pending
      // and rejected rows visible to their subject, which is what lets the
      // counts below distinguish the three states.
      final reviews = await _sb
          .db('reviews')
          .select('status')
          .eq('reviewable_type', kind.name)
          .eq('reviewable_id', id);

      var pendingReviews = 0, approvedReviews = 0;
      for (final r in reviews) {
        switch (Fmt.str(r['status'], 'pending')) {
          case 'pending':
            pendingReviews++;
          case 'approved':
            approvedReviews++;
        }
      }

      final stats = <String, dynamic>{
        'total_reviews': reviews.length,
        'pending_reviews': pendingReviews,
        'approved_reviews': approvedReviews,
        'rating': row['rating'],
      };

      if (kind == PlaceKind.pharmacy) {
        // Products, orders and revenue. Only paid orders count as revenue, for
        // the same reason unverified payments are not earnings.
        final products = await _sb
            .db('pharmacy_products')
            .select('id')
            .eq('pharmacy_id', id)
            .count(CountOption.exact);

        final orders = await _sb
            .db('orders')
            .select('total, payment_status')
            .eq('pharmacy_id', id);

        var revenue = 0.0;
        for (final o in orders) {
          if (Fmt.str(o['payment_status']) == 'paid') {
            revenue += Fmt.toDouble(o['total']);
          }
        }

        stats['total_products'] = products.count;
        stats['total_orders'] = orders.length;
        stats['total_revenue'] = revenue;
      } else {
        // Doctors link to a workplace by free-text name in this schema, not a
        // foreign key, so this counts who lists this name — which is not quite
        // the same as "doctors here", and the model's doc says so.
        final name = Fmt.str(row['name']);
        if (name.isEmpty) {
          stats['linked_doctors'] = 0;
        } else {
          final linked = await _sb
              .db('doctors')
              .select('id')
              .eq('hospital_clinic_name', name)
              .count(CountOption.exact);
          stats['linked_doctors'] = linked.count;
        }
      }

      return PlaceDashboard.fromJson({
        'type': kind.name,
        'verification_status': row['verification_status'],
        'status': row['status'],
        'stats': stats,
        'profile': _shapePlace(row),
        'owner': {'name': owner?['name'], 'email': owner?['email']},
      });
    });
  }

  /// Partial update for a hospital, clinic or pharmacy profile.
  ///
  /// The writable columns differ per role — a hospital takes `total_beds` and
  /// `emergency_phone`, a pharmacy takes `delivery_available` and
  /// `drug_license_number` — and `open_24_hours` exists on hospital and pharmacy
  /// but NOT on clinic. The PHP whitelist dropped a foreign field silently;
  /// here [_columnsFor] does the same, because sending a column the table does
  /// not have is a hard Postgrest error rather than a no-op.
  ///
  /// [kind] is still accepted for signature compatibility, but the row is found
  /// from the caller's own ownership — a mismatch would mean writing someone
  /// else's table, so the resolved kind wins.
  Future<Place> updatePlaceProfile(
    Map<String, Object?> fields, {
    required PlaceKind kind,
  }) async {
    return SupabaseService.guard(() async {
      final place = await _requirePlace();
      final resolved = place.kind;
      final userId = place.row['user_id'] as String;

      final split = _split(_clean(fields));

      if (split.user.isNotEmpty) {
        await _sb.db('users').update(split.user).eq('id', userId);
      }

      // Keep only columns this table actually has.
      final allowed = _columnsFor(resolved);
      final patch = <String, dynamic>{
        for (final e in split.own.entries)
          if (allowed.contains(e.key)) e.key: e.value,
      };

      Map<String, dynamic> updated;
      if (patch.isNotEmpty) {
        updated = await _sb
            .db(resolved.listKey)
            .update(patch)
            .eq('user_id', userId)
            .select()
            .single();
      } else {
        updated = place.row;
      }

      return Place.fromJson(_shapePlace(updated), resolved);
    });
  }

  // -- §6–9 Reviews about me -----------------------------------------------

  /// Includes pending reviews, so a provider sees what is about to go public.
  Future<Paged<ProviderReview>> reviews({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String? status,
  }) async {
    return SupabaseService.guard(() async {
      final target = await _currentTarget();
      final range = PageRange(page, limit);

      var query = _sb
          .db('reviews')
          .select('id, rating, comment, status, created_at, '
              'users!left(name, profile_image)')
          .eq('reviewable_type', target.type)
          .eq('reviewable_id', target.id);

      if (_has(status)) query = query.eq('status', status!.trim());

      final res = await query
          .order('created_at', ascending: false)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return Paged(
        items: res.data.map((r) {
          final author = r['users'] as Map<String, dynamic>?;
          return ProviderReview.fromJson({
            ...r,
            'reviewer_name': author?['name'],
            'reviewer_image':
                _sb.storageHelper.avatar(author?['profile_image'] as String?),
          });
        }).toList(),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  // -------------------------------------------------------------------------
  // Ownership resolution
  // -------------------------------------------------------------------------

  /// The caller's own `doctors` row, or a 403.
  Future<Map<String, dynamic>> _requireDoctor() async {
    final userId = _requireUser();
    final row = await _sb
        .db('doctors')
        .select(_doctorColumns)
        .eq('user_id', userId)
        .maybeSingle();

    if (row == null) {
      throw ApiException(
        message: 'This area is only available to doctors.',
        statusCode: 403,
      );
    }
    return row;
  }

  /// The caller's own hospital / clinic / pharmacy row, or a 403.
  ///
  /// The three tables are tried in turn rather than trusting a role string: a
  /// user whose `users.role` says 'hospital' but who owns no hospital row would
  /// otherwise produce an empty dashboard instead of a clear refusal.
  Future<_OwnedPlace> _requirePlace() async {
    final userId = _requireUser();

    for (final kind in PlaceKind.values) {
      final row = await _sb
          .db(kind.listKey)
          .select()
          .eq('user_id', userId)
          .maybeSingle();
      if (row != null) return _OwnedPlace(kind, row);
    }

    throw ApiException(
      message: 'This area is only available to registered providers.',
      statusCode: 403,
    );
  }

  /// What this caller is, as a `reviews.reviewable_type` plus the row id.
  Future<({String type, int id})> _currentTarget() async {
    final userId = _requireUser();

    final doctor = await _sb
        .db('doctors')
        .select('id')
        .eq('user_id', userId)
        .maybeSingle();
    if (doctor != null) return (type: 'doctor', id: Fmt.toInt(doctor['id']));

    for (final kind in PlaceKind.values) {
      final row = await _sb
          .db(kind.listKey)
          .select('id')
          .eq('user_id', userId)
          .maybeSingle();
      if (row != null) return (type: kind.name, id: Fmt.toInt(row['id']));
    }

    throw ApiException(
      message: 'This area is only available to registered providers.',
      statusCode: 403,
    );
  }

  // -------------------------------------------------------------------------
  // Shaping
  // -------------------------------------------------------------------------

  /// Merges the doctor row with its owning user row into the shape
  /// [Doctor.fromJson] reads.
  Map<String, dynamic> _shapeDoctor(
    Map<String, dynamic> doctor,
    Map<String, dynamic>? user,
  ) =>
      {
        ...doctor,
        'name': user?['name'],
        'phone': user?['phone'],
        'email': user?['email'],
        'profile_image':
            _sb.storageHelper.avatar(user?['profile_image'] as String?),
        // The model reads `specialty` / `workplace`, not the column names.
        'specialty': doctor['specialization'],
        'workplace': doctor['hospital_clinic_name'],
        'available_days': _splitCsv(doctor['available_days']),
      };

  /// Adds the synthesised fields [Place.fromJson] expects.
  Map<String, dynamic> _shapePlace(Map<String, dynamic> r) => {
        ...r,
        'hours': _hours(r),
        'beds_total': r['total_beds'],
        'is_24h': r['open_24_hours'],
      };

  String? _hours(Map<String, dynamic> r) {
    if (Fmt.toBool(r['open_24_hours'])) return 'Open 24 hours';
    final from = Fmt.str(r['opening_time']);
    final to = Fmt.str(r['closing_time']);
    if (from.isEmpty || to.isEmpty) return null;
    return '${Fmt.time(from)} – ${Fmt.time(to)}';
  }

  /// Flattens the patient onto the keys [Appointment.fromJson] reads.
  ///
  /// The doctor's own name is not attached: this list is the doctor's, and every
  /// row would carry their own name. `doctor_name` therefore falls back to the
  /// model's 'Doctor' default, which no provider screen renders.
  Map<String, dynamic> _shapeAppointment(
    Map<String, dynamic> r,
    Map<String, Map<String, dynamic>> patients,
  ) {
    final patient = patients[Fmt.str(r['patient_id'])];
    return {
      ...r,
      'patient_name': patient?['name'],
      'patient_phone': patient?['phone'],
    };
  }

  /// uuid -> `users` row, for a page of appointments or payments.
  ///
  /// A doctor may read these rows through `users_select_appointment_counterparty`,
  /// which is scoped to the appointment relationship — so this returns the
  /// patients on their own list and nobody else.
  Future<Map<String, Map<String, dynamic>>> _patients(
    Iterable<Object?> ids,
  ) async {
    final unique = <String>{
      for (final id in ids)
        if (Fmt.str(id).isNotEmpty) Fmt.str(id),
    }.toList();

    if (unique.isEmpty) return const {};

    final rows = await _sb
        .db('users')
        .select('id, name, phone')
        .inFilter('id', unique);

    return {for (final r in rows) Fmt.str(r['id']): r};
  }

  // -------------------------------------------------------------------------
  // Payload handling
  // -------------------------------------------------------------------------

  /// Drops nulls so a partial update never blanks a column, trims strings so
  /// " " does not overwrite a real value with whitespace, drops admin-only
  /// columns, applies [_fieldAliases], and coerces types.
  Map<String, dynamic> _clean(Map<String, Object?> fields) {
    final out = <String, dynamic>{};
    fields.forEach((key, value) {
      if (value == null) return;

      final column = _fieldAliases[key] ?? key;
      if (_guardedColumns.contains(column)) return;

      if (value is String) {
        final t = value.trim();
        if (t.isEmpty) return;
        final coerced = _coerce(column, t);
        if (coerced != null) out[column] = coerced;
        return;
      }

      out[column] = _boolColumns.contains(column) ? Fmt.toBool(value) : value;
    });
    return out;
  }

  /// Turns a form string into what the column's type needs.
  ///
  /// Returns null when the value cannot be represented — an unparseable year is
  /// dropped rather than sent, because Postgres would answer 22P02 and the user
  /// would lose the whole save over one bad field.
  static Object? _coerce(String column, String value) {
    if (_intColumns.contains(column)) return int.tryParse(value);
    if (_numColumns.contains(column)) return double.tryParse(value);
    if (_boolColumns.contains(column)) return Fmt.toBool(value);
    return value;
  }

  /// Routes each column to the table that owns it.
  static ({Map<String, dynamic> user, Map<String, dynamic> own}) _split(
    Map<String, dynamic> patch,
  ) {
    final user = <String, dynamic>{};
    final own = <String, dynamic>{};
    patch.forEach((key, value) {
      if (_userColumns.contains(key)) {
        user[key] = value;
      } else {
        own[key] = value;
      }
    });
    return (user: user, own: own);
  }

  /// The writable columns of each place table, so a field belonging to another
  /// kind is dropped instead of erroring.
  static Set<String> _columnsFor(PlaceKind kind) {
    const shared = {
      'name',
      'email',
      'phone',
      'website',
      'address',
      'city',
      'area',
      'description',
      'opening_time',
      'closing_time',
      'established_year',
      'license_number',
      'license_document',
    };

    switch (kind) {
      case PlaceKind.hospital:
        return {
          ...shared,
          'registration_number',
          'emergency_phone',
          'hospital_type',
          'total_beds',
          'icu_beds',
          'facilities',
          'departments',
          'open_24_hours',
        };
      case PlaceKind.clinic:
        return {
          ...shared,
          'registration_number',
          'clinic_type',
          'services',
          'specializations',
          'available_days',
        };
      case PlaceKind.pharmacy:
        return {
          ...shared,
          'drug_license_number',
          'owner_name',
          'pharmacist_name',
          'pharmacist_license',
          'whatsapp',
          'pharmacy_type',
          'services',
          'delivery_available',
          'delivery_radius_km',
          'open_24_hours',
        };
    }
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

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

  static List<String> _splitCsv(Object? v) {
    if (v is List) return v.map((e) => e.toString()).toList();
    final s = Fmt.str(v);
    if (s.isEmpty) return const [];
    return s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }
}

/// A provider row plus which of the three tables it came from.
class _OwnedPlace {
  const _OwnedPlace(this.kind, this.row);

  final PlaceKind kind;
  final Map<String, dynamic> row;
}

final providerRepositoryProvider = Provider<ProviderRepository>(
  (ref) => ProviderRepository(ref.watch(supabaseServiceProvider)),
);
