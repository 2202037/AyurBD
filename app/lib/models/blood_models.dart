/// Blood bank: per-hospital stock rows and the public donor request board.
library;

import '../core/utils/formatters.dart';

/// The eight groups, matching `const BLOOD_GROUPS` in blood_bank.php. Order is
/// the display order for the filter chips.
const List<String> kBloodGroups = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];

class BloodStock {
  const BloodStock({
    required this.id,
    required this.bloodGroup,
    required this.units,
    this.status = 'available',
    this.hospitalId,
    this.hospitalName,
    this.contactPhone,
    this.location,
    this.city,
    this.bankId,
    this.updatedAt,
  });

  /// Synthetic: `bank_id * 10 + group_index`, built by the UNION ALL in
  /// blood_bank.php. Stable across requests, but it is NOT a primary key and
  /// must never be posted back to the server as one — use [bankId] for that.
  final int id;

  final String bloodGroup;

  /// One of the eight `blood_banks` group columns, unpivoted server-side.
  final int units;

  /// Derived server-side, not stored: unavailable at 0, low below 5, otherwise
  /// available. `blood_banks` has a bank-level status but no per-group flag.
  final String status;

  /// `blood_banks.id`. Named [bankId] because banks are their own table with no
  /// FK to `hospitals`.
  final int? bankId;

  /// Always null on the live schema — kept so an older cached response, or a
  /// future hospital-linked bank, still deserialises. Never rendered.
  final int? hospitalId;

  /// `blood_banks.name`.
  final String? hospitalName;

  /// `blood_banks.phone`. §8 wants one-tap call, so this is the number to dial.
  final String? contactPhone;

  /// Address and city joined into one line by the API, because the card renders
  /// a single line.
  final String? location;

  /// `blood_banks.city`, kept separate for the "find on map" search text.
  final String? city;

  final String? updatedAt;

  /// Mirrors `blood_stock_public()` in blood_bank.php field for field.
  ///
  /// There is no `distance_km` and there are no coordinates: `blood_banks` has
  /// city and address but no latitude/longitude, so nothing here can be sorted
  /// or filtered by distance without inventing the numbers.
  factory BloodStock.fromJson(Map<String, dynamic> json) => BloodStock(
        id: Fmt.toInt(json['id']),
        bloodGroup: Fmt.str(json['blood_group'], '—'),
        units: Fmt.toInt(json['units_available'] ?? json['units']),
        status: Fmt.str(json['status'], 'available'),
        bankId: Fmt.toInt(json['bank_id']) == 0 ? null : Fmt.toInt(json['bank_id']),
        hospitalId:
            Fmt.toInt(json['hospital_id']) == 0 ? null : Fmt.toInt(json['hospital_id']),
        hospitalName: _orNull(json['hospital_name'] ?? json['bank_name']),
        contactPhone: _orNull(json['contact_phone'] ?? json['phone']),
        location: _orNull(json['location']),
        city: _orNull(json['city']),
        updatedAt: _orNull(json['updated_at']),
      );

  bool get inStock => units > 0;

  /// Drives the pill colour via AppColors.forStatus. Trust the server's own
  /// flag, but never show "available" on a row with nothing left in it.
  String get availabilityStatus => units <= 0 ? 'unavailable' : status;

  String get unitsLabel => units <= 0 ? 'Out of stock' : '$units unit${units == 1 ? '' : 's'}';

  /// What to type into a maps search. There are no coordinates to link to, so
  /// the handoff is by name and place.
  String get mapQuery =>
      [hospitalName, location ?? city].where((s) => s != null && s.isNotEmpty).join(' ');
}

class BloodRequest {
  const BloodRequest({
    required this.id,
    required this.bloodGroup,
    required this.unitsNeeded,
    required this.status,
    required this.contactPhone,
    required this.patientName,
    this.hospitalName,
    this.city,
    this.neededBy,
    this.note,
    this.requesterName,
    this.createdAt,
  });

  final int id;
  final String bloodGroup;

  /// `blood_requests.units_needed` (1..20, enforced by validate() server-side).
  final int unitsNeeded;

  /// active | fulfilled | cancelled — the live enum. There is no 'open'.
  final String status;

  /// Required by the API. §8 wants one-tap call, so this is the number to dial.
  /// Stored as `requester_phone`.
  final String contactPhone;

  /// Who the blood is for. NOT NULL in the database, so always present.
  final String patientName;

  /// Free text on the request, not a FK to `hospitals` — the requester may name
  /// a place that is not in the directory.
  final String? hospitalName;

  /// NOT NULL server-side; nullable here only to survive an older cached
  /// response that predates the field.
  final String? city;

  /// `needed_by`, a plain date (yyyy-MM-dd). Required by the API and the column.
  final String? neededBy;

  /// The `reason` column, sent as both `note` and `reason`.
  final String? note;

  /// Free text captured on the form. `blood_requests` has no requester_id and no
  /// FK to users, so there is no requester id to expose and none is modelled.
  final String? requesterName;
  final String? createdAt;

  /// Mirrors `blood_request_public()` in blood_bank.php field for field.
  factory BloodRequest.fromJson(Map<String, dynamic> json) => BloodRequest(
        id: Fmt.toInt(json['id']),
        bloodGroup: Fmt.str(json['blood_group'], '—'),
        unitsNeeded: Fmt.toInt(json['units_needed'], 1),
        status: Fmt.str(json['status'], 'active'),
        contactPhone: Fmt.str(json['contact_phone'] ?? json['requester_phone']),
        patientName: Fmt.str(json['patient_name'], 'Patient'),
        hospitalName: _orNull(json['hospital_name']),
        city: _orNull(json['city']),
        neededBy: _orNull(json['needed_by']),
        note: _orNull(json['note'] ?? json['reason']),
        requesterName: _orNull(json['requester_name']),
        createdAt: _orNull(json['created_at']),
      );

  bool get isOpen => status == 'active';

  String get unitsLabel =>
      '$unitsNeeded unit${unitsNeeded == 1 ? '' : 's'} needed';

  /// How close the deadline is, derived from `needed_by`.
  ///
  /// This replaces the urgency field the old model carried: `blood_requests` has
  /// no urgency column, so a self-reported priority would have been invented.
  /// A real date is better evidence anyway.
  int? get daysUntilNeeded {
    final d = Fmt.date(neededBy ?? '');
    if (d == null) return null;
    final now = DateTime.now();
    return DateTime(d.year, d.month, d.day)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
  }

  bool get isOverdue => (daysUntilNeeded ?? 1) < 0;

  /// Drives the pill colour via AppColors.forStatus.
  String get urgencyStatus {
    final d = daysUntilNeeded;
    if (d == null) return 'normal';
    if (d < 0) return 'cancelled';   // past its date — renders muted/danger
    if (d == 0) return 'critical';
    if (d <= 2) return 'high';
    return 'low';
  }

  String get neededByLabel {
    final d = daysUntilNeeded;
    if (d == null) return 'Date not given';
    if (d < 0) return 'Date passed';
    if (d == 0) return 'Needed today';
    if (d == 1) return 'Needed tomorrow';
    return 'Needed in $d days';
  }
}

/// A registered volunteer donor from `blood_donors`.
class BloodDonor {
  const BloodDonor({
    required this.id,
    required this.name,
    required this.bloodGroup,
    required this.phone,
    required this.city,
    this.area,
    this.lastDonationDate,
    this.isAvailable = true,
  });

  final int id;
  final String name;
  final String bloodGroup;
  final String phone;
  final String city;
  final String? area;
  final String? lastDonationDate;
  final bool isAvailable;

  factory BloodDonor.fromJson(Map<String, dynamic> json) => BloodDonor(
        id: Fmt.toInt(json['id']),
        name: Fmt.str(json['name'], 'Donor'),
        bloodGroup: Fmt.str(json['blood_group'], '—'),
        phone: Fmt.str(json['phone']),
        city: Fmt.str(json['city']),
        area: _orNull(json['area']),
        lastDonationDate: _orNull(json['last_donation_date']),
        isAvailable: Fmt.toBool(json['is_available'], true),
      );

  String get locationLabel =>
      area != null && area!.isNotEmpty ? '$area, $city' : city;

  /// Donors must wait about three months between donations. Shown as guidance
  /// only — the server does not enforce it.
  bool get isLikelyEligible {
    final d = Fmt.date(lastDonationDate ?? '');
    if (d == null) return true;
    return DateTime.now().difference(d).inDays >= 90;
  }
}

String? _orNull(Object? v) {
  final s = Fmt.str(v);
  return s.isEmpty ? null : s;
}
