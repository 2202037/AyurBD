/// Blood stock, the donor register, and the request board — from Supabase.
///
/// Public surface is unchanged: `inventory()`, `nearby()`, `donors()`,
/// `registerDonor()`, `requests()`, `createRequest()`.
///
/// The one structural difference is the stock list. `blood_banks` stores the
/// eight groups as eight integer COLUMNS, and blood_bank.php unpivoted them with
/// a `UNION ALL` so each group became its own row. Postgrest cannot express
/// that, so the unpivot happens in [_expand] here instead. The wire shape handed
/// to [BloodStock.fromJson] is identical, including the synthetic
/// `bank_id * 10 + group_index` id.
///
/// Because one bank becomes up to eight rows, pagination stays keyed to BANKS:
/// `meta.total` is the bank count and `meta.limit` the bank page size, so
/// `hasMore` and `lastPage` remain correct and infinite scroll cannot run off
/// the end. Only `items.length` differs from `limit`, which no caller asserts.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show CountOption;

import '../../../core/constants/app_config.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/api_result.dart';
import '../../../core/network/supabase_service.dart';
import '../../../core/providers.dart';
import '../../../core/utils/formatters.dart';
import '../../../models/blood_models.dart';

/// The result of a city lookup.
///
/// Named "nearby" because that is what the screen calls it, but there is no
/// distance in it: `blood_banks` stores no coordinates, so the filter is by city
/// and no `distance_km` exists. [city] echoes what was actually searched.
class NearbyStock {
  const NearbyStock({required this.page, required this.city});

  final Paged<BloodStock> page;
  final String city;
}

class BloodRepository {
  BloodRepository(this._sb);

  final SupabaseService _sb;

  /// Display order for the chips, and the index used in the synthetic row id.
  /// Must stay aligned with [_groupColumns] — the two are indexed together.
  static const _groups = kBloodGroups;

  /// The eight stock columns, in the same order as [_groups].
  static const _groupColumns = [
    'blood_a_positive',
    'blood_a_negative',
    'blood_b_positive',
    'blood_b_negative',
    'blood_ab_positive',
    'blood_ab_negative',
    'blood_o_positive',
    'blood_o_negative',
  ];

  static const _bankColumns = 'id, name, address, city, phone, email, status, '
      'updated_at, blood_a_positive, blood_a_negative, blood_b_positive, '
      'blood_b_negative, blood_ab_positive, blood_ab_negative, '
      'blood_o_positive, blood_o_negative';

  /// `location` is matched against the bank's city, name and address, so one
  /// free-text box still covers all three.
  Future<Paged<BloodStock>> inventory({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String? bloodGroup,
    String? location,
    bool inStockOnly = false,
  }) async {
    return SupabaseService.guard(() async {
      final range = PageRange(page, limit);

      var query =
          _sb.db('blood_banks').select(_bankColumns).eq('status', 'active');

      if (location != null && location.trim().isNotEmpty) {
        final term = _escapeOr(location.trim());
        query = query.or(
          'city.ilike.%$term%,'
          'name.ilike.%$term%,'
          'address.ilike.%$term%',
        );
      }

      // With a single group asked for, "in stock only" is a real column filter.
      // Without one it cannot be — a bank may be empty of A+ and full of O-, so
      // the row-level filter is applied after the unpivot instead.
      final column = _columnFor(bloodGroup);
      if (inStockOnly && column != null) query = query.gt(column, 0);

      final res = await query
          .order('name', ascending: true)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return Paged(
        items: _expand(
          res.data,
          bloodGroup: bloodGroup,
          inStockOnly: inStockOnly,
        ),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  /// Blood banks in one city.
  ///
  /// This used to take a lat/lng and a radius and sort by Haversine distance.
  /// `blood_banks` has no coordinates, so that ranking was measuring nothing.
  /// City is the finest granularity the data supports, and a blank one is
  /// rejected rather than returning the whole country.
  Future<NearbyStock> nearby({
    required String city,
    String? bloodGroup,
    int page = 1,
    int limit = AppConfig.defaultPageSize,
  }) async {
    return SupabaseService.guard(() async {
      final trimmed = city.trim();
      if (trimmed.isEmpty) {
        throw ApiException(
          message: 'Please enter a city to search.',
          statusCode: 400,
          errors: const {'city': 'Please enter a city.'},
        );
      }

      final range = PageRange(page, limit);

      var query = _sb
          .db('blood_banks')
          .select(_bankColumns)
          .eq('status', 'active')
          .ilike('city', '%${_escapeLike(trimmed)}%');

      final column = _columnFor(bloodGroup);
      if (column != null) query = query.gt(column, 0);

      final res = await query
          .order('name', ascending: true)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return NearbyStock(
        page: Paged(
          items: _expand(res.data, bloodGroup: bloodGroup),
          meta: PageMeta(page: page, limit: limit, total: res.count),
        ),
        city: trimmed,
      );
    });
  }

  /// Registered volunteer donors, least-recently-donated first.
  ///
  /// `nullsFirst` is deliberate: a donor who has never donated has a null
  /// `last_donation_date` and is the most eligible of all, so they belong at the
  /// top rather than the bottom.
  Future<Paged<BloodDonor>> donors({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String? bloodGroup,
    String? city,
  }) async {
    return SupabaseService.guard(() async {
      final range = PageRange(page, limit);

      var query = _sb
          .db('blood_donors')
          .select('id, name, blood_group, phone, city, area, '
              'last_donation_date, is_available')
          .eq('is_available', true);

      if (_has(bloodGroup)) query = query.eq('blood_group', bloodGroup!.trim());
      if (_has(city)) query = query.eq('city', city!.trim());

      final res = await query
          .order('last_donation_date', ascending: true, nullsFirst: true)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return Paged(
        items: res.data.map(BloodDonor.fromJson).toList(),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  /// Register (or re-register) the signed-in user as a donor. Calling this twice
  /// updates the existing record rather than creating a duplicate.
  ///
  /// `blood_donors.name` is NOT NULL, so [name] falls back to the account's name
  /// — which is itself NOT NULL, so a signed-in user always has one.
  Future<void> registerDonor({
    required String phone,
    required String bloodGroup,
    required String city,
    String? name,
    String? area,
    DateTime? lastDonationDate,
  }) async {
    await SupabaseService.guard(() async {
      final userId = _requireUser();

      final profile = await _sb
          .db('users')
          .select('name')
          .eq('id', userId)
          .maybeSingle();

      final donorName = _firstNonEmpty([name, profile?['name']]);
      if (donorName.isEmpty) {
        throw ApiException(
          message: 'A name is required to register as a donor.',
          statusCode: 422,
          errors: const {'name': 'Please enter your name.'},
        );
      }

      final payload = {
        'user_id': userId,
        'name': donorName,
        'phone': phone.trim(),
        'blood_group': bloodGroup,
        'city': city.trim(),
        'area': _nullIfEmpty(area),
        'last_donation_date':
            lastDonationDate == null ? null : Fmt.apiDate(lastDonationDate),
        'is_available': true,
      };

      // Update-then-insert rather than upsert: `user_id` is nullable (guest
      // donors are allowed), and an upsert would need a conflict target that
      // does not apply to those rows.
      final existing = await _sb
          .db('blood_donors')
          .select('id')
          .eq('user_id', userId)
          .maybeSingle();

      if (existing == null) {
        await _sb.db('blood_donors').insert(payload);
      } else {
        await _sb.db('blood_donors').update(payload).eq('id', existing['id']);
      }
    });
  }

  /// The public board shows only `active` requests, soonest-needed first.
  ///
  /// `mine: true` still matches on the phone number stored on the account:
  /// `blood_requests` has no user_id column, so a request posted with a
  /// different contact number will not appear, and a user with no phone on file
  /// gets an empty list. That was true of the PHP too — the column does not
  /// exist to filter on.
  Future<Paged<BloodRequest>> requests({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String? bloodGroup,
    String? city,
    String? status,
    bool mine = false,
  }) async {
    return SupabaseService.guard(() async {
      final range = PageRange(page, limit);

      var query = _sb.db('blood_requests').select(
            'id, requester_name, requester_phone, patient_name, blood_group, '
            'units_needed, hospital_name, city, needed_by, reason, status, '
            'created_at',
          );

      if (mine) {
        final userId = _requireUser();
        final profile = await _sb
            .db('users')
            .select('phone')
            .eq('id', userId)
            .maybeSingle();

        final phone = Fmt.str(profile?['phone']);
        if (phone.isEmpty) {
          // No phone on file means nothing can be matched. Returning an empty
          // page is the honest answer and matches the old behaviour.
          return Paged<BloodRequest>(
            items: const [],
            meta: PageMeta(page: page, limit: limit, total: 0),
          );
        }
        query = query.eq('requester_phone', phone);
      } else {
        // The board is public and shows open requests only, unless a specific
        // status was asked for below.
        if (!_has(status)) query = query.eq('status', 'active');
      }

      if (_has(status)) query = query.eq('status', status!.trim());
      if (_has(bloodGroup)) query = query.eq('blood_group', bloodGroup!.trim());
      if (_has(city)) query = query.eq('city', city!.trim());

      final res = await query
          .order('needed_by', ascending: true)
          .order('created_at', ascending: false)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return Paged(
        items: res.data.map(BloodRequest.fromJson).toList(),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  /// Posts a request to the board.
  ///
  /// Column names, not the old request keys: the phone is `requester_phone` and
  /// the free-text note is `reason`. `requester_name`, `requester_phone`,
  /// `patient_name`, `hospital_name`, `city` and `needed_by` are all NOT NULL.
  Future<BloodRequest> createRequest({
    required String patientName,
    required String bloodGroup,
    required int unitsNeeded,
    required String hospitalName,
    required String city,
    required DateTime neededBy,
    required String contactPhone,
    String? requesterName,
    String? reason,
  }) async {
    return SupabaseService.guard(() async {
      // Falls back to the account name when the form did not collect one. A
      // guest has no account to fall back to, hence the explicit check.
      var name = _firstNonEmpty([requesterName]);
      if (name.isEmpty) {
        final userId = _sb.currentUserId;
        if (userId != null && userId.isNotEmpty) {
          final profile = await _sb
              .db('users')
              .select('name')
              .eq('id', userId)
              .maybeSingle();
          name = Fmt.str(profile?['name']);
        }
      }
      if (name.isEmpty) {
        throw ApiException(
          message: 'Please give a contact name for this request.',
          statusCode: 422,
          errors: const {'requester_name': 'Please enter your name.'},
        );
      }

      final row = await _sb.db('blood_requests').insert({
        'requester_name': name,
        'requester_phone': contactPhone.trim(),
        'patient_name': patientName.trim(),
        'blood_group': bloodGroup,
        'units_needed': unitsNeeded,
        'hospital_name': hospitalName.trim(),
        'city': city.trim(),
        'needed_by': Fmt.apiDate(neededBy),
        'reason': _nullIfEmpty(reason),
      }).select(
        'id, requester_name, requester_phone, patient_name, blood_group, '
        'units_needed, hospital_name, city, needed_by, reason, status, '
        'created_at',
      ).single();

      return BloodRequest.fromJson(row);
    });
  }

  // -------------------------------------------------------------------------
  // Unpivot — reproduces the UNION ALL in blood_bank.php
  // -------------------------------------------------------------------------

  /// Turns each bank row into one [BloodStock] per group.
  ///
  /// The id is `bank_id * 10 + group_index`, as before: stable across requests
  /// but not a primary key, which is why [BloodStock.bankId] carries the real
  /// one.
  List<BloodStock> _expand(
    List<Map<String, dynamic>> banks, {
    String? bloodGroup,
    bool inStockOnly = false,
  }) {
    final wanted = _indexOf(bloodGroup);
    final out = <BloodStock>[];

    for (final bank in banks) {
      final bankId = Fmt.toInt(bank['id']);
      final location = _location(bank);

      for (var i = 0; i < _groups.length; i++) {
        if (wanted != null && wanted != i) continue;

        final units = Fmt.toInt(bank[_groupColumns[i]]);
        if (inStockOnly && units <= 0) continue;

        out.add(BloodStock.fromJson({
          'id': bankId * 10 + i,
          'bank_id': bankId,
          'blood_group': _groups[i],
          'units_available': units,
          'status': _statusFor(units),
          'bank_name': bank['name'],
          'contact_phone': bank['phone'],
          'location': location,
          'city': bank['city'],
          'updated_at': bank['updated_at'],
        }));
      }
    }

    return out;
  }

  /// Derived server-side before, derived here now: unavailable at 0, low below
  /// 5, otherwise available. `blood_banks` has a bank-level status but no
  /// per-group flag.
  static String _statusFor(int units) {
    if (units <= 0) return 'unavailable';
    if (units < 5) return 'low';
    return 'available';
  }

  /// Address and city joined into the single line the card renders.
  static String _location(Map<String, dynamic> bank) {
    final parts = [Fmt.str(bank['address']), Fmt.str(bank['city'])]
        .where((s) => s.isNotEmpty)
        .toList();
    return parts.join(', ');
  }

  static int? _indexOf(String? group) {
    if (group == null) return null;
    final g = group.trim().toUpperCase();
    if (g.isEmpty) return null;
    final i = _groups.indexOf(g);
    return i < 0 ? null : i;
  }

  /// The stock column for one group, or null when no single group was asked for.
  static String? _columnFor(String? group) {
    final i = _indexOf(group);
    return i == null ? null : _groupColumns[i];
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

  static String? _nullIfEmpty(String? v) {
    final s = Fmt.str(v);
    return s.isEmpty ? null : s;
  }

  static String _firstNonEmpty(List<Object?> candidates) {
    for (final c in candidates) {
      final s = Fmt.str(c);
      if (s.isNotEmpty) return s;
    }
    return '';
  }

  static String _escapeOr(String term) =>
      term.replaceAll(RegExp(r'[,()]'), ' ').replaceAll('*', '');

  /// `%` and `_` are wildcards in LIKE, so a city typed with either would match
  /// more than the user asked for.
  static String _escapeLike(String term) =>
      term.replaceAll('%', '').replaceAll('_', '');
}

final bloodRepositoryProvider = Provider<BloodRepository>(
  (ref) => BloodRepository(ref.watch(supabaseServiceProvider)),
);
