# AYUR — Master Implementation Plan

**Read this file completely before touching any code.** Every other file in
`spec/` is subordinate to it. If a part file appears to contradict this file,
this file wins — stop and report the conflict.

Target: a production-standard bilingual (English / বাংলা) healthcare platform for
Bangladesh, built in Flutter on Supabase, running on many devices at once, with
a commission-taking payment system and no logical contradictions in its booking,
review or money flows.

---

## 0. Why the previous attempt produced a login screen and nothing else

The user ran an agent against `AYURBD_PART1_SETUP.md` and
`AYURBD_PART2_ROUTER_AUTH.md` and got an app that boots to `/login` with a
"Demo admin access" card and nothing behind it.

That is the correct output of those files. They are **incomplete by
construction**: Part 2 ends at Step 15, `verify_email_screen.dart`. There was
never a Part 3. An agent executing both faithfully builds an auth flow and no
application.

Worse, those guides describe a *different app* than this repository:

| | Uploaded guides | This repo (real, deployed) |
|---|---|---|
| Bootstrap | `flutter create ayurbd` | 115 Dart files already written |
| User table | `profiles` | `users` |
| Doctor table | `doctor_profiles` | `doctors` |
| Booking table | `bookings` | `appointments` |
| PK style | `uuid` everywhere | `uuid` users, `bigint identity` elsewhere |
| Migrations | none | 23 applied |

Executing them here would delete a working backend and 115 files of working
Dart. **The files in `uploads/` are superseded. Do not execute them. This
`spec/` directory replaces them.**

### The rule this creates

> **Never mark a phase complete because you ran out of instructions.** If a part
> tells you to start something and does not tell you how to finish it, stop and
> say so. Do not ship a stub and call it done.

---

## 1. Ground truth — what already exists

Verified by direct inspection on 2026-08-10. Do not re-derive. Do not assume
anything below is missing.

### Backend (live)

- **Supabase project** `https://cbmmhygivrejcjpfodkr.supabase.co`, a `const` in
  `app/lib/core/constants/app_config.dart`. Publishable key only, never secret.
- **25 tables** in `public`: `users, doctors, clinics, hospitals, pharmacies,
  pharmacy_products, appointments, payments, payment_sessions, provider_payouts,
  orders, order_items, cart, reviews, feedback, blogs, blood_banks,
  blood_donors, blood_requests, notifications, device_tokens,
  emergency_hotlines, emergency_sms, audit_log, app_audit_log`
- **23 migrations**, `20260806000000` → `20260809000002`. The tail is
  payment-architecture work — read `PAYMENT_ARCHITECTURE_FIX.md` before
  touching payments.
- **`rls_policies.sql`** — per-command policies, never `FOR ALL`.
- **`storage_setup.sql`** — buckets `avatars`, `provider-documents`,
  `product-images`, `blog-covers`.
- **4 Edge Functions**: `create-checkout-session`, `create-payment-intent`,
  `payment-webhook`, `stripe-webhook`.

### Flutter app — 115 Dart files, working

| Module | Files | Status |
|---|---:|---|
| `auth` | 14 | login, register ×5 roles, profile |
| `admin` | 14 | 11 console screens |
| `provider` | 12 | doctor + place dashboards |
| `content` | 9 | blog, notifications, static pages |
| `pharmacy` | 8 | catalogue, cart, orders |
| `appointments` | 7 | book, pay, receipt |
| `patient` | 7 | dashboard, nearby, emergency |
| `directory` | 5 | doctors, places |
| `blood_bank` | 3 | inventory, donors, requests |
| `payment` | 1 | Stripe Checkout + manual verify |
| `home` | 3 | shell + **stale `stub_dashboard_screen.dart`** |
| `booking`, `doctor`, `hospital`, `shop` | **0** | **empty dead directories** |

### The real gaps

1. **No localization whatsoever.** No `lib/l10n/`, no `flutter_localizations`.
   Every string is a hardcoded English literal — and 8 files contain hardcoded
   *Bangla*, so the app is accidentally bilingual in an unmanaged way. → Part 06
2. **`stub_dashboard_screen.dart` tells providers and admins their dashboard
   "is not built"** — but `provider` and `admin` are built. Stale. → Parts 09, 10
3. **Four empty feature directories** from an aborted refactor. → Part 01
4. **Payment credentials absent**, flow unexercisable. → Part 04
5. **Business-logic integrity is not enforced in the database.** Double booking,
   premature reviews and ~20 sibling contradictions. → **Part 12**

### Environment constraints — state these honestly, never paper over them

- **`flutter analyze` / `flutter build` have never been run here.** No Dart
  change in this repo has been compile-checked. If you cannot run them, say so.
  Never claim a build passes that you did not run.
- **Android release builds fail** for an unrelated reason:
  `app/android/gradle.properties` asks for `-Xmx8G -XX:MaxMetaspaceSize=4G`,
  which this host cannot satisfy; the Gradle daemon dies of native OOM. Try
  `-Xmx3G -XX:MaxMetaspaceSize=1G`. Release still signs with the debug key.
- **`app/ios/` does not exist.**
- **`Glob` and unscoped `Grep` give spurious "No files found" on this `F:` path.**
  Always pass an absolute `path:` and re-run before trusting a negative.

---

## 2. Technology decisions — answering the questions in the brief

The user asked five open questions. Answered here once, with reasoning, and
treated as settled by every part file.

### Q1. SQL or NoSQL? Supabase or Firebase?

**Supabase (PostgreSQL). Already chosen and already deployed — the right call,
and here is why it stays.**

This application is *relational in its bones*. A booking references a patient, a
doctor, a slot, a payment and a payout. A review is only valid if a completed
appointment exists linking that patient to that provider. A commission split
must reconcile to the paisa across three tables. These are joins and invariants,
and a relational database enforces them for you.

The decisive argument is **Q4 below**: the double-booking rule. In PostgreSQL it
is one line — a unique index. In Firestore there is no such construct; you must
hand-write a transaction and hope every future code path remembers to use it.
A rule the database enforces cannot be bypassed by a bug in the app. A rule the
app enforces is one refactor away from silently breaking.

| Need | PostgreSQL / Supabase | Firestore / Firebase |
|---|---|---|
| Prevent double booking | `unique index` — impossible to violate | manual transaction, easy to bypass |
| "Review only after consultation" | `CHECK` + trigger, server-side | client logic or a Cloud Function |
| Commission arithmetic | `numeric(10,2)`, exact | float64, rounding drift on money |
| Compare doctors by price/rating | one SQL query with joins | denormalise, or N reads |
| Search medicines by name | full-text index, one query | needs paid Algolia |
| "Show all appointments today" | trivial `WHERE` | composite index per query shape |
| Audit trail | triggers write it automatically | app must remember every time |
| Row-level security | RLS, enforced by the DB engine | security rules, separate language |
| Cost as you grow | predictable | per-document reads, spikes badly |

Firebase suits document-shaped, denormalised, mostly-append data — chat, feeds,
telemetry. Yours is a booking-and-money system. Use the relational database.

**Free tier is sufficient for testing**: 500 MB database, 1 GB storage, 50 000
monthly active users, unlimited API requests, and Auth with email verification
included. The one caveat worth planning around: **a free project is paused after
7 days of inactivity.** Open the dashboard weekly, or accept a cold start.

### Q2. Which cloud storage?

**Supabase Storage.** Same project, same auth, same RLS engine. An image upload
is authorised by the same policy language as a table read, which means one
mental model instead of two. Four buckets already exist; Part 02 covers them.

Free tier: 1 GB storage, 2 GB egress per month. Ample for testing. The practical
risk is not the quota but *unbounded uploads* — Part 02 mandates client-side
compression, dimension caps and MIME allowlists so a single 12 MP phone photo
does not consume 4 MB of a 1 GB budget.

**On video:** the brief mentions users uploading video. Do not build that on the
free tier. A 60-second clip is 30–60 MB; twenty of them exhaust the entire
storage quota, and egress dies first. Part 07 specifies images only, with the
schema left video-ready (`media_type` column) so it can be enabled later on a
paid plan or an external host.

### Q3. Authentication and OTP

**Supabase Auth (GoTrue) with email verification — free and already wired.**

**SMS OTP is deliberately excluded, and this is the one place where the answer
is "no free option exists."** Every SMS gateway charges per message; Bangladeshi
providers require a business licence. Twilio's trial only sends to numbers you
pre-verify, which is useless for real signups.

What Part 03 specifies instead:

- Email verification (free, unlimited, already working).
- Phone number collected and stored, validated against the Bangladeshi format
  `01[3-9]XXXXXXXX`, but *unverified* and labelled as such in the UI.
- A `phone_verified boolean` column and a `PhoneVerifier` interface with a
  no-op implementation, so an SMS provider drops in later without a schema change.
- For provider accounts, verification is **manual by admin** against uploaded
  documents (BMDC registration, drug licence, hospital registration) — which is
  stronger identity proof than an SMS OTP anyway, and is what the brief asks for.

### Q4. The payment system, and whether the "money via admin" idea works

**The user's instinct is correct, and it has a name: an escrow / aggregator
model. It is exactly how Uber, Airbnb and Foodpanda work.** Money lands in the
platform account, the platform retains commission, the remainder is settled to
the provider. Your repository already implements this — see
`provider_payouts` and `PAYMENT_ARCHITECTURE_FIX.md`.

One critical caveat to understand before going live: **in production this model
is legally regulated.** Holding other people's money makes you a payment
aggregator, which in Bangladesh requires Bangladesh Bank authorisation, and
internationally requires either a licence or a platform like Stripe Connect that
holds the licence for you. For a testing, demo or academic build this does not
apply, because no real money moves. Build it now; get advice before real money.

**For the testing phase, the free approach that actually works:**

1. **A simulated gateway** — the primary demo path. A realistic in-app bKash /
   Nagad / Rocket / card sheet with explicit outcome buttons (success,
   insufficient funds, wrong PIN, timeout, cancelled). Writes the *same* real
   rows and drives the *same* status transitions as a live gateway. Needs zero
   credentials, works offline, demos anywhere. This is what makes your app
   presentable today.
2. **Manual transfer with admin verification** — already built. The patient
   sends money to a bKash number and submits the transaction ID; the admin
   verifies. Genuinely free, genuinely usable in Bangladesh, and it is how many
   real small platforms operate.
3. **Stripe test mode** — already built via Edge Functions. Realistic card flow
   with test cards, free forever in test mode, but needs keys and internet.
4. **SSLCommerz sandbox** — the `payment_method` enum already includes
   `sslcommerz`. The Bangladeshi gateway with a free sandbox. Documented as the
   production path.

All four sit behind **one `PaymentGateway` interface** selected by a config
flag, so switching is a one-line change. **Per decision D2 every credential slot
is created but left empty, and the app runs perfectly with them empty.**

The commission mechanics — admin sets a percentage per category, it is computed
at booking time, frozen onto the row, and split into a payout record — are
specified in Part 04 §4 and enforced by database triggers rather than app code,
so a client cannot tamper with the split.

### Q5. Google Maps

**Google Maps Platform requires a billing card even for the free $200/month
credit.** If the user will not add a card, Part 08 specifies **OpenStreetMap via
`flutter_map`** — no key, no card, no quota — with the `google_maps_flutter`
integration documented as a drop-in alternative behind the same widget interface.

Distance sorting does not need a map at all: PostGIS is enabled and the
repositories already return `distance_km`. Directions open the device's native
maps app via a `geo:` URL, which is free on every platform.

### What the brief did not ask about, but the app needs

Identified during the audit; each is specified in the part shown.

| Gap | Why it matters | Part |
|---|---|---|
| Prescription upload | Pharmacy legally cannot sell certain medicines without one | 09 |
| Appointment rescheduling | Users cancel-and-rebook otherwise, losing the slot | 08 |
| Refund flow | Doctor cancels — money must return, and be auditable | 04 |
| Provider "leave"/blackout dates | Doctor on holiday still shows bookable slots | 09 |
| Search across everything | Users do not know whether they want a doctor or a hospital | 08 |
| Offline / poor-network handling | Bangladeshi mobile data is intermittent | 07 |
| Accessibility | Font scaling, contrast, screen reader labels | 07 |
| Data export / account deletion | Legal right, and the brief asks for deletion review | 10 |
| Rate limiting | A scraper can enumerate every doctor's phone number | 02 |
| Duplicate-review prevention | One review per completed appointment | 12 |

---

## 3. Logical integrity — the brief's item 4, and its hidden siblings

The user named two contradictions and asked what else is like them. The audit
found **21**. They share one root cause and therefore one cure.

### The governing principle

> **A business rule enforced only in Dart is a rule that will eventually be
> violated.** Enforce every invariant in PostgreSQL — constraint, trigger, or
> `SECURITY DEFINER` function — and let the UI merely *predict* what the
> database will allow. The UI's job is to avoid ugly errors; the database's job
> is to make violations impossible.

Two patients tapping "confirm" in the same 200 ms is not hypothetical — it is
routine when a popular doctor opens a slot. Client-side checking cannot prevent
it, because both clients read "available" before either writes.

### 4.1 — Two patients cannot book the same doctor at the same time

**Solution: a partial unique index. One line, unbypassable.**

```sql
create unique index uq_doctor_slot_active
  on public.appointments (doctor_id, appointment_date, appointment_time)
  where status not in ('cancelled', 'expired');
```

The second concurrent insert fails with SQLSTATE `23505`, which
`SupabaseService.guard()` already maps to a 409. The UI shows "this slot was
just taken" and refreshes. Note `where status not in (...)` — a cancelled
booking must free the slot, and without that clause it would block it forever.

Payment adds a wrinkle the brief calls out: **the slot must be held during
checkout but released if payment never completes.** Part 12 specifies a hold
with `status='pending_payment'` plus a `hold_expires_at` timestamp, a
`pg_cron` job expiring stale holds every minute, and the same unique index
covering held rows so a hold genuinely blocks others.

### 4.2 — Reviews only after the consultation has happened

**Solution: a trigger validating four conditions, server-side.**

A review row may be inserted only if: an appointment exists linking this
reviewer to this target; its scheduled end time is in the past *in Asia/Dhaka*;
its status is `completed` (not `cancelled` or `no_show`); and no review already
exists for that appointment. Every branch is checked in the database, so an
attacker with a REST client gets the same answer as the UI.

Timezone matters: a device set to UTC would otherwise let a Dhaka patient review
six hours early. The DB already has a `dhaka_timezone_fix` migration; Part 12
requires all such comparisons go through `now() at time zone 'Asia/Dhaka'`.

### 4.3 — The other 19 contradictions found in the audit

Full remediation SQL for each is in **Part 12**.

| # | Contradiction | Enforcement |
|---|---|---|
| 1 | Two patients book one slot | partial unique index |
| 2 | Review before consultation | trigger, 4 conditions |
| 3 | Booking a doctor in the past | `CHECK` on date/time |
| 4 | Booking outside published hours | trigger vs `available_days` |
| 5 | Booking an unverified provider | trigger on `verification_status` |
| 6 | Booking while another booking is unpaid | trigger, one pending hold per patient |
| 7 | Two reviews for one appointment | unique constraint |
| 8 | Reviewing a provider never consulted | trigger requires an appointment link |
| 9 | Ordering more medicine than stock | trigger decrements atomically |
| 10 | Stock going negative under concurrency | `CHECK (stock >= 0)` + row lock |
| 11 | Paying twice for one appointment | unique index on verified payments |
| 12 | Commission not reconciling to total | `CHECK (base + fee = total)` |
| 13 | Payout exceeding what was collected | trigger validates against payments |
| 14 | Patient escalating self to admin | column-immutability guard trigger |
| 15 | Provider editing price after booking | price frozen onto the booking row |
| 16 | Blood units going negative | `CHECK` + atomic decrement |
| 17 | Cancelling an already-completed appointment | status-transition state machine |
| 18 | Editing a review years later | edit window, `edited_at` audit |
| 19 | Deleting a user with live appointments | `ON DELETE RESTRICT` + soft delete |
| 20 | Blog published without moderation | status default `draft`, admin transition |
| 21 | Notification forged for another user | no INSERT grant; `SECURITY DEFINER` only |

Each is specified as: the invariant in plain English, the failure scenario, the
exact DDL, the SQLSTATE it raises, how the Dart layer surfaces it bilingually,
and a reproduction test.

---

## 4. The five locked decisions

D1–D4 confirmed by the user on 2026-08-10; D5 follows from §2.

**D1 — Extend the existing app.** Keep the schema, migrations, Edge Functions
and all 115 Dart files. Renaming `users`→`profiles`, `appointments`→`bookings`
or `doctors`→`doctor_profiles` is **forbidden** — those names span 23
migrations, every repository, every RLS policy and every Edge Function.

**D2 — Payments: build the complete flow, leave credentials empty.**
> User's words: *"now, just build it and keep the place empty, i will provide the credentials later"*

Every screen, state, DB write and Edge Function path is written and wired.
Credentials live in exactly one clearly-marked place per surface, holding an
empty string. **The app must start, run and be fully navigable with every slot
empty** — a missing key yields a labelled "payment not configured" state, never
a crash, never a blank screen.

**D3 — Notifications: in-app + local only. No Firebase.** Trigger-driven rows in
`public.notifications`, unread badge, notification centre, locally-scheduled
reminders. `device_tokens` stays (referenced by
`content_repository.registerFcmToken`) but no FCM dependency is added.

**D4 — Deliverable: master index plus numbered parts.** This structure.

**D5 — Stack: Supabase Postgres + Supabase Storage + Supabase Auth; OpenStreetMap
for maps; no SMS OTP.** Rationale in §2.

---

## 5. Execution order

Strictly sequential — each phase depends on the one before. Do not parallelise
across phases. Within a phase, parallelise only where the part file says so.

```
Phase  1   Part 01   Database — schema reference, new migrations, cleanup
Phase  2   Part 12   Logical integrity — the 21 constraints        <-- EARLY, deliberately
Phase  3   Part 02   Backend services — RLS, storage, Edge Functions
Phase  4   Part 03   Authentication — harden, remove demo card, role routing
Phase  5   Part 06   Localization — MUST precede all UI work
Phase  6   Part 07   UI/UX foundation — design system, four-state widgets
Phase  7   Part 04   Payments — gateways, commission, receipts
Phase  8   Part 05   Notifications — triggers, centre, local reminders
Phase  9   Part 08   Patient features — search, compare, book, maps, blood, blog
Phase 10   Part 09   Provider features — doctor, clinic/hospital, pharmacy, blood bank
Phase 11   Part 10   Admin console — verification, moderation, audit, commission
Phase 12   Part 11   QA, verification, completion sign-off
```

Two orderings are load-bearing and must not be rearranged:

**Part 12 is Phase 2, before any feature work.** The integrity constraints define
what the application is permitted to do. Building booking screens first and
adding the double-booking index later means every screen is written against
rules that do not yet exist, and retro-fitting them breaks flows that quietly
depended on the gap.

**Part 06 (localization) precedes all UI work.** Localize afterwards and you
touch ~60 screens twice — and the second pass is the one that gets abandoned.
Establish `AppLocalizations` first; every screen written after Phase 5 is
bilingual on its first write.

---

## 6. Global rules

These bind every part file. Violating one invalidates the work.

**R1 — Zero INSERT statements for business data.** Structure only. No seed rows,
no demo doctors. The sole exception is reference data whitelisted in Part 01 §5
(emergency hotline numbers), each `on conflict do nothing`.

**R2 — Never rename an existing table, column, enum value or route.** Add; do
not rename. A rename cascades into migrations, RLS, Edge Functions and Dart. If
something seems misnamed, note it in the report and leave it.

**R3 — Repository public signatures are frozen.** Rewrite internals freely, add
methods freely, but do not change the name, parameters or return type of an
existing public method — ~60 screens call them. Need different data? Add a new
method beside the old one.

**R4 — No hardcoded user-facing strings after Phase 5.** Everything readable
goes through `AppLocalizations`: errors, empty states, buttons, dialogs,
snackbars, validation messages.

**R5 — Every async surface has four states**: loading, empty, error-with-retry,
content. A blank `Container` while loading, or a raw exception on failure, is
not complete. `core/widgets/state_views.dart` already provides these.

**R6 — Secrets never enter the Flutter binary.** Publishable/anon keys only.
Secrets belong in Edge Function secrets. `app_config.dart` asserts this at
startup — do not weaken that check.

**R7 — Work in vertical slices.** Finish one feature end-to-end (DB → repository
→ provider → screen → l10n → four states) and verify it before starting the
next. The absence of this discipline is what produced the login-screen-only
result.

**R8 — Report honestly.** Maintain `IMPLEMENTATION_LOG.md` at the repo root.
After each phase append what changed, what you verified and *how*, and what you
could not verify. "I could not run `flutter analyze` in this environment" is a
good log line. Claiming a clean build you did not run is a failure.

**R9 — Enforce invariants in the database, not the UI.** Per §3. The UI predicts;
the database decides.

**R10 — Money is `numeric(10,2)`, never float.** No exceptions. Compute
commission in SQL, freeze it onto the row, never recompute it client-side.

---

## 7. Bilingual standard

English and Bangla are **co-equal**. Bangla is not a translation layer bolted
on: a Bangla-first user must complete every journey — register, search, compare,
book, pay, review, get notified — without meeting an English string.

Non-negotiables, detailed in Part 06:

- Runtime switch from Settings, no restart, persisted per user in
  `users.preferred_language`, so it follows them across devices.
- Defaults to device locale; anything but `bn` falls back to English.
- Bangla numerals (০১২৩৪৫৬৭৮৯) for dates, times, money and counts when locale is `bn`.
- `৳` renders correctly in both locales, including in generated PDF receipts —
  which requires embedding a Bangla-capable font in the PDF, or receipts print
  as boxes.
- Admin- and user-authored content (blogs, hotline names, service names) is
  bilingual **at the database level**, not just the UI.
- Font: Hind Siliguri, covering both scripts. A Latin-only font renders Bangla
  as tofu boxes.

---

## 8. Definition of done

Complete when **all** hold. Part 11 turns this into a checkable matrix.

1. `flutter analyze` — zero errors, zero warnings.
2. `flutter build apk --debug` succeeds.
3. Every route in `Routes` resolves to a real screen; no reachable
   `stub_dashboard_screen`.
4. All roles — patient, doctor, clinic, hospital, pharmacy, blood bank, admin —
   land on a functional dashboard.
5. Every screen renders correctly in `en` and `bn`, no hardcoded strings, no
   overflow in either.
6. Every async surface implements all four states (R5).
7. All 21 integrity constraints from Part 12 exist and each has a test proving
   the violation is rejected.
8. Payment runs end-to-end via the simulated gateway with zero credentials, and
   degrades to a labelled "not configured" state for card payment.
9. Commission arithmetic reconciles exactly across `appointments`, `payments`
   and `provider_payouts` for every completed booking.
10. Notifications are trigger-created, appear with a live unread badge, and
    reminders fire locally.
11. Zero INSERT statements for business data in `supabase/`.
12. No `TODO`, `FIXME` or "not implemented" text reachable by a user.
13. `IMPLEMENTATION_LOG.md` records every phase, including what went unverified.

---

## 9. Part index

| Part | File | Covers |
|---|---|---|
| 01 | `01_DATABASE.md` | Schema reference, new migrations, cleanup |
| 02 | `02_BACKEND_SERVICES.md` | RLS, storage, Edge Functions, rate limiting |
| 03 | `03_AUTHENTICATION.md` | Auth hardening, roles, guards, demo-card removal |
| 04 | `04_PAYMENTS.md` | Gateways, commission, escrow, receipts, refunds |
| 05 | `05_NOTIFICATIONS.md` | Triggers, centre, badge, local reminders |
| 06 | `06_LOCALIZATION.md` | English + Bangla, ARB, numerals, DB content |
| 07 | `07_UI_UX.md` | Design system, four states, navigation, accessibility |
| 08 | `08_PATIENT_FEATURES.md` | Search, compare, book, maps, blood, blog, dashboard |
| 09 | `09_PROVIDER_FEATURES.md` | Doctor, clinic/hospital, pharmacy, blood bank |
| 10 | `10_ADMIN_CONSOLE.md` | Verification, moderation, audit, commission control |
| 11 | `11_QA_AND_VERIFICATION.md` | Test matrix, checklist, sign-off |
| 12 | `12_LOGICAL_INTEGRITY.md` | The 21 contradictions and their enforcement |

Start with Part 01. Then Part 12. Then follow §5.



