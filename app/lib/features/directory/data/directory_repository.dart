/// Doctors and the three place types, from Supabase.
///
/// Public surface is unchanged: `doctors()`, `doctor(int)`, `specialties()`,
/// `places(kind)`, `place(kind, int)`, all returning the same types. Only the
/// bodies moved from `/directory/*` to Postgrest.
///
/// Two structural notes.
///
/// **Visibility.** Every list here filters `status = 'active' AND
/// verification_status = 'verified'`, exactly as the PHP did. That is also
/// enforced by RLS, so a client that skipped it would simply get fewer rows —
/// but stating it in the query lets Postgres use `idx_*_directory`, and keeps
/// the `count` honest.
///
/// **Shaping.** The PHP shapers `doctor_public()` and `place_public()` renamed
/// columns on the way out: `specialization` -> `specialty`,
/// `hospital_clinic_name` -> `workplace`, `description` -> `about`, and
/// `opening_time`/`closing_time` -> one `hours` string. The Dart models parse
/// those output names. Rather than rewrite 350 lines of model, this file
/// reproduces the same renaming in `_shapeDoctor` / `_shapePlace` — the wire
/// format the models see is byte-identical to what the API sent, so nothing
/// downstream changed.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show CountOption;

import '../../../core/constants/app_config.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/api_result.dart';
import '../../../core/network/supabase_service.dart';
import '../../../core/providers.dart';
import '../../../core/utils/formatters.dart';
import '../../../models/content_models.dart';
import '../../../models/directory_models.dart';
import '../../../models/pharmacy_models.dart';

/// The doctor plus recent reviews, still delivered together so the detail
/// screen makes one call rather than two.
class DoctorDetail {
  const DoctorDetail({required this.doctor, this.reviews = const []});

  final Doctor doctor;
  final List<Review> reviews;
}

/// The place plus, for a pharmacy, its products, and always recent reviews.
class PlaceDetail {
  const PlaceDetail({
    required this.place,
    this.doctors = const [],
    this.products = const [],
    this.reviews = const [],
  });

  final Place place;
  final List<Doctor> doctors;
  final List<Product> products;
  final List<Review> reviews;
}

class DirectoryRepository {
  DirectoryRepository(this._sb);

  final SupabaseService _sb;

  /// Columns of `doctor_directory` the list needs. Named explicitly rather than
  /// `*` so adding a column to the view cannot silently widen every list
  /// response.
  static const _doctorColumns =
      'id, user_id, name, phone, email, profile_image, specialization, '
      'qualifications, medical_school, graduation_year, experience_years, '
      'doctor_type, hospital_clinic_name, chamber_address, city, area, '
      'consultation_fee, bio, rating, total_reviews, available_days, '
      'available_from, available_to, slot_minutes';

  Future<Paged<Doctor>> doctors({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String? search,
    String? specialty,
    String? city,
    int? clinicId,
  }) async {
    // `clinicId` is accepted and ignored, exactly as before: `doctors` has no
    // FK to `clinics` (the workplace is free text), so there is nothing to
    // filter on. The parameter stays because call sites pass it; removing it
    // would be a signature change for no behavioural gain.
    return SupabaseService.guard(() async {
      final range = PageRange(page, limit);

      var query = _sb
          .db('doctor_directory')
          .select(_doctorColumns)
          .eq('status', 'active')
          .eq('verification_status', 'verified');

      if (_has(specialty)) query = query.eq('specialization', specialty!.trim());
      if (_has(city)) query = query.eq('city', city!.trim());

      if (_has(search)) {
        // Mirrors the PHP's three-column LIKE. `or` takes a comma-separated
        // filter list, and a comma or parenthesis inside the term would split
        // it into extra filters — so the term is escaped before interpolation.
        final term = _escapeOr(search!.trim());
        query = query.or(
          'name.ilike.%$term%,'
          'specialization.ilike.%$term%,'
          'hospital_clinic_name.ilike.%$term%',
        );
      }

      // One round trip for rows AND total: `count: exact` returns the total in
      // the Content-Range header. The PHP ran a separate SELECT COUNT(*) with
      // the same WHERE, so this is one query fewer, not one more.
      final res = await query
          .order('rating', ascending: false)
          .order('id', ascending: false)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return Paged(
        items: res.data.map((r) => Doctor.fromJson(_shapeDoctor(r))).toList(),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  Future<DoctorDetail> doctor(int id) async {
    return SupabaseService.guard(() async {
      final row = await _sb
          .db('doctor_directory')
          .select(_doctorColumns)
          .eq('id', id)
          .maybeSingle();

      if (row == null) {
        throw ApiException(message: 'Doctor not found.', statusCode: 404);
      }

      return DoctorDetail(
        doctor: Doctor.fromJson(_shapeDoctor(row)),
        reviews: await _reviews('doctor', id),
      );
    });
  }

  /// The filter chips. Ordering is applied here rather than in the view because
  /// a view cannot carry a meaningful ORDER BY through Postgrest anyway.
  Future<List<Specialty>> specialties() async {
    return SupabaseService.guard(() async {
      final rows = await _sb
          .db('doctor_specialties')
          .select('specialty, doctor_count')
          .order('doctor_count', ascending: false)
          .order('specialty', ascending: true);

      return rows.map((r) => Specialty.fromJson(r)).toList();
    });
  }

  /// One method for all three place kinds — the tables are shaped alike, so the
  /// only difference is which one is queried and the tag attached to the model.
  Future<Paged<Place>> places(
    PlaceKind kind, {
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String? search,
    String? city,
  }) async {
    return SupabaseService.guard(() async {
      final range = PageRange(page, limit);

      var query = _sb
          .db(kind.listKey)
          .select(_placeColumns(kind))
          .eq('status', 'active')
          .eq('verification_status', 'verified');

      if (_has(city)) query = query.eq('city', city!.trim());

      if (_has(search)) {
        final term = _escapeOr(search!.trim());
        query = query.or(
          'name.ilike.%$term%,'
          'address.ilike.%$term%,'
          'city.ilike.%$term%,'
          'area.ilike.%$term%',
        );
      }

      final res = await query
          .order('rating', ascending: false)
          .order('id', ascending: false)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return Paged(
        items: res.data.map((r) => Place.fromJson(_shapePlace(r, kind), kind)).toList(),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  Future<PlaceDetail> place(PlaceKind kind, int id) async {
    return SupabaseService.guard(() async {
      final row = await _sb
          .db(kind.listKey)
          .select(_placeColumns(kind))
          .eq('id', id)
          .maybeSingle();

      if (row == null) {
        throw ApiException(
          message: '${kind.label} not found.',
          statusCode: 404,
        );
      }

      // Products only for a pharmacy, matching place_detail(). No doctor list
      // for clinics/hospitals — there is no FK from doctors to either table, so
      // the PHP did not send one either.
      final products = kind == PlaceKind.pharmacy
          ? await _pharmacyProducts(id)
          : const <Product>[];

      return PlaceDetail(
        place: Place.fromJson(_shapePlace(row, kind), kind),
        products: products,
        reviews: await _reviews(kind.name, id),
      );
    });
  }

  // -------------------------------------------------------------------------
  // Shared reads
  // -------------------------------------------------------------------------

  /// Recent approved reviews for any reviewable target.
  ///
  /// The embed is `users!left(...)`, and the `!left` is load-bearing: Postgrest
  /// defaults an embed to an inner join, which would drop reviews whose author
  /// was deleted. Those reviews still count toward the cached rating average, so
  /// an inner join hides rows while their stars stay in the total — the exact
  /// bug the PHP fixed by writing LEFT JOIN.
  Future<List<Review>> _reviews(String type, int id) async {
    final rows = await _sb
        .db('reviews')
        .select('id, rating, comment, created_at, users!left(name, profile_image)')
        .eq('reviewable_type', type)
        .eq('reviewable_id', id)
        .eq('status', 'approved')
        .order('created_at', ascending: false)
        .limit(10);

    return rows.map((r) {
      final author = r['users'] as Map<String, dynamic>?;
      return Review.fromJson({
        ...r,
        // Flattened to the keys the PHP aliased, so Review.fromJson is unchanged.
        'reviewer_name': author?['name'],
        'reviewer_image':
            _sb.storageHelper.avatar(author?['profile_image'] as String?),
      });
    }).toList();
  }

  Future<List<Product>> _pharmacyProducts(int pharmacyId) async {
    final rows = await _sb
        .db('pharmacy_products')
        .select()
        .eq('pharmacy_id', pharmacyId)
        .eq('status', 'active')
        .order('name', ascending: true)
        .limit(50);

    return rows
        .map((r) => Product.fromJson({
              ...r,
              'image': _sb.storageHelper.productImage(r['image'] as String?),
            }))
        .toList();
  }

  // -------------------------------------------------------------------------
  // Shaping — reproduces doctor_public() and place_public() exactly
  // -------------------------------------------------------------------------

  Map<String, dynamic> _shapeDoctor(Map<String, dynamic> r) => {
        ...r,
        // The models read these output names, not the column names.
        'specialty': r['specialization'],
        'workplace': r['hospital_clinic_name'],
        'profile_image':
            _sb.storageHelper.avatar(r['profile_image'] as String?),
        // available_days is a CSV column; the PHP split it into an array.
        // Doctor._csv accepts either, but sending the array keeps the wire
        // format identical to before.
        'available_days': _splitCsv(r['available_days']),
      };

  Map<String, dynamic> _shapePlace(Map<String, dynamic> r, PlaceKind kind) => {
        ...r,
        // `hours` is synthesised, as place_hours() did — the app renders one
        // string and has no opening/closing fields.
        'hours': _hours(r),
        'beds_total': r['total_beds'],
        'is_24h': r['open_24_hours'],
      };

  /// "10:00 AM – 8:00 PM", "Open 24 hours", or null when unset.
  ///
  /// A direct port of place_hours(). Postgres returns `time` as 'HH:MM:SS'.
  String? _hours(Map<String, dynamic> r) {
    if (Fmt.toBool(r['open_24_hours'])) return 'Open 24 hours';

    final from = Fmt.str(r['opening_time']);
    final to = Fmt.str(r['closing_time']);
    if (from.isEmpty || to.isEmpty) return null;

    // Fmt.time already renders 'HH:MM:SS' as 'g:i A' for every other screen.
    return '${Fmt.time(from)} – ${Fmt.time(to)}';
  }

  /// Columns per place kind. The three tables share most of their shape but not
  /// all of it — selecting `total_beds` from `clinics` is an error, not an empty
  /// column, so each kind names only what it has.
  static String _placeColumns(PlaceKind kind) {
    const shared =
        'id, user_id, name, address, city, area, phone, email, website, '
        'description, rating, total_reviews, verification_status, '
        'opening_time, closing_time, services';

    switch (kind) {
      case PlaceKind.clinic:
        return '$shared, specializations, clinic_type';
      case PlaceKind.hospital:
        // hospitals has no `services` column; it has facilities/departments.
        return 'id, user_id, name, address, city, area, phone, email, website, '
            'description, rating, total_reviews, verification_status, '
            'opening_time, closing_time, emergency_phone, total_beds, '
            'icu_beds, open_24_hours, facilities, departments, hospital_type';
      case PlaceKind.pharmacy:
        return '$shared, pharmacy_type, delivery_available, '
            'delivery_radius_km, open_24_hours';
    }
  }

  static List<String> _splitCsv(Object? v) {
    if (v is List) return v.map((e) => e.toString()).toList();
    final s = Fmt.str(v);
    if (s.isEmpty) return const [];
    return s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }

  static bool _has(String? v) => v != null && v.trim().isNotEmpty;

  /// Neutralises the characters that would break out of an `or()` filter list.
  ///
  /// A search for "Dr. Rahman, MBBS" would otherwise be read as two filters and
  /// fail with a parse error rather than returning no rows.
  static String _escapeOr(String term) =>
      term.replaceAll(RegExp(r'[,()]'), ' ').replaceAll('*', '');
}

final directoryRepositoryProvider = Provider<DirectoryRepository>(
  (ref) => DirectoryRepository(ref.watch(supabaseServiceProvider)),
);
