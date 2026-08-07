# AGENTS.md

Flutter client for AYUR, a Bangladeshi Ayurvedic healthcare platform. The app
talks **only** to Supabase (PostgREST + GoTrue + Storage) — the legacy PHP/MySQL
backend in `../backend/` is retired, so `dio` is gone and nothing hand-writes a
JWT. The Supabase schema/RLS/storage SQL lives one level up in `../supabase/`.
The root `README.md` describes the dead PHP flow; `app/README.md` is current.

## Commands

- `flutter analyze` — passes; the only output is `info`-level deprecation
  warnings (`Radio` groupValue/onChanged, Supabase `anonKey` in `main.dart` and
  `widget_test.dart`, `userDeleted`). Don't treat them as your regression; don't
  mass-"fix" them.
- `flutter test` — green. `test/widget_test.dart` pumps `AyurApp` inside a
  `ProviderScope` with `prefsStoreProvider` overridden, and initialises Supabase
  with `autoRefreshToken: false` so the router guard has a client but no token
  timer leaks into the test zone. If you add a test that touches a repository,
  mirror that setup — and keep `pumpAndSettle` out: the guard parks everyone on
  the splash (continuous spinner) until `restore()` resolves, which never
  happens in a widget test.
- `flutter run -d chrome` — the Supabase URL and anon key are **hard-coded** in
  `lib/core/constants/app_config.dart`; no `--dart-define` needed. Opt-in network
  logging: `--dart-define=AYUR_VERBOSE_HTTP=true` (noisy on web; keep off).

## Bootstrap contract (lib/main.dart)

Order is load-bearing: `PrefsStore.open()` → `Supabase.initialize(...)` with
`SecureGotrueStorage` → subscribe to `authStateChanges` → `restore()`, all
before `runApp`. Consequences for edits and tests:

- `prefsStoreProvider` (core/providers.dart) **throws** unless overridden —
  main() opens SharedPreferences and overrides it. Widget tests already do this
  (see widget_test.dart).
- `supabaseServiceProvider` reads `Supabase.instance.client`, so anything that
  builds the router (or any repository) needs `Supabase.initialize()` to have run
  first, or an override. `widget_test.dart` calls `Supabase.initialize()` in the
  test to satisfy this.
- 401 / revoked token = normal logout via `signedOutByServer()`, never an error
  dialog. Don't re-add an error screen for it.

## Architecture

- Feature folders: `lib/features/<feature>/{data,presentation}` — repository +
  Riverpod controllers + screens. Shared stuff in `lib/core/` (network, storage,
  utils, widgets), models in `lib/models/`, app wiring in `lib/app/`.
- State: `flutter_riverpod` with plain providers (no codegen). Files are rich
  doc-commented; keep those comments truthful when you change behaviour.
- Every repository call goes through `SupabaseService.guard()` (core/network/
  supabase_service.dart), which converts `PostgrestException`/`AuthException`/
  `StorageException`/socket/timeout into `ApiException`. Never let a raw
  PostgrestException reach a screen.
- Repositories shape wire rows to the exact keys the models parse
  (`specialization`→`specialty`, `hospital_clinic_name`→`workplace`, CSV
  `available_days`→`List`, synthesised `hours`). Query real column names, then
  re-key in `_shape*`; do not rename the model keys.
- Models parse through `Fmt.*` coercion (core/utils/formatters.dart) — Postgrest
  can return numbers as strings. Wire-key mismatches fail **silently** (null),
  so check column name → shape key → model key when adding a field.
- Storage columns hold object **paths**, never URLs. Repositories convert via
  `storageHelper.avatar()/productImage()/blogCover()/providerDocument()` before
  building models; widgets (`RemoteImage`, `AvatarCircle` in
  core/widgets/state_views.dart) only ever see finished URLs.
- Pagination is `PagedController` + `PagedListView` (core/paged_controller.dart),
  1-based pages, `.count(CountOption.exact)` for totals. Six list screens share
  it — don't hand-roll scroll-driven loading.
- Auth/roles: `role` is read from `public.users`, never client-supplied
  metadata. `admin` is not self-registerable. Router guards live in
  `lib/app/router.dart`; `_under()` does segment-aware prefix matching so the
  patient `/doctors` directory never matches the `/doctor` workspace. Route
  strings live in the `Routes` class — don't hard-code them in widgets.

## Supabase backend (../supabase/)

- Canonical SQL files: `schema.sql` → `rls_policies.sql` → `storage_setup.sql`, all
  idempotent. `migrations/` holds timestamped copies for `supabase db push`
  (project `cbmmhygivrejcjpfodkr`, linked via the CLI). After editing a
  canonical file, re-copy it into `migrations/` before pushing; `0000` is a
  deliberate reset that drops `public` — push only to a disposable project.
  `admin_bootstrap.sql` promotes a pre-created Auth user to `admin`;
  SQL cannot create the Auth user itself. Old MySQL dumps / `admin@ayur.test`
  credentials do **not** work.
- No RLS on views: `admin_dashboard_stats` is a plain `security_invoker` view
  with direct SELECT revoked from client roles; the admin gate is the SECURITY
  DEFINER `admin_dashboard_stats()` function, which the Dart `dashboard()` calls
  via RPC (a non-admin gets 42501 → 403).
- Four buckets: `avatars`, `product-images`, `blog-covers` (public),
  `provider-documents` (private, signed URLs). Bucket names in
  `app_config.dart` must match `storage_setup.sql`; upload paths must start with
  the owner's uuid or storage RLS refuses them.
- The anon key is committed on purpose (RLS is the real gate). Error mapping
  lives in `SupabaseService` — 42501 = RLS refusal, PGRST116 = no row (404),
  23505 = unique violation (friendly message per constraint), P0001 = raised
  business rule.

## Conventions / gotchas

- No `assets/` bundle in pubspec — every image loads over HTTP. Don't add an
  `assets/` entry unless you actually add files.
- All formatting goes through `Fmt` (money `৳`, dates, times). There is
  deliberately **no** distance/geo formatter — the schema has no lat/lng.
- Supabase session and cached user live in the OS keystore
  (`SecureGotrueStorage`); theme mode is the only thing in SharedPreferences.



## BUSINESS RULES

- Payment verification is manual only.
- Never mark an appointment as paid until an admin verifies the payment.
- Appointment slots must never allow double booking.
- Doctor confirmation is the only action that generates a confirmation code.
- Preserve all payment history; never overwrite verified records.
- Keep appointment status and payment status as separate concepts.
- All business rules must be enforced on the backend, not just in the Flutter client.