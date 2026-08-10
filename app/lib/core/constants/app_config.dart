/// Build-time configuration. Nothing secret lives here (§10) — the anon key is
/// designed to be shipped in a client binary, and every table it can reach is
/// gated by the RLS policies in `supabase/rls_policies.sql`.
///
/// The app now uses fixed Supabase credentials so release builds do not depend
/// on `--dart-define`.
library;

import 'package:flutter/foundation.dart' show kIsWeb;

class AppConfig {
  const AppConfig._();

  static const String appName = 'AYUR';

  static const String supabaseUrl = 'https://cbmmhygivrejcjpfodkr.supabase.co';

  static const String supabaseAnonKey =
      'sb_publishable_jhfgd59kqxmBmSR1XciofQ_TeWGrF5G';

  // -------------------------------------------------------------------------
  // Backend reachability
  //
  // The Supabase backend is the SAME deployed HTTPS host on every platform —
  // web, Android and iOS. It is deliberately a `const`, not a `--dart-define`,
  // so a release build cannot be produced against a developer's machine by
  // forgetting a flag.
  //
  // What *is* environment-dependent is the FRONTEND origin: a debug web build
  // is served from http://localhost:<port>, a release web build from the
  // production domain, and a phone has no origin at all. Those two ideas used
  // to be conflated, which is the bug this section exists to prevent — see
  // [paymentReturnTarget].
  // -------------------------------------------------------------------------

  /// Hosts that are valid for a *frontend* dev server but never for the
  /// backend. A phone resolving one of these reaches itself, not the server.
  static const Set<String> _loopbackHosts = {
    'localhost',
    '127.0.0.1',
    '0.0.0.0',
    '::1',
    // The Android emulator's alias for the host machine. Correct for the old
    // XAMPP setup, meaningless for a hosted Supabase project.
    '10.0.2.2',
  };

  /// Fails fast if [supabaseUrl] or [supabaseAnonKey] could not work in
  /// production. Called by `bootstrap()` in main.dart before
  /// `Supabase.initialize`.
  ///
  /// This is a real runtime check rather than an `assert`, because an assert is
  /// compiled out of exactly the build where the mistake matters. Throwing here
  /// costs one string comparison at startup and converts a class of silent
  /// "the app works on my machine" failures into an immediate, named error.
  static void assertValidBackendConfig() {
    final uri = Uri.tryParse(supabaseUrl);

    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw StateError(
        'AppConfig.supabaseUrl is not a valid absolute URL: "$supabaseUrl".',
      );
    }
    if (uri.scheme != 'https') {
      throw StateError(
        'AppConfig.supabaseUrl must use https, got "${uri.scheme}". '
        'Android 9+ and iOS ATS both block cleartext by default, so an http '
        'backend fails on device even when it works in a browser.',
      );
    }
    if (_loopbackHosts.contains(uri.host.toLowerCase())) {
      throw StateError(
        'AppConfig.supabaseUrl points at "${uri.host}", which on a phone means '
        'the phone itself. The Supabase backend must be the deployed host. '
        'A localhost origin is only ever valid for the Flutter web dev server '
        '(see AppConfig.paymentReturnTarget).',
      );
    }
    // The publishable/anon key is meant to ship in a client binary; a secret
    // key is not, and shipping one would hand every installer full
    // RLS-bypassing access to the database.
    if (supabaseAnonKey.startsWith('sb_secret_') ||
        supabaseAnonKey.contains('service_role')) {
      throw StateError(
        'AppConfig.supabaseAnonKey looks like a SECRET key. Flutter must only '
        'ever carry the publishable/anon key.',
      );
    }
    if (supabaseAnonKey.trim().isEmpty) {
      throw StateError('AppConfig.supabaseAnonKey is empty.');
    }
  }

  // -------------------------------------------------------------------------
  // Frontend origin (Stripe return trip)
  // -------------------------------------------------------------------------

  /// Where Stripe should send the browser back to once checkout finishes.
  ///
  /// This is the one place a localhost URL is legitimate, and only on web.
  /// The distinction the rest of this file is built around:
  ///
  ///   * Supabase backend  — always [supabaseUrl], the deployed HTTPS host.
  ///   * Frontend origin   — whatever is running the UI. On a debug web build
  ///     that is `http://localhost:<port>`; on a release web build it is the
  ///     production domain; on Android/iOS there is no origin, so the return
  ///     trip is the `ayurbd://` custom scheme registered in the manifest.
  ///
  /// Computed from `Uri.base` rather than hard-coded, so the web dev server's
  /// port — which `flutter run` picks at random unless `--web-port` is passed —
  /// is always right without anyone editing a constant.
  ///
  /// The Edge Function validates whatever it receives here against its own
  /// allowlist before handing it to Stripe; this value is a *request*, not a
  /// trusted input. See supabase/functions/create-checkout-session/index.ts.
  static String get paymentReturnTarget {
    if (!kIsWeb) return 'ayurbd';
    try {
      // Origin only — never the current path or hash, which would otherwise
      // round-trip a stale route into the redirect.
      //
      // `Uri.origin` throws a StateError unless the scheme is http/https with a
      // non-empty host. That is always true of a page Flutter web is serving,
      // but a throw here would break the pay button rather than the redirect,
      // so the failure is contained: '' makes the Edge Function fall back to
      // its configured APP_URL, which is the behaviour that shipped before
      // this value was sent at all.
      return Uri.base.origin;
    } on StateError {
      return '';
    }
  }

  /// Log Postgrest/GoTrue traffic to the console.
  ///
  /// Opt-in, not on by default:
  ///     flutter run --dart-define=AYUR_VERBOSE_HTTP=true
  ///
  /// On web this is not a harmless debug aid. Whole response bodies for a
  /// 20-row list endpoint are a lot of JSON per navigation, Chrome's console
  /// keeps every line, and the paint cost of that output lands on the same
  /// thread that draws the UI — enough to make the app feel frozen on a screen
  /// that merely loads a list. It also puts access tokens and profile data into
  /// the browser console, which is why it stays off in release builds.
  static const bool verboseHttp =
      bool.fromEnvironment('AYUR_VERBOSE_HTTP', defaultValue: false);

  static const int defaultPageSize = 20;

  /// Dhaka. Used for appointment date maths so a device set to another zone
  /// still books the slot the clinic expects.
  static const String currency = '৳';
  static const String currencyCode = 'BDT';

  /// Storage bucket names. These are the four buckets created by
  /// `supabase/storage_setup.sql`; the string literals must match it exactly,
  /// and the path conventions documented there are enforced by its policies.
  static const String bucketAvatars = 'avatars';
  static const String bucketProviderDocuments = 'provider-documents';
  static const String bucketProductImages = 'product-images';
  static const String bucketBlogCovers = 'blog-covers';

  /// Pass-through for image URLs reaching the widget layer.
  ///
  /// This used to prefix a relative path such as `uploads/doctors/3.jpg` with
  /// the XAMPP asset root. It no longer builds anything, and that is the point:
  /// resolving a bare path requires knowing which BUCKET it lives in, and the
  /// widgets that call this (`RemoteImage`, `AvatarCircle` in
  /// core/widgets/state_views.dart, used at 26 sites) receive only a path. So
  /// the bucket is applied one layer down instead — every repository maps its
  /// storage columns to absolute public URLs via [SupabaseStorage] before the
  /// model is constructed, and by the time a URL arrives here it is already
  /// absolute.
  ///
  /// A non-absolute value therefore means a leftover PHP-era path (see
  /// storage_setup.sql PART 6 note 4: those rows point at objects that do not
  /// exist in any bucket). Returning '' makes the widgets draw their existing
  /// placeholder instead of firing a request that would 404 — the same visual
  /// result the old code produced when the PHP host 404'd, so no screen
  /// changes.
  static String resolveAsset(String? path) {
    if (path == null) return '';
    final p = path.trim();
    if (p.isEmpty) return '';
    if (p.startsWith('http://') || p.startsWith('https://')) return p;
    return '';
  }
}
