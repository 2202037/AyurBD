-- =====================================================================
-- AYUR — schema.sql
-- PostgreSQL / Supabase structure converted from ayur_db (MariaDB 10.4).
-- =====================================================================
--
-- STRUCTURE ONLY. This file contains no INSERT statement and no data of
-- any kind. Every table is empty after it runs.
--
-- Run order:
--     1. schema.sql        (this file)
--     2. rls_policies.sql
--     3. storage_setup.sql
--
-- Run it in the Supabase SQL Editor, or `supabase db push`. It is
-- idempotent: re-running drops and recreates its own objects only, and
-- never touches auth.* or storage.* tables beyond adding policies.
--
-- ---------------------------------------------------------------------
-- CONVERSION DECISIONS — the non-obvious ones, so review is possible.
--
-- 1. users.id is uuid and REFERENCES auth.users(id) ON DELETE CASCADE.
--    Supabase Auth owns identity; public.users is the profile mirror.
--    Every FK that pointed at users.id is therefore uuid too:
--        appointments.patient_id      blogs.author_id
--        doctors.user_id              blood_donors.user_id
--        hospitals.user_id            cart.user_id
--        clinics.user_id              orders.user_id
--        pharmacies.user_id           notifications.user_id
--        payments.user_id             device_tokens.user_id
--        payments.verified_by         feedback.user_id
--        reviews.user_id              app_audit_log.user_id
--        appointments.payment_verified_by
--    All other primary keys stay integer (bigint identity), so
--    doctors.id, products.id and appointments.id keep the int contract
--    the Flutter models and route helpers already expect.
--
-- 2. users.password is GONE. Password hashes live in auth.users,
--    managed by Supabase. Keeping a second hash column would be a
--    liability, not a migration. This is the one intentional column
--    removal in the whole file.
--
-- 3. MySQL enums become native PostgreSQL enum types. Two notes:
--      * MySQL silently accepts '' for an enum it cannot parse (the
--        live data has appointments.type = ''). Postgres rejects it.
--        Where the dump showed that, the column is nullable and the
--        app must send NULL rather than ''.
--      * payment_method values contain '/' ('Credit/Debit Card'). That
--        is legal in a Postgres enum label and is preserved verbatim so
--        the Dart strings need no remapping.
--
-- 4. MySQL `year(4)` has no Postgres equivalent. Converted to smallint
--    with a sane range CHECK (1800..current year + 1).
--
-- 5. `tinyint(1)` becomes boolean. Dart already treats these as bool.
--
-- 6. ON UPDATE current_timestamp() does not exist in Postgres. Replaced
--    by the set_updated_at() trigger, attached to every table that had
--    the MySQL clause.
--
-- 7. The 36 MySQL audit triggers are reproduced as ONE generic
--    plpgsql function (audit_row_change) attached per table, instead of
--    36 hand-written bodies. Same rows land in audit_log; to_jsonb
--    replaces JSON_OBJECT and is complete rather than a field subset.
--
-- 8. Logic that lived in PHP and would otherwise be LOST is now in the
--    database, because the PHP layer is being deleted:
--      * rating / total_reviews recalculation  (was admin.php,
--        content.php) -> recalc_reviewable_rating() trigger on reviews.
--      * confirmation_code generation (was provider.php) ->
--        generate_confirmation_code(), same 32-char ambiguity-free
--        alphabet, same length 8.
--      * order_number 'AYU-000123' (was pharmacy.php, via a second
--        UPDATE after insert) -> orders_set_order_number() BEFORE
--        INSERT trigger, which removes the temp-value write entirely.
--
-- 9. audit_log.old_values / new_values were longtext + json_valid()
--    CHECK. They become native jsonb, which is a strict superset of
--    that guarantee.
--
-- 10. 23 tables, not 21. The base dump has 21; emergency_hotlines and
--     emergency_sms come from migration_v2.sql PARTS 4-5. Both are live
--     routes (index.php:135-136) with a Flutter screen behind them, so
--     they are part of the structure even though the dump predates them.
--     Their seed rows are NOT reproduced -- structure only.
--
-- 11. Notifications become trigger-driven (PART 3.4). The PHP inserted
--     notification rows for OTHER users from seven endpoints -- a doctor
--     notifying a patient, an admin notifying a provider. From a client
--     under RLS that is indistinguishable from forging a notification for
--     someone else, so `authenticated` has no INSERT on the table at all.
--     SECURITY DEFINER triggers fire on the state change instead. Same
--     wording, same rows, no client trust required.
--
-- 12. Two more pieces of PHP-only logic moved into triggers for the same
--     reason -- the client must not be trusted with either:
--       * appointments.payment_status -> 'paid' now happens only inside
--         payments_apply_verification (was provider.php:468, enforced by
--         a README rule the client could ignore).
--       * a cancelled paid appointment -> 'refunded'
--         (was appointments.php:603).
-- =====================================================================

-- pgcrypto supplies gen_random_bytes() for generate_confirmation_code().
-- On Supabase it lives in the `extensions` schema and is already
-- enabled; this is a no-op safety net for local/self-hosted runs.
create extension if not exists pgcrypto with schema extensions;

-- =====================================================================
-- PART 0 — ENUM TYPES
-- =====================================================================

drop type if exists user_role cascade;
create type user_role as enum
  ('patient', 'doctor', 'hospital', 'clinic', 'pharmacy', 'admin');

drop type if exists gender_type cascade;
create type gender_type as enum ('male', 'female', 'other');

drop type if exists blood_group cascade;
create type blood_group as enum
  ('A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-');

drop type if exists verification_status cascade;
create type verification_status as enum ('pending', 'verified', 'rejected');

-- doctors / hospitals / clinics / pharmacies lifecycle.
drop type if exists provider_status cascade;
create type provider_status as enum ('pending', 'active', 'inactive');

-- blood_banks and pharmacy_products use a two-value status; kept as its
-- own type rather than reusing provider_status so 'pending' cannot be
-- written to a column that never allowed it.
drop type if exists active_status cascade;
create type active_status as enum ('active', 'inactive');

drop type if exists doctor_type cascade;
create type doctor_type as enum ('general', 'specialist', 'consultant');

drop type if exists clinic_type cascade;
create type clinic_type as enum
  ('general', 'dental', 'eye', 'diagnostic', 'specialized', 'polyclinic');

drop type if exists hospital_type cascade;
create type hospital_type as enum
  ('private', 'government', 'specialized', 'teaching');

drop type if exists pharmacy_type cascade;
create type pharmacy_type as enum ('retail', 'wholesale', 'hospital', 'chain');

drop type if exists appointment_type cascade;
create type appointment_type as enum ('new', 'followup', 'online');

drop type if exists appointment_status cascade;
create type appointment_status as enum
  ('pending', 'confirmed', 'completed', 'cancelled', 'expired');

-- appointments.payment_status and orders.payment_status.
drop type if exists payment_state cascade;
create type payment_state as enum ('pending', 'paid', 'refunded');

-- payments.payment_status — a different set from payment_state.
drop type if exists payment_verification_status cascade;
create type payment_verification_status as enum
  ('pending', 'verified', 'rejected');

drop type if exists payment_method cascade;
create type payment_method as enum
  ('bKash', 'Nagad', 'Rocket', 'Credit/Debit Card', 'Bank Transfer', 'Cash', 'sslcommerz');

drop type if exists order_status cascade;
create type order_status as enum
  ('pending', 'confirmed', 'processing', 'shipped', 'delivered', 'cancelled');

drop type if exists blood_request_status cascade;
create type blood_request_status as enum ('active', 'fulfilled', 'cancelled');

drop type if exists reviewable_type cascade;
create type reviewable_type as enum
  ('doctor', 'hospital', 'clinic', 'pharmacy');

drop type if exists review_status cascade;
create type review_status as enum ('pending', 'approved', 'rejected');

drop type if exists feedback_type cascade;
create type feedback_type as enum
  ('general', 'suggestion', 'complaint', 'bug_report', 'doctor_issue',
   'hospital_issue', 'appointment_issue', 'payment_issue', 'appreciation');

drop type if exists feedback_status cascade;
create type feedback_status as enum
  ('new', 'in_progress', 'resolved', 'closed');

drop type if exists feedback_priority cascade;
-- Matches MySQL exactly: low | normal | high | urgent.
--
-- NOTE for the Dart batch: the admin UI sends 'medium', not 'normal'
-- (admin_feedback_screen.dart line 39, admin_repository.dart line 228).
-- 'medium' is deliberately NOT added as a fourth spelling of the same
-- level -- two names for one priority would make
-- `if (f.priority != 'low' && f.priority != 'medium')` on line 228 render
-- a badge for 'normal' but not for 'medium'. Instead the admin repository
-- maps medium <-> normal at the boundary, so the DB keeps one value per
-- level and the UI is unchanged.
create type feedback_priority as enum ('low', 'normal', 'high', 'urgent');

drop type if exists blog_status cascade;
-- 'archived' is NOT in the MySQL enum, which is enum('draft','published').
-- It is added here deliberately: admin_blogs_screen.dart offers an
-- "Archived" option in its status dropdown (lines 28 and 358), and
-- admin_repository.dart documents the parameter as
-- "draft | published | archived". Against MySQL that write is rejected, so
-- the button is dead. migration_v2.sql tried to introduce it via
-- ADD COLUMN IF NOT EXISTS `status` enum('draft','published','archived'),
-- but `status` already existed, so the clause was a silent no-op.
-- Including the value here makes an existing UI control work instead of
-- erroring, without touching the UI.
create type blog_status as enum ('draft', 'published', 'archived');

drop type if exists device_platform cascade;
create type device_platform as enum ('android', 'ios', 'web');

drop type if exists sms_status cascade;
create type sms_status as enum ('queued', 'sent', 'failed');

drop type if exists audit_action cascade;
create type audit_action as enum ('INSERT', 'UPDATE', 'DELETE');

-- =====================================================================
-- PART 1 — TABLES
-- =====================================================================

-- ---------------------------------------------------------------------
-- users — profile mirror of auth.users.
--
-- No `password` column: see conversion note 2.
-- id is NOT generated. It must equal auth.users.id, which the
-- handle_new_user() trigger below takes care of on signup.
-- ---------------------------------------------------------------------
create table public.users (
  id            uuid        primary key references auth.users (id) on delete cascade,
  name          varchar(100) not null,
  email         varchar(100) not null,
  phone         varchar(20),
  gender        gender_type,
  address       text,
  profile_image varchar(255),
  role          user_role   default 'patient',
  city          varchar(100),
  blood_group   blood_group,
  is_active     boolean     not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint users_email_key unique (email)
);

comment on table  public.users is 'Profile data for auth.users. Passwords live in auth.users.';
comment on column public.users.profile_image is 'Object path inside the `avatars` storage bucket.';
comment on column public.users.is_active is 'Ban flag. Admins set this false to suspend an account; the ban trigger cancels the user''s future appointments.';

create index idx_users_email on public.users (email);
create index idx_users_role  on public.users (role);
create index idx_users_city  on public.users (city);
create index idx_users_is_active on public.users (is_active);

-- ---------------------------------------------------------------------
-- doctors
-- ---------------------------------------------------------------------
create table public.doctors (
  id                       bigint generated always as identity primary key,
  user_id                  uuid    not null references public.users (id) on delete cascade,
  bmdc_registration_number varchar(50),
  bmdc_certificate         varchar(255),
  specialization           varchar(100),
  qualifications           varchar(255),
  medical_school           varchar(255),
  graduation_year          smallint,
  experience_years         integer default 0,
  doctor_type              doctor_type default 'general',
  hospital_clinic_name     varchar(255),
  chamber_address          text,
  city                     varchar(50),
  area                     varchar(100),
  consultation_fee         numeric(10,2) default 0.00,
  bio                      text,
  rating                   numeric(3,2) default 0.00,
  total_reviews            integer default 0,
  verification_status      verification_status default 'pending',
  status                   provider_status default 'pending',
  rejection_reason         text,
  -- from migration_v1: the slot generator needs these.
  available_days           varchar(100),
  available_from           time,
  available_to             time,
  slot_minutes             integer default 30,
  is_deleted               boolean not null default false,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  constraint doctors_user_id_key unique (user_id),
  constraint doctors_graduation_year_check
    check (graduation_year is null
           or graduation_year between 1800 and extract(year from now())::int + 1),
  constraint doctors_experience_years_check check (experience_years >= 0),
  constraint doctors_consultation_fee_check check (consultation_fee >= 0),
  constraint doctors_rating_check check (rating >= 0 and rating <= 5),
  constraint doctors_total_reviews_check check (total_reviews >= 0),
  constraint doctors_slot_minutes_check
    check (slot_minutes is null or slot_minutes between 5 and 240),
  -- A chamber window must not end before it starts.
  constraint doctors_available_window_check
    check (available_from is null or available_to is null
           or available_to > available_from)
);

comment on column public.doctors.available_days is 'csv of lowercase day names: sat,sun,mon,tue,wed,thu,fri. NULL = not configured.';
comment on column public.doctors.bmdc_certificate is 'Object path inside the `provider-documents` storage bucket (private).';
comment on column public.doctors.rejection_reason is 'Set by an admin when verification_status becomes rejected; surfaced in the rejection notification.';
comment on column public.doctors.is_deleted is 'Soft delete. True hides the doctor from the directory and blocks new bookings without destroying appointment/payment history.';

create index idx_doctors_specialization on public.doctors (specialization);
create index idx_doctors_city           on public.doctors (city);
create index idx_doctors_status         on public.doctors (status);
create index idx_doctors_verification   on public.doctors (verification_status);
create index idx_doctors_is_deleted     on public.doctors (is_deleted);
-- The directory list is always "active + verified, best rated first".
-- One composite index serves the default query and its ordering.
create index idx_doctors_directory
  on public.doctors (status, verification_status, rating desc, total_reviews desc);

-- ---------------------------------------------------------------------
-- hospitals
-- ---------------------------------------------------------------------
create table public.hospitals (
  id                  bigint generated always as identity primary key,
  user_id             uuid    not null references public.users (id) on delete cascade,
  name                varchar(255) not null,
  registration_number varchar(100),
  license_number      varchar(100),
  license_document    varchar(255),
  email               varchar(100),
  phone               varchar(20),
  emergency_phone     varchar(20),
  website             varchar(255),
  address             text    not null,
  city                varchar(50) not null,
  area                varchar(100),
  hospital_type       hospital_type default 'private',
  established_year    smallint,
  total_beds          integer default 0,
  icu_beds            integer default 0,
  facilities          text,
  departments         text,
  open_24_hours       boolean default false,
  opening_time        time,
  closing_time        time,
  description         text,
  rating              numeric(3,2) default 0.00,
  total_reviews       integer default 0,
  verification_status verification_status default 'pending',
  status              provider_status default 'pending',
  rejection_reason    text,
  is_deleted          boolean not null default false,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint hospitals_user_id_key unique (user_id),
  constraint hospitals_established_year_check
    check (established_year is null
           or established_year between 1800 and extract(year from now())::int + 1),
  constraint hospitals_total_beds_check check (total_beds >= 0),
  constraint hospitals_icu_beds_check   check (icu_beds >= 0),
  constraint hospitals_icu_lte_total_check check (icu_beds <= total_beds),
  constraint hospitals_rating_check check (rating >= 0 and rating <= 5),
  constraint hospitals_total_reviews_check check (total_reviews >= 0)
);

comment on column public.hospitals.license_document is 'Object path inside the `provider-documents` storage bucket (private).';

create index idx_hospitals_city          on public.hospitals (city);
create index idx_hospitals_hospital_type on public.hospitals (hospital_type);
create index idx_hospitals_status        on public.hospitals (status);
create index idx_hospitals_directory
  on public.hospitals (status, verification_status, rating desc, total_reviews desc);
create index idx_hospitals_is_deleted    on public.hospitals (is_deleted);

-- ---------------------------------------------------------------------
-- clinics
-- ---------------------------------------------------------------------
create table public.clinics (
  id                  bigint generated always as identity primary key,
  user_id             uuid    not null references public.users (id) on delete cascade,
  name                varchar(255) not null,
  registration_number varchar(100),
  license_number      varchar(100),
  license_document    varchar(255),
  email               varchar(100),
  phone               varchar(20),
  website             varchar(255),
  address             text    not null,
  city                varchar(50) not null,
  area                varchar(100),
  clinic_type         clinic_type default 'general',
  established_year    smallint,
  services            text,
  specializations     text,
  available_days      varchar(100),
  opening_time        time,
  closing_time        time,
  description         text,
  rating              numeric(3,2) default 0.00,
  total_reviews       integer default 0,
  verification_status verification_status default 'pending',
  status              provider_status default 'pending',
  rejection_reason    text,
  is_deleted          boolean not null default false,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint clinics_user_id_key unique (user_id),
  constraint clinics_established_year_check
    check (established_year is null
           or established_year between 1800 and extract(year from now())::int + 1),
  constraint clinics_rating_check check (rating >= 0 and rating <= 5),
  constraint clinics_total_reviews_check check (total_reviews >= 0)
);

comment on column public.clinics.license_document is 'Object path inside the `provider-documents` storage bucket (private).';

create index idx_clinics_city        on public.clinics (city);
create index idx_clinics_clinic_type on public.clinics (clinic_type);
create index idx_clinics_status      on public.clinics (status);
create index idx_clinics_directory
  on public.clinics (status, verification_status, rating desc, total_reviews desc);
create index idx_clinics_is_deleted  on public.clinics (is_deleted);

-- ---------------------------------------------------------------------
-- pharmacies
-- ---------------------------------------------------------------------
create table public.pharmacies (
  id                  bigint generated always as identity primary key,
  user_id             uuid    not null references public.users (id) on delete cascade,
  name                varchar(255) not null,
  license_number      varchar(100) not null,
  drug_license_number varchar(100),
  license_document    varchar(255),
  owner_name          varchar(100),
  pharmacist_name     varchar(100),
  pharmacist_license  varchar(100),
  email               varchar(100),
  phone               varchar(20),
  whatsapp            varchar(20),
  address             text    not null,
  city                varchar(50) not null,
  area                varchar(100),
  pharmacy_type       pharmacy_type default 'retail',
  established_year    smallint,
  services            text,
  delivery_available  boolean default false,
  delivery_radius_km  integer default 0,
  open_24_hours       boolean default false,
  opening_time        time,
  closing_time        time,
  description         text,
  rating              numeric(3,2) default 0.00,
  total_reviews       integer default 0,
  verification_status verification_status default 'pending',
  status              provider_status default 'pending',
  rejection_reason    text,
  is_deleted          boolean not null default false,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint pharmacies_user_id_key unique (user_id),
  constraint pharmacies_established_year_check
    check (established_year is null
           or established_year between 1800 and extract(year from now())::int + 1),
  constraint pharmacies_delivery_radius_check check (delivery_radius_km >= 0),
  constraint pharmacies_rating_check check (rating >= 0 and rating <= 5),
  constraint pharmacies_total_reviews_check check (total_reviews >= 0)
);

comment on column public.pharmacies.license_document is 'Object path inside the `provider-documents` storage bucket (private).';

create index idx_pharmacies_city          on public.pharmacies (city);
create index idx_pharmacies_pharmacy_type on public.pharmacies (pharmacy_type);
create index idx_pharmacies_status        on public.pharmacies (status);
create index idx_pharmacies_directory
  on public.pharmacies (status, verification_status, rating desc, total_reviews desc);
create index idx_pharmacies_is_deleted    on public.pharmacies (is_deleted);

-- ---------------------------------------------------------------------
-- appointments
--
-- `type` is nullable: the live data contains '' for it, which no
-- Postgres enum can hold. The app sends NULL where it used to send ''.
-- ---------------------------------------------------------------------
create table public.appointments (
  id                  bigint generated always as identity primary key,
  patient_id          uuid    not null references public.users (id) on delete cascade,
  -- RESTRICT, not CASCADE: an appointment is a financial and clinical
  -- record, and a doctor is soft-deleted (is_deleted) rather than removed.
  doctor_id           bigint  not null references public.doctors (id) on delete restrict,
  doctor_name         varchar(255),
  appointment_date    date    not null,
  appointment_time    time    not null,
  type                appointment_type default 'new',
  symptoms            text,
  notes               text,
  fee                 numeric(10,2) default 0.00,
  status              appointment_status default 'pending',
  payment_status      payment_state default 'pending',
  payment_verified_at timestamptz,
  payment_verified_by uuid references public.users (id) on delete set null,
  confirmation_code   varchar(12),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint appointments_confirmation_code_key unique (confirmation_code),
  constraint appointments_fee_check check (fee >= 0)
);

comment on column public.appointments.doctor_name is 'Snapshot of the doctor''s name at booking time, so history survives a soft delete or rename.';

create index idx_appointments_patient on public.appointments (patient_id);
create index idx_appointments_doctor  on public.appointments (doctor_id);
create index idx_appointments_date    on public.appointments (appointment_date);
create index idx_appointments_status  on public.appointments (status);
create index idx_appointments_confirmation_code
  on public.appointments (confirmation_code);
-- "my appointments, newest first" and the doctor's day list.
create index idx_appointments_patient_date
  on public.appointments (patient_id, appointment_date desc);
create index idx_appointments_doctor_date
  on public.appointments (doctor_id, appointment_date desc);

-- Double-booking guard the PHP layer never had: one doctor cannot hold
-- two live appointments in the same slot. Cancelled and expired ones are
-- excluded so a freed slot can be rebooked.
create unique index uq_appointments_doctor_slot
  on public.appointments (doctor_id, appointment_date, appointment_time)
  where status not in ('cancelled', 'expired');

-- ---------------------------------------------------------------------
-- payments
-- ---------------------------------------------------------------------
create table public.payments (
  id               bigint generated always as identity primary key,
  appointment_id   bigint  not null references public.appointments (id) on delete cascade,
  user_id          uuid    not null references public.users (id) on delete cascade,
  amount           numeric(10,2) not null,
  payment_method   payment_method not null,
  transaction_id   varchar(100),
  sender_number    varchar(20),
  payment_status   payment_verification_status default 'pending',
  verified_by      uuid references public.users (id) on delete set null,
  verified_at      timestamptz,
  rejection_reason text,
  notes            text,
  -- SSLCommerz fields. gateway identifies the online flow (NULL = manual
  -- bank transfer / mobile banking); gateway_transaction_id is the
  -- gateway's own transaction id, which the validate step checks against
  -- the gateway API before the payment is accepted.
  gateway                varchar(30),
  gateway_transaction_id varchar(100),
  refunded_at            timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint payments_amount_check check (amount >= 0)
  -- Deliberately NOT constrained: "rejected implies rejection_reason is
  -- not null". The PHP allowed a reason-less rejection, so enforcing it
  -- here would turn a working action into a runtime error.
);

-- Idempotency backstop for the gateway: one gateway transaction can be
-- recorded once, no matter how many times the success callback fires.
create unique index uq_payments_gateway_txn
  on public.payments (gateway_transaction_id)
  where gateway_transaction_id is not null;

create index idx_payments_appointment on public.payments (appointment_id);
create index idx_payments_user        on public.payments (user_id);
create index idx_payments_transaction on public.payments (transaction_id);
create index idx_payments_status      on public.payments (payment_status);
create index idx_payments_verified_by on public.payments (verified_by);

-- ---------------------------------------------------------------------
-- payment_sessions — one SSLCommerz attempt per appointment.
--
-- The gateway redirect flow is asynchronous: the app asks to pay, the
-- user pays on SSLCommerz's hosted page, and the gateway calls back. The
-- session row is what ties those moments together and makes the flow
-- idempotent -- re-initialising returns the SAME live session instead of
-- opening a second one.
--
-- Only the Edge Functions write to this table (service role). The client
-- reads its own sessions and may expire one it started by mistake.
-- ---------------------------------------------------------------------
create table public.payment_sessions (
  id             uuid primary key default extensions.gen_random_uuid(),
  user_id        uuid    not null references public.users (id) on delete cascade,
  appointment_id bigint  not null references public.appointments (id) on delete cascade,
  amount         numeric(10,2) not null,
  gateway_ref    varchar(100),
  gateway_txn_id varchar(100),
  status         varchar(30) not null default 'initiated',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint payment_sessions_amount_check check (amount >= 0),
  constraint payment_sessions_status_check
    check (status in ('initiated', 'paid', 'failed', 'expired', 'refunded'))
);

comment on column public.payment_sessions.gateway_ref is 'SSLCommerz sessionkey returned by the init call.';
comment on column public.payment_sessions.gateway_txn_id is 'SSLCommerz tran_id (the session id) echoed back by the gateway.';
comment on column public.payment_sessions.status is 'initiated|paid|failed|expired|refunded';

create index idx_payment_sessions_user on public.payment_sessions (user_id);
create index idx_payment_sessions_appt on public.payment_sessions (appointment_id);
create index idx_payment_sessions_status on public.payment_sessions (status);
-- One live session per appointment: an unpaid appointment has at most one
-- initiated or paid attempt outstanding.
create unique index uq_payment_sessions_active_appt
  on public.payment_sessions (appointment_id)
  where status in ('initiated', 'paid');

-- ---------------------------------------------------------------------
-- pharmacy_products
-- ---------------------------------------------------------------------
create table public.pharmacy_products (
  id                    bigint generated always as identity primary key,
  pharmacy_id           bigint  not null references public.pharmacies (id) on delete cascade,
  name                  varchar(255) not null,
  generic_name          varchar(255),
  brand                 varchar(150),
  category              varchar(100),
  description           text,
  image                 varchar(255),
  price                 numeric(10,2) not null default 0.00,
  mrp                   numeric(10,2),
  unit                  varchar(50),
  stock                 integer not null default 0,
  prescription_required boolean not null default false,
  status                active_status default 'active',
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint pharmacy_products_price_check check (price >= 0),
  constraint pharmacy_products_stock_check check (stock >= 0),
  -- A strike-through price below the real price would render as a
  -- negative discount in the UI.
  constraint pharmacy_products_mrp_check check (mrp is null or mrp >= price)
);

comment on column public.pharmacy_products.image is 'Object path inside the `product-images` storage bucket (public).';
comment on column public.pharmacy_products.mrp is 'strike-through price; NULL = no discount shown';

create index idx_products_pharmacy on public.pharmacy_products (pharmacy_id);
create index idx_products_category on public.pharmacy_products (category);
create index idx_products_status   on public.pharmacy_products (status);
create index idx_products_name     on public.pharmacy_products (name);

-- Product search was PHP `LIKE '%term%'`, which cannot use a b-tree
-- index. pg_trgm makes the same substring search index-backed across
-- name, generic_name and brand.
create extension if not exists pg_trgm with schema extensions;
create index idx_products_search_trgm
  on public.pharmacy_products
  using gin ((coalesce(name, '') || ' ' ||
              coalesce(generic_name, '') || ' ' ||
              coalesce(brand, '')) extensions.gin_trgm_ops);

-- ---------------------------------------------------------------------
-- cart
-- ---------------------------------------------------------------------
create table public.cart (
  id         bigint generated always as identity primary key,
  user_id    uuid    not null references public.users (id) on delete cascade,
  product_id bigint  not null references public.pharmacy_products (id) on delete cascade,
  quantity   integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint uq_cart_user_product unique (user_id, product_id),
  constraint cart_quantity_check check (quantity > 0)
);

create index idx_cart_product on public.cart (product_id);

-- ---------------------------------------------------------------------
-- orders
-- ---------------------------------------------------------------------
create table public.orders (
  id               bigint generated always as identity primary key,
  user_id          uuid    not null references public.users (id) on delete cascade,
  pharmacy_id      bigint  references public.pharmacies (id) on delete set null,
  -- NOT NULL with no default: orders_set_order_number() fills it in a
  -- BEFORE INSERT trigger, so the PHP temp-value-then-UPDATE dance is
  -- gone and the column is never briefly wrong.
  order_number     varchar(20) not null,
  subtotal         numeric(10,2) not null default 0.00,
  delivery_fee     numeric(10,2) not null default 0.00,
  total            numeric(10,2) not null default 0.00,
  payment_method   payment_method not null default 'Cash',
  payment_status   payment_state default 'pending',
  transaction_id   varchar(100),
  sender_number    varchar(20),
  status           order_status default 'pending',
  delivery_name    varchar(100) not null,
  delivery_phone   varchar(20)  not null,
  delivery_address text    not null,
  delivery_city    varchar(50),
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint uq_order_number unique (order_number),
  constraint orders_subtotal_check     check (subtotal >= 0),
  constraint orders_delivery_fee_check check (delivery_fee >= 0),
  constraint orders_total_check        check (total >= 0)
);

comment on column public.orders.pharmacy_id is 'NULL if the order spans pharmacies';

create index idx_orders_user      on public.orders (user_id);
create index idx_orders_pharmacy  on public.orders (pharmacy_id);
create index idx_orders_status    on public.orders (status);
create index idx_orders_user_date on public.orders (user_id, created_at desc);

-- ---------------------------------------------------------------------
-- order_items
--
-- product_name and unit_price are copied, not joined: an order is a
-- historical record and must not change if the product is later
-- renamed, repriced or deleted. Hence product_id ON DELETE SET NULL.
-- ---------------------------------------------------------------------
create table public.order_items (
  id           bigint generated always as identity primary key,
  order_id     bigint  not null references public.orders (id) on delete cascade,
  product_id   bigint  references public.pharmacy_products (id) on delete set null,
  product_name varchar(255) not null,
  unit_price   numeric(10,2) not null,
  quantity     integer not null default 1,
  line_total   numeric(10,2) not null,
  created_at   timestamptz not null default now(),
  constraint order_items_unit_price_check check (unit_price >= 0),
  constraint order_items_quantity_check   check (quantity > 0),
  constraint order_items_line_total_check  check (line_total >= 0)
);

create index idx_order_items_order   on public.order_items (order_id);
create index idx_order_items_product on public.order_items (product_id);

-- ---------------------------------------------------------------------
-- reviews
-- ---------------------------------------------------------------------
-- Polymorphic by (reviewable_type, reviewable_id), as in MySQL. No FK
-- is possible on a polymorphic pair; recalc_reviewable_rating()
-- validates the target instead.
create table public.reviews (
  id              bigint generated always as identity primary key,
  user_id         uuid    not null references public.users (id) on delete cascade,
  reviewable_type reviewable_type not null,
  reviewable_id   bigint  not null,
  -- For doctor reviews this links the review to the appointment it
  -- resulted from, which is what lets "one review per appointment" be a
  -- database constraint rather than a UI promise. NULL for reviews of
  -- hospitals/clinics/pharmacies, which have no appointment.
  appointment_id  bigint  references public.appointments (id) on delete cascade,
  rating          smallint not null,
  comment         text,
  status          review_status default 'pending',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint reviews_rating_check check (rating >= 1 and rating <= 5)
);

comment on column public.reviews.appointment_id is 'Doctor reviews must reference an owned appointment with the reviewed doctor; enforced by guard_reviews_insert.';

create index idx_reviews_user       on public.reviews (user_id);
create index idx_reviews_reviewable on public.reviews (reviewable_type, reviewable_id);
create index idx_reviews_status     on public.reviews (status);
-- The public "approved reviews for this doctor, newest first" query.
create index idx_reviews_target_approved
  on public.reviews (reviewable_type, reviewable_id, created_at desc)
  where status = 'approved';
-- One review per appointment.
create unique index uq_reviews_appointment
  on public.reviews (appointment_id)
  where appointment_id is not null;
-- One review per target per user, whatever the target kind.
create unique index uq_reviews_user_target
  on public.reviews (user_id, reviewable_type, reviewable_id);

-- ---------------------------------------------------------------------
-- blood_banks
-- ---------------------------------------------------------------------
create table public.blood_banks (
  id                bigint generated always as identity primary key,
  name              varchar(255) not null,
  address           text    not null,
  city              varchar(100) not null,
  phone             varchar(20),
  email             varchar(100),
  blood_a_positive  integer default 0,
  blood_a_negative  integer default 0,
  blood_b_positive  integer default 0,
  blood_b_negative  integer default 0,
  blood_ab_positive integer default 0,
  blood_ab_negative integer default 0,
  blood_o_positive  integer default 0,
  blood_o_negative  integer default 0,
  status            active_status default 'active',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint blood_banks_stock_non_negative check (
    blood_a_positive  >= 0 and blood_a_negative  >= 0 and
    blood_b_positive  >= 0 and blood_b_negative  >= 0 and
    blood_ab_positive >= 0 and blood_ab_negative >= 0 and
    blood_o_positive  >= 0 and blood_o_negative  >= 0
  )
);

create index idx_blood_banks_city   on public.blood_banks (city);
create index idx_blood_banks_status on public.blood_banks (status);

-- ---------------------------------------------------------------------
-- blood_donors
-- ---------------------------------------------------------------------
create table public.blood_donors (
  id                 bigint generated always as identity primary key,
  user_id            uuid    references public.users (id) on delete set null,
  name               varchar(100) not null,
  phone              varchar(20)  not null,
  email              varchar(100),
  blood_group        blood_group  not null,
  city               varchar(50)  not null,
  area               varchar(100),
  address            text,
  last_donation_date date,
  is_available       boolean default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint blood_donors_last_donation_check
    check (last_donation_date is null or last_donation_date <= current_date)
);

create index idx_donors_user        on public.blood_donors (user_id);
create index idx_donors_blood_group on public.blood_donors (blood_group);
create index idx_donors_city        on public.blood_donors (city);
create index idx_donors_available   on public.blood_donors (is_available);
-- The donor search is always group + city among available donors.
create index idx_donors_search
  on public.blood_donors (blood_group, city)
  where is_available;

-- ---------------------------------------------------------------------
-- blood_requests
-- ---------------------------------------------------------------------
create table public.blood_requests (
  id              bigint generated always as identity primary key,
  requester_name  varchar(100) not null,
  requester_phone varchar(20)  not null,
  patient_name    varchar(100) not null,
  blood_group     blood_group  not null,
  units_needed    integer default 1,
  hospital_name   varchar(255) not null,
  city            varchar(50)  not null,
  needed_by       date    not null,
  reason          text,
  status          blood_request_status default 'active',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint blood_requests_units_check check (units_needed > 0)
);

create index idx_requests_blood_group on public.blood_requests (blood_group);
create index idx_requests_city        on public.blood_requests (city);
create index idx_requests_status      on public.blood_requests (status);
create index idx_requests_active
  on public.blood_requests (blood_group, city, needed_by)
  where status = 'active';

-- ---------------------------------------------------------------------
-- notifications
-- ---------------------------------------------------------------------
create table public.notifications (
  id         bigint generated always as identity primary key,
  user_id    uuid    not null references public.users (id) on delete cascade,
  type       varchar(50) not null default 'general',
  title      varchar(255) not null,
  body       text,
  route      varchar(255),
  ref_id     bigint,
  is_read    boolean not null default false,
  created_at timestamptz not null default now()
);

comment on column public.notifications.type   is 'appointment|payment|order|blood|general';
comment on column public.notifications.route  is 'in-app deep link, e.g. /appointments';
comment on column public.notifications.ref_id is 'id of the appointment/order this refers to';

create index idx_notifications_user_read on public.notifications (user_id, is_read);
create index idx_notifications_created   on public.notifications (created_at);
-- The bell badge counts unread rows for one user.
create index idx_notifications_unread
  on public.notifications (user_id, created_at desc)
  where not is_read;

-- ---------------------------------------------------------------------
-- device_tokens
-- ---------------------------------------------------------------------
create table public.device_tokens (
  id         bigint generated always as identity primary key,
  user_id    uuid    not null references public.users (id) on delete cascade,
  fcm_token  varchar(255) not null,
  platform   device_platform default 'android',
  created_at timestamptz not null default now(),
  constraint uq_device_token unique (fcm_token)
);

create index idx_device_tokens_user on public.device_tokens (user_id);

-- ---------------------------------------------------------------------
-- feedback
-- ---------------------------------------------------------------------
create table public.feedback (
  id             bigint generated always as identity primary key,
  user_id        uuid    references public.users (id) on delete set null,
  name           varchar(100) not null,
  email          varchar(100) not null,
  phone          varchar(20),
  feedback_type  feedback_type default 'general',
  subject        varchar(255) not null,
  message        text    not null,
  admin_response text,
  status         feedback_status   default 'new',
  priority       feedback_priority default 'normal',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index idx_feedback_user     on public.feedback (user_id);
create index idx_feedback_status   on public.feedback (status);
create index idx_feedback_type     on public.feedback (feedback_type);
create index idx_feedback_priority on public.feedback (priority);

-- ---------------------------------------------------------------------
-- blogs
-- ---------------------------------------------------------------------
create table public.blogs (
  id           bigint generated always as identity primary key,
  author_id    uuid    references public.users (id) on delete set null,
  slug         varchar(200) not null,
  title        varchar(255) not null,
  excerpt      varchar(500),
  content      text    not null,
  cover_image  varchar(255),
  category     varchar(100),
  tags         varchar(255),
  status       blog_status default 'draft',
  published_at timestamptz,
  views        integer not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint uq_blog_slug unique (slug),
  constraint blogs_views_check check (views >= 0)
);

comment on column public.blogs.tags        is 'comma separated';
comment on column public.blogs.cover_image is 'Object path inside the `blog-covers` storage bucket (public).';

create index idx_blogs_status_pub on public.blogs (status, published_at desc);
create index idx_blogs_category   on public.blogs (category);
create index idx_blogs_author     on public.blogs (author_id);

-- ---------------------------------------------------------------------
-- emergency_hotlines — reference data for the emergency screen.
--
-- From migration_v2.sql PART 5. Not present in the base dump, but
-- GET /emergency/hotlines is a live route (index.php:135) backed by
-- patient.php:209, so omitting this table would remove a working screen.
--
-- The rows themselves (999, 199, 16163, 16263, 109) are NOT seeded here:
-- structure only. The screen renders an empty list until they are added.
-- ---------------------------------------------------------------------
create table public.emergency_hotlines (
  id          bigint generated always as identity primary key,
  name        varchar(150) not null,
  phone       varchar(30)  not null,
  category    varchar(50)  not null default 'general',
  description varchar(255),
  sort_order  integer      not null default 0,
  status      active_status not null default 'active'
);

comment on table public.emergency_hotlines is
  'Public reference data. Deliberately readable without auth: someone who needs 999 should not have to sign in first.';

create index idx_hotline_status on public.emergency_hotlines (status);
-- Serves the exact ORDER BY sort_order ASC, id ASC of patient.php:216.
create index idx_hotline_order  on public.emergency_hotlines (sort_order, id)
  where status = 'active';

-- ---------------------------------------------------------------------
-- emergency_sms — a log, not a transmitter.
--
-- From migration_v2.sql PART 4. No SMS gateway is configured, so
-- patient.php:262 records the request and leaves status 'queued'. The row
-- IS the deliverable; keeping the table means an unsent emergency stays
-- visible instead of being lost.
-- ---------------------------------------------------------------------
create table public.emergency_sms (
  id              bigint generated always as identity primary key,
  -- nullable and ON DELETE SET NULL: auth is optional on this route, so an
  -- anonymous emergency must still be recordable.
  user_id         uuid references public.users (id) on delete set null,
  sender_phone    varchar(20) not null,
  recipient_phone varchar(20) not null,
  message         text        not null,
  location        varchar(255),
  latitude        numeric(10,7),
  longitude       numeric(10,7),
  status          sms_status  not null default 'queued',
  created_at      timestamptz not null default now(),
  -- The PHP validated these ranges per-request (patient.php:257-258);
  -- as constraints they hold for every writer, including the SDK.
  constraint emergency_sms_lat_check check (latitude  between  -90 and  90),
  constraint emergency_sms_lng_check check (longitude between -180 and 180)
);

create index idx_emergency_user    on public.emergency_sms (user_id);
create index idx_emergency_created on public.emergency_sms (created_at desc);

-- ---------------------------------------------------------------------
-- audit_log — written only by triggers.
-- ---------------------------------------------------------------------
create table public.audit_log (
  id               bigint generated always as identity primary key,
  table_name       varchar(100) not null,
  -- text, not bigint: users.id is a uuid while every other audited
  -- table has a bigint id, and this one column must hold both.
  record_id        text    not null,
  action_type      audit_action not null,
  old_values       jsonb,
  new_values       jsonb,
  changed_fields   text,
  action_timestamp timestamptz not null default now(),
  ip_address       inet,
  user_agent       text
);

create index idx_audit_table_name  on public.audit_log (table_name);
create index idx_audit_record_id   on public.audit_log (record_id);
create index idx_audit_action_type on public.audit_log (action_type);
create index idx_audit_timestamp   on public.audit_log (action_timestamp desc);
create index idx_audit_table_record on public.audit_log (table_name, record_id);

-- ---------------------------------------------------------------------
-- app_audit_log — written by the application (login, logout, ...).
-- ---------------------------------------------------------------------
create table public.app_audit_log (
  id         bigint generated always as identity primary key,
  user_id    uuid    references public.users (id) on delete set null,
  action     varchar(50) not null,
  entity     varchar(50),
  -- text for the same reason as audit_log.record_id: this may hold a
  -- uuid (entity='users') or a bigint (entity='appointments').
  entity_id  text,
  details    jsonb,
  ip_address inet,
  created_at timestamptz not null default now()
);

comment on column public.app_audit_log.action is 'login|logout|create|update|change_password|...';

create index idx_app_audit_user    on public.app_audit_log (user_id);
create index idx_app_audit_action  on public.app_audit_log (action);
create index idx_app_audit_created on public.app_audit_log (created_at desc);

-- =====================================================================
-- PART 2 — FUNCTIONS
--
-- Every function is SECURITY INVOKER unless it must cross an RLS
-- boundary, and every one pins search_path — an unpinned search_path on
-- a SECURITY DEFINER function is a privilege-escalation vector.
-- =====================================================================

-- ---------------------------------------------------------------------
-- set_updated_at — replaces MySQL's ON UPDATE current_timestamp().
-- ---------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- audit_row_change — one generic replacement for the 36 MySQL triggers.
--
-- changed_fields is computed by comparing OLD and NEW as jsonb, so it
-- needs no per-table field list and cannot drift when a column is added.
-- SECURITY DEFINER because audit_log denies direct writes to end users;
-- only this trigger may insert.
-- ---------------------------------------------------------------------
create or replace function public.audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old     jsonb;
  v_new     jsonb;
  v_changed text;
  v_record  text;
begin
  if tg_op = 'INSERT' then
    v_new    := to_jsonb(new);
    v_record := v_new ->> 'id';

  elsif tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
    v_new := to_jsonb(new);
    v_record := v_new ->> 'id';

    -- Keys whose value differs, ignoring updated_at (which the
    -- set_updated_at trigger changes on every write and which would
    -- otherwise appear in every single audit row).
    select string_agg(key, ',' order by key)
      into v_changed
      from jsonb_each(v_new) n(key, value)
     where key <> 'updated_at'
       and value is distinct from (v_old -> n.key);

    -- Nothing of substance changed: do not write an audit row. This
    -- mirrors the MySQL `IF changed != ''` guard.
    if v_changed is null then
      return null;
    end if;

  else -- DELETE
    v_old    := to_jsonb(old);
    v_record := v_old ->> 'id';
  end if;

  insert into public.audit_log
    (table_name, record_id, action_type, old_values, new_values, changed_fields)
  values
    (tg_table_name, v_record, tg_op::public.audit_action,
     v_old, v_new, v_changed);

  return null;   -- AFTER trigger: return value is ignored.
end;
$$;

revoke all on function public.audit_row_change() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- recalc_reviewable_rating
--
-- Was PHP (admin.php moderate + content.php create). Recomputes the
-- cached rating/total_reviews on the reviewed entity from APPROVED
-- reviews only, so a pending review does not move the average.
--
-- COALESCE guards the zero-approved-review case: avg() returns NULL
-- there and rating is NOT NULL DEFAULT 0.00.
--
-- Runs for INSERT, UPDATE and DELETE, and on UPDATE also fixes the OLD
-- target when a review is repointed — something the PHP never did.
-- ---------------------------------------------------------------------
create or replace function public.recalc_reviewable_rating()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_new_type public.reviewable_type;
  v_new_id   bigint;
  v_old_type public.reviewable_type;
  v_old_id   bigint;
  v_targets  record;
begin
  -- NEW is unassigned on DELETE and OLD on INSERT, so each is read only
  -- where it exists. They cannot be referenced inside a guarded SQL
  -- query instead: PL/pgSQL substitutes both before the WHERE runs.
  if tg_op <> 'DELETE' then
    v_new_type := new.reviewable_type;
    v_new_id   := new.reviewable_id;
  end if;

  if tg_op <> 'INSERT' then
    v_old_type := old.reviewable_type;
    v_old_id   := old.reviewable_id;
  end if;

  -- Both the new and the previous target may need recomputing; distinct
  -- collapses them when a review was not repointed.
  for v_targets in
    select distinct t.rtype, t.rid
      from (values (v_new_type, v_new_id),
                   (v_old_type, v_old_id)) t(rtype, rid)
     where t.rtype is not null
  loop
    if v_targets.rtype = 'doctor' then
      update public.doctors d
         set rating = coalesce((
               select round(avg(r.rating), 2) from public.reviews r
                where r.reviewable_type = 'doctor' and r.reviewable_id = d.id
                  and r.status = 'approved'), 0),
             total_reviews = (
               select count(*) from public.reviews r
                where r.reviewable_type = 'doctor' and r.reviewable_id = d.id
                  and r.status = 'approved')
       where d.id = v_targets.rid;

    elsif v_targets.rtype = 'hospital' then
      update public.hospitals h
         set rating = coalesce((
               select round(avg(r.rating), 2) from public.reviews r
                where r.reviewable_type = 'hospital' and r.reviewable_id = h.id
                  and r.status = 'approved'), 0),
             total_reviews = (
               select count(*) from public.reviews r
                where r.reviewable_type = 'hospital' and r.reviewable_id = h.id
                  and r.status = 'approved')
       where h.id = v_targets.rid;

    elsif v_targets.rtype = 'clinic' then
      update public.clinics c
         set rating = coalesce((
               select round(avg(r.rating), 2) from public.reviews r
                where r.reviewable_type = 'clinic' and r.reviewable_id = c.id
                  and r.status = 'approved'), 0),
             total_reviews = (
               select count(*) from public.reviews r
                where r.reviewable_type = 'clinic' and r.reviewable_id = c.id
                  and r.status = 'approved')
       where c.id = v_targets.rid;

    elsif v_targets.rtype = 'pharmacy' then
      update public.pharmacies p
         set rating = coalesce((
               select round(avg(r.rating), 2) from public.reviews r
                where r.reviewable_type = 'pharmacy' and r.reviewable_id = p.id
                  and r.status = 'approved'), 0),
             total_reviews = (
               select count(*) from public.reviews r
                where r.reviewable_type = 'pharmacy' and r.reviewable_id = p.id
                  and r.status = 'approved')
       where p.id = v_targets.rid;
    end if;
  end loop;

  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- reviews_check_target — the integrity check a polymorphic FK cannot do.
-- Rejects a review pointed at an entity that does not exist.
--
-- SECURITY DEFINER on purpose. This stands in for a foreign key, and a
-- foreign key does not consult RLS. As SECURITY INVOKER the existence
-- probe would be filtered by the caller's own policies, so reviewing a
-- provider the caller cannot SELECT would fail with "the doctor does not
-- exist" when it does -- a misleading error, and a way to probe which
-- rows are hidden.
-- ---------------------------------------------------------------------
create or replace function public.reviews_check_target()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_exists boolean;
begin
  case new.reviewable_type
    when 'doctor' then
      select exists(select 1 from public.doctors    where id = new.reviewable_id) into v_exists;
    when 'hospital' then
      select exists(select 1 from public.hospitals  where id = new.reviewable_id) into v_exists;
    when 'clinic' then
      select exists(select 1 from public.clinics    where id = new.reviewable_id) into v_exists;
    when 'pharmacy' then
      select exists(select 1 from public.pharmacies where id = new.reviewable_id) into v_exists;
  end case;

  if not v_exists then
    raise exception 'reviews: no % exists with id %',
      new.reviewable_type, new.reviewable_id
      using errcode = 'foreign_key_violation';
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- generate_confirmation_code — was provider_confirmation_code() in PHP.
-- Same 32-char alphabet (no I, O, 0, 1 — unreadable aloud) and length 8.
-- gen_random_bytes is cryptographic, matching PHP's random_int().
-- ---------------------------------------------------------------------
create or replace function public.generate_confirmation_code()
returns varchar(12)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_out      text := '';
  v_bytes    bytea;
begin
  v_bytes := extensions.gen_random_bytes(8);
  for i in 0 .. 7 loop
    -- 32 = length(v_alphabet); & 31 maps a byte onto it without bias.
    v_out := v_out || substr(v_alphabet, (get_byte(v_bytes, i) & 31) + 1, 1);
  end loop;
  return v_out;
end;
$$;

-- ---------------------------------------------------------------------
-- appointments_set_confirmation_code
--
-- The PHP generated a code when a doctor confirmed an appointment. Doing
-- it in a trigger also closes the race the PHP comment admitted to: the
-- unique index on confirmation_code now backstops a collision, and the
-- loop retries instead of failing the request.
--
-- SECURITY DEFINER because the uniqueness probe must see EVERY
-- appointment. As SECURITY INVOKER a patient's RLS policies would hide
-- other patients' rows, the probe would report "no collision" against a
-- code that does exist, and the insert would then fail on the unique
-- index -- turning a retryable collision into a user-visible error.
-- ---------------------------------------------------------------------
create or replace function public.appointments_set_confirmation_code()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code    varchar(12);
  v_attempt int := 0;
begin
  if new.status in ('confirmed', 'completed')
     and new.confirmation_code is null then
    loop
      v_attempt := v_attempt + 1;
      v_code := public.generate_confirmation_code();
      exit when not exists (
        select 1 from public.appointments where confirmation_code = v_code
      );
      if v_attempt >= 10 then
        raise exception 'could not generate a unique confirmation_code';
      end if;
    end loop;
    new.confirmation_code := v_code;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- orders_set_order_number — was 'AYU-' + str_pad(id) in pharmacy.php.
--
-- The PHP inserted a throwaway 'TMP-...' then UPDATEd it, because it
-- needed lastInsertId(). A BEFORE INSERT trigger can read the sequence
-- directly, so the temporary value never exists.
-- ---------------------------------------------------------------------
create or replace function public.orders_set_order_number()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.order_number is null or new.order_number = '' then
    new.order_number := 'AYU-' || lpad(new.id::text, 6, '0');
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- notify — the single writer for public.notifications.
--
-- WHY THIS EXISTS. In PHP, seven endpoints inserted notification rows for
-- SOMEONE ELSE: a doctor confirming an appointment notified the patient,
-- an admin verifying a provider notified that provider, and so on. That
-- works when a trusted server holds the only DB connection. It cannot
-- work from the Flutter client under RLS -- a doctor writing a row whose
-- user_id is the patient's is precisely what an insert policy has to
-- forbid, or any user could forge a notification for any other user.
--
-- So notifications are not written by the app at all any more. They are
-- written by these SECURITY DEFINER triggers, which fire on the state
-- change that the notification describes. The app keeps only its reads
-- and its "mark as read" update. Behaviour and wording are unchanged;
-- the notification simply becomes a consequence of the state change
-- rather than a second statement the client has to remember to send.
-- ---------------------------------------------------------------------
create or replace function public.notify(
  p_user_id uuid,
  p_title   text,
  p_body    text,
  p_type    text,
  p_route   text,
  p_ref_id  bigint
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Older provider rows may have no owning user; the PHP guarded on this
  -- (`if (!empty($row['user_id']))`) and so does this.
  if p_user_id is null then
    return;
  end if;

  insert into public.notifications (user_id, title, body, type, route, ref_id)
  values (p_user_id, p_title, p_body, p_type, p_route, p_ref_id);
end;
$$;

revoke all on function
  public.notify(uuid, text, text, text, text, bigint)
  from public, anon, authenticated;

comment on function public.notify(uuid, text, text, text, text, bigint) is
  'Internal. Trigger-only writer for notifications; EXECUTE is revoked so no client can forge a notification for another user.';

-- ---------------------------------------------------------------------
-- appointments_notify — was 3 insert sites:
--   appointments.php:415  booking            -> patient
--   appointments.php:609  cancellation       -> patient
--   provider.php:284      doctor status move -> patient
-- ---------------------------------------------------------------------
create or replace function public.appointments_notify()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform public.notify(
      new.patient_id,
      'Appointment requested',
      'Your appointment request for ' || to_char(new.appointment_date, 'YYYY-MM-DD')
        || ' at ' || to_char(new.appointment_time, 'HH24:MI')
        || ' has been received.',
      'appointment', '/appointments', new.id
    );
    return null;
  end if;

  -- UPDATE: only a status transition is worth telling the patient about.
  if new.status is distinct from old.status then
    if new.status = 'confirmed' then
      perform public.notify(new.patient_id, 'Appointment confirmed',
        'Your appointment has been confirmed by the doctor.',
        'appointment', '/appointments', new.id);

    elsif new.status = 'completed' then
      perform public.notify(new.patient_id, 'Appointment completed',
        'Your appointment is marked complete. You can now leave a review.',
        'appointment', '/appointments', new.id);

    elsif new.status = 'cancelled' then
      -- appointments.php:614 used the date; provider.php:279 said "by the
      -- doctor". The date version is kept: it is the one a patient with
      -- several appointments can actually act on.
      perform public.notify(new.patient_id, 'Appointment cancelled',
        'Your appointment on ' || to_char(new.appointment_date, 'YYYY-MM-DD')
          || ' has been cancelled.',
        'appointment', '/appointments', new.id);

    elsif new.status = 'expired' then
      perform public.notify(new.patient_id, 'Appointment expired',
        'Your appointment on ' || to_char(new.appointment_date, 'YYYY-MM-DD')
          || ' has expired. You can book a new slot.',
        'appointment', '/appointments', new.id);
    end if;
  end if;

  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- appointments_refund_on_cancel — was appointments.php:603.
--
-- A paid appointment that gets cancelled is marked 'refunded'. Note the
-- payments row is deliberately NOT touched: payment_verification_status
-- has no 'refunded' value, and widening it would change a column the
-- website already reads. Same decision the PHP documented at :598.
-- ---------------------------------------------------------------------
create or replace function public.appointments_refund_on_cancel()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'cancelled'
     and old.status <> 'cancelled'
     and new.payment_status = 'paid' then
    new.payment_status := 'refunded';
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- payments_notify — was 2 insert sites:
--   appointments.php:744  patient submits payment -> patient
--   provider.php:489      doctor verifies/rejects -> patient
-- ---------------------------------------------------------------------
create or replace function public.payments_notify()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
begin
  if tg_op = 'INSERT' then
    perform public.notify(new.user_id, 'Payment submitted',
      'Your payment details were received and are awaiting verification.',
      'payment', '/appointments', new.appointment_id);
    return null;
  end if;

  if new.payment_status is distinct from old.payment_status then
    if new.payment_status = 'verified' then
      -- The code is set by payments_apply_verification below, which runs
      -- BEFORE this trigger, so it is already visible here.
      select confirmation_code into v_code
        from public.appointments where id = new.appointment_id;

      perform public.notify(new.user_id, 'Payment verified',
        'Your payment was verified.'
          || coalesce(' Confirmation code: ' || v_code, ''),
        'payment', '/appointments', new.appointment_id);

    elsif new.payment_status = 'rejected' then
      perform public.notify(new.user_id, 'Payment rejected',
        'Your payment was rejected: '
          || coalesce(new.rejection_reason, 'no reason given'),
        'payment', '/appointments', new.appointment_id);
    end if;
  end if;

  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- payments_apply_verification — was provider.php:458-482.
--
-- Verifying a payment is the ONE place appointments.payment_status
-- becomes 'paid'. The PHP enforced that by convention (a README rule that
-- the patient app must never set it); here the patient simply has no
-- UPDATE policy on appointments.payment_status-bearing rows, and this
-- SECURITY DEFINER trigger performs the flip. Also clears a stale
-- rejection_reason on re-verification, as the PHP did at :459.
-- ---------------------------------------------------------------------
create or replace function public.payments_apply_verification()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.payment_status = 'verified'
     and old.payment_status is distinct from 'verified' then

    new.rejection_reason := null;
    new.verified_at      := coalesce(new.verified_at, now());
    new.verified_by      := coalesce(new.verified_by, auth.uid());

    -- The confirmation code is filled by appointments_set_confirmation_code,
    -- which fires on this same UPDATE.
    update public.appointments
       set payment_status      = 'paid',
           payment_verified_at = now(),
           payment_verified_by = coalesce(new.verified_by, auth.uid()),
           status              = case when status = 'pending'
                                      then 'confirmed' else status end
     where id = new.appointment_id;
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- providers_notify — was admin.php:335, one function per provider table.
--
-- Fires when an admin moderates a provider. The PHP appended the
-- rejection reason to the body; the reason is not a column on these
-- tables, so it is not reproducible here and the base message is used.
-- ---------------------------------------------------------------------
create or replace function public.providers_notify()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.verification_status is distinct from old.verification_status then
    if new.verification_status = 'verified' then
      perform public.notify(new.user_id, 'Account verified',
        'Your account has been verified and is now listed publicly.',
        'system', '/dashboard', new.id);
      return null;
    elsif new.verification_status = 'rejected' then
      perform public.notify(new.user_id, 'Verification rejected',
        'Your verification was not approved.'
          || coalesce(' Reason: ' || new.rejection_reason, ''),
        'system', '/dashboard', new.id);
      return null;
    end if;
  end if;

  -- Only report a bare activate/deactivate when it was not already
  -- covered by the verify/reject message above (verify also activates).
  if new.status is distinct from old.status then
    if new.status = 'active' then
      perform public.notify(new.user_id, 'Account activated',
        'Your account is active again.', 'system', '/dashboard', new.id);
    elsif new.status = 'inactive' then
      perform public.notify(new.user_id, 'Account deactivated',
        'Your account has been deactivated.', 'system', '/dashboard', new.id);
    end if;
  end if;

  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- orders_notify — was pharmacy.php:513.
-- ---------------------------------------------------------------------
create or replace function public.orders_notify()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.notify(new.user_id, 'Order placed',
    'Order ' || new.order_number || ' has been received and is being processed.',
    'order', '/pharmacy/orders', new.id);
  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- feedback_notify — was admin.php:679. Fires when an admin answers.
-- ---------------------------------------------------------------------
create or replace function public.feedback_notify()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.admin_response is not null
     and new.admin_response is distinct from old.admin_response then
    perform public.notify(new.user_id, 'Response to your feedback',
      new.admin_response, 'system', '/feedback', new.id);
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- handle_new_user — mirrors auth.users into public.users on signup.
--
-- This is what makes "auth with UUID users" work without the app
-- writing its own profile row: the client calls auth.signUp() with
-- metadata and the row appears atomically.
--
-- Reads name/phone/role/gender from raw_user_meta_data. role falls back
-- to 'patient' when absent, and an invalid role string also becomes
-- 'patient' rather than aborting the signup.
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.user_role;
begin
  begin
    v_role := coalesce(
      (new.raw_user_meta_data ->> 'role')::public.user_role,
      'patient'
    );
  exception when invalid_text_representation or others then
    v_role := 'patient';
  end;

  insert into public.users (id, email, name, phone, gender, role, city)
  values (
    new.id,
    new.email,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'name'), ''), split_part(new.email, '@', 1)),
    nullif(trim(new.raw_user_meta_data ->> 'phone'), ''),
    case
      when (new.raw_user_meta_data ->> 'gender') in ('male', 'female', 'other')
      then (new.raw_user_meta_data ->> 'gender')::public.gender_type
    end,
    v_role,
    nullif(trim(new.raw_user_meta_data ->> 'city'), '')
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- handle_user_email_change — keeps public.users.email in step when the
-- user changes it through Supabase Auth.
-- ---------------------------------------------------------------------
create or replace function public.handle_user_email_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.email is distinct from old.email then
    update public.users set email = new.email where id = new.id;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Role helpers for RLS. SECURITY DEFINER so a policy can read the
-- caller's role without recursing into users' own RLS policy.
--
-- STABLE lets the planner call these once per statement rather than
-- once per row, which matters on every policy in rls_policies.sql.
-- ---------------------------------------------------------------------
create or replace function public.current_user_role()
returns public.user_role
language sql
stable
security definer
set search_path = ''
as $$
  select role from public.users where id = auth.uid();
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.users where id = auth.uid() and role = 'admin'
  );
$$;

-- Doctor row owned by the caller, or NULL. Used by the doctor-workspace
-- policies so they never hard-code a join. Returns NULL for a suspended
-- (is_active = false) user, so every doctor-scoped policy denies them.
create or replace function public.current_doctor_id()
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select d.id
    from public.doctors d
    join public.users u on u.id = d.user_id
   where d.user_id = auth.uid() and u.is_active;
$$;

create or replace function public.current_pharmacy_id()
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select p.id
    from public.pharmacies p
    join public.users u on u.id = p.user_id
   where p.user_id = auth.uid() and u.is_active;
$$;

grant execute on function public.current_user_role()  to authenticated;
grant execute on function public.is_admin()           to authenticated;
grant execute on function public.current_doctor_id()  to authenticated;
grant execute on function public.current_pharmacy_id() to authenticated;

-- ---------------------------------------------------------------------
-- available_slots — the booking calendar's slot generator.
--
-- Was PHP: read available_days/from/to/slot_minutes, walk the window,
-- drop slots already taken. Kept server-side so the app cannot be
-- talked into offering a slot that is gone, and so one round trip
-- replaces a read-then-filter.
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
  v_doc record;
  v_day text;
begin
  select available_days, available_from, available_to,
         coalesce(slot_minutes, 30) as slot_minutes
    into v_doc
    from public.doctors
   where id = p_doctor_id and status = 'active' and not is_deleted;

  -- Not configured -> no slots. The UI already handles the empty case
  -- by telling the patient to call the chamber.
  if v_doc is null
     or v_doc.available_days is null
     or v_doc.available_from is null
     or v_doc.available_to   is null then
    return;
  end if;

  -- 'sat'..'fri', matching the csv the column stores.
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
     where -- never offer a slot in the past
           s.ts > now()
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

grant execute on function public.available_slots(bigint, date) to anon, authenticated;

-- ---------------------------------------------------------------------
-- guard_provider_insert — the INSERT half of the PART 1 column guards.
--
-- The RLS column guards (rls_policies.sql) hold UPDATE columns shut, but
-- an INSERT path can mint a row whose trusted columns are already
-- "verified": doctors_insert_own checks only user_id = auth.uid(), so a
-- provider could register themselves as already verified. This trigger
-- forces every self-registered provider row to the pending state; admin
-- writes (and internal SECURITY DEFINER paths, where current_user is the
-- function owner, not authenticated) pass straight through.
-- ---------------------------------------------------------------------
create or replace function public.guard_provider_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if public.is_admin() then
    return new;
  end if;
  if new.user_id is distinct from (select auth.uid()) then
    raise exception 'a provider row must be owned by the caller'
      using errcode = '42501';
  end if;
  if not exists (select 1 from public.users u where u.id = auth.uid() and u.is_active) then
    raise exception 'account is not active' using errcode = '42501';
  end if;

  new.verification_status := 'pending';
  new.status              := 'pending';
  new.rating              := 0;
  new.total_reviews       := 0;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- guard_appointments_insert — force the money/status fields a patient
-- must never choose, and validate the slot server-side.
--
-- The booking path that clients must use is appointments_book() below,
-- but a direct PostgREST insert is still possible (appointments_insert_patient),
-- so this trigger enforces the same invariants on that path: the fee is
-- always the doctor's current price, the status always starts 'pending',
-- the doctor must be active/verified/not soft-deleted, and the slot must
-- be inside the doctor's published window and currently free.
-- ---------------------------------------------------------------------
create or replace function public.guard_appointments_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fee  numeric(10,2);
  v_name varchar(255);
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if public.is_admin() then
    return new;
  end if;
  if new.patient_id is distinct from (select auth.uid()) then
    raise exception 'an appointment must be booked by the patient'
      using errcode = '42501';
  end if;
  if not exists (select 1 from public.users u where u.id = auth.uid() and u.is_active) then
    raise exception 'account is not active' using errcode = '42501';
  end if;

  select d.consultation_fee, u.name
    into v_fee, v_name
    from public.doctors d
    join public.users u on u.id = d.user_id
   where d.id = new.doctor_id
     and d.status = 'active'
     and d.verification_status = 'verified'
     and not d.is_deleted;
  if not found then
    raise exception 'this doctor is not accepting appointments'
      using errcode = '42501';
  end if;

  new.fee               := v_fee;
  new.doctor_name       := v_name;
  new.status            := 'pending';
  new.payment_status    := 'pending';
  new.payment_verified_at := null;
  new.payment_verified_by := null;

  -- available_slots() encodes the window/day/past rules; the partial
  -- unique index uq_appointments_doctor_slot is the concurrency backstop.
  if not exists (
    select 1 from public.available_slots(new.doctor_id, new.appointment_date) s
     where s.slot_time = new.appointment_time
  ) then
    raise exception 'this slot is not available' using errcode = '23505';
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- guard_payments_insert — a submitted payment is evidence, and the
-- amounts/statuses on it must not be client-chosen.
--
-- The patient may submit a manual (non-gateway) payment against their own
-- appointment. The trigger forces amount = the appointment's fee, resets
-- the verification fields, refuses gateway identifiers (gateway payments
-- are written only by the SSLCommerz Edge Function as service role), and
-- blocks double payment.
-- ---------------------------------------------------------------------
create or replace function public.guard_payments_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt public.appointments%rowtype;
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if public.is_admin() then
    return new;
  end if;
  if new.user_id is distinct from (select auth.uid()) then
    raise exception 'a payment must be attributed to the caller'
      using errcode = '42501';
  end if;
  if not exists (select 1 from public.users u where u.id = auth.uid() and u.is_active) then
    raise exception 'account is not active' using errcode = '42501';
  end if;
  if new.payment_method = 'sslcommerz' then
    raise exception 'gateway payments are written only by the payment provider'
      using errcode = '42501';
  end if;

  select * into v_appt
    from public.appointments
   where id = new.appointment_id;
  if not found then
    raise exception 'no such appointment' using errcode = 'PGRST116';
  end if;
  if v_appt.patient_id is distinct from (select auth.uid()) then
    raise exception 'this appointment belongs to another patient'
      using errcode = '42501';
  end if;
  if v_appt.status in ('cancelled', 'expired') then
    raise exception 'this appointment is no longer payable'
      using errcode = 'P0001';
  end if;
  if v_appt.payment_status in ('paid', 'refunded') then
    raise exception 'this appointment is already paid' using errcode = '23505';
  end if;

  new.gateway                := null;
  new.gateway_transaction_id := null;
  new.amount                 := v_appt.fee;
  new.payment_status         := 'pending';
  new.verified_at            := null;
  new.verified_by            := null;
  new.rejection_reason       := null;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- guard_reviews_insert — the INSERT half of review integrity.
--
-- A review must start 'pending' (the old policy let a client insert
-- status = 'approved' and self-approve), must be attributed to the
-- caller, and — for a doctor review — must reference an appointment the
-- patient owns with the reviewed doctor. There is deliberately NO
-- "must be completed" requirement: the product decision is that a review
-- may be left at any time against an owned appointment, and the unique
-- indexes make it one review per appointment and one per target per user.
-- ---------------------------------------------------------------------
create or replace function public.guard_reviews_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owned boolean;
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if public.is_admin() then
    return new;
  end if;
  if new.user_id is distinct from (select auth.uid()) then
    raise exception 'a review must be attributed to the caller'
      using errcode = '42501';
  end if;
  if not exists (select 1 from public.users u where u.id = auth.uid() and u.is_active) then
    raise exception 'account is not active' using errcode = '42501';
  end if;

  new.status := 'pending';

  if new.reviewable_type = 'doctor' then
    if new.appointment_id is null then
      raise exception 'a doctor review must reference an appointment'
        using errcode = '23505';
    end if;
    select exists (
      select 1 from public.appointments a
       where a.id = new.appointment_id
         and a.patient_id = (select auth.uid())
         and a.doctor_id  = new.reviewable_id
    ) into v_owned;
    if not v_owned then
      raise exception 'the appointment does not match the reviewed doctor'
        using errcode = '23505';
    end if;
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- guard_orders_insert / guard_order_items_insert — orders are trusted
-- money records, so the client cannot write them directly.
--
-- The only writer is place_order(), a SECURITY DEFINER RPC that computes
-- totals and decrements stock inside one transaction. A client-side
-- insert (or line item) is refused outright.
-- ---------------------------------------------------------------------
create or replace function public.guard_orders_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if public.is_admin() then
    return new;
  end if;
  raise exception 'orders must be created through public.place_order()'
    using errcode = 'P0001';
end;
$$;

create or replace function public.guard_order_items_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if public.is_admin() then
    return new;
  end if;
  raise exception 'order items are written only by public.place_order()'
    using errcode = 'P0001';
end;
$$;

-- ---------------------------------------------------------------------
-- appointments_book — the single, race-safe booking RPC.
--
-- Validates the doctor and the slot, then inserts forcing fee/status/
-- payment_status from the server side. Concurrency is handled by
-- uq_appointments_doctor_slot: two patients grabbing the same slot at the
-- same instant produce a 23505 unique violation, which SupabaseService
-- maps to the friendly "slot taken" 409 the booking screen already
-- handles. Returns the fresh row so the app can build its model without a
-- second round trip.
-- ---------------------------------------------------------------------
create or replace function public.appointments_book(
  p_doctor_id        bigint,
  p_appointment_date date,
  p_appointment_time time,
  p_type             public.appointment_type default 'new',
  p_symptoms         text default null,
  p_notes            text default null
)
returns public.appointments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_patient uuid := (select auth.uid());
  v_appt    public.appointments;
begin
  if v_patient is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.users u where u.id = v_patient and u.is_active) then
    raise exception 'account is not active' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.available_slots(p_doctor_id, p_appointment_date) s
     where s.slot_time = p_appointment_time
  ) then
    raise exception 'this slot is not available' using errcode = '23505';
  end if;

  insert into public.appointments
    (patient_id, doctor_id, doctor_name, appointment_date, appointment_time,
     type, symptoms, notes, fee, status, payment_status)
  select v_patient,
         p_doctor_id,
         u.name,
         p_appointment_date,
         p_appointment_time,
         coalesce(p_type, 'new'::public.appointment_type),
         p_symptoms,
         p_notes,
         d.consultation_fee,
         'pending'::public.appointment_status,
         'pending'::public.payment_state
    from public.doctors d
    join public.users u on u.id = d.user_id
   where d.id = p_doctor_id
     and d.status = 'active'
     and d.verification_status = 'verified'
     and not d.is_deleted
  returning * into v_appt;

  if not found then
    raise exception 'this doctor is not accepting appointments'
      using errcode = '42501';
  end if;

  return v_appt;
end;
$$;

-- ---------------------------------------------------------------------
-- place_order — the only way to create an order.
--
-- Was pharmacy.php's read-then-write checkout, which trusted client
-- totals and split the work across statements. This computes subtotal
-- from the products table, checks and decrements stock in the same
-- transaction, snapshots the line items and empties the cart — all
-- atomically. The client supplies only delivery details and its payment
-- choice.
-- ---------------------------------------------------------------------
create or replace function public.place_order(
  p_delivery_name    text,
  p_delivery_phone   text,
  p_delivery_address text,
  p_delivery_city    text default null,
  p_payment_method   public.payment_method default 'Cash',
  p_sender_number    text default null,
  p_notes            text default null
)
returns public.orders
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user      uuid := (select auth.uid());
  v_subtotal  numeric(10,2) := 0;
  v_delivery  numeric(10,2);
  v_total     numeric(10,2);
  v_pharmacy  bigint;
  v_order     public.orders;
  v_item      record;
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.users u where u.id = v_user and u.is_active) then
    raise exception 'account is not active' using errcode = '42501';
  end if;

  -- Totals come from the products table, never from the client.
  select coalesce(sum(p.price * c.quantity), 0)
    into v_subtotal
    from public.cart c
    join public.pharmacy_products p on p.id = c.product_id
   where c.user_id = v_user
     and p.status = 'active';

  if v_subtotal = 0 then
    raise exception 'cart is empty' using errcode = 'P0001';
  end if;

  -- Free delivery over ৳500, otherwise ৳60 — the same rule the basket screen
  -- shows, so the quoted figure and the written figure cannot disagree.
  v_delivery := case when v_subtotal >= 500.00 then 0.00 else 60.00 end;

  -- A single-pharmacy basket records which pharmacy; a mixed basket stays null
  -- (that is what the nullable FK is for).
  v_pharmacy := (
    select case
             when count(distinct p.pharmacy_id) = 1 then min(p.pharmacy_id)
             else null
           end
      from public.cart c
      join public.pharmacy_products p on p.id = c.product_id
     where c.user_id = v_user
       and p.status = 'active');

  -- Stock: decrement atomically, and abort if anything is short. The
  -- WHERE stock >= quantity makes a stock race a raised error rather
  -- than a negative inventory.
  for v_item in
    select c.product_id, c.quantity, p.name as product_name
      from public.cart c
      join public.pharmacy_products p on p.id = c.product_id
     where c.user_id = v_user
       and p.status = 'active'
     order by c.id
  loop
    update public.pharmacy_products
       set stock = stock - v_item.quantity
     where id = v_item.product_id
       and stock >= v_item.quantity;
    if not found then
      raise exception 'insufficient stock for %', v_item.product_name
        using errcode = 'P0001';
    end if;
  end loop;

  v_total := v_subtotal + v_delivery;

  insert into public.orders
    (user_id, pharmacy_id, subtotal, delivery_fee, total, payment_method,
     payment_status, transaction_id, sender_number, status, delivery_name,
     delivery_phone, delivery_address, delivery_city, notes)
  values
    (v_user, v_pharmacy, v_subtotal, v_delivery, v_total, p_payment_method,
     'pending', null, p_sender_number, 'pending', p_delivery_name,
     p_delivery_phone, p_delivery_address, p_delivery_city, p_notes)
  returning * into v_order;

  insert into public.order_items
    (order_id, product_id, product_name, unit_price, quantity, line_total)
  select v_order.id, c.product_id, p.name, p.price, c.quantity, p.price * c.quantity
    from public.cart c
    join public.pharmacy_products p on p.id = c.product_id
   where c.user_id = v_user
     and p.status = 'active';

  delete from public.cart where user_id = v_user;

  return v_order;
end;
$$;

-- ---------------------------------------------------------------------
-- expire_stale_appointments — turns past unpaid appointments 'expired'.
--
-- A pending/confirmed appointment whose slot is in the past and that was
-- never paid can never happen; leaving it 'pending' forever lets it squat
-- on the slot (the unique index) and pollutes both dashboards. This runs
-- lazily: a statement-level AFTER trigger fires it on any appointment
-- write, and it is cheap because it touches only stale rows and stops
-- once they are expired (the next invocation matches nothing).
-- ---------------------------------------------------------------------
create or replace function public.expire_stale_appointments()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Re-entrancy guard: this is a FOR EACH STATEMENT trigger, and its own
  -- UPDATE below would otherwise fire the trigger again, recursing until
  -- the stack limit. The transaction-local flag makes the nested call a
  -- no-op. See PART 3.4: payments_apply_verification and friends also
  -- UPDATE appointments, so the guard is what lets them survive.
  if current_setting('appointments.expire_lock', true) is not null then
    return null;
  end if;
  perform set_config('appointments.expire_lock', '1', true);

  update public.appointments
     set status = 'expired'
   where status in ('pending', 'confirmed')
     and payment_status = 'pending'
     and (appointment_date < current_date
          or (appointment_date = current_date
              and appointment_time < localtime));

  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- users_ban_enforce — what happens the moment an admin flips is_active
-- to false: the user's future live appointments are cancelled (paid ones
-- become 'refunded' via appointments_refund_on_cancel) and the user is
-- told. Re-activating sends a notification too.
-- ---------------------------------------------------------------------
create or replace function public.users_ban_enforce()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.is_active is distinct from old.is_active then
    if not new.is_active then
      update public.appointments
         set status = 'cancelled'
       where patient_id = new.id
         and status in ('pending', 'confirmed')
         and appointment_date >= current_date;

      perform public.notify(new.id, 'Account suspended',
        'Your account has been suspended. Your pending appointments were cancelled.',
        'system', '/', null);
    else
      perform public.notify(new.id, 'Account reactivated',
        'Your account is active again.',
        'system', '/', null);
    end if;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- my_stats / doctor_stats / admin_dashboard_stats — server-side dashboard
-- tallies.
--
-- The patient and provider dashboards used to fetch whole lists and count
-- in Dart, which downloaded unbounded rows to render a few numbers. These
-- functions return one row each, computed with correlated subqueries (no
-- join fan-out), and the admin panel replaces ~21 serialized count() calls
-- with one select.
-- ---------------------------------------------------------------------
create or replace function public.my_stats()
returns table (
  appointments_total     bigint,
  appointments_pending   bigint,
  appointments_confirmed bigint,
  appointments_completed bigint,
  appointments_cancelled bigint,
  unpaid_appointments    bigint,
  payments_verified      bigint,
  orders_total           bigint
)
language sql
security definer
set search_path = ''
as $$
  select
    (select count(*) from public.appointments a where a.patient_id = u.id)::bigint,
    (select count(*) from public.appointments a where a.patient_id = u.id and a.status = 'pending')::bigint,
    (select count(*) from public.appointments a where a.patient_id = u.id and a.status = 'confirmed')::bigint,
    (select count(*) from public.appointments a where a.patient_id = u.id and a.status = 'completed')::bigint,
    (select count(*) from public.appointments a where a.patient_id = u.id and a.status = 'cancelled')::bigint,
    (select count(*) from public.appointments a
       where a.patient_id = u.id and a.status <> 'cancelled'
         and a.payment_status = 'pending')::bigint,
    (select count(*) from public.payments p where p.user_id = u.id and p.payment_status = 'verified')::bigint,
    (select count(*) from public.orders o where o.user_id = u.id)::bigint
  from public.users u
  where u.id = (select auth.uid());
$$;

create or replace function public.doctor_stats()
returns table (
  appointments_total     bigint,
  appointments_pending   bigint,
  appointments_confirmed bigint,
  appointments_completed bigint,
  appointments_cancelled bigint,
  payments_pending       bigint,
  payments_verified      bigint,
  revenue                numeric(12,2)
)
language sql
security definer
set search_path = ''
as $$
  select
    (select count(*) from public.appointments a where a.doctor_id = d.id)::bigint,
    (select count(*) from public.appointments a where a.doctor_id = d.id and a.status = 'pending')::bigint,
    (select count(*) from public.appointments a where a.doctor_id = d.id and a.status = 'confirmed')::bigint,
    (select count(*) from public.appointments a where a.doctor_id = d.id and a.status = 'completed')::bigint,
    (select count(*) from public.appointments a where a.doctor_id = d.id and a.status = 'cancelled')::bigint,
    (select count(*) from public.payments p join public.appointments a on a.id = p.appointment_id where a.doctor_id = d.id and p.payment_status = 'pending')::bigint,
    (select count(*) from public.payments p join public.appointments a on a.id = p.appointment_id where a.doctor_id = d.id and p.payment_status = 'verified')::bigint,
    (select coalesce(sum(a.fee), 0) from public.appointments a where a.doctor_id = d.id and a.payment_status = 'paid')::numeric(12,2)
  from public.doctors d
  where d.user_id = (select auth.uid());
$$;

create or replace view public.admin_dashboard_stats
with (security_invoker = on) as
select
  (select count(*) from public.users)::bigint as total_users,
  (select count(*) from public.users where role = 'patient')::bigint as total_patients,
  (select count(*) from public.users where role = 'doctor')::bigint as total_doctors,
  (select count(*) from public.doctors)::bigint as total_doctors_rows,
  (select count(*) from public.hospitals)::bigint as total_hospitals,
  (select count(*) from public.clinics)::bigint as total_clinics,
  (select count(*) from public.pharmacies)::bigint as total_pharmacies,
  (select count(*) from public.blood_banks)::bigint as total_blood_banks,
  (select count(*) from public.doctors where verification_status = 'pending')::bigint as pending_doctors,
  (select count(*) from public.hospitals where verification_status = 'pending')::bigint as pending_hospitals,
  (select count(*) from public.clinics where verification_status = 'pending')::bigint as pending_clinics,
  (select count(*) from public.pharmacies where verification_status = 'pending')::bigint as pending_pharmacies,
  (select count(*) from public.appointments)::bigint as total_appointments,
  (select count(*) from public.appointments where status = 'pending')::bigint as appointments_pending,
  (select count(*) from public.appointments where status = 'confirmed')::bigint as appointments_confirmed,
  (select count(*) from public.appointments where status = 'completed')::bigint as appointments_completed,
  (select count(*) from public.payments where payment_status = 'verified')::bigint as payments_verified,
  (select count(*) from public.payments where payment_status = 'pending')::bigint as payments_pending,
  (select coalesce(sum(a.fee), 0) from public.appointments a where a.payment_status = 'paid')::numeric(12,2) as revenue,
  (select count(*) from public.orders)::bigint as total_orders,
  (select count(*) from public.reviews where status = 'pending')::bigint as pending_reviews,
  (select count(*) from public.feedback where status = 'new')::bigint as pending_feedback,
  (select count(*) from public.blood_requests where status = 'active')::bigint as active_blood_requests,
  (select count(*) from public.app_audit_log)::bigint as audit_logs,
  (select count(*) from public.audit_log)::bigint as db_audit_logs;

comment on view public.admin_dashboard_stats is
  'One-row admin overview. security_invoker, and RLS on the view itself restricts it to admins.';

-- =====================================================================
-- PART 3 — TRIGGERS
-- =====================================================================

-- ---------------------------------------------------------------------
-- 3.1 updated_at — every table that had ON UPDATE current_timestamp().
-- ---------------------------------------------------------------------
create trigger users_set_updated_at             before update on public.users             for each row execute function public.set_updated_at();
create trigger doctors_set_updated_at           before update on public.doctors           for each row execute function public.set_updated_at();
create trigger hospitals_set_updated_at         before update on public.hospitals         for each row execute function public.set_updated_at();
create trigger clinics_set_updated_at           before update on public.clinics           for each row execute function public.set_updated_at();
create trigger pharmacies_set_updated_at        before update on public.pharmacies        for each row execute function public.set_updated_at();
create trigger appointments_set_updated_at      before update on public.appointments      for each row execute function public.set_updated_at();
create trigger payments_set_updated_at          before update on public.payments          for each row execute function public.set_updated_at();
create trigger pharmacy_products_set_updated_at before update on public.pharmacy_products for each row execute function public.set_updated_at();
create trigger cart_set_updated_at              before update on public.cart              for each row execute function public.set_updated_at();
create trigger orders_set_updated_at            before update on public.orders            for each row execute function public.set_updated_at();
create trigger reviews_set_updated_at           before update on public.reviews           for each row execute function public.set_updated_at();
create trigger blood_banks_set_updated_at       before update on public.blood_banks       for each row execute function public.set_updated_at();
create trigger blood_donors_set_updated_at      before update on public.blood_donors      for each row execute function public.set_updated_at();
create trigger blood_requests_set_updated_at    before update on public.blood_requests    for each row execute function public.set_updated_at();
create trigger feedback_set_updated_at          before update on public.feedback          for each row execute function public.set_updated_at();
create trigger blogs_set_updated_at             before update on public.blogs             for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- 3.2 audit_log — the 12 tables MySQL audited, same coverage.
-- (appointments, blood_banks, blood_donors, blood_requests, clinics,
--  doctors, feedback, hospitals, payments, pharmacies, reviews, users)
-- ---------------------------------------------------------------------
create trigger appointments_audit   after insert or update or delete on public.appointments   for each row execute function public.audit_row_change();
create trigger blood_banks_audit    after insert or update or delete on public.blood_banks    for each row execute function public.audit_row_change();
create trigger blood_donors_audit   after insert or update or delete on public.blood_donors   for each row execute function public.audit_row_change();
create trigger blood_requests_audit after insert or update or delete on public.blood_requests for each row execute function public.audit_row_change();
create trigger clinics_audit        after insert or update or delete on public.clinics        for each row execute function public.audit_row_change();
create trigger doctors_audit        after insert or update or delete on public.doctors        for each row execute function public.audit_row_change();
create trigger feedback_audit       after insert or update or delete on public.feedback       for each row execute function public.audit_row_change();
create trigger hospitals_audit      after insert or update or delete on public.hospitals      for each row execute function public.audit_row_change();
create trigger payments_audit       after insert or update or delete on public.payments       for each row execute function public.audit_row_change();
create trigger pharmacies_audit     after insert or update or delete on public.pharmacies     for each row execute function public.audit_row_change();
create trigger reviews_audit        after insert or update or delete on public.reviews        for each row execute function public.audit_row_change();
create trigger users_audit          after insert or update or delete on public.users          for each row execute function public.audit_row_change();

-- ---------------------------------------------------------------------
-- 3.3 business logic recovered from PHP
-- ---------------------------------------------------------------------

-- Reject a review aimed at a non-existent entity.
create trigger reviews_check_target_trg
  before insert or update of reviewable_type, reviewable_id on public.reviews
  for each row execute function public.reviews_check_target();

-- Keep doctors/hospitals/clinics/pharmacies rating + total_reviews true.
create trigger reviews_recalc_rating
  after insert or update or delete on public.reviews
  for each row execute function public.recalc_reviewable_rating();

-- Issue a confirmation code the moment an appointment is confirmed.
create trigger appointments_confirmation_code
  before insert or update of status on public.appointments
  for each row execute function public.appointments_set_confirmation_code();

-- AYU-000123, with no temporary value ever stored.
create trigger orders_order_number
  before insert on public.orders
  for each row execute function public.orders_set_order_number();

-- Mark a cancelled-but-paid appointment refunded (was appointments.php:603).
-- BEFORE, so it rewrites the row rather than issuing a second UPDATE.
create trigger appointments_refund
  before update of status on public.appointments
  for each row execute function public.appointments_refund_on_cancel();

-- Flip appointments.payment_status to 'paid' on verification.
-- BEFORE UPDATE, and named to sort before payments_notify_trg so the
-- confirmation code it causes to be issued is visible to the notifier.
create trigger payments_apply_verification_trg
  before update of payment_status on public.payments
  for each row execute function public.payments_apply_verification();

-- ---------------------------------------------------------------------
-- 3.3a INSERT integrity guards (the INSERT halves of the column guards)
-- ---------------------------------------------------------------------

-- A self-registered provider row always starts pending/unrated.
create trigger providers_guard_insert
  before insert on public.doctors
  for each row execute function public.guard_provider_insert();

create trigger hospitals_guard_insert
  before insert on public.hospitals
  for each row execute function public.guard_provider_insert();

create trigger clinics_guard_insert
  before insert on public.clinics
  for each row execute function public.guard_provider_insert();

create trigger pharmacies_guard_insert
  before insert on public.pharmacies
  for each row execute function public.guard_provider_insert();

-- Appointment money/status fields are server-forced; slot is validated.
create trigger appointments_guard_insert
  before insert on public.appointments
  for each row execute function public.guard_appointments_insert();

-- Manual payments are re-stamped to the appointment's fee and 'pending'.
create trigger payments_guard_insert
  before insert on public.payments
  for each row execute function public.guard_payments_insert();

-- Reviews start 'pending'; doctor reviews must reference an owned
-- appointment with the reviewed doctor.
create trigger reviews_guard_insert
  before insert on public.reviews
  for each row execute function public.guard_reviews_insert();

-- Orders and their line items exist only via place_order().
create trigger orders_guard_insert
  before insert on public.orders
  for each row execute function public.guard_orders_insert();

create trigger order_items_guard_insert
  before insert on public.order_items
  for each row execute function public.guard_order_items_insert();

-- ---------------------------------------------------------------------
-- 3.3b lifecycle
-- ---------------------------------------------------------------------

-- Suspend: cancel + refund the user's future appointments. Fires on the
-- users row itself, so it cannot be skipped by editing a different table.
create trigger users_ban_enforce_trg
  before update of is_active on public.users
  for each row execute function public.users_ban_enforce();

-- Lazy expiry of past unpaid appointments. Statement-level so one write
-- sweeps the whole table; it stops by itself once nothing is stale.
create trigger appointments_expire_stale_trg
  after insert or update on public.appointments
  for each statement execute function public.expire_stale_appointments();

-- ---------------------------------------------------------------------
-- 3.4 notifications
--
-- These replace the seven PHP INSERT INTO notifications sites. They are
-- AFTER triggers returning NULL: the row is already committed to its
-- table and the notification is a side effect.
--
-- PostgreSQL fires same-event triggers in alphabetical order, which is
-- why payments_apply_verification_trg (a) precedes payments_notify_trg
-- (n) -- the notifier needs the confirmation code the first one issues.
-- ---------------------------------------------------------------------
create trigger appointments_notify_trg
  after insert or update of status on public.appointments
  for each row execute function public.appointments_notify();

create trigger payments_notify_trg
  after insert or update of payment_status on public.payments
  for each row execute function public.payments_notify();

create trigger orders_notify_trg
  after insert on public.orders
  for each row execute function public.orders_notify();

create trigger feedback_notify_trg
  after update of admin_response on public.feedback
  for each row execute function public.feedback_notify();

create trigger doctors_notify_trg
  after update of verification_status, status on public.doctors
  for each row execute function public.providers_notify();

create trigger hospitals_notify_trg
  after update of verification_status, status on public.hospitals
  for each row execute function public.providers_notify();

create trigger clinics_notify_trg
  after update of verification_status, status on public.clinics
  for each row execute function public.providers_notify();

create trigger pharmacies_notify_trg
  after update of verification_status, status on public.pharmacies
  for each row execute function public.providers_notify();

-- ---------------------------------------------------------------------
-- 3.5 auth.users -> public.users
--
-- These live on auth.users, which Supabase owns. Dropping first makes
-- the file re-runnable.
-- ---------------------------------------------------------------------
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

drop trigger if exists on_auth_user_email_changed on auth.users;
create trigger on_auth_user_email_changed
  after update of email on auth.users
  for each row execute function public.handle_user_email_change();

-- =====================================================================
-- PART 4 — VIEWS
--
-- The app's directory screens each need provider rows joined to the
-- owning user (for name/phone/profile_image). These views centralise
-- that join so the Dart layer selects from one relation instead of
-- hand-writing an embed per screen.
--
-- A view runs with the privileges of its caller here (security_invoker
-- = on, PG15+), so RLS on the underlying tables still applies. Without
-- that flag a view would silently bypass RLS — the single most common
-- Supabase security mistake.
-- =====================================================================

create or replace view public.doctor_directory
with (security_invoker = on) as
select d.id,
       d.user_id,
       u.name,
       u.phone,
       -- Exposed because the doctor detail screen shows it, and because the
       -- PHP shaper sent it as `doctor_email`. Reachable only through the
       -- provider-owner SELECT policy on users, which the view honours via
       -- security_invoker.
       u.email,
       u.profile_image,
       d.specialization,
       d.qualifications,
       d.medical_school,
       d.graduation_year,
       d.experience_years,
       d.doctor_type,
       d.hospital_clinic_name,
       d.chamber_address,
       d.city,
       d.area,
       d.consultation_fee,
       d.bio,
       d.rating,
       d.total_reviews,
       d.verification_status,
       d.status,
       d.available_days,
       d.available_from,
       d.available_to,
       d.slot_minutes,
       d.created_at
  from public.doctors d
  join public.users   u on u.id = d.user_id;

comment on view public.doctor_directory is
  'doctors + owning user. Honours RLS via security_invoker.';

-- Unified city/area text search across all four provider kinds, which
-- is what /nearby did in PHP with a four-way UNION.
create or replace view public.provider_search
with (security_invoker = on) as
select 'doctor'::public.reviewable_type as provider_type,
       d.id, u.name, d.city, d.area, d.rating, d.total_reviews,
       u.profile_image as image, d.status, d.verification_status
  from public.doctors d join public.users u on u.id = d.user_id
union all
select 'hospital', h.id, h.name, h.city, h.area, h.rating, h.total_reviews,
       null, h.status, h.verification_status
  from public.hospitals h
union all
select 'clinic', c.id, c.name, c.city, c.area, c.rating, c.total_reviews,
       null, c.status, c.verification_status
  from public.clinics c
union all
select 'pharmacy', p.id, p.name, p.city, p.area, p.rating, p.total_reviews,
       null, p.status, p.verification_status
  from public.pharmacies p;

comment on view public.provider_search is
  'Backs the /nearby city+area search across all provider kinds.';

-- ---------------------------------------------------------------------
-- doctor_specialties — the filter chips on the doctor list.
--
-- Replaces GET /directory/specialties, which ran
--   SELECT specialization, COUNT(*) ... GROUP BY specialization
--   ORDER BY doctor_count DESC, specialization ASC
--
-- This is a view rather than a Dart-side aggregation because Postgrest
-- cannot express GROUP BY. The alternative was to fetch every visible
-- doctor row and count in the client, which downloads the whole
-- directory to render a row of chips and gets the count wrong as soon as
-- pagination truncates the result.
--
-- The visibility filter is duplicated here from the directory policies on
-- purpose: an aggregate must count only the doctors a caller could
-- actually list, otherwise the chip says 12 and the filtered list shows
-- 3.
-- ---------------------------------------------------------------------
create or replace view public.doctor_specialties
with (security_invoker = on) as
select d.specialization                as specialty,
       count(*)::integer               as doctor_count
  from public.doctors d
 where d.status = 'active'
   and d.verification_status = 'verified'
   and not d.is_deleted
   and d.specialization is not null
   and d.specialization <> ''
 group by d.specialization;

comment on view public.doctor_specialties is
  'specialization + doctor_count for the directory filter chips. Ordering is applied by the caller.';

-- =====================================================================
-- PART 5 — GRANTS
--
-- RLS decides row visibility; grants decide whether the role may reach
-- the table at all. Both are needed.
-- =====================================================================

grant usage on schema public to anon, authenticated;

-- Public, read-only surfaces for a signed-out visitor.
grant select on public.doctors           to anon, authenticated;
grant select on public.hospitals         to anon, authenticated;
grant select on public.clinics           to anon, authenticated;
grant select on public.pharmacies        to anon, authenticated;
grant select on public.pharmacy_products to anon, authenticated;
grant select on public.blood_banks       to anon, authenticated;
grant select on public.blood_donors      to anon, authenticated;
grant select on public.blood_requests    to anon, authenticated;
grant select on public.blogs             to anon, authenticated;
grant select on public.reviews           to anon, authenticated;
grant select on public.users             to anon, authenticated;
grant select on public.doctor_directory   to anon, authenticated;
grant select on public.provider_search    to anon, authenticated;
grant select on public.doctor_specialties to anon, authenticated;
-- Public by design: GET /emergency/hotlines required no token in the PHP.
grant select on public.emergency_hotlines to anon, authenticated;

-- RPC entry points the Flutter client calls.
grant execute on function public.appointments_book(bigint, date, time, public.appointment_type, text, text) to authenticated;
grant execute on function public.place_order(text, text, text, text, public.payment_method, text, text) to authenticated;
grant execute on function public.expire_stale_appointments() to authenticated;
grant execute on function public.my_stats()       to authenticated;
grant execute on function public.doctor_stats()   to authenticated;

-- One-row admin overview; RLS on the view itself is added in
-- rls_policies.sql.
grant select on public.admin_dashboard_stats to authenticated;

-- payment_sessions: the client reads its own sessions. Creation and
-- advancement are service-role-only (the SSLCommerz Edge Functions), so
-- there is no INSERT or UPDATE grant.
grant select on public.payment_sessions to authenticated;

-- Guests may post a blood request or feedback, as the PHP allowed.
grant insert on public.blood_requests to anon;
grant insert on public.feedback       to anon;
grant insert on public.blood_donors   to anon;
-- POST /emergency/sms took optional auth (patient.php:246). An emergency
-- must not require a login.
grant insert on public.emergency_sms  to anon;

grant select, insert, update, delete on public.users             to authenticated;
grant select, insert, update, delete on public.doctors           to authenticated;
grant select, insert, update, delete on public.hospitals         to authenticated;
grant select, insert, update, delete on public.clinics           to authenticated;
grant select, insert, update, delete on public.pharmacies        to authenticated;
grant select, insert, update, delete on public.appointments      to authenticated;
grant select, insert, update, delete on public.payments          to authenticated;
grant select, insert, update, delete on public.pharmacy_products to authenticated;
grant select, insert, update, delete on public.cart              to authenticated;
grant select, insert, update, delete on public.orders            to authenticated;
grant select, insert, update, delete on public.order_items       to authenticated;
grant select, insert, update, delete on public.reviews           to authenticated;
grant select, insert, update, delete on public.blood_banks       to authenticated;
grant select, insert, update, delete on public.blood_donors      to authenticated;
grant select, insert, update, delete on public.blood_requests    to authenticated;
-- No INSERT: notifications are written only by the trigger functions in
-- PART 3.4, never by a client. The app reads them and marks them read.
grant select, update                 on public.notifications     to authenticated;
grant select, insert, update, delete on public.device_tokens     to authenticated;
grant select, insert, update, delete on public.feedback          to authenticated;
grant select, insert, update, delete on public.blogs             to authenticated;
grant select, insert, update, delete on public.emergency_hotlines to authenticated;
grant select, insert                 on public.emergency_sms     to authenticated;
grant select, insert                 on public.app_audit_log     to authenticated;

-- audit_log is trigger-written and admin-read. Nobody gets INSERT:
-- audit_row_change() is SECURITY DEFINER and does not need it.
grant select on public.audit_log to authenticated;

-- =====================================================================
-- END OF STRUCTURE
--
-- No INSERT statement appears anywhere above. Every table is empty.
-- Next: rls_policies.sql, then storage_setup.sql.
-- =====================================================================
