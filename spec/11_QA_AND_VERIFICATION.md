# Part 11 — QA, Verification and Sign-off

This is Phase 12 of master plan §5, and it is the only part file whose output is
evidence rather than code. Everything below is written to be **executed**, not
read: every claim in this project's final report must trace to a command in this
file that someone actually ran and whose output they saw.

Read master plan §6 R8 before you use anything here. The single failure this part
exists to prevent is an agent writing "verified" beside a check it did not run.

---

## 0. Ground truth about the machine this spec was written on

State this verbatim in `IMPLEMENTATION_LOG.md`, because every command below was
written blind:

> **This workspace has no Flutter SDK and no PostgreSQL client.** `flutter`,
> `dart`, `psql` and `supabase` are all absent. No command in
> `spec/11_QA_AND_VERIFICATION.md` was executed while writing it. Every command
> was derived from the real files in this repository, but **none of them has been
> observed to produce the output it claims.** The first person or agent with a
> Flutter SDK and a Postgres connection is the first person to run any of them,
> and is expected to correct this file where reality differs.

Checks that were run here, and are therefore trustworthy: the `grep`/`ls`-class
static checks in §3, because `grep` exists. Everything involving `flutter`,
`dart`, `psql`, `supabase`, `gradle`, `adb` or `unzip` was **never executed**.

Three further facts, each contradicting an earlier document in this repository.
They are stated here because a test suite built on a false premise fails for the
wrong reason and gets disabled.

| Claim in older docs | Reality, verified 2026-08-10 | Consequence for QA |
|---|---|---|
| "4 Edge Functions" (`00_MASTER_PLAN.md` §1) | **2.** `supabase/functions/create-checkout-session/index.ts` and `supabase/functions/stripe-webhook/index.ts` exist. `create-payment-intent/` and `payment-webhook/` are **empty directories** — no `index.ts`, nothing to deploy. | §1.5 deploys two functions. Deploying the empty two fails with "entrypoint not found"; that is not a regression to debug. |
| "PostGIS is enabled and the repositories already return `distance_km`" (`00_MASTER_PLAN.md` §2 Q5) | **False.** The only extensions created anywhere in `supabase/` are `pgcrypto` (`supabase/schema.sql:149`) and `pg_trgm` (`supabase/schema.sql:754`). `distance_km` appears nowhere in `supabase/schema.sql`. `app/lib/core/utils/formatters.dart` says so explicitly in its closing comment: *"Nothing in this database stores latitude/longitude … Leaving the formatter here would only invite a fabricated '2.3 km away' back into the UI."* | **Do not write a distance-sorting test.** There is no distance. A "nearby" screen that claims kilometres is fabricating them, and that is a defect to file, not a feature to verify. |
| The release APK has no INTERNET permission | **Already fixed in source.** `app/android/app/src/main/AndroidManifest.xml:16` now carries `<uses-permission android:name="android.permission.INTERNET"/>`, added in commit `c1fa8e8`. | The *source* is fixed. §8.1 still verifies against the **built artefact**, because the source being right has never once been the thing that was wrong. |

---

## 1. Environment setup

### 1.1 Flutter

`app/pubspec.yaml` declares `sdk: '>=3.3.0 <4.0.0'` — that is the **Dart** SDK, not
Flutter. The floor it implies is Flutter 3.19 (Dart 3.3). Do not use the floor.
`app_links: ^7.2.1` and `flutter_lints: ^4.0.0` both resolve to versions published
against later SDKs, and `dart format` changed its default line handling after
3.3, which would make the §3.2 gate fail on formatting the previous developer's
editor produced.

**Pin Flutter 3.24.5 (Dart 3.5.4) or newer in the 3.24 line.** Record the exact
version you used; a formatting gate is only reproducible against a named
formatter.

```bash
flutter --version
# Expect a first line containing "Flutter 3.24." or later, and
# "• Dart version 3.5." or later. Anything below 3.19 cannot resolve pubspec.

cd "F:/Project folder/AyurBD/app"
flutter pub get
# Expect: "Got dependencies!" and no "version solving failed".
# Expect NO warning naming app_links, supabase_flutter or flutter_lints.
```

If version solving fails, do **not** loosen the constraint in `pubspec.yaml` —
that is a shared file and the pin is deliberate. Upgrade Flutter instead.

### 1.2 The Supabase CLI

```bash
supabase --version          # expect 1.200.0 or later
supabase login              # opens a browser, stores an access token
cd "F:/Project folder/AyurBD"
supabase link --project-ref cbmmhygivrejcjpfodkr
```

`cbmmhygivrejcjpfodkr` is the live project, hard-coded at
`app/lib/core/constants/app_config.dart:17`. Linking to it means **`supabase db
push` writes to the database the deployed app reads.** For anything in §4 —
which inserts rows and expects failures — use a scratch project or a local
`supabase start` instead. The invariant tests are transactional and roll back,
but a `rollback` you forgot to type is a row in production, and master plan R1
allows exactly zero.

### 1.3 Applying migrations

```bash
cd "F:/Project folder/AyurBD"
supabase db push
# Expect the 23 files in supabase/migrations/ to be listed as already applied,
# and only files you added in Phases 1–2 to actually run.

# Confirm the count matches what is on disk:
ls -1 supabase/migrations/*.sql | wc -l          # 23 before Phase 1 adds any
psql "$DATABASE_URL" -Atc \
  "select count(*) from supabase_migrations.schema_migrations"
# Expect the same number. A mismatch means a migration was applied by hand in
# the SQL editor and is not in the folder — find it before doing anything else.
```

`supabase/schema.sql` is **not** a migration and must never be run. It is a
155 KB dump used as a reading reference; `12_LOGICAL_INTEGRITY.md` §1 calls this
"the `schema.sql` trap". Running it against a live project would attempt to
recreate 25 existing tables.

### 1.4 The database URL

Everything in §4 needs `DATABASE_URL`. Get it from the dashboard under
**Project Settings → Database → Connection string → URI**, and use the *session*
pooler on port 5432, not the transaction pooler on 6543 — §4 opens two concurrent
sessions and holds a transaction open across a lock wait, which the transaction
pooler will not do.

```bash
export DATABASE_URL='postgresql://postgres.cbmmhygivrejcjpfodkr:<password>@aws-0-<region>.pooler.supabase.com:5432/postgres'
psql "$DATABASE_URL" -Atc "select current_database(), version()"
# Expect: postgres|PostgreSQL 15.x ...
```

Never put this string in a file inside the repo. `.gitignore` covers `.env` and
`.env.*` (`.gitignore:29-30`), so `.env.local` is the safe place for it.

### 1.5 Deploying the two Edge Functions

```bash
cd "F:/Project folder/AyurBD"
supabase functions deploy create-checkout-session
supabase functions deploy stripe-webhook
# Expect: "Deployed Function <name> on project cbmmhygivrejcjpfodkr".

supabase functions list
# Expect exactly two rows. If create-payment-intent or payment-webhook appear,
# they were deployed from some earlier state of the repo and are now
# unmaintained code running in production — delete them:
#   supabase functions delete create-payment-intent
#   supabase functions delete payment-webhook
```

Do not attempt `supabase functions deploy create-payment-intent`. The directory
exists and is empty; the CLI fails with an entrypoint error. That is correct
behaviour, not a bug to work around.

`stripe-webhook` must be deployed with `--no-verify-jwt`. Stripe signs its
requests with its own scheme and sends no Supabase JWT, so with JWT verification
on, every webhook is rejected at the edge and payments never settle:

```bash
supabase functions deploy stripe-webhook --no-verify-jwt
```

### 1.6 Secrets — set them, leave them empty (D2)

Master plan D2: *"build it and keep the place empty."* An empty secret is not the
same as an absent one. An absent secret makes `Deno.env.get("STRIPE_SECRET_KEY")!`
throw a `TypeError` inside the isolate, which surfaces to the app as a 500 with no
body — indistinguishable from the function being down. An empty string reaches
the function's own configuration check and returns the named
`STRIPE_NOT_CONFIGURED` response that `04_PAYMENTS.md` §2.2 specifies, which the
UI renders as the labelled "not configured" state.

Four are read by the two live functions — verified with
`grep -n "Deno.env.get" supabase/functions/*/index.ts`:

| Secret | Read at | D2 value |
|---|---|---|
| `STRIPE_SECRET_KEY` | `create-checkout-session/index.ts:244`, `stripe-webhook/index.ts:155` | **empty** |
| `STRIPE_WEBHOOK_SECRET` | `stripe-webhook/index.ts:156` | **empty** |
| `APP_URL` | `create-checkout-session/index.ts:297` | **empty** |
| `APP_WEB_ORIGINS` | `create-checkout-session/index.ts:103` | **empty** |

```bash
supabase secrets set STRIPE_SECRET_KEY=""
supabase secrets set STRIPE_WEBHOOK_SECRET=""
supabase secrets set APP_URL=""
supabase secrets set APP_WEB_ORIGINS=""

supabase secrets list
# Expect all four names present. The CLI prints a digest, not the value, so an
# empty secret and a real one look identical here — the name being listed is
# the whole assertion.
```

`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY`
(`create-checkout-session/index.ts:241-243`) are injected by the platform. Never
set them by hand. Never let the service-role key reach `app_config.dart` —
`assertValidBackendConfig()` (`app/lib/core/constants/app_config.dart:56`) throws
at startup if the shipped key looks like a secret, and master plan R6 forbids
weakening that check.

### 1.7 The empty-credential acceptance run

This is the D2 definition of done and the first thing to run after any payment
change. With all four secrets empty:

```bash
cd "F:/Project folder/AyurBD/app"
flutter run -d chrome        # or: flutter run -d <android-device-id>
```

| # | Step | Expected result |
|---|---|---|
| 1 | App launches | Splash → login. **No exception in the console.** Not a red screen, not a blank one. |
| 2 | Register a patient, verify email, sign in | Patient dashboard renders. |
| 3 | Open Doctors → a doctor → Book | Slot grid renders from `available_slots()`. |
| 4 | Pick a slot, confirm | Appointment created with `status='pending_payment'`. |
| 5 | Payment method sheet opens | **bKash / Nagad / Rocket / Card (simulated) are enabled.** The Stripe "Card" row is **present, disabled**, subtitled with the localized "not configured" string. It is visible, not hidden — a hidden option cannot be explained. |
| 6 | Tap the disabled Stripe row | An info sheet naming the missing configuration. No navigation, no spinner that never ends. |
| 7 | Pay through the simulated gateway, outcome "Success" | Appointment `confirmed`, payment `verified`, a `provider_payouts` row exists. |
| 8 | Navigate every tab and every role dashboard | Every route resolves. No reachable `stub_dashboard_screen`. No raw exception text anywhere. |

Step 1 is the load-bearing one. **A missing credential must never produce a crash
or a blank screen** — only a labelled state. If the app throws at boot with empty
secrets, D2 is not satisfied no matter what else works.

---

## 2. Per-phase exit criteria

Master plan §5 fixes the order; this section fixes when each phase may be called
done. Each criterion is a command and an expected output. A phase whose criteria
have not been *run* is not complete — R8 forbids inferring them.

Two commands recur; define them once.

```bash
export AYUR="F:/Project folder/AyurBD"
analyze() { (cd "$AYUR/app" && flutter analyze); }
smoke()   { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
              -f "$AYUR/supabase/tests/integrity_smoke.sql"; }
```

### Phase 1 — Part 01, Database

| # | Criterion | Command | Expected |
|---|---|---|---|
| 1.1 | Every migration applied | `psql "$DATABASE_URL" -Atc "select count(*) from supabase_migrations.schema_migrations"` | equals `ls -1 supabase/migrations/*.sql \| wc -l` |
| 1.2 | 25 tables still present, none renamed (R2) | `psql "$DATABASE_URL" -Atc "select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE'"` | `25` or more; never fewer |
| 1.3 | The four dead directories are gone | `ls "$AYUR/app/lib/features"` | no `booking`, `doctor`, `hospital`, `shop` |
| 1.4 | No top-level INSERT except hotlines | §3.4 | one table name: `emergency_hotlines` |
| 1.5 | Bilingual content columns exist | `psql "$DATABASE_URL" -Atc "select count(*) from information_schema.columns where table_schema='public' and column_name like '%\_bn'"` | ≥ 6 |
| 1.6 | Analyzer still clean | `analyze` | `No issues found!` |

### Phase 2 — Part 12, Logical integrity

| # | Criterion | Command | Expected |
|---|---|---|---|
| 2.1 | Every specified structure exists | `smoke` | exits 0, prints no `INTEGRITY SMOKE FAILED` |
| 2.2 | All 21 invariant tests reject their violation | `bash supabase/tests/run_all.sh` (§4.2) | `21 passed, 0 failed` |
| 2.3 | DETAIL codes in sync with Dart | `bash scripts/verify_integrity.sh` (Part 12 §22) | `DETAIL codes: in sync.` |
| 2.4 | No time comparison bypasses Dhaka | `grep -rn "appointment_date\|appointment_time" supabase/ \| grep "now()" \| grep -v "Asia/Dhaka"` | zero lines |
| 2.5 | The double-booking message actually matches | `grep -n "uq_appointments_doctor_slot" app/lib/core/network/supabase_service.dart` | ≥ 1 hit. Today `supabase_service.dart:329` tests `appointments_no_double_booking` and `uniq_doctor_slot`, and the real index (`supabase/schema.sql:588`) is `uq_appointments_doctor_slot` — so the most important error in the app currently reads "That already exists." |

### Phase 3 — Part 02, Backend services

| # | Criterion | Command | Expected |
|---|---|---|---|
| 3.1 | RLS on every public table | `psql "$DATABASE_URL" -Atc "select count(*) from pg_tables t join pg_class c on c.relname=t.tablename where t.schemaname='public' and not c.relrowsecurity"` | `0` |
| 3.2 | No `FOR ALL` policy | `psql "$DATABASE_URL" -Atc "select count(*) from pg_policies where schemaname='public' and cmd='ALL'"` | `0` |
| 3.3 | Four storage buckets | `psql "$DATABASE_URL" -Atc "select string_agg(id,',' order by id) from storage.buckets"` | `avatars,blog-covers,product-images,provider-documents` |
| 3.4 | Buckets have size and MIME limits | `psql "$DATABASE_URL" -Atc "select count(*) from storage.buckets where file_size_limit is null or allowed_mime_types is null"` | `0` |
| 3.5 | Exactly two functions deployed | `supabase functions list \| grep -c ACTIVE` | `2` |

### Phase 4 — Part 03, Authentication

| # | Criterion | Command | Expected |
|---|---|---|---|
| 4.1 | Demo-admin card gone | `grep -rin "demo admin\|demo_admin" app/lib` | zero lines |
| 4.2 | Role escalation blocked | §4 test T14 | `42501` |
| 4.3 | Every role lands somewhere real | manual §6.11 | 7 roles, 7 dashboards, no stub |
| 4.4 | Session in the OS keystore | `grep -rn "FlutterSecureStorage" app/lib/core/storage/` | ≥ 1 hit |
| 4.5 | Analyzer clean | `analyze` | `No issues found!` |

### Phase 5 — Part 06, Localization

| # | Criterion | Command | Expected |
|---|---|---|---|
| 5.1 | ARB files exist and are parallel | `python -c "import json;a=json.load(open('app/lib/l10n/app_en.arb'));b=json.load(open('app/lib/l10n/app_bn.arb'));k=lambda d:{x for x in d if not x.startswith('@')};print(sorted(k(a)^k(b)))"` | `[]` |
| 5.2 | Generated bindings compile | `cd app && flutter gen-l10n && flutter analyze` | `No issues found!` |
| 5.3 | No hardcoded user-facing strings (R4) | §3.3 | zero lines |
| 5.4 | Bangla numerals | `flutter test test/unit/bangla_numerals_test.dart` | `All tests passed!` |
| 5.5 | Language survives a restart | manual §6.7 step 9 | still Bangla |

### Phase 6 — Part 07, UI/UX

| # | Criterion | Command | Expected |
|---|---|---|---|
| 6.1 | Four states everywhere (R5) | `grep -rLn "LoadingView\|ErrorView\|EmptyView" app/lib/features/*/presentation/*_screen.dart` | only screens with no async surface; list them by name in the log |
| 6.2 | Four-states widget test | `flutter test test/widget/async_state_test.dart` | `All tests passed!` |
| 6.3 | Dark mode on every screen | manual §6.8 | no unreadable contrast |
| 6.4 | No overflow at 1.3× text scale | manual §6.7 | no yellow-black stripes |
| 6.5 | Formatting gate | §3.2 | exit 0 |

### Phase 7 — Part 04, Payments

| # | Criterion | Command | Expected |
|---|---|---|---|
| 7.1 | End-to-end on the simulated gateway | manual §6.1 | `confirmed` + `verified` + payout row |
| 7.2 | Empty credentials never crash | §1.7 | all 8 rows pass |
| 7.3 | Commission reconciles to the paisa | §4 test T12 + `select count(*) from payments where admin_share + provider_share <> amount` | `0` |
| 7.4 | Commission arithmetic unit test | `flutter test test/unit/commission_test.dart` | `All tests passed!` |
| 7.5 | Old transactions immutable after a rate change | manual §6.6 | historic `admin_share` unchanged |
| 7.6 | Double payment refused | §4 test T11 | `23505` or `P0001`/`ALREADY_PAID` |

### Phase 8 — Part 05, Notifications

| # | Criterion | Command | Expected |
|---|---|---|---|
| 8.1 | Rows are trigger-created, not client-created | `psql "$DATABASE_URL" -Atc "select count(*) from information_schema.role_table_grants where table_name='notifications' and privilege_type='INSERT' and grantee in ('anon','authenticated')"` | `0` |
| 8.2 | Forging refused | §4 test T21 | `42501` |
| 8.3 | Badge updates | manual §6.1 step 14 | count rises on refresh |
| 8.4 | No Firebase (D3) | `grep -n "firebase" app/pubspec.yaml` | zero lines |

### Phase 9 — Part 08, Patient features

| # | Criterion | Command | Expected |
|---|---|---|---|
| 9.1 | Search returns results in both locales | manual | Bangla query matches `name_bn` |
| 9.2 | Slot computation unit test | `flutter test test/unit/slot_test.dart` | `All tests passed!` |
| 9.3 | Review eligibility predicate test | `flutter test test/unit/review_eligibility_test.dart` | `All tests passed!` |
| 9.4 | No fabricated distance | `grep -rn "distance" app/lib/features/patient/presentation/` | zero lines — see §0, there is no latitude in this schema |
| 9.5 | Blood units cannot go negative | §4 test T16 | `P0001` / `BLOOD_OUT_OF_STOCK` |

### Phase 10 — Part 09, Provider features

| # | Criterion | Command | Expected |
|---|---|---|---|
| 10.1 | Verification lifecycle | manual §6.4 | unverified provider unbookable |
| 10.2 | Stock exhaustion handled | manual §6.5 | `OUT_OF_STOCK`, stock unchanged |
| 10.3 | Fee frozen after booking | §4 test T15 | historic `appointments.fee` unchanged |
| 10.4 | No stub reachable | `grep -rn "stub_dashboard_screen" app/lib/app/router.dart` | zero lines |

### Phase 11 — Part 10, Admin console

| # | Criterion | Command | Expected |
|---|---|---|---|
| 11.1 | Commission change is forward-only | manual §6.6 | old rows unchanged |
| 11.2 | Payout cannot exceed collection | §4 test T13 | `P0001` / `PAYOUT_AMOUNT_MISMATCH` |
| 11.3 | Blog needs moderation | §4 test T20 | `42501`, or zero rows |
| 11.4 | Audit log written | `psql "$DATABASE_URL" -Atc "select count(*) from public.audit_log where created_at > now() - interval '1 hour'"` | greater than 0 after §6 |

### Phase 12 — Part 11, this file

| # | Criterion | Command | Expected |
|---|---|---|---|
| 12.1 | Analyzer clean | `analyze` | `No issues found!` |
| 12.2 | Formatted | §3.2 | exit 0 |
| 12.3 | Debug APK builds | `cd app && flutter build apk --debug` | `Built build/app/outputs/flutter-apk/app-debug.apk` |
| 12.4 | Release APK has INTERNET in the artefact | §8.1 | the string is found |
| 12.5 | All 21 invariant tests pass | §4.2 | `21 passed, 0 failed` |
| 12.6 | All 9 manual journeys pass | §6 | every step matches |
| 12.7 | Two devices share state | §7 | both see the same row |
| 12.8 | `IMPLEMENTATION_LOG.md` complete | `grep -c "^## Phase" IMPLEMENTATION_LOG.md` | `12` |
| 12.9 | Acceptance matrix all filled | §9 | every row Verified or Not verified — never blank |

---

## 3. Static gates

These run without a database, a device or an emulator. They are the cheapest
checks in the project, so they run every phase, not only at the end.

### 3.1 Analyzer — zero errors

```bash
cd "F:/Project folder/AyurBD/app"
flutter analyze
```

Expected, exactly:

```
Analyzing app...
No issues found! (ran in N.Ns)
```

`app/analysis_options.yaml` includes `package:flutter_lints/flutter.yaml` and adds
no custom rules, so the baseline is the standard Flutter lint set. Master plan §8
item 1 requires zero errors and zero warnings. Infos from `flutter_lints` are not
warnings, but a phase that adds fifty of them is degrading the codebase: record
the info count each phase and keep it non-increasing.

**Never run here.** The 115 Dart files under `app/lib` and the three files under
`app/test` have never been compile-checked in this workspace.

### 3.2 Formatting

```bash
cd "F:/Project folder/AyurBD/app"
dart format --output=none --set-exit-if-changed .
```

Exit 0, final line `Formatted N files (0 changed)`. A non-zero exit lists the
offending files; run `dart format .` and commit that.

**A caveat specific to this repository.** Most files under `app/lib` use CRLF line
endings while the files under `app/test` use LF. `dart format` normalises to LF.
On Windows with `core.autocrlf=true` this is invisible; on Linux or in CI the
first run rewrites hundreds of files. Do that rewrite as **its own commit, before
any feature work**, or every subsequent diff is unreviewable.

### 3.3 R4 — no hardcoded user-facing strings in `lib/features/`

Master plan R4 binds only after Phase 5. Before then these greps document the
debt; after Phase 5 a non-empty result is a failure.

`06_LOCALIZATION.md:11-13` records the pre-Phase-5 baseline: 250 `Text('`, 0
`Text("`, 415 hardcoded `labelText`/`hintText`/`title`/`label`/`tooltip`. Use
those numbers as the burn-down target.

```bash
cd "F:/Project folder/AyurBD"

# (a) Literal text in a widget. Excludes AppLocalizations lookups, which are
#     identifiers, and excludes '' and ' ' which are layout, not language.
grep -rnE "Text\(\s*'[^']" app/lib/features --include=*.dart \
  | grep -v "AppLocalizations" | grep -v "l10n\." | grep -v "context\.l10n"

# (b) Decoration and tooltip strings — the ones everyone forgets, and the
#     larger half of the debt at 415 vs 250.
grep -rnE "(labelText|hintText|helperText|errorText|tooltip|semanticLabel)\s*:\s*'[^']" \
  app/lib/features --include=*.dart

# (c) Snackbars, dialogs and thrown user-facing messages.
grep -rnE "SnackBar\(|AlertDialog\(|throw ApiException\(" -A 4 \
  app/lib/features --include=*.dart | grep -E "'[A-Z][a-z]+ [a-z]"

# (d) Bangla already hardcoded in Dart. Master plan §1 counts 8 such files;
#     these are the accidental bilingualism that must move into app_bn.arb.
grep -rlP "[\x{0980}-\x{09FF}]" app/lib --include=*.dart
```

Expected after Phase 5: **(a), (b) and (c) print nothing.** (d) prints at most
`app/lib/core/constants/app_config.dart`, which holds `currency = '৳'` at line
152 — a symbol, not a sentence, and correctly outside the ARB files because it is
identical in both locales.

The greps are deliberately narrow. A broader `grep "'"` matches route paths,
column names, enum values and asset keys, drowning the real hits — a gate that
cries wolf is a gate somebody comments out.

### 3.4 R1 — zero INSERT statements for business data

The literal command the brief asks for, and its honest output as measured in this
workspace:

```bash
cd "F:/Project folder/AyurBD"
grep -ci "insert into" supabase/*.sql supabase/migrations/*.sql
```

Actual output today (26 files; only non-zero lines shown):

```
supabase/schema.sql:9
supabase/storage_setup.sql:1
supabase/migrations/20260806000001_schema.sql:7
supabase/migrations/20260806000003_payment_commission_reviews.sql:4
supabase/migrations/20260806000004_guard_session_user_fix.sql:2
supabase/migrations/20260806000006_escrow_payment_flow.sql:1
supabase/migrations/20260806000008_handle_new_user_role_whitelist.sql:1
supabase/migrations/20260806000009_payments_guard_dead_appointment.sql:1
supabase/migrations/20260807220207_fix_booking_status_pending_payment.sql:1
supabase/migrations/20260809000002_payment_architecture_fix.sql:9
```

**That total does not violate R1, and reporting the number alone would be
dishonest in both directions.** Almost every hit is an INSERT *inside a function
body* — the mechanism of the application, not seed data: `audit_row_change()`
writing the audit log (`supabase/schema.sql:1294`), `notify_user()` writing a
notification (`:1573`), `payments_apply_verification()` minting a payout
(`:1778`, `:1838`), `handle_new_user()` creating the profile row (`:1965`),
`appointments_book()` (`:2628`) and `place_order()` (`:2750`, `:2760`). Deleting
them would break the app. `supabase/storage_setup.sql:105` is a **comment**
showing an insert, not one.

R1 is about rows that exist because a developer put them there. Ask that question
directly — a top-level INSERT, at column 1, outside any `$$ … $$` body:

```bash
grep -rniE "^insert into" supabase/*.sql supabase/migrations/*.sql
```

Actual output today — two lines, and they need a ruling:

```
supabase/migrations/20260806000003_payment_commission_reviews.sql:392:
  insert into public.provider_payouts (provider_user_id, payment_id, ...)
supabase/migrations/20260806000003_payment_commission_reviews.sql:407:
  insert into public.provider_payouts (provider_user_id, order_id, ...)
```

**These are permitted, and here is the reasoning.** Both are
`insert … select … on conflict … do nothing` **backfills** (see the comment at
`20260806000003_payment_commission_reviews.sql:380-386`): when the migration
introduced the commission split, payments already marked `verified` had no payout
row, so the provider dashboard's balance was incomplete. The statements derive
rows from data that already existed rather than inventing any — run them on an
empty database and they insert nothing. That is categorically different from a
demo doctor. They are idempotent, and they are historical: the migration is
already applied and must never be edited.

The check that actually enforces R1, therefore, is *which tables* receive
top-level rows:

```bash
grep -rhoiE "^insert into[[:space:]]+(public\.)?[a-z_]+" \
  supabase/*.sql supabase/migrations/*.sql \
  | sed -E 's/^[Ii][Nn][Ss][Ee][Rr][Tt][[:space:]]+[Ii][Nn][Tt][Oo][[:space:]]+(public\.)?//' \
  | sort -u
```

Expected after Phase 1: exactly two names — `provider_payouts` (the historical
backfill above) and `emergency_hotlines` (the reference-data exception).

**The emergency-hotline exception, named explicitly so this gate is never falsely
failed.** Master plan R1's sole carve-out is the reference data whitelisted in
`01_DATABASE.md` §5: the published Bangladesh national emergency numbers — 999,
16263, 199 and the rest — inserted bilingually with `name`/`name_bn` and
`description`/`description_bn`, each `on conflict do nothing` against
`uq_hotline_phone` (`01_DATABASE.md:865`). The justification is a safety one: an
emergency screen that is empty until an admin types into it is a screen that is
empty during an emergency. **As of this writing that migration does not exist
yet** — `grep -rin "emergency_hotlines" supabase/` returns only grants and
policies, no rows. Phase 1 creates it. Until then the expected table list is one
name, not two.

```bash
# Every permitted top-level insert must be idempotent.
grep -rniE "^insert into" -A 40 supabase/migrations/*.sql | grep -ci "on conflict"
# Expect a count equal to the number of top-level inserts found above.
```

---

## 4. SQL invariant test suite

`12_LOGICAL_INTEGRITY.md` §22 provides a **smoke suite** that asserts the 21
mechanisms *exist*. This section provides the complement: a suite that asserts
each mechanism *works*, by attempting the violation and requiring the right
SQLSTATE. §22 explains why they must stay separate — a suite that needs fixtures
gets skipped on production, and production is where you most need to know the
index is there.

### 4.1 Where the tests live, and why that does not break R1

New folder `supabase/tests/`, containing `_helpers.sql`, `_fixtures.sql`,
`t01_…` through `t21_…`, and `run_all.sh`.

Two rules make this compatible with master plan R1:

1. **Every test runs inside `begin … rollback`.** No test commits. A fixture row
   exists for the duration of one transaction and then does not exist.
2. **The §3.4 R1 gate globs `supabase/*.sql` and `supabase/migrations/*.sql`.**
   Neither pattern recurses, so `supabase/tests/*.sql` is outside it. That is
   deliberate, and stating it here is the point: a gate with an unstated blind
   spot is a gate someone will eventually hide seed data behind. If you ever need
   the tests included, they must remain transactional.

### 4.2 The harness

```sql
-- supabase/tests/_helpers.sql
--
-- Assertion helpers for the integrity suite. Loaded by every t*.sql.
-- Defined in pg_temp so they vanish with the session and can never be
-- mistaken for application code.
--
-- Usage:
--   select pg_temp.expect('label', $sql$ ...violating statement... $sql$,
--                         '23505');
--   select pg_temp.expect('label', $sql$ ... $sql$, 'P0001', 'REVIEW_TOO_EARLY');
--   select pg_temp.expect_ok('label', $sql$ ...must succeed... $sql$);
--   select pg_temp.report();

\set ON_ERROR_STOP on
\set QUIET on

create temporary table if not exists _results(
  label text, ok boolean, detail text
);

create or replace function pg_temp.expect(
  p_label  text,
  p_sql    text,
  p_state  text,
  p_detail text default null
) returns void language plpgsql as $fn$
declare
  got_state  text := '00000';
  got_detail text;
  ok         boolean;
  msg        text;
begin
  -- The inner BEGIN opens a subtransaction. When p_sql raises, that
  -- subtransaction rolls back and the outer transaction survives, so one
  -- failing assertion does not abort the remaining tests in the file.
  -- This is the only reason the suite can put many assertions in one
  -- transaction: at the psql level, the first error would poison it.
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics
      got_state  = returned_sqlstate,
      got_detail = pg_exception_detail;
  end;

  ok := (got_state = p_state)
        and (p_detail is null or got_detail = p_detail);

  msg := format('expected %s%s, got %s%s',
                p_state,
                coalesce('/' || p_detail, ''),
                got_state,
                coalesce('/' || nullif(got_detail, ''), ''));

  insert into _results values (p_label, ok, msg);
  raise notice '% %  — %', case when ok then 'PASS' else 'FAIL' end, p_label, msg;
end $fn$;

create or replace function pg_temp.expect_ok(p_label text, p_sql text)
returns void language plpgsql as $fn$
begin
  perform pg_temp.expect(p_label, p_sql, '00000');
end $fn$;

-- Prints the tally and raises if anything failed, so run_all.sh can rely
-- on psql's exit code rather than parsing output.
create or replace function pg_temp.report() returns void
language plpgsql as $fn$
declare n_pass int; n_fail int;
begin
  select count(*) filter (where ok), count(*) filter (where not ok)
    into n_pass, n_fail from _results;
  raise notice '---- % passed, % failed ----', n_pass, n_fail;
  if n_fail > 0 then
    raise exception 'INTEGRITY SUITE FAILED: % assertion(s)', n_fail;
  end if;
end $fn$;
```

Three things about that helper are load-bearing and easy to get wrong.

**`get stacked diagnostics … pg_exception_detail`** is how the DETAIL code is
read. Part 12 §2 establishes that DETAIL carries a `SHOUTING_SNAKE_CASE` machine
code and that `_detailCode()` (`app/lib/core/network/supabase_service.dart:281`)
lifts it onto `ApiException.code`. Asserting the SQLSTATE alone is not enough:
six different review failures all raise `P0001` (Part 12 §5), and a test that
only checks `P0001` passes when the wrong one fires.

**The nested `begin … exception`** is what makes several assertions per file
possible. Without it the first raised error aborts the psql transaction and every
later statement returns `25P02 current transaction is aborted`.

**`00000` as the success sentinel.** `expect_ok` reuses the same path so a
"must succeed" assertion reports through the same tally.

<!--CONT-->
