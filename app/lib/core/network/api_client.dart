/// REMOVED — safe to delete this file.
///
/// This held `ApiClient` and `RawPage`: the Dio-based HTTP client for the PHP
/// backend, its JWT interceptor, its §6 envelope unwrapping and its
/// DioException translation. Nothing references any of it any more.
///
/// Every repository now takes a `SupabaseService`
/// (lib/core/network/supabase_service.dart) and talks to PostgREST, GoTrue and
/// Supabase Storage directly. `dio` is no longer in pubspec.yaml, so leaving the
/// old body here would have been an unresolvable import and a hard build
/// failure.
///
/// Emptied rather than deleted only because the migration ran without shell
/// access. `git rm` it whenever convenient — nothing imports it, and as written
/// it declares nothing and imports nothing, so it compiles to an empty library.
///
/// What replaced what:
///   ApiClient.get/post/put/delete   ->  SupabaseService.db(table) + PostgREST
///   ApiClient.getPage / RawPage     ->  PageRange + PageMeta + Paged<T>
///   RawPage.envelope                ->  repositories shape their own extras
///   ApiClient.onUnauthorized (401)  ->  GoTrue session refresh + authStateChanges
///   Dio token interceptor           ->  GoTrue attaches the JWT itself
///   DioException -> ApiException    ->  SupabaseService.guard()
///   AppConfig.baseUrl / timeouts    ->  AppConfig.supabaseUrl + supabaseAnonKey
library;
