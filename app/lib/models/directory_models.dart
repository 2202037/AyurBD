/// Directory entities: doctors and the three place types (clinic, hospital,
/// pharmacy). The API returns places through one `place_public()` shaper, so one
/// Dart class covers all three and [PlaceKind] records which list it came from.
library;

import '../core/utils/formatters.dart';

/// Mirrors `doctor_public()` in backend/api/v1/directory.php field for field.
///
/// Several names here are deliberately not the ones a fresh guess would pick,
/// because they follow the live `doctors` table: it stores `qualifications`
/// (plural), `hospital_clinic_name` (exposed as `workplace`), `bio`,
/// `chamber_address` and `total_reviews`. The earlier version of this class read
/// `qualification`, `clinic_name`, `about`, `address` and `review_count`, none of
/// which the API sends — every one of those fields silently arrived null.
///
/// Three things are absent on purpose:
///  * **No `clinic_id`.** `doctors` has no FK to `clinics`; the workplace is
///    free text, so there is nothing to navigate to.
///  * **No `distance_km`.** No table in this database has coordinates, so a
///    distance could only be invented.
///  * **No `is_available` column.** [isAvailable] is derived from whether the
///    schedule columns are filled in.
class Doctor {
  const Doctor({
    required this.id,
    required this.name,
    required this.specialty,
    this.userId,
    this.qualifications,
    this.medicalSchool,
    this.graduationYear,
    this.doctorType,
    this.experienceYears = 0,
    this.consultationFee = 0,
    this.rating = 0,
    this.reviewCount = 0,
    this.image,
    this.bio,
    this.workplace,
    this.city,
    this.area,
    this.chamberAddress,
    this.phone,
    this.email,
    this.availableDays = const [],
    this.availableFrom,
    this.availableTo,
    this.slotMinutes = 30,
  });

  final int id;

  /// `doctors.user_id` — the login row behind this profile. A uuid, because it
  /// references `users.id`. Not the same as [id], which is the doctors-table
  /// bigint used by every directory route and by `appointments.doctor_id`.
  ///
  /// The two id types are the reason those stayed distinct: mixing them up used
  /// to be a silent bug between two ints, and is now a compile error.
  final String? userId;

  final String name;
  final String specialty;

  /// `doctors.qualifications`, e.g. "MBBS, FCPS (Medicine)".
  final String? qualifications;

  final String? medicalSchool;
  final int? graduationYear;

  /// `doctors.doctor_type`, e.g. "Ayurvedic" / "General".
  final String? doctorType;

  final int experienceYears;
  final double consultationFee;
  final double rating;
  final int reviewCount;
  final String? image;

  /// `doctors.bio`.
  final String? bio;

  /// `doctors.hospital_clinic_name` — free text, not a link to a clinic row.
  final String? workplace;

  final String? city;
  final String? area;

  /// `doctors.chamber_address`.
  final String? chamberAddress;

  final String? phone;
  final String? email;

  /// Sent as a JSON array by `doctor_public()`, which splits the stored CSV.
  /// [_csv] still accepts the raw string so a hand-written row cannot break it.
  final List<String> availableDays;
  final String? availableFrom;
  final String? availableTo;
  final int slotMinutes;

  factory Doctor.fromJson(Map<String, dynamic> json) => Doctor(
        id: Fmt.toInt(json['id']),
        // A uuid string, not an int — see the field declaration.
        userId: _orNull(json['user_id']),
        name: Fmt.str(json['name'], 'Unnamed doctor'),
        specialty: Fmt.str(json['specialty'], 'General'),
        qualifications: _orNull(json['qualifications']),
        medicalSchool: _orNull(json['medical_school']),
        graduationYear:
            Fmt.toInt(json['graduation_year']) == 0 ? null : Fmt.toInt(json['graduation_year']),
        doctorType: _orNull(json['doctor_type']),
        experienceYears: Fmt.toInt(json['experience_years']),
        consultationFee: Fmt.toDouble(json['consultation_fee']),
        rating: Fmt.toDouble(json['rating']),
        reviewCount: Fmt.toInt(json['total_reviews']),
        image: _orNull(json['profile_image']),
        bio: _orNull(json['bio']),
        workplace: _orNull(json['workplace']),
        city: _orNull(json['city']),
        area: _orNull(json['area']),
        chamberAddress: _orNull(json['chamber_address']),
        phone: _orNull(json['phone']),
        email: _orNull(json['email']),
        availableDays: _csv(json['available_days']),
        availableFrom: _orNull(json['available_from']),
        availableTo: _orNull(json['available_to']),
        slotMinutes: Fmt.toInt(json['slot_minutes'], 30),
      );

  /// Derived, not stored. A doctor is bookable when the schedule columns the
  /// migration added are actually filled in — there is no availability flag to
  /// read, and treating "no schedule" as available would offer slots that
  /// `appointments_slots()` then returns empty.
  bool get isAvailable =>
      availableDays.isNotEmpty && availableFrom != null && availableTo != null;

  String get feeLabel => consultationFee <= 0 ? 'Fee on request' : Fmt.money(consultationFee);

  String get experienceLabel =>
      experienceYears <= 0 ? 'New practitioner' : '$experienceYears yrs experience';

  /// Where they practise. Falls back through workplace → area → city so a
  /// partly-filled profile still says something true.
  String get workplaceLabel {
    final parts = [workplace, area ?? city].where((s) => s != null && s.isNotEmpty);
    return parts.isEmpty ? 'Practice not listed' : parts.join(', ');
  }

  /// `Sat, Sun, Mon` for the doctor card.
  String get daysLabel => availableDays.isEmpty ? 'Schedule on request' : availableDays.join(', ');

  String get hoursLabel {
    if (availableFrom == null || availableTo == null) return '';
    return '${Fmt.time(availableFrom)} – ${Fmt.time(availableTo)}';
  }
}

/// Which directory a [Place] came from. Drives the icon, the title and the
/// endpoint used to reload it.
enum PlaceKind {
  clinic,
  hospital,
  pharmacy;

  String get label {
    switch (this) {
      case PlaceKind.clinic:
        return 'Clinic';
      case PlaceKind.hospital:
        return 'Hospital';
      case PlaceKind.pharmacy:
        return 'Pharmacy';
    }
  }

  /// Display label. Not a wire key — see [listKey].
  String get plural {
    switch (this) {
      case PlaceKind.clinic:
        return 'Clinics';
      case PlaceKind.hospital:
        return 'Hospitals';
      case PlaceKind.pharmacy:
        return 'Pharmacies';
    }
  }

  /// The wrapper key `place_list()` uses inside `data` — lowercase and matching
  /// the table name. Kept separate from [plural] so renaming a UI label can
  /// never break JSON parsing.
  String get listKey {
    switch (this) {
      case PlaceKind.clinic:
        return 'clinics';
      case PlaceKind.hospital:
        return 'hospitals';
      case PlaceKind.pharmacy:
        return 'pharmacies';
    }
  }

  /// The wrapper key `place_detail()` uses — the singular form.
  String get detailKey => name;
}

/// Mirrors `place_public()` in directory.php, which shapes clinics, hospitals
/// and pharmacies through one function.
///
/// **No coordinates and no distance.** None of the three tables has latitude or
/// longitude, so `/nearby` is a city filter rather than a radius search and there
/// is no `distance_km` to display or sort by. The previous version declared all
/// three fields; they were always null.
///
/// Also gone: `image` (no photo column on any of the three tables),
/// `is_verified` and `is_active` (the real column is a three-state
/// `verification_status` enum, and there is no active flag at all), and
/// `has_blood_bank` (blood stock lives in the separate `blood_banks` table,
/// which is not joined to hospitals).
class Place {
  const Place({
    required this.id,
    required this.kind,
    required this.name,
    this.userId,
    this.address,
    this.city,
    this.area,
    this.phone,
    this.email,
    this.website,
    this.about,
    this.rating = 0,
    this.reviewCount = 0,
    this.openingHours,
    this.services = const [],
    this.doctorCount = 0,
    this.productCount = 0,
    this.emergencyPhone,
    this.bedsTotal,
    this.icuBeds,
    this.is24h = false,
    this.deliveryAvailable = false,
    this.verificationStatus,
  });

  final int id;
  final PlaceKind kind;
  final String name;

  /// The owning login row, when the place has one. A uuid — see [Doctor.userId].
  final String? userId;

  final String? address;
  final String? city;
  final String? area;
  final String? phone;
  final String? email;
  final String? website;

  /// `description` on all three tables.
  final String? about;

  final double rating;
  final int reviewCount;

  /// `hours` — already composed by `place_hours()` into one string, e.g.
  /// "10:00 AM – 8:00 PM" or "Open 24 hours".
  final String? openingHours;

  /// Comma-separated on the row; the shaper sends whichever of `facilities`,
  /// `departments`, `services` or `specializations` the table actually has.
  final List<String> services;

  /// Clinics and hospitals only.
  final int doctorCount;

  /// Pharmacies only.
  final int productCount;

  /// Hospitals only.
  final String? emergencyPhone;
  final int? bedsTotal;
  final int? icuBeds;
  final bool is24h;

  /// Pharmacies only.
  final bool deliveryAvailable;

  /// `verification_status`: 'pending', 'verified' or 'rejected'.
  final String? verificationStatus;

  factory Place.fromJson(Map<String, dynamic> json, PlaceKind kind) => Place(
        id: Fmt.toInt(json['id']),
        kind: kind,
        name: Fmt.str(json['name'], 'Unnamed'),
        userId: _orNull(json['user_id']),
        address: _orNull(json['address']),
        city: _orNull(json['city']),
        area: _orNull(json['area']),
        phone: _orNull(json['phone']),
        email: _orNull(json['email']),
        website: _orNull(json['website']),
        about: _orNull(json['description']),
        rating: Fmt.toDouble(json['rating']),
        reviewCount: Fmt.toInt(json['total_reviews']),
        openingHours: _orNull(json['hours']),
        services: _csv(json['facilities'] ??
            json['departments'] ??
            json['services'] ??
            json['specializations']),
        doctorCount: Fmt.toInt(json['doctor_count']),
        productCount: Fmt.toInt(json['product_count']),
        emergencyPhone: _orNull(json['emergency_phone']),
        bedsTotal: Fmt.toInt(json['beds_total']) == 0 ? null : Fmt.toInt(json['beds_total']),
        icuBeds: Fmt.toInt(json['icu_beds']) == 0 ? null : Fmt.toInt(json['icu_beds']),
        is24h: Fmt.toBool(json['is_24h']),
        deliveryAvailable: Fmt.toBool(json['delivery_available']),
        verificationStatus: _orNull(json['verification_status']),
      );

  /// Only a completed check earns a badge. 'pending' shows nothing rather than
  /// implying either outcome.
  bool get isVerified => verificationStatus == 'verified';

  String get locationLabel {
    final parts = [address, area, city].where((p) => p != null && p.isNotEmpty).toList();
    return parts.isEmpty ? 'Location not listed' : parts.join(', ');
  }

  /// What to type into a maps search, since there are no coordinates to link to.
  String get mapQuery =>
      [name, address ?? area ?? city].where((s) => s != null && s.isNotEmpty).join(' ');
}

/// `/directory/specialties` — name plus how many doctors practise it.
class Specialty {
  const Specialty({required this.name, this.doctorCount = 0});

  final String name;
  final int doctorCount;

  factory Specialty.fromJson(Map<String, dynamic> json) => Specialty(
        name: Fmt.str(json['specialty'] ?? json['name'], 'General'),
        doctorCount: Fmt.toInt(json['doctor_count'] ?? json['total']),
      );
}

String? _orNull(Object? v) {
  final s = Fmt.str(v);
  return s.isEmpty ? null : s;
}

List<String> _csv(Object? v) {
  if (v is List) {
    return v.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
  }
  final s = Fmt.str(v);
  if (s.isEmpty) return const [];
  return s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
}
