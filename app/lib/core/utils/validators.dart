/// Client-side form validation. Mirrors `backend/helpers/validator.php` so the
/// user gets instant feedback — but §10 is explicit that the server validates
/// again regardless. This is UX, not security.
library;

class Validators {
  const Validators._();

  static String? required(String? v, [String field = 'This field']) {
    if (v == null || v.trim().isEmpty) return '$field is required.';
    return null;
  }

  static String? name(String? v) {
    final r = required(v, 'Name');
    if (r != null) return r;
    if (v!.trim().length < 3) return 'Name must be at least 3 characters.';
    if (v.trim().length > 100) return 'Name must be under 100 characters.';
    return null;
  }

  static String? email(String? v) {
    final r = required(v, 'Email');
    if (r != null) return r;
    final ok = RegExp(r'^[\w.+\-]+@[\w\-]+\.[\w.\-]+$').hasMatch(v!.trim());
    return ok ? null : 'Enter a valid email address.';
  }

  /// Bangladeshi mobile: 01[3-9] + 8 digits, optionally +880 / 880 prefixed.
  static String? phone(String? v, {bool optional = false}) {
    if (v == null || v.trim().isEmpty) {
      return optional ? null : 'Phone number is required.';
    }
    final digits = v.replaceAll(RegExp(r'[\s\-()]'), '');
    final ok = RegExp(r'^(?:\+?880|0)1[3-9]\d{8}$').hasMatch(digits);
    return ok ? null : 'Enter a valid Bangladeshi mobile number (e.g. 01712345678).';
  }

  /// Matches the register endpoint: 8+ chars with a letter and a number.
  static String? password(String? v) {
    if (v == null || v.isEmpty) return 'Password is required.';
    if (v.length < 8) return 'Password must be at least 8 characters.';
    if (!RegExp(r'[A-Za-z]').hasMatch(v)) return 'Include at least one letter.';
    if (!RegExp(r'\d').hasMatch(v)) return 'Include at least one number.';
    return null;
  }

  static String? confirmPassword(String? v, String original) {
    if (v == null || v.isEmpty) return 'Confirm your password.';
    if (v != original) return 'Passwords do not match.';
    return null;
  }

  /// Login only needs "not empty" — the strength rules belong on register, or an
  /// existing account with a shorter password could never sign in.
  static String? loginPassword(String? v) =>
      (v == null || v.isEmpty) ? 'Password is required.' : null;

  static String? positiveInt(String? v, {String field = 'Value', int max = 999}) {
    final r = required(v, field);
    if (r != null) return r;
    final n = int.tryParse(v!.trim());
    if (n == null) return '$field must be a number.';
    if (n < 1) return '$field must be at least 1.';
    if (n > max) return '$field cannot exceed $max.';
    return null;
  }

  static String? notes(String? v, {int max = 500}) {
    if (v == null || v.trim().isEmpty) return null; // optional everywhere
    if (v.trim().length > max) return 'Please keep this under $max characters.';
    return null;
  }

  /// A required free-text field with the same bounds the server enforces.
  ///
  /// Use this wherever the column is NOT NULL: the server's `required|min|max`
  /// would reject a blank value with a 422 anyway, and catching it here means the
  /// user finds out before the round trip.
  static String? text(
    String? v, {
    String field = 'This field',
    int min = 2,
    int max = 255,
  }) {
    final r = required(v, field);
    if (r != null) return r;
    final t = v!.trim();
    if (t.length < min) return '$field must be at least $min characters.';
    if (t.length > max) return '$field must be under $max characters.';
    return null;
  }
}
