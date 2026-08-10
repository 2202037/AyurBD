# Part 01 — Database

Subordinate to `spec/00_MASTER_PLAN.md`. Read that first. If this file appears
to contradict it, stop and report.

This part is Phase 1. Nothing else may start until it is applied and verified.

---

## 0. Before you write a single line

The schema in this repository is not a draft. It is 25 tables, 23 applied
migrations, roughly 60 trigger functions and a complete per-command RLS model,
and it is live at the project in `app/lib/core/constants/app_config.dart`.
Most of what a greenfield brief would tell you to build here **already exists**.

Three things in particular were verified on 2026-08-10 and are already done.
Do not re-add them:

| Thing you might assume is missing | Where it already is |
|---|---|
| Double-booking prevention on `doctor_id + date + time` | `supabase/schema.sql:588` — partial unique index `uq_appointments_doctor_slot` |
| A `notify(...)` SECURITY DEFINER helper plus appointment / payment / provider / order / feedback notification triggers | `supabase/schema.sql:1553` (helper), `1591`, `1684`, `1856`, `1897`, `1914` (triggers) |
| The `guard_admin_only_columns()` column-immutability trigger | `supabase/migrations/20260809000002_payment_architecture_fix.sql:101`, wired at `:146`+ |

Your job in this part is therefore narrower and more specific than "build the
database". It is: **document what exists so the next nine parts can rely on it,
then add the four genuinely missing things** (bilingual content columns, a
language preference column, two missing notification triggers, and their
indexes), and delete the dead files.

---

## 1. Table reference

Read this instead of re-reading 155 KB of `schema.sql`. Line numbers are into
`supabase/schema.sql`.

Two ID conventions coexist, deliberately (locked by D1 — do not unify them):

- `users.id` is `uuid`, a FK to `auth.users(id) on delete cascade`. It is **not**
  generated; `handle_new_user()` (`supabase/schema.sql:1965`) mirrors the auth row
  into `public.users` at signup, which is what makes `auth.uid()` usable directly
  in every RLS policy.
- **Every other table** uses `bigint generated always as identity`. `generated
  always` means an explicit id in an INSERT is rejected, not silently honoured.

### 1.1 Identity domain

| Table | Line | Purpose | Key columns | FKs | Dart consumer |
|---|---:|---|---|---|---|
| `users` | 282 | Profile mirror of `auth.users`. No password column. | `id uuid pk`, `name`, `email unique`, `phone`, `gender`, `role`, `city`, `blood_group`, `is_active`, `profile_image` | `id → auth.users(id)` | `auth_repository.dart`, `admin_repository.dart` |

`is_active` is the ban flag: setting it false fires a trigger
(`supabase/schema.sql:2833`) that cancels the user's future appointments and
notifies them. `profile_image` holds an **object path** inside the `avatars`
bucket, never a URL (see Part 02 §4).

### 1.2 Provider domain

All four provider tables share a lifecycle shape: `user_id` (unique, owner),
`verification_status`, `status`, `rejection_reason`, `commission_percentage`,
`rating`, `total_reviews`, `is_deleted`.

| Table | Line | Distinctive columns | Dart consumer |
|---|---:|---|---|
| `doctors` | 311 | `bmdc_registration_number`, `specialization`, `consultation_fee`, `available_days`, `available_from`, `available_to`, `slot_minutes` | `directory_repository.dart`, `provider_repository.dart` |
| `hospitals` | 380 | `total_beds`, `icu_beds`, `departments`, `facilities`, `emergency_phone` | `directory_repository.dart`, `provider_repository.dart` |
| `clinics` | 437 | `services`, `specializations`, `clinic_type` | same |
| `pharmacies` | 488 | `services`, `pharmacy_type`, delivery fields | `pharmacy_repository.dart`, `provider_repository.dart` |

`is_deleted` is a soft delete. A doctor is never physically removed, because
`appointments.doctor_id` is `on delete restrict` — an appointment is a financial
record. Any directory query must filter `not is_deleted`.

`doctors.available_days` is a **CSV of lowercase 3-letter day names**
(`sat,sun,mon,tue,wed,thu,fri`), not a normalised table. That is the slot model
in this app; see §3.3.

### 1.3 Booking and payment domain

| Table | Line | Purpose | Key columns | Dart consumer |
|---|---:|---|---|---|
| `appointments` | 547 | One booking. | `patient_id uuid`, `doctor_id bigint`, `doctor_name` (snapshot), `appointment_date`, `appointment_time`, `fee`, `status`, `payment_status`, `confirmation_code` | `appointment_repository.dart` |
| `payments` | 595 | Payment evidence + money split. | `appointment_id`, `user_id`, `amount`, `payment_method`, `transaction_id`, `payment_status`, `admin_share`, `provider_share`, `stripe_session_id`, `stripe_payment_intent_id`, `gateway`, `gateway_transaction_id` | `appointment_repository.dart`, `payment_service.dart` |
| `payment_sessions` | 688 | One live gateway attempt per appointment. **uuid PK** — the only non-users table that is not bigint. | `id uuid`, `user_id`, `appointment_id`, `amount`, `gateway_ref`, `gateway_txn_id`, `status varchar(30)` | Edge Functions only; client reads own |
| `provider_payouts` | 864 | What a provider is owed after verification. | `provider_share`, source refs | `provider_repository.dart`, `admin_repository.dart` |

Three subtleties that trip up every agent:

1. **`appointments.payment_status` and `payments.payment_status` are different
   types.** The first is `payment_state` (`pending|paid|refunded`); the second is
   `payment_verification_status` (`pending|verified|rejected`). Writing
   `'verified'` to an appointment, or `'paid'` to a payment, fails at the type
   boundary.
2. **`payment_sessions.status` is a `varchar(30)` with a CHECK, not an enum** —
   `check (status in ('initiated','paid','failed','expired','refunded'))` at
   `supabase/schema.sql:699`. Do not "tidy" it into an enum; the Edge Functions
   write it as a string.
3. Money columns are protected by partial unique indexes that exist for
   idempotency, not tidiness: `uq_payments_gateway_txn` (649),
   `uq_payments_stripe_session` (660), `uq_payments_stripe_pi` (664),
   `uq_payments_pending_appt` (672), `uq_payment_sessions_active_appt` (712).
   Read `PAYMENT_ARCHITECTURE_FIX.md` before touching any of them.

### 1.4 Commerce domain

| Table | Line | Purpose | Notes | Dart consumer |
|---|---:|---|---|---|
| `pharmacy_products` | 719 | Catalogue. | `name`, `generic_name`, `brand`, `category`, `description`, `image`; GIN full-text index over name+generic+brand at `:739` | `pharmacy_repository.dart` |
| `cart` | 764 | Per-user cart. | | `pharmacy_repository.dart` |
| `orders` | 780 | One order. | `order_number` filled by a BEFORE INSERT trigger, never by the client; `admin_share`/`provider_share` mirror the payments split | `pharmacy_repository.dart` |
| `order_items` | 833 | Line items. | `product_name` and `unit_price` are **copied, not joined**, so history survives a rename or reprice; `product_id` is `on delete set null` | `pharmacy_repository.dart` |

### 1.5 Community domain

| Table | Line | Purpose | Notes | Dart consumer |
|---|---:|---|---|---|
| `reviews` | 902 | Ratings for any provider. | `reviewable_type` enum + id; moderation via `review_status` | `directory_repository.dart` |
| `feedback` | 1069 | Contact/complaint inbox. | `priority` is `low\|normal\|high\|urgent`; the admin UI says "medium" and the repository maps medium ↔ normal at the boundary (see the comment at `schema.sql:237`) | `admin_repository.dart` |
| `blogs` | 1093 | Articles. | Columns are `title`, `excerpt`, **`content`**, `cover_image`, `slug`, `status`, `published_at`, `views`. **There is no `body` column.** | `content_repository.dart` |
| `blood_banks` | 940 | Directory of banks. | | `blood_repository.dart` |
| `blood_donors` | 972 | Registered donors. | `blood_group`, `city`, `is_available`; partial index `idx_donors_search` on `(blood_group, city) where is_available` | `blood_repository.dart` |
| `blood_requests` | 1002 | Open requests. | `blood_group`, `city`, `needed_by`, `status`; **no `user_id` column** — a request carries `requester_name`/`requester_phone` only | `blood_repository.dart` |

`blood_requests` having no owning user is load-bearing for §3.4: a "your blood
group is needed" notification can only be addressed to **donors**, matched on
`blood_group` + `city`, because the requester may not be a registered user at all.

### 1.6 Ops domain

| Table | Line | Purpose | Notes |
|---|---:|---|---|
| `notifications` | 1029 | In-app notification rows. | `id bigint`, `user_id uuid`, `type varchar(50) default 'general'`, `title varchar(255) not null`, `body text`, `route varchar(255)`, `ref_id bigint`, `is_read boolean`, `created_at`. **Written only by triggers** — see §3.4. Consumed by `content_repository.dart`. |
| `device_tokens` | 1055 | FCM tokens. | Kept because `content_repository.registerFcmToken` references it. D3 forbids adding Firebase; the table stays unused. |
| `emergency_hotlines` | 1129 | Public reference data. | `name`, `phone`, `category`, `description`, `sort_order`, `status`. Readable by `anon` on purpose. The only table §5 permits rows in. |
| `emergency_sms` | 1155 | A log, not a transmitter. | No SMS gateway configured; rows stay `queued`. |
| `audit_log` | 1180 | Trigger-written change log. | `record_id` is `text`, because it must hold both a uuid and a bigint. |
| `app_audit_log` | 1204 | Client-reported app events. | The only audit table with a client insert policy. |

---

## 2. Enum catalogue

Every enum in `public`, with every value, from `supabase/schema.sql:155-269`.
These are the exact strings Dart must send. A typo is a `22P02 invalid input
value for enum` at runtime, not a compile error.

| Enum | Values | Used by |
|---|---|---|
| `user_role` | `patient`, `doctor`, `hospital`, `clinic`, `pharmacy`, `admin` | `users.role` |
| `gender_type` | `male`, `female`, `other` | `users.gender` |
| `blood_group` | `A+`, `A-`, `B+`, `B-`, `AB+`, `AB-`, `O+`, `O-` | `users`, `blood_donors`, `blood_requests` |
| `verification_status` | `pending`, `verified`, `rejected` | all 4 provider tables |
| `provider_status` | `pending`, `active`, `inactive` | all 4 provider tables |
| `active_status` | `active`, `inactive` | `blood_banks`, `pharmacy_products`, `emergency_hotlines` |
| `doctor_type` | `general`, `specialist`, `consultant` | `doctors.doctor_type` |
| `clinic_type` | `general`, `dental`, `eye`, `diagnostic`, `specialized`, `polyclinic` | `clinics.clinic_type` |
| `hospital_type` | `private`, `government`, `specialized`, `teaching` | `hospitals.hospital_type` |
| `pharmacy_type` | `retail`, `wholesale`, `hospital`, `chain` | `pharmacies.pharmacy_type` |
| `appointment_type` | `new`, `followup`, `online` | `appointments.type` |
| `appointment_status` | `pending`, `pending_payment`, `confirmed`, `completed`, `cancelled`, `expired` | `appointments.status` |
| `payment_state` | `pending`, `paid`, `refunded` | `appointments.payment_status`, `orders.payment_status` |
| `payment_verification_status` | `pending`, `verified`, `rejected` | `payments.payment_status` |
| `payment_method` | `bKash`, `Nagad`, `Rocket`, `Credit/Debit Card`, `Bank Transfer`, `Cash`, `sslcommerz` | `payments`, `orders` |
| `order_status` | `pending`, `confirmed`, `processing`, `shipped`, `delivered`, `cancelled` | `orders.status` |
| `blood_request_status` | `active`, `fulfilled`, `cancelled` | `blood_requests.status` |
| `reviewable_type` | `doctor`, `hospital`, `clinic`, `pharmacy` | `reviews.reviewable_type` |
| `review_status` | `pending`, `approved`, `rejected` | `reviews.status` |
| `feedback_type` | `general`, `suggestion`, `complaint`, `bug_report`, `doctor_issue`, `hospital_issue`, `appointment_issue`, `payment_issue`, `appreciation` | `feedback.feedback_type` |
| `feedback_status` | `new`, `in_progress`, `resolved`, `closed` | `feedback.status` |
| `feedback_priority` | `low`, `normal`, `high`, `urgent` | `feedback.priority` |
| `blog_status` | `draft`, `published`, `archived` | `blogs.status` |
| `device_platform` | `android`, `ios`, `web` | `device_tokens.platform` |
| `sms_status` | `queued`, `sent`, `failed` | `emergency_sms.status` |
| `audit_action` | `INSERT`, `UPDATE`, `DELETE` | `audit_log.action_type` |

Note the **capitalisation and punctuation** of `payment_method`: `bKash` (lower
b, capital K) and `Credit/Debit Card` with a slash and spaces. Case-normalising
these in Dart breaks every insert.

`payment_method` also carries `sslcommerz` alongside the Stripe work. Both
gateway paths exist in the schema; only Stripe has Edge Functions.

### 2.1 The rule for changing an enum

> **Adding a value is safe. Removing or renaming one is a breaking change that
> RLS and Dart will not warn you about.**

Adding is safe and online:

```sql
alter type public.appointment_status add value if not exists 'no_show';
```

Removing or renaming is not, for three compounding reasons:

1. **RLS policies embed enum literals in their `USING` / `WITH CHECK`
   expressions.** `appointments_update_doctor` and the partial index
   `uq_appointments_doctor_slot` both name `'cancelled'` and `'expired'`
   textually. PostgreSQL will not let you drop a value that a dependent
   expression references, and if you force it by recreating the type, every
   policy and index built on the old type is silently rebuilt against the new
   one — or dropped by the `cascade`.
2. **`schema.sql` opens each type with `drop type if exists … cascade`.** Re-running
   it after a rename does not error; it takes the dependents with it. That is
   fine on a reset, catastrophic on a live project.
3. **Dart sends bare strings.** There is no generated enum binding. A renamed
   value compiles perfectly and fails at runtime in the user's hands.

R2 in the master plan already forbids renames. This is the concrete reason.

---

## 3. New migrations

Eight new files. Create them exactly with these names, in this order — Supabase
applies migrations in filename order, `0004` depends on `0001`, `0006` depends
on `0003`, and `0008` depends on `0007`.

```
supabase/migrations/20260810000001_bilingual_content_columns.sql
supabase/migrations/20260810000002_user_preferred_language.sql
supabase/migrations/20260810000003_slot_integrity.sql
supabase/migrations/20260810000004_notification_triggers_gap.sql
supabase/migrations/20260810000005_phone_verification_interface.sql
supabase/migrations/20260810000006_doctor_schedule.sql
supabase/migrations/20260810000007_hospital_services.sql
supabase/migrations/20260810000008_commission_rates.sql
```

`0001`–`0004` are specified in **§3.1–§3.4**: they add columns and triggers to
tables that already exist. `0005`–`0008` are specified in **§6**, after the
cleanup and reference-data sections, because they are a different kind of change
— each one closes a gap the master plan named in §2 or in its "what the brief did
not ask about" table, and three of the four create new tables. Each was checked
against the live schema first: none of the four objects they create exists today.

Apply all eight in filename order regardless of which section documents them.

Every statement below is idempotent (`if not exists` / `or replace` /
`drop … if exists` first). Re-running a migration must never error — you will
re-run them while iterating.

### 3.1 `20260810000001_bilingual_content_columns.sql`

Master plan §5 requires that *content*, not only chrome, is bilingual. A hotline
called "National Emergency Service" is useless to a Bangla-first user in a
crisis, and no UI translation layer can fix it, because the string lives in a row.

Column names are verified against the real schema. **`blogs` has `title`,
`excerpt` and `content` — there is no `body` column**, so the Bangla twins are
`title_bn`, `excerpt_bn`, `content_bn`.

Every new column is nullable with no default. English stays canonical: the Dart
resolver reads `bn` when locale is `bn` **and** the value is non-empty, else
falls back to English. A NOT NULL default would have forced fake Bangla into
every existing row.

```sql
-- =====================================================================
-- 20260810000001_bilingual_content_columns.sql
-- Bangla twins for admin- and provider-authored content.
-- Nullable by design: English remains the canonical fallback.
-- Structure only. No INSERT statements (master plan R1).
-- =====================================================================

-- blogs: real columns are title / excerpt / content.
alter table public.blogs
  add column if not exists title_bn   varchar(255),
  add column if not exists excerpt_bn varchar(500),
  add column if not exists content_bn text;

comment on column public.blogs.title_bn is
  'Bangla title. NULL or empty means fall back to title.';
comment on column public.blogs.content_bn is
  'Bangla body. NULL or empty means fall back to content.';

-- emergency_hotlines: the crisis screen must be fully Bangla.
alter table public.emergency_hotlines
  add column if not exists name_bn        varchar(150),
  add column if not exists description_bn varchar(255);

-- pharmacy_products: patients search medicines by Bangla brand name.
alter table public.pharmacy_products
  add column if not exists name_bn        varchar(255),
  add column if not exists description_bn text;

-- Provider free-text service listings. These are the ONLY service/specialty
-- columns that exist; there is no services table.
--   doctors.specialization  varchar(100)   schema.sql:316
--   hospitals.departments   text           schema.sql:400
--   clinics.services        text           schema.sql:452
--   clinics.specializations text           schema.sql:453
--   pharmacies.services     text           schema.sql:506
alter table public.doctors
  add column if not exists specialization_bn varchar(100),
  add column if not exists bio_bn            text;

alter table public.hospitals
  add column if not exists departments_bn text,
  add column if not exists facilities_bn  text,
  add column if not exists description_bn text;

alter table public.clinics
  add column if not exists services_bn        text,
  add column if not exists specializations_bn text,
  add column if not exists description_bn     text;

alter table public.pharmacies
  add column if not exists services_bn    text,
  add column if not exists description_bn text;

-- Bangla search must be as fast as English search. The existing GIN index
-- (schema.sql:739) covers name/generic_name/brand only, so a Bangla query
-- would sequential-scan the catalogue.
create index if not exists idx_products_search_bn
  on public.pharmacy_products
  using gin (to_tsvector('simple',
    coalesce(name_bn, '') || ' ' || coalesce(name, '')));

-- Blog list filtered by language availability: "show me articles that exist
-- in Bangla" is a real query for a bn-locale reader.
create index if not exists idx_blogs_has_bn
  on public.blogs (status, published_at desc)
  where title_bn is not null;
```

`to_tsvector('simple', …)` rather than `'english'`: the `english` dictionary
stems Latin words and would mangle Bangla tokens. `simple` just lowercases and
splits, which is correct for a script Postgres has no stemmer for.

### 3.2 `20260810000002_user_preferred_language.sql`

Part 06 makes the language switchable at runtime and persisted **per user**.
Persisting only to `SharedPreferences` is not enough: the master plan says "no
restart, persisted per user", and a per-device store loses the choice on
reinstall and on a second device. It also cannot be read by anything
server-side, which matters the moment a notification body needs a language.

```sql
-- =====================================================================
-- 20260810000002_user_preferred_language.sql
-- Server-side home for the D3 / Part 06 language choice.
-- =====================================================================

alter table public.users
  add column if not exists preferred_language varchar(2) not null default 'en';

-- Idempotent constraint add: ALTER TABLE ... ADD CONSTRAINT has no
-- IF NOT EXISTS, so drop first.
alter table public.users
  drop constraint if exists users_preferred_language_check;

alter table public.users
  add constraint users_preferred_language_check
  check (preferred_language in ('en', 'bn'));

comment on column public.users.preferred_language is
  'UI language, en|bn. Default en. Written by the client on the Settings toggle; read by notification triggers to pick a title language.';
```

`default 'en'` and `not null` are safe here (unlike the content columns) because
every existing row genuinely has a defined answer: the app has only ever
rendered English.

**The column must be writable by its owner and by nobody else.** The existing
`users_update_self` policy already allows a self-update, and the
`aa_guard_users` trigger guards only `role`, `email` and `is_active` — so
`preferred_language` is writable by the owner with no further change. Confirm
this rather than assuming it (Part 02 §3 has the query).

### 3.3 `20260810000003_slot_integrity.sql`

**Read this section before writing SQL. Most of it already exists.**

How slots work today, verified:

- `doctors.available_days` (CSV `sat,sun,…`), `available_from`, `available_to`,
  `slot_minutes` describe a repeating daily window. There is no slot table.
- `public.available_slots(p_doctor_id bigint, p_date date)` at
  `supabase/schema.sql:2073` generates the times server-side: it walks the
  window with `generate_series`, drops slots in the past **compared against
  Dhaka wall-clock** (`now() at time zone 'Asia/Dhaka'` — plain `now()` is UTC
  and would keep a just-passed Dhaka slot bookable for six hours), and excludes
  times already taken by a non-cancelled, non-expired appointment. It is
  `security definer`, `stable`, and granted to `anon, authenticated`.
- The partial unique index `uq_appointments_doctor_slot`
  (`supabase/schema.sql:588`) enforces one live appointment per
  `(doctor_id, appointment_date, appointment_time)`, excluding `cancelled` and
  `expired` so a freed slot can be rebooked.

#### The race condition, concretely

`available_slots()` is a read. Two patients can both read 10:00 as free:

```
t0  Patient A: select * from available_slots(7, '2026-08-14')  -> [.. 10:00 ..]
t1  Patient B: select * from available_slots(7, '2026-08-14')  -> [.. 10:00 ..]
t2  Patient A: insert into appointments (... 10:00 ...)         -> ok
t3  Patient B: insert into appointments (... 10:00 ...)         -> ???
```

Without a database-level constraint, t3 succeeds and the doctor has two patients
in one chair. A `not exists` check inside the INSERT path does **not** fix this
either: under `READ COMMITTED`, B's subquery cannot see A's uncommitted row, so
both checks pass and both rows land. Only a unique index makes t3 fail, because
uniqueness is enforced at the index level after the row is written, and the
second writer blocks on A's uncommitted key and then fails when A commits.

That index exists. **Do not add a second one.** What you must do is make sure the
failure is *legible* — at t3 Postgres raises SQLSTATE `23505` with the message
`duplicate key value violates unique constraint "uq_appointments_doctor_slot"`,
and a patient must never see that string.

```sql
-- =====================================================================
-- 20260810000003_slot_integrity.sql
--
-- The double-booking guard already exists:
--   uq_appointments_doctor_slot   supabase/schema.sql:588
-- This migration does NOT re-create it. It (a) asserts it is present so a
-- drifted environment fails loudly here rather than silently in
-- production, and (b) turns its raw 23505 into a message a patient can act
-- on.
-- =====================================================================

do $$
begin
  if not exists (
    select 1 from pg_indexes
     where schemaname = 'public'
       and indexname  = 'uq_appointments_doctor_slot'
  ) then
    raise exception
      'uq_appointments_doctor_slot is missing. Do not proceed: the double-booking guard is absent. Re-apply 20260806000001_schema.sql.';
  end if;
end $$;

-- Friendly slot-collision message. BEFORE INSERT, so it fires before the
-- index does and the patient gets a sentence instead of a constraint name.
-- This is a UX layer over the constraint, never a replacement for it: it
-- races exactly as described above, and the index is what actually holds.
create or replace function public.appointments_slot_taken_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
      from public.appointments a
     where a.doctor_id        = new.doctor_id
       and a.appointment_date = new.appointment_date
       and a.appointment_time = new.appointment_time
       and a.status not in ('cancelled', 'expired')
       and (tg_op = 'INSERT' or a.id <> new.id)
  ) then
    raise exception 'SLOT_TAKEN'
      using errcode = '23505',
            hint    = 'That time was just booked by someone else. Please pick another slot.';
  end if;
  return new;
end;
$$;

comment on function public.appointments_slot_taken_message() is
  'UX helper. Converts a slot collision into SLOT_TAKEN before uq_appointments_doctor_slot raises a raw constraint error. Advisory only; the unique index is the real guard.';

drop trigger if exists zz_slot_taken_message on public.appointments;

-- zz_ prefix: same-event triggers fire in alphabetical order, and this one
-- must run AFTER the aa_guard_* triggers have settled the final values of
-- doctor_id / date / time. Checking before them would test a value the row
-- is not going to keep.
create trigger zz_slot_taken_message
  before insert or update of appointment_date, appointment_time, doctor_id
  on public.appointments
  for each row execute function public.appointments_slot_taken_message();

-- The slot generator's hot path: "is this (doctor, date, time) taken?" for a
-- whole day. The existing idx_appointments_doctor_date is (doctor_id,
-- appointment_date desc) and does not carry the time, so available_slots()
-- re-reads the heap for every candidate.
create index if not exists idx_appointments_slot_lookup
  on public.appointments (doctor_id, appointment_date, appointment_time)
  where status not in ('cancelled', 'expired');
```

Dart must catch `PostgrestException` with `code == '23505'` **or** a message
containing `SLOT_TAKEN` and re-fetch the slot list, showing the localized
"slot taken" string. Part 08 specifies that screen behaviour.

### 3.4 `20260810000004_notification_triggers_gap.sql`

**Read the inventory before writing.** Most of the notification system exists.

| Event | Function | Line | Status |
|---|---|---:|---|
| `notify(...)` SECURITY DEFINER helper | `public.notify` | 1553 | **Exists** |
| Appointment requested / confirmed / completed / cancelled / expired | `appointments_notify()` | 1591 | **Exists** |
| Payment submitted / verified / rejected | `payments_notify()` | 1684 | **Exists** |
| Provider verified / rejected / activated / deactivated | `providers_notify()` | 1856 | **Exists**, wired to all 4 provider tables (3159-3171) |
| Order **placed** | `orders_notify()` | 1897 | **Exists — INSERT only** |
| Feedback answered | `feedback_notify()` | 1914 | **Exists** |
| Account suspended / reactivated | inline in the ban trigger | 2833 | **Exists** |
| Order **status changed** (confirmed → shipped → delivered …) | — | — | **MISSING** |
| Blood request matches a donor's group | — | — | **MISSING** |

So the task is two triggers, not nine. Everything else is already wired at
`supabase/schema.sql:3143-3171`.

The existing `notify()` signature — reuse it, do not redefine it:

```sql
public.notify(p_user_id uuid, p_title text, p_body text,
              p_type text, p_route text, p_ref_id bigint) returns void
```

It is `security definer`, `set search_path = ''`, it early-returns on a NULL
`p_user_id`, and `EXECUTE` is revoked from `public, anon, authenticated`
(`schema.sql:1578`). That revoke is deliberate and must stay.

#### Why `authenticated` must have NO insert grant on `notifications`

This is the single most important rule in this file, and it is already correct
in the repo — `supabase/schema.sql:3381` grants only `select, update`, and
`rls_policies.sql:836` deliberately creates no INSERT policy. Preserve it.

The reasoning is a dilemma with no third option. A notification is by nature
addressed to *someone else*: the doctor confirms, the **patient** is told. So a
client-side INSERT policy must be one of:

- `with check (user_id = auth.uid())` — a user may only insert notifications for
  themselves. This makes every genuine cross-user notification impossible. The
  doctor confirming an appointment cannot write to the patient's row, so the
  feature silently does nothing.
- `with check (true)` — anyone may insert for anyone. Now any authenticated
  account can forge "Payment verified" or "Your appointment is cancelled" into
  any other user's notification centre, with a `route` of their choosing. That
  is a phishing primitive delivered inside the trusted UI.

There is no policy that is both useful and safe, because the safety condition
depends on *why* the row is being written, and RLS can only see *who* is writing
it. Moving the decision into a `SECURITY DEFINER` trigger is what resolves it:
the trigger knows the row was produced by a real state transition, and it runs
as the function owner, so it bypasses both the missing grant and RLS.

Therefore:

```sql
-- Already true in the repo. Assert, do not "fix".
-- grant select, update on public.notifications to authenticated;  -- no insert
-- grant usage on sequence: not needed, nothing client-side inserts.
```

If you ever find yourself writing `supabase.from('notifications').insert(...)`
in Dart, you have taken a wrong turn. Add a trigger instead.

#### The migration

```sql
-- =====================================================================
-- 20260810000004_notification_triggers_gap.sql
--
-- Closes the two gaps in the trigger-driven notification model:
--   1. order status transitions after placement
--   2. a new blood request reaching matching donors
--
-- public.notify() (schema.sql:1553) is reused as-is. Nothing here grants
-- INSERT on notifications to any client role -- see the section above.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Order status transitions.
--
-- orders_notify() (schema.sql:1897) fires on INSERT only and says "Order
-- placed". A buyer currently learns nothing when the pharmacy ships. This
-- is a separate function rather than an edit to orders_notify(), so the
-- existing INSERT wording and its trigger are untouched (master plan R2).
-- ---------------------------------------------------------------------
create or replace function public.orders_status_notify()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_title text;
  v_body  text;
begin
  if new.status is not distinct from old.status then
    return null;
  end if;

  case new.status
    when 'confirmed' then
      v_title := 'Order confirmed';
      v_body  := 'Order ' || new.order_number || ' has been confirmed by the pharmacy.';
    when 'processing' then
      v_title := 'Order being prepared';
      v_body  := 'Order ' || new.order_number || ' is being prepared.';
    when 'shipped' then
      v_title := 'Order shipped';
      v_body  := 'Order ' || new.order_number || ' is on its way.';
    when 'delivered' then
      v_title := 'Order delivered';
      v_body  := 'Order ' || new.order_number || ' has been delivered.';
    when 'cancelled' then
      v_title := 'Order cancelled';
      v_body  := 'Order ' || new.order_number || ' has been cancelled.';
    else
      return null;   -- 'pending' is the initial state; orders_notify covers it
  end case;

  perform public.notify(
    new.user_id, v_title, v_body, 'order', '/pharmacy/orders', new.id
  );
  return null;
end;
$$;

drop trigger if exists orders_status_notify on public.orders;

-- AFTER UPDATE: the row is committed-visible to the function, and a
-- notification must never be able to abort the business write. Returning
-- null from an AFTER trigger is correct and ignored.
create trigger orders_status_notify
  after update of status on public.orders
  for each row execute function public.orders_status_notify();

-- ---------------------------------------------------------------------
-- 2. Blood request -> matching donors.
--
-- IMPORTANT: blood_requests has NO user_id column (schema.sql:1002). A
-- request carries requester_name/requester_phone only, because the PHP
-- route accepted anonymous requests. So this fans OUT to donors; there is
-- no requester to notify.
--
-- Matching rule: same blood_group, same city, is_available, and the donor
-- is a registered user (user_id not null -- guest donor rows exist, see
-- donors_insert_guest in rls_policies.sql:779). notify() would no-op on a
-- null user_id anyway; the WHERE makes that explicit and skips the calls.
-- ---------------------------------------------------------------------
create or replace function public.blood_requests_notify_donors()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_donor record;
  v_sent  integer := 0;
begin
  if new.status <> 'active' then
    return null;
  end if;

  for v_donor in
    select d.user_id
      from public.blood_donors d
     where d.blood_group  = new.blood_group
       and d.city         = new.city
       and d.is_available
       and d.user_id is not null
     -- A citywide O- shortage should not mint 4000 rows in one statement.
     -- Nearest-first is not expressible (no coordinates on donors), so the
     -- cap is deterministic: most recently registered available donors.
     order by d.updated_at desc
     limit 50
  loop
    perform public.notify(
      v_donor.user_id,
      'Blood needed: ' || new.blood_group,
      new.units_needed || ' unit(s) of ' || new.blood_group
        || ' needed at ' || new.hospital_name || ', ' || new.city
        || ' by ' || to_char(new.needed_by, 'YYYY-MM-DD') || '.',
      'blood', '/blood-bank/requests', new.id
    );
    v_sent := v_sent + 1;
  end loop;

  return null;
end;
$$;

comment on function public.blood_requests_notify_donors() is
  'Fans a new active blood request out to up to 50 matching available donors. blood_requests has no owning user, so there is no requester-side notification.';

drop trigger if exists blood_requests_notify_donors on public.blood_requests;

create trigger blood_requests_notify_donors
  after insert on public.blood_requests
  for each row execute function public.blood_requests_notify_donors();

-- ---------------------------------------------------------------------
-- 3. Indexes for the new query patterns.
-- ---------------------------------------------------------------------

-- The donor fan-out above. idx_donors_search is (blood_group, city) WHERE
-- is_available, which matches the predicate but not the ORDER BY, so the
-- planner sorts. This one serves both.
create index if not exists idx_donors_match_recent
  on public.blood_donors (blood_group, city, updated_at desc)
  where is_available and user_id is not null;

-- The notification centre's list query: one user's rows, newest first,
-- filtered by type ("show me only payments"). The existing
-- idx_notifications_unread is partial on `not is_read` and cannot serve a
-- read-inclusive type filter.
create index if not exists idx_notifications_user_type_created
  on public.notifications (user_id, type, created_at desc);

-- The order-status timeline a buyer opens from the notification.
create index if not exists idx_orders_user_status
  on public.orders (user_id, status, created_at desc);

-- Language-aware content lookups (paired with 20260810000001).
create index if not exists idx_users_preferred_language
  on public.users (preferred_language);
```

#### Notification language

The trigger bodies above are English. Making them bilingual server-side would
mean either duplicating every string into a `title_bn` column on `notifications`
(a schema change to a hot table) or branching on `users.preferred_language`
inside every trigger (a join per notification).

Neither is worth it. **The chosen approach:** `notifications.type` plus a stable
`title` acts as a translation *key* for the common cases, and Part 05 specifies
a client-side map from the known English titles to localized strings, falling
back to the raw stored text for anything unrecognised. Free-text bodies that
embed an order number or a hospital name stay as stored. Do not add `title_bn`
to `notifications` without re-reading Part 05 §4.

---

## 4. Cleanup

Four empty directories and three dead files. All verified on 2026-08-10.

### 4.1 The four empty feature directories — delete now

Verified empty (`find … -type f | wc -l` returns 0 for each):

```
app/lib/features/booking/
app/lib/features/doctor/
app/lib/features/hospital/
app/lib/features/shop/
```

They are the residue of an aborted refactor. Their names collide conceptually
with the real modules (`appointments`, `directory`, `provider`, `pharmacy`),
which is exactly how an agent ends up creating a second booking flow beside the
working one.

```bash
cd "F:/Project folder/AyurBD"
rm -rf app/lib/features/booking app/lib/features/doctor \
       app/lib/features/hospital app/lib/features/shop
```

Git does not track empty directories, so if `git status` shows nothing after
this, the deletion still succeeded on disk. That is the expected result.

### 4.2 The two tombstone files — delete now

Both were read in full. Each contains only a doc comment and the single
statement `library;` — no class, no import, no export:

| File | Size | Content |
|---|---:|---|
| `app/lib/core/network/api_client.dart` | 1412 B | Doc comment + `library;` |
| `app/lib/core/constants/api_endpoints.dart` | 1367 B | Doc comment + `library;` |

Both say in their own text "safe to delete this file … `git rm` it whenever
convenient". They were emptied rather than removed only because the migration
ran without shell access.

**Verify before deleting** — the master plan warns that `Grep` returns spurious
negatives on this `F:` path, so run this and require zero output:

```bash
cd "F:/Project folder/AyurBD"
grep -rn "api_client\|api_endpoints\|ApiClient\|ApiEndpoints" app/lib --include=*.dart
# zero lines -> safe
rm app/lib/core/network/api_client.dart app/lib/core/constants/api_endpoints.dart
```

If that grep returns anything other than the files' own paths, stop and report.

### 4.3 `stub_dashboard_screen.dart` — DO NOT delete yet

`app/lib/features/home/presentation/stub_dashboard_screen.dart` is stale dead
code that tells doctor / clinic / pharmacy / hospital / admin users their
dashboard "is not built", when `features/provider` (12 files) and
`features/admin` (14 files) are in fact built.

It is nonetheless **the last thing to delete, not the first**. Deleting it in
Phase 1 breaks whatever still resolves through it and leaves five roles with no
landing screen at all — a strictly worse state than a stale placeholder, and
one that blocks Phases 3 through 8 from being testable.

Sequence:

1. **Phase 1 (now):** leave the file. Record it in `IMPLEMENTATION_LOG.md` as a
   known deletion pending Part 09.
2. **Part 09:** replace the role-routing that reaches it with real provider
   dashboards.
3. **Part 09, final step:** confirm the router no longer references it, then
   delete:

```bash
cd "F:/Project folder/AyurBD"
grep -rn "stub_dashboard\|StubDashboard" app/lib --include=*.dart
# only the file's own definition -> safe to remove
rm app/lib/features/home/presentation/stub_dashboard_screen.dart
```

Definition-of-done item 3 ("No `stub_dashboard_screen` remains reachable") is
checked in Part 11, not here.

---

## 5. Permitted reference data

### R1, restated

> **Zero INSERT statements for business data.** No seed rows, no demo data, no
> sample doctors, no test patients, no placeholder products, no example blog
> posts. Structure only.

This is not a style preference. A seeded row is indistinguishable from a real
one to every screen, every count and every admin report, and the person who has
to find and delete them later is the user.

### The single exception

**Emergency hotline numbers, and nothing else.** These are published national
public-service numbers, not business data: they are identical for every
deployment, they are not owned by any user, and an empty emergency screen during
an actual emergency is a safety failure. `emergency_hotlines` is also the one
table deliberately readable by `anon` (`schema.sql:1139`) precisely because
someone who needs 999 should not have to sign in first.

Put this in `20260810000001_bilingual_content_columns.sql`, **after** the
`add column` statements that create `name_bn` and `description_bn` — it depends
on them.

Every row is `on conflict do nothing`, keyed on `phone`, so re-running the
migration cannot duplicate a number or overwrite an admin's edit.

```sql
-- ---------------------------------------------------------------------
-- PERMITTED REFERENCE DATA -- the ONLY INSERT allowed in this project.
-- Published Bangladesh national emergency numbers. See spec/01_DATABASE.md
-- section 5. Do not extend this list with anything user-owned.
-- ---------------------------------------------------------------------

-- on conflict needs a unique key to target. phone is the natural one.
create unique index if not exists uq_hotline_phone
  on public.emergency_hotlines (phone);

insert into public.emergency_hotlines
  (name, name_bn, phone, category, description, description_bn, sort_order, status)
values
  ('National Emergency Service', 'জাতীয় জরুরি সেবা', '999',
   'emergency', 'Police, fire and ambulance, one number, 24/7',
   'পুলিশ, ফায়ার সার্ভিস ও অ্যাম্বুলেন্স — একটি নম্বরে, ২৪/৭', 10, 'active'),

  ('National Health Call Centre', 'স্বাস্থ্য বাতায়ন', '16263',
   'health', 'Government health advice line, 24/7',
   'সরকারি স্বাস্থ্য পরামর্শ সেবা, ২৪/৭', 20, 'active'),

  ('Fire Service and Civil Defence', 'ফায়ার সার্ভিস ও সিভিল ডিফেন্স', '199',
   'emergency', 'Fire and rescue control room',
   'অগ্নিনির্বাপণ ও উদ্ধার নিয়ন্ত্রণ কক্ষ', 30, 'active'),

  ('Shishu Bandhu (child helpline)', 'শিশু বন্ধু', '1098',
   'child', 'Child protection helpline',
   'শিশু সুরক্ষা হেল্পলাইন', 40, 'active'),

  ('Women and Children Helpline', 'নারী ও শিশু নির্যাতন প্রতিরোধে হেল্পলাইন', '109',
   'women', 'Violence against women and children',
   'নারী ও শিশু নির্যাতন প্রতিরোধ', 50, 'active'),

  ('National Helpline for Citizens', 'সরকারি তথ্য ও সেবা', '333',
   'general', 'Government information and services',
   'সরকারি তথ্য ও সেবা', 60, 'active'),

  ('Anti-Corruption Commission', 'দুর্নীতি দমন কমিশন', '106',
   'general', 'Anti-corruption complaint line',
   'দুর্নীতি অভিযোগ কেন্দ্র', 70, 'active'),

  ('Bangladesh Railway Helpline', 'বাংলাদেশ রেলওয়ে হেল্পলাইন', '163',
   'transport', 'Railway information and complaints',
   'রেল তথ্য ও অভিযোগ', 80, 'active')
on conflict (phone) do nothing;
```

Note both `name` and `name_bn` are supplied. A hotline whose Bangla name is NULL
would fall back to English on the one screen where that is least acceptable.

**Not permitted, to be explicit:** doctors, clinics, hospitals, pharmacies,
products, blogs, blood banks, blood donors, users of any role (including a demo
admin — use `supabase/admin_bootstrap.sql`, which promotes an existing
account rather than creating one), appointments, orders, reviews, feedback,
notifications, or "just one test row to check it works". Check it works with a
`select`.

---

## 6. Migrations 0005–0008 — the gaps the master plan named

The four migrations below are separated from §3 because each one closes a gap
identified in master plan §2 or in its "what the brief did not ask about, but the
app needs" table, rather than merely extending an existing table:

| Migration | Closes | Named in |
|---|---|---|
| `0005` phone verification interface | no phone verification, and no place to put one | master plan Q3 |
| `0006` doctor schedule | provider leave/blackout dates; per-day hours | master plan §2 gap table |
| `0007` hospital services | a priced, comparable service catalogue | brief item 3 |
| `0008` commission rates | admin sets commission per category | master plan Q4 |

Every one was verified absent before being specified. The verification command is
given at the top of each subsection; run it and confirm the negative before
writing SQL, because master plan §1 warns that `Grep` returns spurious "no files
found" results on this `F:` path.

### 6.1 `20260810000005_phone_verification_interface.sql`

Master plan Q3 settles this: **no SMS OTP is built, because no free SMS path
exists.** What is built is the *shape* of one, so that dropping in a gateway
later is a code change and not a schema migration on a live table.

Verified absent: `grep -n "phone_verified" supabase/schema.sql` returns nothing.

```sql
-- =====================================================================
-- 20260810000005_phone_verification_interface.sql
--
-- The interface for phone verification, with no verifier behind it.
-- Master plan Q3: SMS OTP is deliberately excluded (every gateway
-- charges, and Bangladeshi providers require a business licence). This
-- migration adds only the columns a future verifier would need, so
-- enabling one later does not require a migration against a hot table.
--
-- NOTHING in this migration sends anything. phone_verified stays false
-- for every row until a real verifier writes it.
-- =====================================================================

alter table public.users
  add column if not exists phone_verified    boolean     not null default false,
  add column if not exists phone_verified_at timestamptz;

comment on column public.users.phone_verified is
  'False for every row today: no SMS gateway is configured (master plan Q3). The UI must label an unverified number as unverified rather than implying it was checked.';
comment on column public.users.phone_verified_at is
  'When a verifier confirmed the number. NULL while phone_verified is false.';

-- The two columns must agree. A verified_at with phone_verified = false
-- (or the reverse) would make "is this number checked?" ambiguous, and
-- the UI would have to guess.
alter table public.users
  drop constraint if exists users_phone_verified_check;

alter table public.users
  add constraint users_phone_verified_check
  check ((phone_verified = false and phone_verified_at is null)
         or (phone_verified = true  and phone_verified_at is not null));

-- Bangladeshi mobile format, enforced server-side as well as in Dart.
-- NULL is allowed: phone is optional on the users table today and R2
-- forbids tightening that into NOT NULL.
alter table public.users
  drop constraint if exists users_phone_format_check;

alter table public.users
  add constraint users_phone_format_check
  check (phone is null or btrim(phone) = '' or phone ~ '^01[3-9][0-9]{8}$');
```

**A warning about that last constraint.** `ALTER TABLE ... ADD CONSTRAINT`
validates every existing row. If any `users.phone` was written by the PHP era in
another shape (`+8801…`, spaces, dashes), this statement aborts the migration.
Run the audit query **before** applying, and if it returns rows, either normalise
them in a separate statement or add the constraint `NOT VALID`:

```sql
-- Audit first.
select id, phone from public.users
 where phone is not null and btrim(phone) <> ''
   and phone !~ '^01[3-9][0-9]{8}$';

-- If rows come back and you cannot normalise them safely, this form adds
-- the rule for FUTURE writes without failing on historical ones:
--   alter table public.users add constraint users_phone_format_check
--     check (...) not valid;
```

`phone_verified` is **not** added to the `aa_guard_users` trigger's admin-only
column list, and that is deliberate: guarding it would mean only an admin could
ever set it, which blocks the very verifier this migration exists to enable. The
protection is instead that no client-reachable code path writes it — Part 03
specifies that the future `PhoneVerifier` writes it through a `SECURITY DEFINER`
RPC, exactly like `notify()`.

---

### 6.2 `20260810000006_doctor_schedule.sql` — the slot model

This is the largest decision in Part 01. Read the whole section before writing.

### What exists today

| Object | Where | What it does |
|---|---|---|
| `doctors.available_days` | `supabase/schema.sql:339` | `varchar(100)`, CSV of `sat,sun,mon,tue,wed,thu,fri` |
| `doctors.available_from` / `available_to` | `:340`, `:341` | one `time` window, the same on every working day |
| `doctors.slot_minutes` | `:342` | `integer default 30`, CHECK between 5 and 240 |
| `available_slots(bigint, date)` | `:2073` | walks the window with `generate_series`, drops past slots against `now() at time zone 'Asia/Dhaka'`, excludes taken times |
| `uq_appointments_doctor_slot` | `:588` | partial unique index, the double-booking guard |

So slots are **computed, never stored**. There is no slot table.

### What this model cannot express

1. **Different hours on different days.** A doctor working 09:00–13:00 on
   Saturday and 17:00–21:00 on Tuesday cannot be represented: there is one
   `available_from`/`available_to` pair for all seven days.
2. **A lunch break or a second sitting.** One window per day, so a
   morning-and-evening chamber is either one long window that offers slots
   during the gap, or half the real availability.
3. **Leave and blackout dates.** Master plan §2 lists "Provider leave/blackout
   dates — doctor on holiday still shows bookable slots" as a real gap. There is
   nowhere to put a date the doctor is away, so `available_slots()` cheerfully
   offers Eid.

### The choice: schedule template + computed slots, not a generated slot table

Two designs were considered.

**Rejected — a materialised `doctor_slots` table**, one row per bookable time,
generated N days ahead by a job. It makes "is this slot free" a plain row lookup
and lets a slot carry its own state. It also means: a doctor with a 30-minute
slot over a 6-hour day is 12 rows/day, 4 380 rows/year, times every doctor —
and every schedule edit has to regenerate the future rows and reconcile them
against existing bookings. Worse, it creates **two sources of truth for
availability** (the slot row and the appointment row) which then have to be kept
consistent, which is exactly the class of bug this whole spec exists to remove.

**Chosen — a schedule template plus the existing computed generator.** Keep
`available_slots()` as the single answer to "what is bookable", and give it
richer inputs: a per-day working-hours table, and a blackout table. Availability
stays derived, so it cannot drift from the bookings; a schedule edit is one row
change and takes effect on the next query; and the storage cost is a handful of
rows per doctor forever instead of thousands per year.

The cost of the choice, stated honestly: computing slots is more expensive than
reading them, and the query runs on every booking-screen open. That is bounded
by the index in this migration and by the fact that a single doctor-day is at
most a few dozen candidate times.

**Backward compatibility is mandatory (R2, R3).** `doctors.available_days`,
`available_from`, `available_to` and `slot_minutes` are **not** dropped and not
renamed. The new function falls back to them when a doctor has no template rows,
so every doctor configured today keeps working unchanged and migration to the
new model is per-doctor and voluntary.

### Weekday encoding — read this or the schedule will be off by one

The legacy CSV stores English three-letter names (`sat`, `sun`, …). The new table
stores an integer, and it uses **PostgreSQL's own `extract(dow from date)`
convention** so that no lookup table is needed:

| `weekday` | Day | Legacy CSV token |
|---:|---|---|
| 0 | Sunday | `sun` |
| 1 | Monday | `mon` |
| 2 | Tuesday | `tue` |
| 3 | Wednesday | `wed` |
| 4 | Thursday | `thu` |
| 5 | Friday | `fri` |
| 6 | Saturday | `sat` |

Note this is **not** the Bangladeshi week order (which starts Saturday). Do not
"fix" it to match the UI. The UI orders the list for display; the column stores
what `extract(dow)` returns, because that is what the generator compares against,
and any other encoding needs a conversion in the hot path that will eventually be
written the wrong way round.

### The migration

```sql
-- =====================================================================
-- 20260810000006_doctor_schedule.sql
--
-- A real availability model: per-weekday working windows, per-window
-- slot length, and blackout/leave dates. Slots stay COMPUTED --
-- available_slots() remains the single source of truth for "what is
-- bookable" -- so availability can never drift from the appointments
-- table. See spec/01_DATABASE.md section 6.2 for why a materialised
-- doctor_slots table was rejected.
--
-- doctors.available_days / available_from / available_to / slot_minutes
-- are NOT dropped (master plan R2). They remain the fallback for any
-- doctor with no template rows.
--
-- Structure only. No INSERT statements (master plan R1).
-- =====================================================================

-- btree_gist lets an EXCLUDE constraint mix an equality test on
-- doctor_id/weekday with an overlap test on the time window. Without it
-- the exclusion constraint below cannot be created.
create extension if not exists btree_gist with schema extensions;

-- IMMUTABLE, so it may appear inside an index/exclusion expression.
-- A plain `extract(...)` chain is immutable too, but naming it keeps the
-- constraint readable and keeps the two range endpoints in step.
create or replace function public.time_to_minutes(p_t time)
returns integer
language sql
immutable
set search_path = ''
as $$
  select (extract(hour from p_t) * 60 + extract(minute from p_t))::int;
$$;

comment on function public.time_to_minutes(time) is
  'Minutes since midnight. Exists so doctor_schedules_no_overlap can build an int4range from two time columns; PostgreSQL has no built-in range type over `time`.';

-- ---------------------------------------------------------------------
-- doctor_schedules -- the working-hours template.
--
-- One row per (doctor, weekday, window). MULTIPLE rows per weekday are
-- the point: a morning chamber and an evening chamber are two rows, and
-- the lunch gap between them is simply not covered by either.
-- ---------------------------------------------------------------------
create table if not exists public.doctor_schedules (
  id           bigint generated always as identity primary key,
  doctor_id    bigint  not null references public.doctors (id) on delete cascade,
  -- extract(dow): 0 = Sunday .. 6 = Saturday. See the table above.
  weekday      smallint not null,
  starts_at    time    not null,
  ends_at      time    not null,
  slot_minutes integer not null default 30,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint doctor_schedules_weekday_check
    check (weekday between 0 and 6),
  constraint doctor_schedules_window_check
    check (ends_at > starts_at),
  -- Mirrors doctors_slot_minutes_check (schema.sql:352) so the two
  -- models cannot disagree about what a legal slot length is.
  constraint doctor_schedules_slot_minutes_check
    check (slot_minutes between 5 and 240),
  -- A window shorter than one slot generates nothing and looks like a
  -- bug to the doctor who entered it.
  constraint doctor_schedules_window_fits_slot_check
    check (public.time_to_minutes(ends_at) - public.time_to_minutes(starts_at)
           >= slot_minutes)
);

comment on table public.doctor_schedules is
  'Per-weekday working windows. Slots are computed from these by available_slots(); nothing here stores a bookable slot.';

-- Two active windows on the same weekday must not overlap, or the
-- generator emits the same time twice and the patient sees a duplicate.
-- An EXCLUDE constraint is the only way to say this: a unique index
-- cannot express "ranges must not intersect".
alter table public.doctor_schedules
  drop constraint if exists doctor_schedules_no_overlap;

alter table public.doctor_schedules
  add constraint doctor_schedules_no_overlap
  exclude using gist (
    doctor_id with =,
    weekday   with =,
    int4range(public.time_to_minutes(starts_at),
              public.time_to_minutes(ends_at)) with &&
  ) where (is_active);
```

The `where (is_active)` clause on the EXCLUDE matters: a doctor editing their
schedule typically deactivates a window and adds a replacement that covers part
of the same range. Without the predicate, the deactivated row would block the
new one and the edit would fail with a constraint the doctor cannot interpret.

```sql
-- ---------------------------------------------------------------------
-- doctor_blackouts -- leave, holidays, conference days.
--
-- A date RANGE, not a single date, because "away 12-20 September" is one
-- intent and eight rows is eight chances to get it wrong.
-- ---------------------------------------------------------------------
create table if not exists public.doctor_blackouts (
  id         bigint generated always as identity primary key,
  doctor_id  bigint  not null references public.doctors (id) on delete cascade,
  starts_on  date    not null,
  ends_on    date    not null,   -- inclusive
  reason     varchar(255),
  reason_bn  varchar(255),
  created_at timestamptz not null default now(),
  constraint doctor_blackouts_range_check check (ends_on >= starts_on)
);

comment on table public.doctor_blackouts is
  'Dates a doctor is unavailable. ends_on is INCLUSIVE. available_slots() returns nothing for a covered date.';
comment on column public.doctor_blackouts.ends_on is
  'Inclusive. A single-day leave is starts_on = ends_on.';

-- Overlapping leave rows are harmless (the date is still blacked out)
-- but they confuse the provider UI's "your leave" list, so they are
-- merged rather than forbidden -- forbidding them would reject the
-- ordinary act of extending existing leave by a day.
create index if not exists idx_doctor_blackouts_lookup
  on public.doctor_blackouts (doctor_id, starts_on, ends_on);
```

### Indexes, and the query each one serves

```sql
-- Query: the generator's template read --
--   select ... from doctor_schedules
--    where doctor_id = $1 and weekday = extract(dow from $2) and is_active
-- Covering (doctor_id, weekday) with the predicate turns this into a
-- single index scan of at most a few rows.
create index if not exists idx_doctor_schedules_lookup
  on public.doctor_schedules (doctor_id, weekday)
  where is_active;

-- Query: the provider's "my week" editor --
--   select ... from doctor_schedules where doctor_id = $1
--    order by weekday, starts_at
-- Serves both the filter and the ORDER BY, so no sort node.
create index if not exists idx_doctor_schedules_doctor_order
  on public.doctor_schedules (doctor_id, weekday, starts_at);

-- Query: "is this doctor on leave on this date?" --
--   select 1 from doctor_blackouts
--    where doctor_id = $1 and $2 between starts_on and ends_on
-- (idx_doctor_blackouts_lookup above serves this; declared with the
-- table so the two are read together.)
```

### The rewritten generator

`available_slots(bigint, date)` is replaced with `create or replace function` —
**same name, same argument types, same return type**, because Dart, the guards
and `appointments_book()` all call it. Changing the signature would break
`guard_appointments_insert()` at `supabase/schema.sql:2234` and
`appointments_book()` at
`supabase/migrations/20260809000002_payment_architecture_fix.sql:765`.

```sql
-- ---------------------------------------------------------------------
-- available_slots -- rewritten. SAME SIGNATURE (bigint, date) -> table
-- (slot_time time), because guard_appointments_insert() and
-- appointments_book() both call it and R3 freezes the contract.
--
-- Resolution order:
--   1. doctor_blackouts covers the date            -> no slots
--   2. doctor_schedules has active rows for the
--      weekday                                     -> use them (may be several)
--   3. otherwise                                   -> legacy CSV window
--                                                     (doctors.available_days)
--
-- Step 3 is what keeps every doctor configured before this migration
-- working with no data change.
-- ---------------------------------------------------------------------
create or replace function public.available_slots(
  p_doctor_id bigint,
  p_date      date
)
returns table (slot_time time)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_doc     record;
  v_day     text;
  v_dow     smallint := extract(dow from p_date)::smallint;
  v_has_tpl boolean;
begin
  select available_days, available_from, available_to,
         coalesce(slot_minutes, 30) as slot_minutes
    into v_doc
    from public.doctors
   where id = p_doctor_id and status = 'active' and not is_deleted;

  if v_doc is null then
    return;
  end if;

  -- 1. Leave wins over everything.
  if exists (
    select 1 from public.doctor_blackouts b
     where b.doctor_id = p_doctor_id
       and p_date between b.starts_on and b.ends_on
  ) then
    return;
  end if;

  select exists (
    select 1 from public.doctor_schedules s
     where s.doctor_id = p_doctor_id
       and s.weekday   = v_dow
       and s.is_active
  ) into v_has_tpl;

  if v_has_tpl then
    -- 2. Template model. One generate_series per window, unioned, so a
    -- morning and an evening sitting both appear and the gap does not.
    return query
      with windows as (
        select s.starts_at, s.ends_at, s.slot_minutes
          from public.doctor_schedules s
         where s.doctor_id = p_doctor_id
           and s.weekday   = v_dow
           and s.is_active
      ),
      slots as (
        select generate_series(
                 p_date + w.starts_at,
                 p_date + w.ends_at - make_interval(mins => w.slot_minutes),
                 make_interval(mins => w.slot_minutes)
               ) as ts
          from windows w
      )
      select distinct s.ts::time
        from slots s
       where s.ts > (now() at time zone 'Asia/Dhaka')
         and not exists (
               select 1
                 from public.appointments a
                where a.doctor_id        = p_doctor_id
                  and a.appointment_date = p_date
                  and a.appointment_time = s.ts::time
                  and a.status not in ('cancelled', 'expired')
             )
       order by 1;
    return;
  end if;

  -- 3. Legacy CSV fallback -- byte-for-byte the pre-migration behaviour.
  if v_doc.available_days is null
     or v_doc.available_from is null
     or v_doc.available_to   is null then
    return;
  end if;

  v_day := lower(to_char(p_date, 'dy'));
  if position(v_day in lower(v_doc.available_days)) = 0 then
    return;
  end if;

  return query
    with slots as (
      select generate_series(
               p_date + v_doc.available_from,
               p_date + v_doc.available_to - make_interval(mins => v_doc.slot_minutes),
               make_interval(mins => v_doc.slot_minutes)
             ) as ts
    )
    select s.ts::time
      from slots s
     where s.ts > (now() at time zone 'Asia/Dhaka')
       and not exists (
             select 1
               from public.appointments a
              where a.doctor_id        = p_doctor_id
                and a.appointment_date = p_date
                and a.appointment_time = s.ts::time
                and a.status not in ('cancelled', 'expired')
           )
     order by 1;
end;
$$;

-- The grant is not inherited by CREATE OR REPLACE on a dropped-and-
-- recreated function, and re-granting is harmless, so state it.
grant execute on function public.available_slots(bigint, date) to anon, authenticated;
```

### Why `distinct` in the template branch

Two active windows on one weekday cannot overlap — the EXCLUDE constraint sees to
that — so in principle no time is generated twice. `distinct` is there for the
case the constraint cannot cover: two windows that *abut* (09:00–12:00 and
12:00–15:00) with different slot lengths still produce disjoint series, but a
future change to the generator's boundary handling would silently duplicate
12:00. The `distinct` costs a sort over a few dozen rows and removes an entire
class of "the same time appeared twice" bug reports.

### RLS and grants for the two new tables

Both tables are new, so they start with no RLS and — because
`20260806000000_reset_public.sql` sets permissive default privileges — with
grants that must be tightened explicitly.

```sql
-- ---------------------------------------------------------------------
-- RLS. A schedule is public information (patients must see when a
-- doctor works) but only the owning doctor or an admin may write it.
-- Per-command policies, never FOR ALL -- matching rls_policies.sql.
-- ---------------------------------------------------------------------
alter table public.doctor_schedules enable row level security;
alter table public.doctor_blackouts enable row level security;

create policy doctor_schedules_select_all
  on public.doctor_schedules for select to anon, authenticated
  using (true);

create policy doctor_schedules_insert_own
  on public.doctor_schedules for insert to authenticated
  with check (doctor_id = public.current_doctor_id());

create policy doctor_schedules_update_own
  on public.doctor_schedules for update to authenticated
  using      (doctor_id = public.current_doctor_id())
  with check (doctor_id = public.current_doctor_id());

create policy doctor_schedules_delete_own
  on public.doctor_schedules for delete to authenticated
  using (doctor_id = public.current_doctor_id());

create policy doctor_schedules_admin_all_select
  on public.doctor_schedules for select to authenticated
  using (public.is_admin());
create policy doctor_schedules_admin_update
  on public.doctor_schedules for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy doctor_schedules_admin_delete
  on public.doctor_schedules for delete to authenticated
  using (public.is_admin());

-- Blackouts: the DATES are public (a patient must see the doctor is
-- away) but the REASON is not -- "cardiac surgery, self" is medical
-- information about the doctor. Part 02 §3 specifies a view that omits
-- reason for non-owners; the table itself is owner/admin read only.
create policy doctor_blackouts_select_own
  on public.doctor_blackouts for select to authenticated
  using (doctor_id = public.current_doctor_id() or public.is_admin());

create policy doctor_blackouts_insert_own
  on public.doctor_blackouts for insert to authenticated
  with check (doctor_id = public.current_doctor_id());

create policy doctor_blackouts_delete_own
  on public.doctor_blackouts for delete to authenticated
  using (doctor_id = public.current_doctor_id() or public.is_admin());

grant select                         on public.doctor_schedules to anon, authenticated;
grant insert, update, delete         on public.doctor_schedules to authenticated;
grant select, insert, delete         on public.doctor_blackouts to authenticated;

-- updated_at maintenance, using the helper that already exists
-- (supabase/schema.sql:1234).
drop trigger if exists set_updated_at on public.doctor_schedules;
create trigger set_updated_at
  before update on public.doctor_schedules
  for each row execute function public.set_updated_at();
```

`available_slots()` is `security definer`, so it reads `doctor_blackouts` past
the owner-only SELECT policy. That is intentional and is the reason a patient can
see *that* a date is unavailable without ever seeing *why*.

---

### 6.3 `20260810000007_hospital_services.sql`

**Verified before specifying.** There is no services table. What exists is free
text:

| Column | Line | Type |
|---|---:|---|
| `hospitals.departments` | `supabase/schema.sql:400` | `text` |
| `hospitals.facilities` | `:399` | `text` |
| `clinics.services` | `:452` | `text` |
| `clinics.specializations` | `:453` | `text` |
| `pharmacies.services` | `:506` | `text` |

A comma-separated string cannot carry a price, a duration or a Bangla name, and
it cannot be searched or compared. The brief's item 3 — a patient choosing an MRI
by price — is not expressible against `text`. So this table is genuinely new.

The owner is modelled as an **XOR of two nullable FKs**, following the precedent
already in the schema at `provider_payouts` (`schema.sql:877`,
`provider_payouts_source_check`): a service belongs to a hospital or to a clinic,
never both and never neither. A polymorphic `(owner_type, owner_id)` pair was
rejected because it admits no foreign key, which is exactly why
`reviews.reviewable_id` needs `reviews_check_target()` (`schema.sql:1418`) to
validate by hand.

```sql
-- =====================================================================
-- 20260810000007_hospital_services.sql
--
-- Priced, bilingual diagnostic and clinical services offered by a
-- hospital or a clinic. Brief item 3: a patient compares an MRI across
-- providers by price, which is impossible against hospitals.departments
-- (a text column).
--
-- Structure only. The MRI/CT/X-ray list is a CHECK on `category`, NOT
-- seed rows -- master plan R1 permits no business-data INSERT, and one
-- provider's service catalogue is business data.
-- =====================================================================

create table if not exists public.hospital_services (
  id                    bigint generated always as identity primary key,
  hospital_id           bigint references public.hospitals (id) on delete cascade,
  clinic_id             bigint references public.clinics   (id) on delete cascade,
  name                  varchar(150) not null,
  name_bn               varchar(150),
  category              varchar(30)  not null default 'other',
  description           text,
  description_bn        text,
  price                 numeric(10,2) not null default 0.00,
  duration_minutes      integer,
  preparation_notes     text,
  preparation_notes_bn  text,
  prescription_required boolean not null default false,
  status                active_status not null default 'active',
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),

  -- Exactly one owner. Same shape as provider_payouts_source_check.
  constraint hospital_services_owner_check check (
    (hospital_id is not null and clinic_id is null)
    or (hospital_id is null and clinic_id is not null)),

  -- R10: money is numeric(10,2) and never negative. A free service is
  -- 0.00, which is different from NULL and renders as "Free".
  constraint hospital_services_price_check check (price >= 0),

  constraint hospital_services_duration_check
    check (duration_minutes is null or duration_minutes between 1 and 1440),

  -- A closed vocabulary, so the patient-side filter chips are a fixed
  -- list and a typo cannot create a category of one.
  constraint hospital_services_category_check check (category in (
    'imaging',      -- MRI, CT, X-ray, ultrasonography
    'pathology',    -- blood test, urine, biopsy
    'cardiology',   -- ECG, echocardiogram, stress test
    'consultation',
    'procedure',
    'therapy',
    'vaccination',
    'other'))
);

comment on table public.hospital_services is
  'Priced services offered by one hospital OR one clinic (XOR, see hospital_services_owner_check). Bilingual: *_bn columns are nullable and fall back to English.';
comment on column public.hospital_services.duration_minutes is
  'Appointment length for this service. NULL means "walk in, no fixed slot".';
comment on column public.hospital_services.category is
  'Closed vocabulary. Adding a value means editing hospital_services_category_check AND the Part 06 ARB keys for the filter chips.';
```

**Why `category` is a CHECK and not an enum.** Every other closed vocabulary in
this schema is an enum, so this is a deliberate exception. §2.1 explains that an
enum value can never safely be removed once RLS or an index references it; this
list is the one most likely to be edited by the user during development ("we need
'dental'"), and a CHECK can be replaced with two statements and no cascade risk.
The trade-off is that Postgres will not catch a typo at the type boundary — the
CHECK catches it at insert time instead, as `23514`.

### Indexes, and the query each one serves

```sql
-- Query: the provider's own catalogue --
--   select ... from hospital_services where hospital_id = $1
--    and status = 'active' order by category, name
create index if not exists idx_hospital_services_hospital
  on public.hospital_services (hospital_id, category, name)
  where hospital_id is not null and status = 'active';

create index if not exists idx_hospital_services_clinic
  on public.hospital_services (clinic_id, category, name)
  where clinic_id is not null and status = 'active';

-- Query: the brief's comparison screen -- "MRI, cheapest first" --
--   select ... from hospital_services
--    where category = $1 and status = 'active' order by price asc
create index if not exists idx_hospital_services_compare
  on public.hospital_services (category, price)
  where status = 'active';

-- Query: bilingual name search across both languages, one index.
-- 'simple' not 'english' for the same reason as 20260810000001: the
-- english stemmer mangles Bangla tokens.
create index if not exists idx_hospital_services_search
  on public.hospital_services
  using gin (to_tsvector('simple',
    coalesce(name, '') || ' ' || coalesce(name_bn, '')));
```

### RLS and grants

```sql
alter table public.hospital_services enable row level security;

-- A price list is public: that is the whole point of the feature.
create policy hospital_services_select_active
  on public.hospital_services for select to anon, authenticated
  using (status = 'active');

create policy hospital_services_select_owner
  on public.hospital_services for select to authenticated
  using (
    (hospital_id is not null and exists (
       select 1 from public.hospitals h
        where h.id = hospital_services.hospital_id
          and h.user_id = (select auth.uid())))
    or (clinic_id is not null and exists (
       select 1 from public.clinics c
        where c.id = hospital_services.clinic_id
          and c.user_id = (select auth.uid())))
    or public.is_admin());

create policy hospital_services_insert_owner
  on public.hospital_services for insert to authenticated
  with check (
    (hospital_id is not null and exists (
       select 1 from public.hospitals h
        where h.id = hospital_services.hospital_id
          and h.user_id = (select auth.uid())
          and h.verification_status = 'verified'))
    or (clinic_id is not null and exists (
       select 1 from public.clinics c
        where c.id = hospital_services.clinic_id
          and c.user_id = (select auth.uid())
          and c.verification_status = 'verified')));

create policy hospital_services_update_owner
  on public.hospital_services for update to authenticated
  using (
    (hospital_id is not null and exists (
       select 1 from public.hospitals h
        where h.id = hospital_services.hospital_id and h.user_id = (select auth.uid())))
    or (clinic_id is not null and exists (
       select 1 from public.clinics c
        where c.id = hospital_services.clinic_id and c.user_id = (select auth.uid())))
    or public.is_admin())
  with check (
    (hospital_id is not null and exists (
       select 1 from public.hospitals h
        where h.id = hospital_services.hospital_id and h.user_id = (select auth.uid())))
    or (clinic_id is not null and exists (
       select 1 from public.clinics c
        where c.id = hospital_services.clinic_id and c.user_id = (select auth.uid())))
    or public.is_admin());

create policy hospital_services_delete_owner
  on public.hospital_services for delete to authenticated
  using (
    (hospital_id is not null and exists (
       select 1 from public.hospitals h
        where h.id = hospital_services.hospital_id and h.user_id = (select auth.uid())))
    or (clinic_id is not null and exists (
       select 1 from public.clinics c
        where c.id = hospital_services.clinic_id and c.user_id = (select auth.uid())))
    or public.is_admin());

grant select                 on public.hospital_services to anon, authenticated;
grant insert, update, delete on public.hospital_services to authenticated;

drop trigger if exists set_updated_at on public.hospital_services;
create trigger set_updated_at
  before update on public.hospital_services
  for each row execute function public.set_updated_at();
```

The `verification_status = 'verified'` test on INSERT but not on UPDATE is
deliberate: an unverified provider must not be able to publish a price list, but
a provider whose verification is later revoked must still be able to correct or
deactivate the rows they already have.

---

### 6.4 `20260810000008_commission_rates.sql`

**Verified before specifying.** `grep -n "commission" supabase/schema.sql` shows
`commission_percentage numeric(5,2) not null default 2.00` on all four provider
tables (`doctors:330`, `hospitals:398`, `clinics:454`, `pharmacies`), and
`payments_apply_verification()` (`schema.sql:1731`) reads
`doctors.commission_percentage` at verification time. There is **no settings
table of any kind** — `grep -ni "app_settings\|platform_settings" supabase/`
returns nothing.

So the per-provider rate exists and works. What is missing is what the brief asks
for: **an admin setting a default percentage per category**, rather than editing
every provider row by hand.

The design keeps the existing mechanism intact. `commission_rates` supplies the
**default** used when a provider row is created; the per-provider
`commission_percentage` continues to be the value actually charged, and continues
to be frozen onto the payment at verification time by the untouched
`payments_apply_verification()`.

That layering is the whole point. If the payment path read the rates table
directly, changing a rate would retroactively change what every historical
provider is owed. Freezing at verification is already correct (R10) and this
migration must not disturb it.

```sql
-- =====================================================================
-- 20260810000008_commission_rates.sql
--
-- Admin-managed DEFAULT commission per provider category.
--
-- This does NOT change how a payment is split. providers still carry
-- commission_percentage, payments_apply_verification() still reads it at
-- verification time and freezes admin_share/provider_share onto the row
-- (master plan R10). This table only supplies the default a NEW provider
-- row starts with, and gives the admin console one place to manage it.
--
-- Structure only. The four category rows are NOT inserted here (R1);
-- resolve_commission_rate() falls back to 2.00 -- the same value the
-- provider tables already default to -- when a category has no row.
-- =====================================================================

create table if not exists public.commission_rates (
  category   varchar(20) primary key,
  percentage numeric(5,2) not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.users (id) on delete set null,
  constraint commission_rates_category_check
    check (category in ('doctor', 'hospital', 'clinic', 'pharmacy')),
  constraint commission_rates_percentage_check
    check (percentage >= 0 and percentage <= 100)
);

comment on table public.commission_rates is
  'Default platform commission per provider category, set by an admin. Applied to NEW provider rows only; an existing provider keeps the percentage frozen on its own row. Never read by the payment split -- see payments_apply_verification (schema.sql:1731).';

-- Natural PK on category: there is exactly one live rate per category,
-- and a surrogate id would permit two rows for 'doctor' with no way to
-- say which is current.
```

```sql
-- ---------------------------------------------------------------------
-- The resolver. STABLE and SECURITY DEFINER so a self-registering
-- provider (who has no SELECT grant on commission_rates while anon) can
-- still have their row stamped.
--
-- The 2.00 fallback is not a magic number: it is the identical default
-- already declared on all four provider tables, so a database with an
-- empty commission_rates behaves exactly as it does today.
-- ---------------------------------------------------------------------
create or replace function public.resolve_commission_rate(p_category text)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select r.percentage from public.commission_rates r
      where r.category = p_category),
    2.00);
$$;

grant execute on function public.resolve_commission_rate(text) to authenticated;

-- ---------------------------------------------------------------------
-- Stamp the category default onto a newly created provider row.
--
-- BEFORE INSERT, and only for untrusted (client) writes: an admin
-- creating a provider with a negotiated rate must be able to set it
-- directly. write_is_trusted() is the repo's own discriminator
-- (20260809000002_payment_architecture_fix.sql:154) -- do NOT reinvent
-- it with current_user or session_user, both of which are wrong here.
-- See section 6.4 note below and Part 12 #14.
-- ---------------------------------------------------------------------
create or replace function public.stamp_default_commission()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.write_is_trusted() then
    return new;
  end if;
  new.commission_percentage := public.resolve_commission_rate(tg_argv[0]);
  return new;
end;
$$;

comment on function public.stamp_default_commission() is
  'BEFORE INSERT on a provider table. Overwrites a client-supplied commission_percentage with the category default from commission_rates, so a provider cannot self-register at 0%.';

-- ab_ prefix: after aa_guard_* (which must see what the client actually
-- submitted) and before zz_* checks. Same ordering discipline as
-- rls_policies.sql:148.
drop trigger if exists ab_stamp_commission on public.doctors;
create trigger ab_stamp_commission
  before insert on public.doctors
  for each row execute function public.stamp_default_commission('doctor');

drop trigger if exists ab_stamp_commission on public.hospitals;
create trigger ab_stamp_commission
  before insert on public.hospitals
  for each row execute function public.stamp_default_commission('hospital');

drop trigger if exists ab_stamp_commission on public.clinics;
create trigger ab_stamp_commission
  before insert on public.clinics
  for each row execute function public.stamp_default_commission('clinic');

drop trigger if exists ab_stamp_commission on public.pharmacies;
create trigger ab_stamp_commission
  before insert on public.pharmacies
  for each row execute function public.stamp_default_commission('pharmacy');

-- ---------------------------------------------------------------------
-- RLS. Read by any signed-in user (a provider is entitled to know the
-- platform's cut); written by admins only.
-- ---------------------------------------------------------------------
alter table public.commission_rates enable row level security;

create policy commission_rates_select_authenticated
  on public.commission_rates for select to authenticated
  using (true);

create policy commission_rates_insert_admin
  on public.commission_rates for insert to authenticated
  with check (public.is_admin());

create policy commission_rates_update_admin
  on public.commission_rates for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy commission_rates_delete_admin
  on public.commission_rates for delete to authenticated
  using (public.is_admin());

grant select                 on public.commission_rates to authenticated;
grant insert, update, delete on public.commission_rates to authenticated;

-- No index beyond the primary key. The table holds at most four rows;
-- any index on it would never be chosen over a sequential scan.
```

### The one trap in this migration

`stamp_default_commission()` **must** use `public.write_is_trusted()`. Two older,
broken discriminators are still visible in the repository's history and an agent
copying the nearest example will pick up the wrong one:

| Test | Where it appears | Why it is wrong |
|---|---|---|
| `current_user not in ('authenticated','anon')` | `supabase/migrations/20260806000001_schema.sql:1896` and five more | Inside a `SECURITY DEFINER` function `current_user` is the owner (`postgres`), so the test is always true and the guard never fires. Fixed by `20260806000004_guard_session_user_fix.sql`. |
| `session_user <> 'authenticator'` | `supabase/schema.sql:2197`, `rls_policies.sql:119` | PostgREST always connects as `authenticator`, including for `service_role`, so trusted server paths are treated as client traffic. Fixed by `20260809000002_payment_architecture_fix.sql:154`. |
| `public.write_is_trusted()` | `20260809000002_payment_architecture_fix.sql:154` | **Correct.** Checks the transaction-local trusted-path marker, then `session_user`, then `is_admin()`. |

`supabase/schema.sql` is a *snapshot that predates the last fix* and still shows
`session_user <> 'authenticator'` in every guard. The migration is authoritative.
This is expanded in Part 12 §14.

---

## 7. Verification

Nothing in this part is complete until these return the expected result. Run them
in the Supabase SQL editor against the live project, in this order.

### 7.1 One query per migration

```sql
-- 20260810000001 -- bilingual columns (expect 16)
select count(*) as bilingual_columns
  from information_schema.columns
 where table_schema = 'public'
   and column_name like '%\_bn'
   and table_name in ('blogs','emergency_hotlines','pharmacy_products',
                      'doctors','hospitals','clinics','pharmacies');

-- 20260810000002 -- language column + its CHECK (expect one row, 'en')
select column_name, data_type, column_default, is_nullable
  from information_schema.columns
 where table_schema = 'public' and table_name = 'users'
   and column_name = 'preferred_language';

-- expect exactly one row
select conname from pg_constraint
 where conrelid = 'public.users'::regclass
   and conname = 'users_preferred_language_check';

-- 20260810000003 -- the double-booking guard survived (expect 1 row)
select indexname, indexdef from pg_indexes
 where schemaname = 'public'
   and indexname = 'uq_appointments_doctor_slot';

-- and the friendly-message trigger exists (expect 1 row)
select tgname from pg_trigger
 where tgrelid = 'public.appointments'::regclass
   and tgname = 'zz_slot_taken_message';

-- 20260810000004 -- two new notification triggers (expect 2 rows)
select tgname, tgrelid::regclass::text as on_table
  from pg_trigger
 where tgname in ('orders_status_notify', 'blood_requests_notify_donors')
 order by 1;

-- 20260810000005 -- phone verification interface (expect 2 rows)
select column_name from information_schema.columns
 where table_schema = 'public' and table_name = 'users'
   and column_name in ('phone_verified', 'phone_verified_at')
 order by 1;

-- 20260810000006 -- slot model (expect 2 rows)
select table_name from information_schema.tables
 where table_schema = 'public'
   and table_name in ('doctor_schedules', 'doctor_blackouts')
 order by 1;

-- the overlap constraint is the one most likely to have failed to build
-- (it needs btree_gist). Expect one row, contype = 'x'.
select conname, contype from pg_constraint
 where conrelid = 'public.doctor_schedules'::regclass
   and conname = 'doctor_schedules_no_overlap';

-- 20260810000007 -- services table (expect 1 row)
select table_name from information_schema.tables
 where table_schema = 'public' and table_name = 'hospital_services';

-- 20260810000008 -- rates table and its four stamp triggers (expect 4)
select tgrelid::regclass::text as on_table
  from pg_trigger where tgname = 'ab_stamp_commission'
 order by 1;
```

### 7.2 Behavioural checks, not just structural ones

A column existing is not the same as a rule working. These four prove behaviour.

```sql
-- The slot generator still answers. Substitute a real doctor id.
-- Expect: rows for a working day, zero rows for a blacked-out day.
select * from public.available_slots(1, current_date + 1);

-- The overlap constraint actually refuses. Expect 23514 then 23P01.
-- Run inside a transaction and roll back -- R1 permits no data.
begin;
  insert into public.doctor_schedules (doctor_id, weekday, starts_at, ends_at)
  values (1, 6, '13:00', '09:00');          -- expect 23514 window_check
rollback;

begin;
  insert into public.doctor_schedules (doctor_id, weekday, starts_at, ends_at)
  values (1, 6, '09:00', '13:00');
  insert into public.doctor_schedules (doctor_id, weekday, starts_at, ends_at)
  values (1, 6, '12:00', '15:00');          -- expect 23P01 exclusion_violation
rollback;

-- The service XOR refuses a two-owner row. Expect 23514.
begin;
  insert into public.hospital_services (hospital_id, clinic_id, name, price)
  values (1, 1, 'MRI Brain', 8500.00);
rollback;

-- The commission stamp fires for client traffic. Run as an authenticated
-- non-admin from the app, inserting a doctors row with
-- commission_percentage = 0: expect the stored value to be the category
-- default, not 0.
select id, commission_percentage from public.doctors
 where user_id = auth.uid();
```

### 7.3 The R1 audit — zero business-data INSERTs

The master plan's definition-of-done item 11 is "zero INSERT statements for
business data in `supabase/`". The naive grep does **not** answer that question,
and reporting its raw number as a pass or a failure is wrong either way:

```bash
cd "F:/Project folder/AyurBD"
grep -ci "insert into" supabase/*.sql
```

This returns a non-zero count for `schema.sql`, `rls_policies.sql` and several
migrations, and **that is correct**. Those matches are `insert into` **inside
trigger and function bodies** — `notify()` writing a notification,
`payments_apply_verification()` minting a payout, `place_order()` creating an
order, `audit_row_change()` writing the audit log. They are the mechanism, not
seed data. Deleting them would break the application.

The check that actually answers item 11 is: **top-level INSERT statements**, i.e.
those at column 1, outside any `$$ ... $$` body.

```bash
cd "F:/Project folder/AyurBD"

# Top-level INSERTs only: an insert at the start of a line, not indented
# inside a function body. Expect ONLY the emergency_hotlines block from
# section 5 and the reference row it targets.
grep -rniE "^insert into" supabase/*.sql supabase/migrations/*.sql

# Same question, asked the other way: which tables are inserted into at
# top level? Expect exactly one -- emergency_hotlines.
grep -rhoiE "^insert into[[:space:]]+(public\.)?[a-z_]+" \
  supabase/*.sql supabase/migrations/*.sql \
  | sed -E 's/^[Ii][Nn][Ss][Ee][Rr][Tt][[:space:]]+[Ii][Nn][Tt][Oo][[:space:]]+(public\.)?//' \
  | sort -u

# Every permitted INSERT must be idempotent. Expect one `on conflict`
# for every top-level insert found above.
grep -rniE "^insert into" -A 40 supabase/migrations/20260810000001_*.sql \
  | grep -ci "on conflict"

# And the raw count, recorded in IMPLEMENTATION_LOG.md for the record --
# report the number AND this explanation, never the number alone.
grep -ci "insert into" supabase/*.sql
```

If the table list from the second command contains anything other than
`emergency_hotlines`, R1 has been violated. Stop, name the file and line in
`IMPLEMENTATION_LOG.md`, and remove the rows.

### 7.4 What to write in `IMPLEMENTATION_LOG.md`

R8 requires an honest record. Append a Phase 1 entry covering, at minimum:

- Which of the eight migrations were **applied to the live project** and which
  were only written to disk. These are different claims and only one of them is
  usually true in a session without database credentials.
- The result of every query in §6.1, as a number, not as "verified".
- Whether `users_phone_format_check` was added valid or `NOT VALID`, and if
  `NOT VALID`, how many existing rows fail it.
- Whether `btree_gist` was available. If `create extension` failed, then
  `doctor_schedules_no_overlap` does not exist and overlapping windows are
  possible — say so plainly rather than letting Part 09 assume the guard is there.
- That `flutter analyze` and `flutter build` were **not** run in this phase, since
  Part 01 changes no Dart beyond the three deletions in §4. State it explicitly;
  master plan §1 records that they have never been run in this repository.
- The `stub_dashboard_screen.dart` deletion is deferred to Part 09 (§4.3).







