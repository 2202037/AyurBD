# AYUR — PHP/MySQL → Supabase migration report

**Deliverable E.** Covers the Flutter source changes made to compile and run against
the already-created Supabase database.

---

## 0. Read this first — verification status

**Nothing in this migration was compile-checked.** The isolated Linux workspace never
started this session (`VM service not running. The service failed to start.`), so there
was no shell, which means:

- `flutter analyze` was **not** run.
- `flutter pub get` and `flutter build` were **not** run.
- No file could be deleted (see §4 — two dead files were emptied instead).

Every correctness claim below is from reading the schema and the call sites. The type
errors I found this way were real ones (§6), but the honest summary is: this is a
careful manual pass, not a verified build. **Run `flutter analyze` first.** Anything it
reports will almost certainly be a small local fix, not a design problem — but expect a
handful.

**Update — first real build attempt.** `flutter run -d chrome` surfaced exactly one
compile error across the whole program, now fixed:

> `lib/main.dart:95: The method 'onDispose' isn't defined for the type 'ProviderContainer'.`

`onDispose` is a method on Riverpod's `Ref`, not on `ProviderContainer` — the container
only exposes `dispose()`. The line was deleted rather than rewritten, because the
subscription it guarded lives for the whole process anyway (see §6.7). One error in a
ten-repository rewrite is a good signal for the rest of the pass, but it does not make
the pass verified: the compiler stops at the front end, so **runtime** behaviour —
especially the PostgREST query shapes in §5 — is still unexercised.

The database was **not** touched. No SQL file was edited, no migration was run, and no
`INSERT` was added. (`schema.sql` contains three `insert into` statements; all three are
inside PL/pgSQL trigger and helper function *bodies* — `audit_log`, `notify()`,
`handle_new_user()` — and predate this session. There is no data seeding anywhere.)

---

## 1. What the migration replaced

| Before | After |
| --- | --- |
| `dio` HTTP client against `backend/api/v1/index.php` | `supabase_flutter` → PostgREST / GoTrue / Storage |
| PHP JWT in `flutter_secure_storage`, attached by an interceptor | GoTrue session, attached by the client itself |
| §6 `{success, data, meta}` envelope | PostgREST rows + `count` |
| `int` `users.id` | `uuid` `users.id`, shared with `auth.users.id` |
| `uploads/...` paths under the XAMPP asset root | four Storage buckets, absolute URLs |
| PHP role checks in each handler | RLS policies + `is_admin()` |

`dio` is gone from `pubspec.yaml`. The only remaining mentions of dio / ApiClient /
`baseUrl` / `readToken` anywhere under `lib/` are prose inside doc comments explaining
what replaced them (verified by grep).

---

## 2. Every modified Dart file

### 2.1 Core

| File | Change |
| --- | --- |
| `lib/core/network/supabase_service.dart` | **New.** The façade every repository holds: `db(table)`, `currentUserId`, `storageHelper`, and `guard()`, which maps AuthException / PostgrestException / StorageException / SocketException / TimeoutException / FormatException → `ApiException` and rethrows an `ApiException` unwrapped. Also `SupabaseStorage` — `publicUrl`, `signedUrl(bucket, path, {expiresInSeconds = 60})`, `uploadBytes`, and the `avatar` / `productImage` / `blogCover` / `providerDocument` shorthands. |
| `lib/core/providers.dart` | `apiClientProvider` → `supabaseServiceProvider`, reading `Supabase.instance.client`. `secureStoreProvider` and `prefsStoreProvider` unchanged. |
| `lib/core/constants/app_config.dart` | `baseUrl` + per-platform host switch + timeouts removed; `supabaseUrl` / `supabaseAnonKey` (both `--dart-define`) + `isConfigured` + `verboseHttp` added. Four bucket-name constants added. `resolveAsset` became a pass-through that returns `''` for any non-absolute path. |
| `lib/core/storage/secure_store.dart` | `readToken` / `writeToken` removed — GoTrue owns the session now. |
| `lib/main.dart` | `bootstrap()` calls `Supabase.initialize()` and fails fast when `AppConfig.isConfigured` is false. The 401 → logout hook became a GoTrue `authStateChanges` listener. |
| `lib/core/network/api_exception.dart` | Unchanged shape; doc comment updated. |
| `lib/core/network/api_result.dart` | Unchanged — `PageRange`, `PageMeta`, `Paged<T>` all survive. Only `RawPage` died with the client. |

### 2.2 Repositories — all ten rewritten

Each now takes a `SupabaseService` instead of an `ApiClient`. **Public method signatures
are byte-identical to the PHP-era ones**, except for the two forced changes in §3, so the
~60 screens, controllers and the router needed no edits.

| File | Notes |
| --- | --- |
| `auth_repository.dart` | GoTrue `signInWithPassword` / `signUp`; role and profile fields ride in `raw_user_meta_data`, and the `handle_new_user()` trigger writes `public.users`. |
| `directory_repository.dart` | Tables plus the `doctor_directory`, `provider_search` and `doctor_specialties` views, which exist because PostgREST cannot GROUP BY. |
| `appointment_repository.dart` | Slots computed client-side from the doctor's availability columns; payments submitted, never self-verified. |
| `pharmacy_repository.dart` | Products, cart, orders. `_applySort` is the builder-type precedent the other files follow. |
| `blood_repository.dart` | Blood banks and requests; the eight stock columns unpivoted to a group→units map. |
| `content_repository.dart` | Blog, static pages, notifications. |
| `patient_repository.dart` | The reference pattern for the rest. |
| `provider_repository.dart` | Doctor/place workspace. Uses the batched `_patients()` uuid lookup (see §5). |
| `admin_repository.dart` | The largest rewrite — full detail in §5. |

### 2.3 Models — UUID changes

| File | Field | Was | Now |
| --- | --- | --- | --- |
| `app_user.dart` | `AppUser.id` | `int` | `String`, parsed with `Fmt.str` |
| `directory_models.dart` | `Doctor.userId`, `Place.userId` | `int?` | `String?` |
| `appointment_models.dart` | `Appointment.patientId` | `int?` | `String?` |
| `admin_models.dart` | `AdminFeedback.userId` | `int?` | `String?` |
| `admin_models.dart` | `AuditEntry.userId` | `int?` | `String?` |
| `admin_models.dart` | `AuditEntry.entityId` | `int?` | `String?` |

`AuditEntry.entityId` is a String for a second reason: `app_audit_log.entity_id` is
`text`, holding a bigint for most tables and a uuid when the entity is a user.

All six were doing `Fmt.toInt(...)` on a uuid column, which yields **0** — so every
signed-in feedback row would have looked identical to every other, and
`f.userId != null` (`hasAccount`) would have been wrongly true for anonymous ones. All
six are only ever null-checked or passed through, never compared as numbers, so no screen
changed. Confirmed by grep: no `int` user/patient/donor/reviewer/author id fields remain
anywhere in `lib/`.

Every other model kept `int` ids — `doctors.id`, `appointments.id`, `orders.id` and the
rest are still bigints. Only user-identity columns became uuids.

---

## 3. The two signature changes

Everything else is source-compatible. These two could not be:

1. **`AdminRepository.deleteUser(String userId)`** — was `int`. An `int` cannot hold a
   uuid. Every call site already passes `AppUser.id`, which is now a `String`, so the
   call sites did not change.
2. **`AdminRepository.saveBlog(...)` returns `({int id, String slug})`** — the slug is now
   minted client-side (§5) and the caller needs it back.

---

## 4. Two files emptied, not deleted

With no shell I could not `git rm`. Both were left as doc-only stubs (`library;` and a
mapping table) — they declare nothing and import nothing, so they compile to empty
libraries and nothing imports either one.

- `lib/core/network/api_client.dart` — held `ApiClient` and `RawPage`. Leaving the body
  would have been an unresolvable `package:dio` import and a hard build failure.
- `lib/core/constants/api_endpoints.dart` — held the PHP route table.

**`git rm` both whenever convenient.**

---

## 5. Admin repository — the notable decisions

The admin console writes directly from the client with no RPC, because the `aa_`-prefixed
`guard_admin_only_columns` triggers **exempt admins**
(`if public.is_admin() then return new; end if;`). That is what makes
`verification_status`, `status`, `reviews.status` and the feedback columns client-writable
without a single database change.

- **Counting.** `_total(query)` takes the already-filtered query and does
  `.limit(1).count(CountOption.exact)` — an exact total with a one-row payload. Used ~18×.
- **Ambiguous embeds.** `appointments` has two FKs to `users` (`patient_id`,
  `payment_verified_by`) and `payments` has two (`user_id`, `verified_by`). PostgREST
  **rejects** a bare `users(...)` embed on either. Both use the batched `_patients()`
  uuid lookup instead. An audit confirmed these are the only two such tables.
- **Doctor search** filters the `users!inner` embed via
  `.or(..., referencedTable: 'users')`; every doctor has a NOT NULL `user_id`, so no rows
  drop.
- **Appointment search** resolves names to ids first (capped at 200 users, so a
  one-letter search cannot blow the request-line limit), then filters on
  `patient_id.in.(...)` / `doctor_id.in.(...)`, returning an empty page early.
- **Private documents.** `provider-documents` is a private bucket, so licences and BMDC
  certificates are signed on demand (`_signDocument`, 300s). Signing is sequential across
  a page — firing 20 storage calls at once is what triggers rate-limiting and fails the
  whole page instead of one card's link. A missing object returns `''` rather than
  throwing, so one stale path cannot empty the moderation queue.
- **Blog slugs.** No trigger exists and `uq_blog_slug` is a hard constraint, so
  `_uniqueSlug` reproduces the PHP `-2`, `-3`, … behaviour, bounded at 50 attempts with a
  timestamp fallback.
- **Audit log** reads `app_audit_log` (`user_id` / `action` / `entity` / `entity_id` /
  `details`), *not* `audit_log` (`table_name` / `record_id` / `action_type` / …). The
  dashboard's `db_audit_logs` count is the one thing that reads `audit_log`.
- **Computed columns.** `blood_banks` has no `total_units` and `users` has no `status`
  column — both are derived or dropped accordingly. `feedback` has no `responded_at`;
  `updated_at` stands in when a response exists.

---

## 6. Errors found and fixed during self-review

All of these were in code written this session, caught by re-reading it:

1. `providerDocument()` returns `Future<String>` and takes a non-nullable `String`, but
   was called synchronously with a `String?` in both admin shapers — **two hard compile
   errors.** Fixed by making the shapers `async`, adding `_signDocument(Object?)`, and
   turning the `.map()` into a sequential `for` loop.
2. `_userColumns` selected `status`, which `users` does not have (schema 239–253).
3. `_count(table, callback)` used an unimported builder type; replaced with `_total(query)`
   and all ~18 call sites rewritten.
4. The six uuid model fields in §2.3.
5. A dead variable justified by a contrived `assert` in `_appointmentSearchIds`, removed.
6. **Pre-existing, found by audit:** the ambiguous `users` embeds in
   `provider_repository.dart` — these would have compiled fine and failed at *runtime*.
7. **`_profileColumns` in `auth_repository.dart` selected `status`, which `public.users`
   does not have.** The same mistake I caught in `admin_repository._userColumns` and
   missed here. PostgREST answers 400 `column users.status does not exist`, and
   `_loadProfile` runs on *every* login, registration and profile refresh — so sign-in
   failed **after** GoTrue had already accepted the password. Removed, along with the dead
   `row['status'] == 'inactive'` check that could never fire and the then-unused `Fmt`
   import. Behavioural note: there is no whole-account disable switch, because the schema
   never modelled one; provider deactivation still works via `status` on the four provider
   tables.
8. **The login screen advertised four seeded demo accounts that do not exist.**
   `patient@ayur.test` and friends came from the MySQL seed data, and the migration was
   structure-only. Every attempt returned "Invalid login credentials", and repeated
   retries tripped GoTrue's per-IP rate limit — surfacing as "Too many attempts. Please
   wait a moment and try again." The card now explains how to register instead.
9. **`container.onDispose(authSub.cancel)` in `main.dart`** — found by the compiler, not
   by me. `onDispose` is a method on `Ref`, not on `ProviderContainer`; I wrote it from
   memory of the wrong API and it could never have compiled. Deleted rather than
   replaced: the container outlives `runApp` and is never disposed, so there was no
   teardown to hook and nothing to cancel from. The subscription is no longer assigned to
   a variable, and the now-unused `dart:async` import came out with it. `router.dart:255`
   uses `ref.onDispose(...)`, which is the correct API and was left alone.

---

## 7. Known behavioural deltas

None of these change the UI, and no feature was removed. Each is a place where the
Supabase behaviour differs from the PHP behind an unchanged surface:

1. **Provider rejection reasons are no longer delivered.** `moderateProvider(reason:)` is
   still accepted for signature compatibility, but there is no column to store it and no
   client INSERT policy on `notifications`. The rejection itself works; the explanation
   does not reach the provider. *The only user-visible loss in the migration.*
2. **`deleteUser` removes `public.users`, not `auth.users`.** Deleting an auth account
   needs the service-role key, which must never ship in a mobile binary. The profile
   disappears from the console and the orphaned auth row stays. Self-deletion is blocked
   (422).
3. **Audit filter dropdowns read a 500-row recent sample**, so a value that appears only
   in very old entries may be missing from the dropdown. The three headline counts are
   exact.
4. **Feedback vocabulary is translated at the boundary** — the UI's `pending`/`medium` are
   the DB's `new`/`normal`. Screens were not touched.
5. **Legacy `uploads/...` image paths render as placeholders.** Those objects exist in no
   bucket; `resolveAsset` returns `''` so the widgets draw their existing placeholder —
   the same visual result as the old 404.

---

## 8. Suggested next steps

1. `flutter pub get`, then **`flutter analyze`** — the one thing this migration could not
   do for itself.
2. Run with `--dart-define=AYUR_SUPABASE_URL=... --dart-define=AYUR_SUPABASE_ANON_KEY=...`
   (the app fails fast with a readable message if either is missing).
3. `git rm` the two stubs in §4.
4. Smoke-test the admin console first — it has the most new query shapes, and the embed
   ambiguity in §5 is the kind of thing that only shows up at runtime.
5. Three public methods compile but have no call sites, and may be dead:
   `blood_repository.dart:202 registerDonor`, `content_repository.dart:131
   registerFcmToken`, and `BloodRepository.donors`.
