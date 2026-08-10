# AYUR Flutter App — Implementation Guide

A complete walkthrough of **how the AYUR Flutter app is implemented**: the
architecture, every feature and which file implements it, how the app talks to
its Supabase backend, and explanations of the important code.

> This document describes the **current** codebase in `app/`. The reader is the
> `AGENTS.md` file in this folder plus this document; `AGENTS.md` covers the
> commands, bootstrap contract and conventions, this document covers *how the
> thing is built*.

---

## 1. Big picture

AYUR is a Bangladeshi Ayurvedic healthcare platform. This repository (`app/`)
is **only the Flutter client**. There is no custom backend server anymore:

- The legacy PHP/MySQL backend under `../backend/` is **retired** and dead.
- The Flutter app talks **only to Supabase** — PostgREST (row data), GoTrue
  (auth) and Storage (files) — plus two Stripe Edge Functions for online
  payments.
- The database schema, Row-Level-Security policies and storage buckets all live
  in `../supabase/` and are the *real* enforcement layer of the business rules.
  The Flutter app is a thin presentation layer over them.

Because all client code is a thin layer over RLS-protected tables, the golden
rule everywhere in this app is:

> **The client asks; the database decides.** Every business rule (double-booking
> prevention, payment verification, stock levels, admin-only writes, money
> amounts) is enforced in `../supabase/schema.sql` / `rls_policies.sql`, and the
> Flutter layer only ever *requests* — an RLS refusal or a guarded `RPC` raising
> a business rule shows up as a clean error the UI can react to.

A request travels this path:

```
Screen (Widget / ConsumerWidget)
  └─ Riverpod controller (StateNotifierProvider / FutureProvider)
       └─ Repository (feature/data/..)
            └─ SupabaseService (core/network/supabase_service.dart)
                 └─ Supabase Flutter SDK (PostgREST / GoTrue / Storage /
                    Edge Function invoke)
                      └─ Supabase project (db + RLS + triggers + SECURITY
                         DEFINER functions)
```

---

## 2. Project layout

```
app/
├── lib/
│   ├── main.dart                  # Bootstrap (order is load-bearing)
│   ├── app/
│   │   ├── app.dart               # MaterialApp.router — thin
│   │   └── router.dart            # GoRouter, all routes + role guards
│   ├── core/                      # Shared, feature-agnostic layers
│   │   ├── constants/             # app_config, app_color, app_theme,
│   │   │                          #   api_endpoints (legacy stub)
│   │   ├── deep_links/            # deep_link_service.dart (Stripe return)
│   │   ├── network/               # supabase_service, api_exception,
│   │   │                          #   api_result (legacy), api_client (REMOVED)
│   │   ├── storage/               # prefs_store (theme), secure_store (session)
│   │   ├── utils/                 # formatters (Fmt), validators,
│   │   │                          #   idempotency, payment_debug_logger
│   │   └── widgets/               # state_views (loading/empty/error/pills/
│   │                              #   images), paged_list_view
│   ├── features/                  # One folder per domain feature
│   │   ├── auth/                  # data/auth_repository, presentation/...
│   │   ├── appointments/          # data/appointment_repository, presentation/...
│   │   ├── payment/               # data/payment_service (only piece of the
│   │   │                          #   payment logic that lives in Dart)
│   │   ├── directory/             # doctors + clinics/hospitals/pharmacies
│   │   ├── pharmacy/              # products, cart, orders
│   │   ├── patient/               # dashboard, my-reviews, nearby, emergency
│   │   ├── provider/              # doctor/hospital/clinic/pharmacy workspaces
│   │   ├── blood_bank/            # stock, donors, requests
│   │   ├── content/               # notifications, blog, reviews, feedback
│   │   ├── admin/                 # the whole moderation console
│   │   └── home/                  # patient shell + tabbed navigation
│   └── models/                    # plain fromJson() models, app_user, etc.
├── test/widget_test.dart          # smoke test with Supabase + prefs overrides
└── supabase/                      # Edge Functions (see ../supabase for SQL)
```

**Layering rules** enforced by the code itself:

- A `features/…/data/` file may import `core/` and other `features/` **data**
  files, but never `presentation/`.
- `core/` never imports `features/` (there is one documented exception —
  the payment-health provider is wired in `appointment_repository.dart`
  specifically to avoid a core→feature import cycle).
- Models are plain `fromJson` factories; they know nothing about Supabase.

---

## 3. How the app talks to the database

### 3.1 The one façade — `SupabaseService`

**File:** `lib/core/network/supabase_service.dart`

Every repository holds a `SupabaseService`. It is a deliberate *thin* façade
over the Supabase client — it does **not** wrap every Postgrest verb (that
would mean re-implementing the fluent builder), it adds the three things the
whole app depends on:

1. **`guard()`** — every repository call is wrapped. It catches
   `AuthException`, `PostgrestException`, `StorageException`,
   `FunctionException`, `SocketException`, `TimeoutException` and
   `FormatException` and converts each into an `ApiException` (see 3.2). This
   is what keeps a raw RLS refusal from ever reaching a screen.
2. **`db(table)`** — a raw `SupabaseQueryBuilder`. Repositories build their
   `.select()/.update()/.insert()/.eq(...)` chains on it.
3. **`rpc<T>(fn)`** — calls the schema’s SECURITY DEFINER functions (booking,
   placing orders, stats, dashboard, etc.).
4. **`functionsInvoke<T>()`** — calls the two Stripe Edge Functions.
5. **Storage helpers** — `storageHelper.avatar()/productImage()/blogCover()/
   providerDocument()` turn storage **object paths** into finished URLs (see
   3.4) plus `uploadBytes()`/`remove()`.

### 3.2 The single error type — `ApiException`

**File:** `lib/core/network/api_exception.dart`

Every failure in the app arrives as `ApiException` with:

- `message` — what to show the user.
- `statusCode` — drives the predicates `isUnauthorized` (401 → normal logout),
  `isConflict` (409 → “that slot was just taken”), `isValidation`
  (400/422 → form errors), plus `fieldError(field)`.
- `errors` — `{field: message}` used to back form fields.
- `code` — a stable machine code (`ALREADY_PAID`, `OUT_OF_STOCK`, …) the
  screens branch on instead of matching English text.

The heart of the mapping lives in `SupabaseService._fromPostgrest()`:

```dart
case '42501':  // Row Level Security refusal  -> 403
case '23505':  // unique violation           -> 409 + constraint-specific text
case '23503':  // foreign key                -> 409 "That item no longer exists."
case '23514'/'22P02': // CHECK / enum        -> 422
case 'P0001':  // raised business rule       -> 422, message passed through
case 'PGRST116': // .single() no row         -> 404
case 'PGRST301'/'401': // no/expired JWT     -> 401 "session expired"
```

Two extra details worth knowing:

- **`_detailCode()`**: the schema’s functions raise
  `raise exception using errcode='P0001', detail='ALREADY_PAID'`. `guard`
  extracts the `SHOUTING_SNAKE_CASE` code from DETAIL so a screen can react to
  the *rule* (`e.hasCode('ALREADY_PAID')`) and not to a sentence that someone
  may later reword.
- **`_uniqueMessage()`**: unique-violation messages are matched on constraint
  names (`appointments_no_double_booking`, `reviews_one_per_user`,
  `uq_payments_stripe_session`, …) to reproduce the friendly PHP-era sentences.

### 3.3 Pagination

PostgREST returns rows plus the total in the `Content-Range` header when asked
with `count: CountOption.exact`. Three small types replace the old PHP
`meta` block:

- `PageRange(page, limit)` — 1-based page → `from`/`to` range indexes.
- `PageMeta(page, limit, total)` — `hasMore`, `lastPage`.
- `Paged<T>` — items + meta; `merge()` appends the next page.

Repositories return `Paged<T>` (see §5.2 for the controller that consumes it).

### 3.4 Storage: objects paths, never URLs

**Files:** `lib/core/network/supabase_service.dart` (`SupabaseStorage`),
`lib/core/constants/app_config.dart` (bucket names), `../supabase/storage_setup.sql`

- Columns store the object **path** (`<owner-uuid>/avatar.jpg`), never a URL.
  This lets the project ref change without a data migration.
- `SupabaseStorage.publicUrl(bucket, path)` builds an absolute CDN URL for the
  three **public** buckets (`avatars`, `product-images`, `blog-covers`).
  Relative `uploads/…` leftover PHP paths return `''` so the widget draws its
  placeholder instead of firing a 404.
- The **private** `provider-documents` bucket is signed
  (`providerDocument()`, default 60s; the admin list uses 300s).
- Uploads are required to start with the owner’s uuid and are sanitised in
  `_sanitize()` (no `/`, no `..`); the storage RLS policies are what actually
  enforce the folder convention.

Repositories convert paths → URLs **before** building a model, so the widget
layer (`RemoteImage`, `AvatarCircle` in `core/widgets/state_views.dart`) only
ever renders finished URLs. Examples:

```dart
// directory_repository.dart  (doctor row)
'profile_image': _sb.storageHelper.avatar(r['profile_image'] as String?),
// admin_repository.dart  (private licence document — signed, 5 min)
await _sb.storageHelper.signedUrl(AppConfig.bucketProviderDocuments, p, expiresInSeconds: 300),
```

### 3.5 Edge Functions

Two Deno functions live in `supabase/functions/` (see §7 for the full payment
flow):

- `create-checkout-session/index.ts` — mints a Stripe Checkout session.
- `stripe-webhook/index.ts` — records the actual charge.

The client calls them through `SupabaseService.functionsInvoke()` (wrapped in
`guard`, so a `FunctionException` is translated via `_fromFunction` into an
`ApiException` carrying the function’s `{code, message}` envelope).

---

## 4. Startup — `lib/main.dart`

The bootstrap order is load-bearing and documented in `AGENTS.md`. In code
terms:

1. `PrefsStore.open()` — opens SharedPreferences **before** the first frame so
   a dark-mode user doesn’t flash light. The store is injected by overriding
   `prefsStoreProvider`.
2. `AppConfig.assertValidBackendConfig()` — refuses to start against an `http`
   / loopback / secret-key config that could not work on a device.
3. `Supabase.initialize(url, anonKey, authOptions: FlutterAuthClientOptions(
   localStorage: SecureGotrueStorage()))` — the session (refresh token) is kept
   in the OS keystore, not SharedPreferences.
4. Enable `PaymentDebugLogger` from `--dart-define=AYUR_PAYMENT_DEBUG`.
5. A `ProviderContainer` is built with the prefs override.
6. `Supabase.instance.client.auth.onAuthStateChange.listen(...)` — GoTrue
   pushes session lifecycle. `signedOut`/`userDeleted`/failed `tokenRefreshed`
   → `authController.signedOutByServer()` — **a 401 is a normal logout**, never
   an error dialog.
7. `await restore()` — reads the cached user from secure storage (no network)
   so the router already knows who is signed in on the very first redirect.
8. `deepLinkService.start(...)` — only *after* `restore()` resolved, so a
   cold-start Stripe redirect lands straight on `/payment-success` instead of
   being swallowed by the splash guard.
9. `runApp(UncontrolledProviderScope(container: …, child: const AyurApp()))`.

`AyurApp` (`app/app.dart`) is deliberately thin: `MaterialApp.router` wired to
the theme provider and the router provider.

---

## 5. State management: Riverpod

`flutter_riverpod` (no codegen). The providers used:

| Provider kind | Where | Used for |
|---|---|---|
| `Provider<T>` | repositories, services | dependency wiring |
| `StateNotifierProvider` | `PagedController<T>`, `AuthController`, `ThemeModeController`, cart | mutable state |
| `FutureProvider.autoDispose` | dashboards | one-shot data |
| `FutureProvider.family` | payment health check | param data |
| `StateProvider` | filter values | filter chips |

Two patterns matter most.

### 5.1 Controllers compose filters → `PagedController`

`lib/core/paged_controller.dart` implements infinite scroll once, and six list
screens plus every admin list share it. A controller is built by watching the
filter providers and the repository:

```dart
// admin_controllers.dart — one of ~14 identical list providers
final adminUsersProvider =
    StateNotifierProvider<PagedController<AdminUser>, PagedState<AdminUser>>((ref) {
  final role  = ref.watch(adminUserRoleProvider);    // StateProvider<String?>
  final search = ref.watch(adminUserSearchProvider);
  final repo  = ref.watch(adminRepositoryProvider);
  return PagedController<AdminUser>(
    (page) => repo.users(page: page, role: role, search: search),
  );
});
```

Changing a `StateProvider` rebuilds the `PagedController` → `PagedState` resets
to page 1 for free — screens change a filter and **never** call `reload()`.

`PagedState<T>` is what screens render:
- `isInitialLoad` / `isFirstPageError` / `isEmpty` / `hasMore` /
  `hasTrailingError`.
- Branched on inside `PagedListView` (`core/widgets/paged_list_view.dart`):
  spinner → error view → empty view → the list + footer.

`PagedController` guards the classic faults:
- **overlapping requests** — `_inFlight` flag;
- **stale responses** — a `_generation` counter ignored any response older
  than the newest reset/refresh/filter change;
- **repeat-firing a failed page on every scroll** — a 3-second cooldown after a
  failure (the footer’s explicit “Try again” is the intended recovery path);
- **null/empty handling** — an `initial` state that used to render a blank
  list is treated as loading (see the long comment on `isInitialLoad`).

`LoadMoreOnScroll` wraps the list and fires `onLoadMore` only on genuine
`ScrollUpdateNotification`/`ScrollEndNotification` movement within 320px of the
bottom — not on the other `ScrollNotification` subtypes, which would turn one
scroll into a cascade of page requests.

### 5.2 Auth state

`lib/features/auth/presentation/auth_controller.dart` holds `AuthState`
(`unknown | authenticated | unauthenticated` + `user` + `busy`). The router
watches it (§6). `main.dart`’s auth stream calls `signedOutByServer()`.

---

## 6. Routing and role guards — `lib/app/router.dart`

GoRouter, one file, ~800 lines. The fundamentals:

- `Routes` — every path in one class; widgets never hard-code a route string.
- `_guard(auth, state)` runs on **every** navigation. Rules:
  1. Not resolved yet → everything parks on `/splash`.
  2. Guest → static pages / emergency / feedback / the five sign-up forms are
     allowed (`_openToAll` / `_anonymousOnly`); everything else bounces to
     `/login`.
  3. Signed in → splash/auth screens bounce to the role’s landing
     (`_landingFor`): patient → `/home`, doctor → `/doctor`, the three place
     roles → `/place`, admin → `/admin`, unknown → `/login`.
  4. `_patientOnly` prefixes bounce every non-patient out.
  5. Each workspace is fenced by **prefix** using `_under(loc, prefix)`, which
     is segment-aware: `_under('/doctors', '/doctor')` is `false`, so the
     patient `/doctors` directory never matches the `/doctor` workspace.
- `_AuthRefresh` bridges Riverpod → go_router’s `refreshListenable`; it only
  notifies when `status` or `role` actually changed (not on every `busy` flip).

Route topology highlights:
- The patient app is a `StatefulShellRoute.indexedStack` (5 tabs: home,
  doctors, shop, appointments, profile) with per-tab navigator keys.
- Booking, cart, checkout, orders, payments, receipts and Stripe return screens
  are **outside** the shell (root navigator) so a mid-checkout tab switch can’t
  silently abandon a flow.
- `/payment-success` and `/payment-cancelled` are reachable by any signed-in
  user (a cold-start deep link is exactly the use-case); the success screen
  re-reads the appointment rather than trusting the URL, and a `return_to`
  query is checked against `paymentReturnAllowlist` (`resolvePaymentReturn`).

---

## 7. Features: file-by-file

Each feature folder follows **`{data,presentation}`**. Below, “file” paths are
relative to `lib/features/<feature>/`.

### 7.1 Auth (`auth/`) — `models/app_user.dart`

| Concern | File |
|---|---|
| GoTrue calls + profile mirror | `data/auth_repository.dart` |
| Session controller | `presentation/auth_controller.dart` |
| Login / role picker / 5 register forms / profile / splash | `presentation/{login_screen, role_picker_screen, register_screen, doctor_register_screen, hospital_register_screen, clinic_register_screen, pharmacy_register_screen, profile_screen, splash_screen}.dart` |
| Role-specific field builders | `data/registration_fields.dart`, `presentation/widgets/registration_fields_ui.dart` |
| Account section (shared by roles) | `presentation/widgets/account_section.dart` |

**How auth works under the hood** (`auth_repository.dart`):

- `login()` → `auth.signInWithPassword` + `_loadProfile()` reads `public.users`
  so `role` is authoritative (never client-supplied metadata), then caches the
  user JSON in the keystore.
- `register()` → `auth.signUp` with profile + role fields as **user metadata**.
  The `handle_new_user()` trigger in `schema.sql` inserts the `public.users`
  row *and* the provider’s directory row in the same transaction — `admin` is
  deliberately not in `_selfRegisterableRoles` and `_safeRole` clamps anything
  unknown to `patient`; the `aa_guard_users` trigger blocks changing `role`
  afterwards.
- `updateProfile()` — only the safe columns; `role`/`email` are absent on
  purpose (touching either would 403 via the guard trigger).
- `changePassword()` — re-signs in with the current password first (GoTrue’s
  `updateUser(password:)` alone would let anyone with an unlocked device change
  it).
- `logout()` — best-effort `auth.signOut()` (works offline) then `store.clear()`.
- `cachedUser()` — `hasSession` (Supabase already rehydrated+refreshed) + the
  cached JSON → cold start with no network.

`profile_screen.dart` backs **two** routes: `/profile` (patient tab) and
`/account` (every other role gets the identical screen pushed over their own
workspace, so they don’t wear the patient tab bar).

Mobile deep link history: this is also where old sessions wrote `ayur.jwt` —
`SecureStore.clear()` still deletes the legacy key so an upgraded app doesn’t
leave a dead PHP bearer token in the keystore.

### 7.2 Appointments + payments (`appointments/`, `payment/`)

| Concern | File |
|---|---|
| Slots / book / cancel / list / receipts / health check | `data/appointment_repository.dart` |
| **All** payment RPCs + Stripe + error mapping | `payment/data/payment_service.dart` |
| Book flow (calendar picker + slot grid) | `presentation/book_appointment_screen.dart` |
| My appointments / payments list | `presentation/my_appointments_screen.dart`, `payments_screen.dart` |
| Stripe return screens | `presentation/payment_success_screen.dart`, `payment_cancelled_screen.dart` |
| Receipt + PDF | `presentation/receipt_screen.dart` |

The **single most important architectural decision** is documented in
`payment_service.dart`’s library doc: *payment logic used to be spread across
three layers that disagreed*. Now the payability rule lives only in the
database (`appointment_payability()`), and **every** Dart path that touches
money goes through `PaymentService`:
- `payability(appointmentId)` — asks the server, free of side effects.
- `submitManualPayment(...)` — bKash/Nagad/Rocket/… via the
  `submit_manual_payment` RPC (advisory-locked, idempotent; writes a
  `payments` row with `payment_status='pending'`; **never** marks the
  appointment paid).
- `startCardCheckout(...)` — calls the Edge Function which asks
  `gateway_payment_begin()`.

`PaymentFailure` enum mirrors the SQL-side codes; `failureForCode()` /
`_safeMessage()` make sure a patient never sees raw SQL/RLS text.

**Booking** (`appointment_repository.dart`): `slots()` reads the doctor’s
schedule first (to distinguish “off duty” from “fully booked”), then calls the
`available_slots` RPC. `book()` calls the `appointments_book` RPC rather than
an INSERT — the server re-checks the slot, stamps the fee from
`doctors.consultation_fee` and snapshots `doctor_name`. A 23505 mid-flight
turns into the “That time slot has just been taken” 409 that both
`appointment_models.dart` and `supabase_service._uniqueMessage` know.

### 7.3 The full Stripe payment flow (end to end)

1. **Patient taps “Pay online”** on an unpaid appointment
   (`payments_screen.dart`).
2. `PaymentService.startCardCheckout` → `functionsInvoke('create-checkout-session')`
   with `{appointment_id, return_target}`. `return_target` is the client’s own
   origin — `AppConfig.paymentReturnTarget` (the `ayurbd` scheme on mobile, the
   `Uri.base.origin` on web).
3. **Edge Function** (`supabase/functions/create-checkout-session/index.ts`):
   - validates the JWT via `auth.getUser()`,
   - validates `return_target` against an **allowlist** (mobile scheme,
     loopback dev origins, `APP_WEB_ORIGINS`, or `APP_URL` fallback) and refuses
     a target that is the Supabase host itself,
   - asks `public.gateway_payment_begin()` (ownership check + advisory lock +
     `assert_appointment_payable()` + returns live `payment_sessions` row),
   - **reuses** an open checkout when the patient taps twice (idempotency),
   - creates/retrieves the Stripe Customer, creates a Checkout Session
     (BDT, `expires_at` = 45min), and attaches the identifiers to the session
     row via `gateway_payment_attach()` (service role).
4. **Stripe hosts the page.** Patient pays or cancels.
5. **Webhook** (`supabase/functions/stripe-webhook/index.ts`) is the
   *authoritative record*:
   - verifies the `stripe-signature` (nothing before that touches the DB),
   - on `checkout.session.completed` with `payment_status=paid` →
     `record_payment_split()` (idempotent on `stripe_session_id`). The
     `payments_apply_verification` trigger fires on that INSERT: sets
     `appointments.payment_status='paid'`, confirms the appointment, splits
     the fee into `admin_share` + `provider_share`, writes the
     `provider_payouts` ledger — all in one transaction.
   - expired / failed attempts → `handle_failed_payment()` retires the session
     row so the patient can start fresh; the booking stays awaiting payment.
   - **Retry discipline**: transient failures answer **500** (Stripe
     redelivers); permanent ones (terminal SQLSTATEs) answer 2xx and log
     `NEEDS_RECONCILIATION` so a human reconciles them.
6. **Browser/app returns** to `success_url`/`cancel_url`.
   - Web: full load on `/#/payment-success?…`; GoRouter reads the hash.
   - Mobile: `ayurbd://payment-success?…` → OS → `deep_link_service.dart`
     (`DeepLinkService.toRouterLocation`) → `router.go(...)`.
7. `PaymentSuccessScreen` re-reads `appointment.byId(id)` (RLS-scoped to the
   signed-in patient) to show the post-webhook state, and can display the
   receipt / PDF (`receipt_screen.dart`).

### 7.4 Directory (`directory/`) — doctors & places

| Concern | File |
|---|---|
| Doctors + three place kinds | `data/directory_repository.dart` |
| Doctor list/detail | `presentation/{doctors, doctor_detail}_screen.dart` |
| Clinics/hospitals/pharmacies list/detail | `presentation/{places, place_detail}_screen.dart` |

Key points:
- Everything filters `status='active' AND verification_status='verified'`
  (also enforced by RLS) — doubles as an index hint and keeps `count` honest.
- **Shaping**: the PHP shapers renamed columns on the way out
  (`specialization→specialty`, `hospital_clinic_name→workplace`,
  `description→about`, opening/closing → one `hours` string, CSV
  `available_days` → `List`). The Dart models parse those *output* names, so
  `_shapeDoctor`/`_shapePlace` reproduce the renames to keep the models
  byte-compatible (see the `!left` embeds, and `_hours()` synthesised from
  `opening_time`/`closing_time`).
- `_escapeOr()` neutralises `,()*` so user search terms can’t break the `or()`
  filter list syntax.

### 7.5 Pharmacy (`pharmacy/`)

| Concern | File |
|---|---|
| Products / cart / orders | `data/pharmacy_repository.dart` |
| Cart state | `presentation/cart_controller.dart` |
| Screens | `presentation/{products, product_detail, cart, checkout, orders, order_detail}_screen.dart` |

Design decision documented in the library doc: PostgRest can’t do the PHP cart
payload’s join+typeof work, so `_cartRows()` + `_buildCart()` reproduce
it — display totals are computed from the same figures `place_order` reads, so
they can’t drift by more than a concurrent edit. **Real money** is computed
only in the `place_order` SECURITY DEFINER RPC (stock decrement with
`WHERE stock >= quantity`, snapshot line items, empty the cart) inside one
transaction; `guard_orders_insert` rejects any other way to create an order.
Checkout ships an **idempotency key** (`uq_orders_idempotency`) so a double tap
/ lost response / resumed app can’t charge twice. The delivery-fee rule
(free > ৳500 else ৳60) is duplicated in `_deliveryFeeFor` **and** inside
`place_order` so they can never disagree.

### 7.6 Patient extras (`patient/`)

| Concern | File |
|---|---|
| Dashboard (`my_stats` RPC) | `presentation/patient_dashboard_screen.dart` |
| My reviews | `presentation/my_reviews_screen.dart`, `review_sheet.dart` |
| Nearby (search across 4 provider types via `provider_search` view) | `presentation/nearby_screen.dart` |
| Emergency hotlines + request | `presentation/emergency_screen.dart` |
| Feedback | `presentation/feedback_screen.dart` |
| Repository | `data/patient_repository.dart` |

Notes: `my_stats` is a SECURITY DEFINER function returning tallies in one row
(replaces ~7 count queries). Nearby uses a view (`provider_search`) and then
`_enrich()` fills in phone/address/subtitle per type. Emergency is public on
purpose (no session needed); the request is **not** transmitted (no SMS gateway
configured) — the UI says so rather than showing a false “sent!”.

### 7.7 Provider workspaces (`provider/`) — §6–§9

| Concern | File |
|---|---|
| Doctor + place dashboards, profile updates, appointments, payouts, reviews | `data/provider_repository.dart` |
| Controllers | `presentation/provider_controllers.dart` |
| Doctor screens | `presentation/{doctor_dashboard, doctor_appointments, doctor_payouts, doctor_profile}_screen.dart` |
| Place screens (hospital/clinic/pharmacy share the tree) | `presentation/{place_dashboard, place_profile}_screen.dart` |
| Shared `ProviderReviewsScreen` | `presentation/provider_reviews_screen.dart` |
| Widgets (stat grid, verification banner, workspace actions) | `presentation/widgets/` |

Details:
- One repository serves all four provider roles; nothing passes a provider id —
  the row is resolved from `auth.uid()` via `_requireDoctor()` /
  `_requirePlace()` and the RLS owner policies, so a doctor calling a place
  method just gets a 403.
- **Escrow money flow**: patient pays platform → admin verifies (the
  verification trigger splits commission + writes `provider_payouts`) → provider
  confirms the booking now that their share is credited (`setAppointmentStatus`,
  which also lets the `appointments_set_confirmation_code` trigger mint the
  confirmation code). `payouts()` reads `provider_payouts`.
- Profile updates span **two tables** (`users` + the provider table); `_split`
  routes each key and `_coerce` casts form strings to the column types Postgres
  demands (int/bool/numeric), `_clean` drops admin-only columns so they can
  never 403 a save, and `_columnsFor` keeps only columns the table actually has
  (a phantom column is a hard PostgREST error, not a no-op).
- `doctorStats`/count queries back the dashboards; `doctor_stats` RPC + two
  real count queries (today/upcoming).

### 7.8 Blood bank (`blood_bank/`)

| Concern | File |
|---|---|
| Stock / donors / requests | `data/blood_repository.dart` |
| Screens | `presentation/{blood_bank, blood_request}_screen.dart` |

The interesting bit: `blood_banks` stores the 8 groups as 8 integer *columns*;
the PHP `UNION ALL` unpivot is reproduced in `_expand()` (one `BloodStock` per
group, synthetic id `bank_id*10+group`). Pagination stays keyed to **banks**
so infinite scroll can’t run off the end. `status` per group (`unavailable`
<1, `low` <5, else `available`) is derived in `_statusFor()`.

### 7.9 Content (`content/`)

| Concern | File |
|---|---|
| Notifications, blog, reviews, feedback | `data/content_repository.dart` |
| Blog list/detail + static pages | `presentation/{blog, blog_detail, about, terms, privacy, contact, static_page}_screen.dart` |
| Notifications | `presentation/notifications_screen.dart` |

Notes: notifications are **read-only** to the client (`authenticated` has
SELECT/UPDATE, no INSERT grant; rows are written only by triggers). The unread
badge uses a separate `head: true` count query so it stays correct when the
list is paginated. Blog list omits `content` so `BlogPost.isSummaryOnly` stays
true; detail fetches the body + up to 4 same-category posts. Reviews aggregate
comes from the target’s cached `rating`/`total_reviews` (kept in step by the
`recalc_reviewable_rating` trigger). Feedback allows guests (name+email then
required) and never sends `status`/`priority` (admin-only guarded columns).

### 7.10 Admin console (`admin/`)

| Concern | File |
|---|---|
| Repository (12+ sections) | `data/admin_repository.dart` |
| Controllers | `presentation/admin_controllers.dart` |
| Screens | `presentation/admin_{dashboard, users, providers, appointments, reviews, feedback, blood_banks, blogs, payments, payouts, audit}_screen.dart` |
| Filter bar | `presentation/widgets/admin_filter_bar.dart` |

Highlights (see the repository library doc for the running list):
- `dashboard()` — one call to the SECURITY DEFINER `admin_dashboard_stats`
  function (replaces 21 count queries); a non-admin gets **42501 → 403**, never
  a row of zeros.
- `deleteUser()` — deletes `public.users` (not `auth.users`, which needs the
  service key that must never ship in a mobile binary) and refuses to delete
  the acting admin.
- `moderateProvider()` — verify/reject/activate/deactivate; rejection reason is
  *stored* on the provider row and echoed into the notification by a trigger.
  `setProviderDeleted()` soft-deletes via `is_deleted` (listings vanish, history
  stays; `appointments_book` refuses the doctor).
- `setUserActive()` — banning fires `users_ban_enforce` (cancels future
  appointments, refunds paid ones).
- **Admin is the only verifier**: `verifyPayment()` writes only
  `payment_status`/`rejection_reason`; the `payments_apply_verification`
  trigger computes the commission split + payout ledger + appointment paid.
- Reviews moderation → `reviews_recalc_rating` trigger updates cached ratings.
- Feedbacks translate enum vocab at the boundary (`new↔pending`,
  `normal↔medium`). Blog slugs are minted here with `_uniqueSlug()`. Audit
  dropdown values come from a capped 500-row sample (PostgREST can’t GROUP BY).
- `settlePayout()` marks a pending payout paid (offline transfer + note).
- The console’s list screens all follow the §5.1 `PagedController` pattern —
  `admin_controllers.dart` is ~14 nearly-identical list providers.

### 7.11 Home / shell (`home/`)

| Concern | File |
|---|---|
| Tab shell (StatefulShellRoute) | `presentation/patient_shell.dart` |
| Home dashboard | `presentation/home_screen.dart` |
| Stub for non-patient roles | `presentation/stub_dashboard_screen.dart` |

---

## 8. Models & the `Fmt` coercion layer

`lib/models/*.dart` are plain immutable classes with `fromJson` factories.
They parse exclusively through `Fmt.*` (`core/utils/formatters.dart`) because
PostgREST returns numbers as strings, uuids are strings (an int parse would
make every `id` read 0 — `app_user.dart` and `appointment_models.dart` call
this out), and CSV/`HH:MM:SS` shapes need normalising.

`Fmt` also owns **display formatting** so a taka amount renders identically
everywhere: `Fmt.money()` (`৳1,250`), `Fmt.dayFull/dateTime/time`,
`Fmt.relative()`, `Fmt.label()` (snake → Title Case), `Fmt.rating()`,
`Fmt.initials()`. There is deliberately **no** distance formatter — the schema
stores no lat/lng.

The wire shapes the models parse are reproduced by repository `_shape*`
methods, so a model never needs to know a Postgres column name. The golden
checklist when adding a field: `column name → shape key → model key`.

Important model behaviour worth knowing:

```dart
// appointment_models.dart — the payability courtesy (server is the authority)
bool get canPay =>
    !isPaid && !isPaymentUnderReview && !isCancelled &&
    paymentStatus != 'refunded' && status != 'completed' &&
    status != 'expired' && fee > 0;
```

`Appointment.isUpcoming` excludes cancelled/expired/completed; `canCancel`,
`canReview`, `paymentLabel` (one line covering every money state),
`isAwaitingPayment` (`pending_payment`) all centralise wording so screens can’t
invent their own.

---

## 9. Important code fragments explained

### 9.1 The guard that makes every error readable

**`lib/core/network/supabase_service.dart`**

```dart
static Future<T> guard<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on ApiException {          // already translated — don't re-wrap
    rethrow;
  } on AuthException catch (e)      { throw _fromAuth(e); }
  on PostgrestException catch (e)   { throw _fromPostgrest(e); }
  on StorageException catch (e)     { throw _fromStorage(e); }
  on FunctionException catch (e)    { throw _fromFunction(e); }
  on SocketException catch (e) {
    throw ApiException(message: 'No connection to the server.\n${e.message}',
                       kind: ApiErrorKind.network);
  }
  on TimeoutException {
    throw ApiException(message: 'The server took too long to respond. …',
                       kind: ApiErrorKind.network);
  }
  on FormatException catch (e) { /* malformed response */ }
}
```

Because `guard` is *static*, it is also used directly by the storage helper and
repositories for sub-operations. **Every** repository method wraps its body in
`SupabaseService.guard(...)`.

### 9.2 `_detailCode`: carrying a machine rule across PostgREST

```dart
static String? _detailCode(PostgrestException e) {
  final detail = (e.details is String ? e.details as String : '').trim();
  if (detail.isEmpty || detail.length > 64) return null;
  return RegExp(r'^[A-Z][A-Z0-9_]*$').hasMatch(detail) ? detail : null;
}
```

The schema’s functions `raise exception using … detail='ALREADY_PAID'`.
This only accepts `SHOUTING_SNAKE_CASE`, so Postgres prose (“Key (id)=(4)
already exists”) is never mistaken for a machine code. Cards it into
`ApiException.code`; screens call `e.hasCode('ALREADY_PAID')`.

### 9.3 The role guard, segment-aware prefix

**`lib/app/router.dart`**

```dart
bool _under(String loc, String prefix) =>
    loc == prefix || loc.startsWith('$prefix/');
```

This is the line that keeps `/doctors` (patient directory) from matching
`/doctor` (provider workspace) — a plain `startsWith` would cannon every
patient browsing doctors into the provider guard.

```dart
String? _guard(AuthState auth, GoRouterState state) {
  final loc = state.matchedLocation;
  if (!auth.isResolved) return loc == Routes.splash ? null : Routes.splash;
  final open = _openToAll.any((p) => _under(loc, p));
  if (!auth.isAuthenticated) {
    if (open) return null;
    final anon = _anonymousOnly.any((p) => _under(loc, p));
    return anon && loc != Routes.splash ? null : Routes.login;
  }
  final role = auth.role;
  final landing = _landingFor(role);
  if (_anonymousOnly.any((p) => _under(loc, p))) return landing;
  if (open) return null;
  if (role != UserRole.patient && _patientOnly.any((p) => _under(loc, p)))
    return landing;
  if (_under(loc, Routes.doctorHome)      && role != UserRole.doctor) return landing;
  if (_under(loc, Routes.placeHome)       && !(role == UserRole.hospital ||
      role == UserRole.clinic || role == UserRole.pharmacy)) return landing;
  if (_under(loc, Routes.adminHome)       && role != UserRole.admin) return landing;
  return null;
}
```

### 9.4 Idempotent manual payment (double tap safe)

The client calls the `submit_manual_payment` RPC; the DB takes an advisory lock
on the appointment, re-checks payability, reads the amount itself, and **returns
an existing pending submission** instead of writing a second row:

```dart
Future<Map<String, dynamic>> submitManualPayment({...}) async {
  if (method.isGateway) throw PaymentException(... 'Please use the online checkout…');
  return _mapErrors(appointmentId, 'submit_manual_payment', () async {
    final row = await _sb.rpc<Map<String, dynamic>>('submit_manual_payment', params: {
      'p_appointment_id': appointmentId,
      'p_payment_method': method.value,          // exact enum value, punct included
      if (_clean(transactionRef) != null) 'p_transaction_id': _clean(transactionRef),
      ...
    });
    return row;
  });
}
```

And `appointment_repository.pay()` re-reads the row afterwards so the caller
gets the same `{appointment}` contract the old PHP response gave.

### 9.5 The edge-function return-target allowlist

**`supabase/functions/create-checkout-session/index.ts`** — the successful
redirect carries `session_id`, so accepting an arbitrary origin would let a
forged call point that redirect at any host. `resolveReturnTarget()` only
accepts: the `ayurbd` mobile scheme, loopback dev origins (any port, since
`flutter run -d chrome` picks a random port), `APP_WEB_ORIGINS`, or `APP_URL`,
and refuses the Supabase host itself.

### 9.6 Shaping example — appointment embeds

**`appointment_repository.dart`** flattens the joins onto the keys the model
already reads, and picks the newest payment submission by `created_at` (a
to-many embed has no ordering guarantee):

```dart
Map<String, dynamic> _shape(Map<String, dynamic> r) {
  final doctor = r['doctors'] as Map<String, dynamic>?;
  final user = doctor?['users'] as Map<String, dynamic>?;
  return {
    ...r,
    'doctor_name': Fmt.str(r['doctor_name'], Fmt.str(user?['name'], 'Doctor')),
    'doctor_specialty': doctor?['specialization'],
    'doctor_image': _sb.storageHelper.avatar(user?['profile_image'] as String?),
    'clinic_name': doctor?['hospital_clinic_name'],
    'clinic_address': doctor?['chamber_address'],
    'payment_review': _latestPaymentStatus(r['payments']),
  };
}
```

The `doctors!left` / `users!left` embeds are load-bearing: PostgREST defaults to
an inner join, which would silently delete a patient’s appointment from their
own list if the doctor’s row were invisible under RLS.

---

## 10. Security & the trusted surface

| What | Where it’s enforced |
|---|---|
| Row ownership (patients see only their own rows) | RLS policies (`../supabase/rls_policies.sql`) |
| Admin-only tables/functions | `*_admin` policies + SECURITY DEFINER functions (non-admin → 42501 → 403) |
| Business rules (double booking, stock, fee immutability, confirmation code) | Triggers + guarded RPCs; the client only *asks* |
| Roles | read from `public.users` by the DB, never client metadata |
| Sessions/refresh tokens | OS keystore (`SecureGotrueStorage`) |
| Payment verification | admin-only; `payments_apply_verification` trigger; webhook is the authority for Stripe |
| Storage paths | must start with the owner uuid (policies); uploads sanitised client-side |
| Stripe redirect targets | Edge Function allowlist |
| Error text | `PaymentService._safeMessage` + `SupabaseService` never leak SQL/RLS prose to users |

---

## 11. Running, testing, contributing

- **Run (web):** `flutter run -d chrome` — Supabase URL + anon key are hard-coded
  in `app_config.dart`; no `--dart-define` needed. Debug HTTP logging via
  `--dart-define=AYUR_VERBOSE_HTTP=true` (noisy, keep off).
- **Tests:** `flutter test` — `test/widget_test.dart` pumps `AyurApp` in a
  `ProviderScope` with `prefsStoreProvider` overridden and initialises Supabase
  with `autoRefreshToken:false` so no token timer leaks. Don’t use
  `pumpAndSettle` (the splash spinner never settles until `restore()` resolves).
- **Analyse:** `flutter analyze` — passes; the only output is `info`-level
  deprecation warnings which are intentional and must not be mass-fixed.
- **Backend edits:** edit `../supabase/{schema,rls_policies,storage_setup}.sql`
  (idempotent), then copy into `migrations/` and push with the CLI. Business
  rules belong in SQL, not Dart.
- **New feature:** mirror the pattern — `features/<x>/data/<x>_repository.dart`
  (returns `Paged<T>` for lists, every call in `guard`, storage columns mapped
  through `storageHelper`, `_shape*` at the boundary) + `presentation/` widgets +
  a `PagedController`-based provider for lists, and route strings in
  `Routes`.