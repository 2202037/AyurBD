/// Build-time configuration. Nothing secret lives here (§10) — the anon key is
/// designed to be shipped in a client binary, and every table it can reach is
/// gated by the RLS policies in `supabase/rls_policies.sql`.
///
/// The app now uses fixed Supabase credentials so release builds do not depend
/// on `--dart-define`.
library;

class AppConfig {
  const AppConfig._();

  static const String appName = 'AYUR';

  static const String supabaseUrl = 'https://cbmmhygivrejcjpfodkr.supabase.co';

  static const String supabaseAnonKey =
      'sb_publishable_jhfgd59kqxmBmSR1XciofQ_TeWGrF5G';

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
