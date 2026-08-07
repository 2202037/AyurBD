/// Display formatting. Kept in one place so a taka amount or an appointment time
/// never renders two different ways on two screens.
library;

import 'package:intl/intl.dart';

import '../constants/app_config.dart';

class Fmt {
  const Fmt._();

  // -- money ---------------------------------------------------------------

  /// `1250` -> `৳1,250`; `1250.5` -> `৳1,250.50`.
  static String money(Object? amount) {
    final v = toDouble(amount);
    final hasPaisa = (v * 100).round() % 100 != 0;
    final pattern = hasPaisa ? '#,##0.00' : '#,##0';
    return '${AppConfig.currency}${NumberFormat(pattern, 'en_US').format(v)}';
  }

  // -- dates ---------------------------------------------------------------

  /// Parses the API's `YYYY-MM-DD` or `YYYY-MM-DD HH:MM:SS`. Returns null rather
  /// than throwing, so one odd row can't take down a list.
  static DateTime? date(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    final s = value.toString().trim();
    if (s.isEmpty) return null;
    return DateTime.tryParse(s.replaceFirst(' ', 'T'));
  }

  /// `31 Jul 2026`
  static String dayMonth(Object? value) {
    final d = date(value);
    return d == null ? '—' : DateFormat('d MMM yyyy').format(d);
  }

  /// `Fri, 31 Jul 2026`
  static String dayFull(Object? value) {
    final d = date(value);
    return d == null ? '—' : DateFormat('EEE, d MMM yyyy').format(d);
  }

  /// `31 Jul 2026, 3:30 PM`
  static String dateTime(Object? value) {
    final d = date(value);
    return d == null ? '—' : DateFormat('d MMM yyyy, h:mm a').format(d);
  }

  /// The API sends slot times as `HH:MM:SS`. Show `3:30 PM`.
  static String time(Object? value) {
    if (value == null) return '—';
    final s = value.toString().trim();
    if (s.isEmpty) return '—';
    final parts = s.split(':');
    if (parts.length >= 2) {
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      if (h != null && m != null) {
        return DateFormat('h:mm a').format(DateTime(2000, 1, 1, h, m));
      }
    }
    return s;
  }

  /// What the API expects back for a date: `YYYY-MM-DD`.
  static String apiDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  /// `2 hours ago`, `just now` — used on the notification list.
  static String relative(Object? value) {
    final d = date(value);
    if (d == null) return '';
    final diff = DateTime.now().difference(d);
    if (diff.isNegative) return dayMonth(d);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return dayMonth(d);
  }

  // -- text ----------------------------------------------------------------

  /// `pending` -> `Pending`; `out_for_delivery` -> `Out For Delivery`.
  static String label(Object? value) {
    final s = value?.toString().trim() ?? '';
    if (s.isEmpty) return '—';
    return s
        .replaceAll(RegExp(r'[_\-]+'), ' ')
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
  }

  // No distance() helper. Nothing in this database stores latitude/longitude —
  // not doctors, not clinics/hospitals/pharmacies, not blood_banks — so there is
  // no distance to format. Leaving the formatter here would only invite a
  // fabricated "2.3 km away" back into the UI.

  static String rating(Object? value) {
    final v = toDouble(value);
    return v <= 0 ? 'New' : v.toStringAsFixed(1);
  }

  static String initials(String? name) {
    final parts = (name ?? '').trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  // -- coercion ------------------------------------------------------------
  // MySQL over JSON hands back DECIMAL as a string and TINYINT as 0/1, so every
  // model reads through these instead of casting.

  static double toDouble(Object? v, [double fallback = 0]) {
    if (v is double) return v;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim()) ?? fallback;
    return fallback;
  }

  static int toInt(Object? v, [int fallback = 0]) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim()) ?? double.tryParse(v.trim())?.toInt() ?? fallback;
    if (v is bool) return v ? 1 : 0;
    return fallback;
  }

  static bool toBool(Object? v, [bool fallback = false]) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      if (['1', 'true', 'yes', 'y'].contains(s)) return true;
      if (['0', 'false', 'no', 'n', ''].contains(s)) return false;
    }
    return fallback;
  }

  static String str(Object? v, [String fallback = '']) {
    if (v == null) return fallback;
    final s = v.toString().trim();
    return s.isEmpty ? fallback : s;
  }
}
