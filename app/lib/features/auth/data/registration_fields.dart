/// Builders for the role-specific half of `POST /auth/register` (§3.2–3.5).
///
/// These exist because `validate()` copies only rule-listed fields: a key the
/// server does not recognise is dropped in silence, so a typo like
/// `specialisation` for `specialization` would not fail loudly — the account
/// would just be created with that field empty. Keeping every wire key in one
/// file, next to the rule set it mirrors, makes that class of bug reviewable.
///
/// Each builder takes already-trimmed display values and emits only the keys
/// that carry content, because a blank string would fail the server's `int` and
/// `time` rules where a missing key passes.
library;

/// Wire values for `users.gender` (`in:male,female,other`).
enum Gender {
  male('male', 'Male'),
  female('female', 'Female'),
  other('other', 'Other');

  const Gender(this.value, this.label);

  final String value;
  final String label;
}

/// The roles a stranger may self-register as.
///
/// `admin` is absent by design — the server clamps it to `patient`, and offering
/// it in a dropdown would advertise a privilege escalation that does not exist.
enum SignupRole {
  patient('patient', 'Patient', 'Book appointments and order medicine'),
  doctor('doctor', 'Doctor', 'Take appointments and manage a chamber'),
  hospital('hospital', 'Hospital', 'List a hospital and its departments'),
  clinic('clinic', 'Clinic', 'List a clinic and its services'),
  pharmacy('pharmacy', 'Pharmacy', 'Sell medicine and take orders');

  const SignupRole(this.value, this.label, this.blurb);

  final String value;
  final String label;

  /// One line under the role name in the picker, so the choice does not rest on
  /// the label alone.
  final String blurb;

  /// True for the four roles whose sign-up creates a directory row that an admin
  /// must then verify (§3.2–3.5). Drives the "pending review" notice.
  bool get isProvider => this != SignupRole.patient;
}

class RegistrationFields {
  const RegistrationFields._();

  /// §3.2 — mirrors the `doctor` branch of `auth_role_rules()`.
  ///
  /// `bmdc_certificate` and the other document fields are `max:255` *strings*, not
  /// uploads: the register endpoint stores a path, and no multipart handler is
  /// wired to it. Screens collect nothing for them, so they are absent here
  /// rather than sent empty.
  static Map<String, Object?> doctor({
    String? bmdcNumber,
    String? specialization,
    String? qualifications,
    String? medicalSchool,
    String? graduationYear,
    String? experienceYears,
    String? doctorType,
    String? hospitalClinicName,
    String? chamberAddress,
    String? area,
    String? consultationFee,
    String? bio,
  }) =>
      _compact({
        'bmdc_number': bmdcNumber,
        'specialization': specialization,
        'qualifications': qualifications,
        'medical_school': medicalSchool,
        'graduation_year': graduationYear,
        'experience_years': experienceYears,
        'doctor_type': doctorType,
        'hospital_clinic_name': hospitalClinicName,
        'chamber_address': chamberAddress,
        'area': area,
        'consultation_fee': consultationFee,
        'bio': bio,
      });

  /// §3.3 — mirrors the `hospital` branch.
  ///
  /// [open24Hours] goes over as `'1'`/`'0'`: the rule is `in:0,1`, which compares
  /// loosely, and the insert casts with `(int)`. A Dart `true` would serialise to
  /// JSON `true` and fail that rule.
  static Map<String, Object?> hospital({
    String? emergencyPhone,
    String? registrationNumber,
    String? licenseNumber,
    String? hospitalType,
    String? establishedYear,
    String? website,
    String? area,
    String? totalBeds,
    String? icuBeds,
    String? facilities,
    String? departments,
    bool? open24Hours,
    String? openingTime,
    String? closingTime,
    String? description,
  }) =>
      _compact({
        'emergency_phone': emergencyPhone,
        'registration_number': registrationNumber,
        'license_number': licenseNumber,
        'hospital_type': hospitalType,
        'established_year': establishedYear,
        'website': website,
        'area': area,
        'total_beds': totalBeds,
        'icu_beds': icuBeds,
        'facilities': facilities,
        'departments': departments,
        'open_24_hours': _flag(open24Hours),
        // Suppressed when the hospital is always open: the server would accept
        // both, but storing hours alongside a 24h flag invites the profile screen
        // to render "Open 24 hours · 09:00–17:00".
        'opening_time': (open24Hours ?? false) ? null : openingTime,
        'closing_time': (open24Hours ?? false) ? null : closingTime,
        'description': description,
      });

  /// §3.4 — mirrors the `clinic` branch.
  ///
  /// `available_days` is `max:100` free text, not a set — the column stores
  /// whatever the form sends. Screens join a weekday picker into a comma list.
  static Map<String, Object?> clinic({
    String? website,
    String? registrationNumber,
    String? licenseNumber,
    String? clinicType,
    String? establishedYear,
    String? area,
    String? services,
    String? specializations,
    String? availableDays,
    String? openingTime,
    String? closingTime,
    String? description,
  }) =>
      _compact({
        'website': website,
        'registration_number': registrationNumber,
        'license_number': licenseNumber,
        'clinic_type': clinicType,
        'established_year': establishedYear,
        'area': area,
        'services': services,
        'specializations': specializations,
        'available_days': availableDays,
        'opening_time': openingTime,
        'closing_time': closingTime,
        'description': description,
      });

  /// §3.5 — mirrors the `pharmacy` branch.
  ///
  /// `license_number` is the one provider field the insert defaults to `''`
  /// rather than null, because the live column is NOT NULL. The screen marks it
  /// required so a pharmacy does not end up with a blank licence on record.
  static Map<String, Object?> pharmacy({
    String? whatsapp,
    String? licenseNumber,
    String? drugLicenseNumber,
    String? pharmacyType,
    String? ownerName,
    String? pharmacistName,
    String? pharmacistLicense,
    String? establishedYear,
    String? area,
    String? services,
    bool? deliveryAvailable,
    String? deliveryRadiusKm,
    bool? open24Hours,
    String? openingTime,
    String? closingTime,
    String? description,
  }) =>
      _compact({
        'whatsapp': whatsapp,
        'license_number': licenseNumber,
        'drug_license_number': drugLicenseNumber,
        'pharmacy_type': pharmacyType,
        'owner_name': ownerName,
        'pharmacist_name': pharmacistName,
        'pharmacist_license': pharmacistLicense,
        'established_year': establishedYear,
        'area': area,
        'services': services,
        'delivery_available': _flag(deliveryAvailable),
        // A radius without delivery is meaningless, and the profile screen would
        // read it as "delivers within 5 km" regardless of the flag.
        'delivery_radius_km':
            (deliveryAvailable ?? false) ? deliveryRadiusKm : null,
        'open_24_hours': _flag(open24Hours),
        'opening_time': (open24Hours ?? false) ? null : openingTime,
        'closing_time': (open24Hours ?? false) ? null : closingTime,
        'description': description,
      });

  /// `in:0,1` wants a scalar 0/1, and JSON `true` is neither. Null stays null so
  /// [_compact] drops the key entirely rather than defaulting the column.
  static String? _flag(bool? v) => v == null ? null : (v ? '1' : '0');

  /// Drops null and whitespace-only values.
  ///
  /// This is what keeps an untouched numeric field from becoming `''` on the
  /// wire, which the server's `int` and `time` rules reject — while an absent key
  /// passes cleanly and leaves the column at its default.
  static Map<String, Object?> _compact(Map<String, Object?> raw) {
    final out = <String, Object?>{};
    raw.forEach((key, value) {
      if (value == null) return;
      if (value is String) {
        final t = value.trim();
        if (t.isEmpty) return;
        out[key] = t;
        return;
      }
      out[key] = value;
    });
    return out;
  }
}
