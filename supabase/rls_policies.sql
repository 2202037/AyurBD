-- =====================================================================
-- AYUR — rls_policies.sql
-- Row Level Security for all 23 tables. Run AFTER schema.sql.
-- =====================================================================
--
-- STRUCTURE ONLY. No INSERT statement, no data.
--
-- ---------------------------------------------------------------------
-- HOW THE OLD RULES BECOME POLICIES
--
-- The PHP enforced access in application code: every endpoint called
-- require_auth() / require_role() and then hand-wrote a WHERE clause
-- (`WHERE user_id = ?`). One forgotten clause was a data leak, and the
-- database itself had no opinion.
--
-- These policies restate those same rules where they cannot be skipped.
-- The Flutter client now talks to PostgREST directly, so this file is the
-- only thing standing between one patient and another patient's rows.
-- Any query the Dart layer sends is filtered here regardless of what the
-- Dart layer intended.
--
-- ---------------------------------------------------------------------
-- CONVENTIONS
--
-- * Policies are per-command (select / insert / update / delete), never
--   `for all`. `for all` hides which command a clause was written for and
--   makes an accidental write-path widening easy to miss in review.
-- * Every policy names its role explicitly (`to anon`, `to authenticated`).
--   Omitting the role means PUBLIC, which includes anon.
-- * Role checks go through the STABLE SECURITY DEFINER helpers from
--   schema.sql (is_admin(), current_user_role(), current_doctor_id(),
--   current_pharmacy_id()). A policy on `users` that itself selected from
--   `users` would recurse; a SECURITY DEFINER helper does not.
-- * `(select auth.uid())` rather than bare `auth.uid()`: wrapping it in a
--   scalar subquery lets the planner evaluate it once per statement
--   instead of once per row. On a 10k-row table that is the difference
--   between an index scan and a sequential scan.
-- * Admin gets a separate permissive policy per table rather than being
--   folded into every other policy's USING clause. Policies are OR-ed, so
--   this is equivalent and far easier to audit.
--
-- ---------------------------------------------------------------------
-- WHAT IS DELIBERATELY PUBLIC
--
-- The PHP served these routes without a token, and the app's pre-login
-- screens depend on them:
--     directory (doctors/hospitals/clinics/pharmacies), products, blog,
--     blood bank inventory + donors + requests, emergency hotlines,
--     approved reviews.
-- Making them auth-only would blank the home screen for a signed-out
-- visitor, so `anon` keeps SELECT on exactly those, and nothing else.
-- =====================================================================

-- =====================================================================
-- PART 0 — ENABLE RLS
--
-- Enabling with no policy denies everything, which is the correct
-- starting point: each table below then opens only what it must.
-- =====================================================================

alter table public.users              enable row level security;
alter table public.doctors            enable row level security;
alter table public.hospitals          enable row level security;
alter table public.clinics            enable row level security;
alter table public.pharmacies         enable row level security;
alter table public.appointments       enable row level security;
alter table public.payments           enable row level security;
alter table public.payment_sessions   enable row level security;
alter table public.pharmacy_products  enable row level security;
alter table public.cart               enable row level security;
alter table public.orders             enable row level security;
alter table public.order_items        enable row level security;
alter table public.provider_payouts   enable row level security;
alter table public.reviews            enable row level security;
alter table public.blood_banks        enable row level security;
alter table public.blood_donors       enable row level security;
alter table public.blood_requests     enable row level security;
alter table public.notifications      enable row level security;
alter table public.device_tokens      enable row level security;
alter table public.feedback           enable row level security;
alter table public.blogs              enable row level security;
alter table public.emergency_hotlines enable row level security;
alter table public.emergency_sms      enable row level security;
alter table public.audit_log          enable row level security;
alter table public.app_audit_log      enable row level security;

-- =====================================================================
-- PART 1 — COLUMN GUARDS
--
-- RLS decides which ROWS you may write. It cannot say "you may update
-- this row but not that column of it", and a WITH CHECK clause cannot see
-- the old value, so it cannot express "unchanged".
--
-- That gap matters here. Without a guard, a patient who may update their
-- own users row may set role = 'admin'; a doctor who may update their own
-- doctors row may set verification_status = 'verified'. Both are one
-- PATCH away and neither is blocked by any policy below.
--
-- One generic trigger closes it.
-- =====================================================================

create or replace function public.guard_admin_only_columns()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_col text;
  v_old jsonb := to_jsonb(old);
  v_new jsonb := to_jsonb(new);
begin
  -- Only client traffic is guarded. The guards are SECURITY DEFINER (they
  -- must read provider/appointment state that RLS would hide from the
  -- caller), so `current_user` is the function owner and always looks like
  -- postgres. The reliable signal is `session_user`: PostgREST connects as
  -- the dedicated `authenticator` role and SET ROLEs to anon/authenticated
  -- per request, so app traffic (anon or signed-in) always sees
  -- session_user = 'authenticator', while postgres / cli_login_postgres /
  -- service_role internal writes see anything else. This is the check that
  -- keeps the guard from breaking the very logic it protects.
  if session_user <> 'authenticator' then
    return new;
  end if;

  if public.is_admin() then
    return new;
  end if;

  foreach v_col in array tg_argv loop
    if v_new -> v_col is distinct from v_old -> v_col then
      raise exception
        'column %.% may only be changed by an administrator',
        tg_table_name, v_col
        using errcode = '42501';
    end if;
  end loop;

  return new;
end;
$$;

comment on function public.guard_admin_only_columns() is
  'Trigger. Rejects a client UPDATE that changes any column named in TG_ARGV unless the caller is an admin. Complements RLS, which cannot express column-level immutability.';

-- NAMING: these are deliberately prefixed `aa_` so they fire FIRST.
-- PostgreSQL runs same-event triggers in alphabetical order, and several
-- BEFORE UPDATE triggers from schema.sql legitimately rewrite guarded
-- columns (appointments_refund sets payment_status; the confirmation-code
-- trigger sets confirmation_code). Firing first means the guard compares
-- against what the CLIENT actually submitted, before any internal trigger
-- has touched the row -- otherwise it would reject the app's own logic.

create trigger aa_guard_users
  before update on public.users
  for each row execute function public.guard_admin_only_columns('role', 'email', 'is_active');

create trigger aa_guard_doctors
  before update on public.doctors
  for each row execute function
    public.guard_admin_only_columns('verification_status', 'status', 'rating', 'total_reviews', 'rejection_reason', 'is_deleted', 'commission_percentage');

create trigger aa_guard_hospitals
  before update on public.hospitals
  for each row execute function
    public.guard_admin_only_columns('verification_status', 'status', 'rating', 'total_reviews', 'rejection_reason', 'is_deleted', 'commission_percentage');

create trigger aa_guard_clinics
  before update on public.clinics
  for each row execute function
    public.guard_admin_only_columns('verification_status', 'status', 'rating', 'total_reviews', 'rejection_reason', 'is_deleted', 'commission_percentage');

create trigger aa_guard_pharmacies
  before update on public.pharmacies
  for each row execute function
    public.guard_admin_only_columns('verification_status', 'status', 'rating', 'total_reviews', 'rejection_reason', 'is_deleted', 'commission_percentage');

-- payment_status here is the money-bearing column. It may only move via
-- payments_apply_verification (a doctor verifying) or appointments_refund
-- (a cancellation) -- never by a direct client write.
create trigger aa_guard_appointments
  before update on public.appointments
  for each row execute function public.guard_admin_only_columns(
    'payment_status', 'payment_verified_at', 'payment_verified_by', 'fee');

create trigger aa_guard_reviews
  before update on public.reviews
  for each row execute function public.guard_admin_only_columns('status');

create trigger aa_guard_feedback
  before update on public.feedback
  for each row execute function
    public.guard_admin_only_columns('admin_response', 'status', 'priority');

create trigger aa_guard_orders
  before update on public.orders
  for each row execute function
    public.guard_admin_only_columns('order_number', 'subtotal', 'delivery_fee', 'total',
      'payment_status', 'admin_share', 'provider_share');

-- =====================================================================
-- PART 2 — users
--
-- PRIVACY NOTE, and the reason this table's policies are the longest in
-- the file. `grant select on public.users to anon` looks harmless because
-- the directory needs a doctor's name and photo. But users also holds
-- email, phone, address and blood_group for every PATIENT. A blanket
-- read policy would publish the entire patient roster to anyone holding
-- the anon key -- which ships inside the app binary and is therefore
-- public by construction.
--
-- So SELECT is scoped to rows there is a reason to see:
--     anon           -> only users who own a publicly-listed provider row
--     authenticated  -> the above, plus yourself, plus the counterparties
--                       of your own appointments
--     admin          -> everything
-- =====================================================================

-- A user who owns a provider row that the public directory already shows.
-- Their name and photo are part of that listing.
create policy users_select_public_providers
  on public.users for select to anon, authenticated
  using (
    exists (
      select 1 from public.doctors d
       where d.user_id = users.id
         and d.status = 'active' and d.verification_status = 'verified'
    )
    or exists (
      select 1 from public.hospitals h
       where h.user_id = users.id
         and h.status = 'active' and h.verification_status = 'verified'
    )
    or exists (
      select 1 from public.clinics c
       where c.user_id = users.id
         and c.status = 'active' and c.verification_status = 'verified'
    )
    or exists (
      select 1 from public.pharmacies p
       where p.user_id = users.id
         and p.status = 'active' and p.verification_status = 'verified'
    )
  );

create policy users_select_self
  on public.users for select to authenticated
  using (id = (select auth.uid()));

-- A doctor must see the patients on their own appointment list, and a
-- patient must see the doctor they booked. Scoped to the appointment
-- relationship, so it reveals nothing about unrelated users.
create policy users_select_appointment_counterparty
  on public.users for select to authenticated
  using (
    exists (
      select 1
        from public.appointments a
        join public.doctors d on d.id = a.doctor_id
       where (a.patient_id = users.id and d.user_id = (select auth.uid()))
          or (d.user_id    = users.id and a.patient_id = (select auth.uid()))
    )
  );

create policy users_select_admin
  on public.users for select to authenticated
  using (public.is_admin());

-- No INSERT policy by design. Profile rows are created only by
-- handle_new_user() when auth.users gains a row. A client that could
-- INSERT here could mint a profile for a uuid it does not own.

create policy users_update_self
  on public.users for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

create policy users_update_admin
  on public.users for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Deleting the profile is not the way to delete an account: auth.users is
-- the parent and cascades down. Admin-only, matching /admin/users/delete.
create policy users_delete_admin
  on public.users for delete to authenticated
  using (public.is_admin());

-- =====================================================================
-- PART 3 — providers: doctors, hospitals, clinics, pharmacies
--
-- Same shape four times: public sees active+verified rows, the owner sees
-- and edits their own row whatever its state (otherwise a pending
-- provider could not fill in their profile to get verified), admin sees
-- and edits all. verification_status / status / rating / total_reviews are
-- blocked from owner edits by the PART 1 guards.
-- =====================================================================

-- -- doctors ----------------------------------------------------------
create policy doctors_select_public
  on public.doctors for select to anon, authenticated
  using (status = 'active' and verification_status = 'verified' and not is_deleted);

create policy doctors_select_own
  on public.doctors for select to authenticated
  using (user_id = (select auth.uid()));

create policy doctors_select_admin
  on public.doctors for select to authenticated
  using (public.is_admin());

create policy doctors_insert_own
  on public.doctors for insert to authenticated
  with check (user_id = (select auth.uid()));

create policy doctors_update_own
  on public.doctors for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy doctors_update_admin
  on public.doctors for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy doctors_delete_admin
  on public.doctors for delete to authenticated
  using (public.is_admin());

-- -- hospitals --------------------------------------------------------
create policy hospitals_select_public
  on public.hospitals for select to anon, authenticated
  using (status = 'active' and verification_status = 'verified' and not is_deleted);

create policy hospitals_select_own
  on public.hospitals for select to authenticated
  using (user_id = (select auth.uid()));

create policy hospitals_select_admin
  on public.hospitals for select to authenticated
  using (public.is_admin());

create policy hospitals_insert_own
  on public.hospitals for insert to authenticated
  with check (user_id = (select auth.uid()));

create policy hospitals_update_own
  on public.hospitals for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy hospitals_update_admin
  on public.hospitals for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy hospitals_delete_admin
  on public.hospitals for delete to authenticated
  using (public.is_admin());

-- -- clinics ----------------------------------------------------------
create policy clinics_select_public
  on public.clinics for select to anon, authenticated
  using (status = 'active' and verification_status = 'verified' and not is_deleted);

create policy clinics_select_own
  on public.clinics for select to authenticated
  using (user_id = (select auth.uid()));

create policy clinics_select_admin
  on public.clinics for select to authenticated
  using (public.is_admin());

create policy clinics_insert_own
  on public.clinics for insert to authenticated
  with check (user_id = (select auth.uid()));

create policy clinics_update_own
  on public.clinics for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy clinics_update_admin
  on public.clinics for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy clinics_delete_admin
  on public.clinics for delete to authenticated
  using (public.is_admin());

-- -- pharmacies -------------------------------------------------------
create policy pharmacies_select_public
  on public.pharmacies for select to anon, authenticated
  using (status = 'active' and verification_status = 'verified' and not is_deleted);

create policy pharmacies_select_own
  on public.pharmacies for select to authenticated
  using (user_id = (select auth.uid()));

create policy pharmacies_select_admin
  on public.pharmacies for select to authenticated
  using (public.is_admin());

create policy pharmacies_insert_own
  on public.pharmacies for insert to authenticated
  with check (user_id = (select auth.uid()));

create policy pharmacies_update_own
  on public.pharmacies for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy pharmacies_update_admin
  on public.pharmacies for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy pharmacies_delete_admin
  on public.pharmacies for delete to authenticated
  using (public.is_admin());

-- =====================================================================
-- PART 4 — appointments and payments
--
-- Two parties per row: the patient (appointments.patient_id) and the
-- doctor (via doctors.user_id). Both must see it; the PHP checked this by
-- hand at appointments.php:570-577, which is the logic restated here.
-- =====================================================================

create policy appointments_select_patient
  on public.appointments for select to authenticated
  using (patient_id = (select auth.uid()));

create policy appointments_select_doctor
  on public.appointments for select to authenticated
  using (doctor_id = public.current_doctor_id());

create policy appointments_select_admin
  on public.appointments for select to authenticated
  using (public.is_admin());

-- A patient books for themselves. Booking on someone else's behalf was
-- never possible in the app and is not possible here.
create policy appointments_insert_patient
  on public.appointments for insert to authenticated
  with check (patient_id = (select auth.uid()));

-- The patient may cancel and edit symptoms/notes. The money columns are
-- held shut by aa_guard_appointments, so this cannot become "mark paid".
create policy appointments_update_patient
  on public.appointments for update to authenticated
  using (patient_id = (select auth.uid()))
  with check (patient_id = (select auth.uid()));

-- The doctor moves status (confirm / complete / cancel) and writes notes.
create policy appointments_update_doctor
  on public.appointments for update to authenticated
  using (doctor_id = public.current_doctor_id())
  with check (doctor_id = public.current_doctor_id());

create policy appointments_update_admin
  on public.appointments for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Cancellation is a status change, not a delete: an appointment is a
-- financial and clinical record. Only admin may actually remove one.
create policy appointments_delete_admin
  on public.appointments for delete to authenticated
  using (public.is_admin());

-- -- payments ---------------------------------------------------------
create policy payments_select_own
  on public.payments for select to authenticated
  using (user_id = (select auth.uid()));

-- The doctor sees payments for their own appointments -- this is what
-- /provider/doctor/payments listed.
create policy payments_select_doctor
  on public.payments for select to authenticated
  using (
    exists (
      select 1 from public.appointments a
       where a.id = payments.appointment_id
         and a.doctor_id = public.current_doctor_id()
    )
  );

create policy payments_select_admin
  on public.payments for select to authenticated
  using (public.is_admin());

-- The patient submits their own payment, and only against their own
-- appointment. Without the second clause a user could attach a payment to
-- a stranger's appointment.
create policy payments_insert_own
  on public.payments for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.appointments a
       where a.id = payments.appointment_id
         and a.patient_id = (select auth.uid())
    )
  );

-- Verification is the ADMIN's action. The patient pays the platform's
-- account and the admin confirms it against the platform's own statement,
-- so the patient gets no UPDATE at all (a submitted payment is evidence),
-- and the doctor — whose dashboard is now read-only for payments — cannot
-- move it either. Only the admin may change payment_status.
create policy payments_update_admin
  on public.payments for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy payments_delete_admin
  on public.payments for delete to authenticated
  using (public.is_admin());

-- -- provider_payouts ------------------------------------------------
-- The ledger of what the platform owes each provider. Readable by the
-- provider it belongs to (their dashboard's "pending payout" balance) and
-- by the admin; only the admin may mark a payout paid (the offline
-- transfer). Nothing ever inserts a row through RLS: payouts are written
-- only by the SECURITY DEFINER verification triggers.
create policy provider_payouts_select_own
  on public.provider_payouts for select to authenticated
  using (provider_user_id = (select auth.uid()));

create policy provider_payouts_select_admin
  on public.provider_payouts for select to authenticated
  using (public.is_admin());

create policy provider_payouts_update_admin
  on public.provider_payouts for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- -- payment_sessions --------------------------------------------------
-- Client reads its own gateway attempts. There is no INSERT and no UPDATE
-- policy: sessions are created and advanced only by the SSLCommerz Edge
-- Functions as service role, which bypasses RLS. Allowing a client to
-- UPDATE its own session would let it self-confirm an attempt it never
-- paid for.
create policy payment_sessions_select_own
  on public.payment_sessions for select to authenticated
  using (user_id = (select auth.uid()));

-- =====================================================================
-- PART 5 — pharmacy: products, cart, orders, order_items
-- =====================================================================

create policy products_select_public
  on public.pharmacy_products for select to anon, authenticated
  using (status = 'active');

-- The owning pharmacy sees its out-of-stock and inactive lines too.
create policy products_select_owner
  on public.pharmacy_products for select to authenticated
  using (pharmacy_id = public.current_pharmacy_id());

create policy products_select_admin
  on public.pharmacy_products for select to authenticated
  using (public.is_admin());

create policy products_insert_owner
  on public.pharmacy_products for insert to authenticated
  with check (pharmacy_id = public.current_pharmacy_id());

create policy products_update_owner
  on public.pharmacy_products for update to authenticated
  using (pharmacy_id = public.current_pharmacy_id())
  with check (pharmacy_id = public.current_pharmacy_id());

create policy products_delete_owner
  on public.pharmacy_products for delete to authenticated
  using (pharmacy_id = public.current_pharmacy_id());

create policy products_admin_all_update
  on public.pharmacy_products for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy products_admin_all_delete
  on public.pharmacy_products for delete to authenticated
  using (public.is_admin());

-- -- cart: strictly private, no admin visibility. Nobody has a reason to
-- -- read another person's basket, so no policy grants it.
create policy cart_select_own
  on public.cart for select to authenticated
  using (user_id = (select auth.uid()));

create policy cart_insert_own
  on public.cart for insert to authenticated
  with check (user_id = (select auth.uid()));

create policy cart_update_own
  on public.cart for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy cart_delete_own
  on public.cart for delete to authenticated
  using (user_id = (select auth.uid()));

-- -- orders ------------------------------------------------------------
create policy orders_select_own
  on public.orders for select to authenticated
  using (user_id = (select auth.uid()));

-- The pharmacy fulfilling the order needs to see it.
create policy orders_select_pharmacy
  on public.orders for select to authenticated
  using (pharmacy_id = public.current_pharmacy_id());

create policy orders_select_admin
  on public.orders for select to authenticated
  using (public.is_admin());

create policy orders_insert_own
  on public.orders for insert to authenticated
  with check (user_id = (select auth.uid()));

-- The customer may cancel and edit delivery details; totals, order_number
-- and payment_status (the money columns) are frozen by aa_guard_orders —
-- payment may only be marked 'paid' by the admin's verification UPDATE.
create policy orders_update_own
  on public.orders for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- The pharmacy advances fulfilment status.
create policy orders_update_pharmacy
  on public.orders for update to authenticated
  using (pharmacy_id = public.current_pharmacy_id())
  with check (pharmacy_id = public.current_pharmacy_id());

create policy orders_update_admin
  on public.orders for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy orders_delete_admin
  on public.orders for delete to authenticated
  using (public.is_admin());

-- -- order_items: visibility is entirely inherited from the parent order,
-- -- so each policy is an EXISTS against orders, which is itself under RLS.
create policy order_items_select_via_order
  on public.order_items for select to authenticated
  using (
    exists (
      select 1 from public.orders o
       where o.id = order_items.order_id
         and (o.user_id = (select auth.uid())
              or o.pharmacy_id = public.current_pharmacy_id()
              or public.is_admin())
    )
  );

create policy order_items_insert_via_order
  on public.order_items for insert to authenticated
  with check (
    exists (
      select 1 from public.orders o
       where o.id = order_items.order_id
         and o.user_id = (select auth.uid())
    )
  );

-- No UPDATE for anyone but admin: a line item is the historical record of
-- what was bought at what price. Editing it would rewrite an invoice.
create policy order_items_update_admin
  on public.order_items for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy order_items_delete_admin
  on public.order_items for delete to authenticated
  using (public.is_admin());

-- =====================================================================
-- PART 6 — reviews
--
-- Public reads approved reviews only. An author additionally sees their
-- own while it is pending, which is what makes "your review is awaiting
-- moderation" possible in the UI. Moderation is admin-only, held by
-- aa_guard_reviews.
-- =====================================================================

create policy reviews_select_approved
  on public.reviews for select to anon, authenticated
  using (status = 'approved');

create policy reviews_select_own
  on public.reviews for select to authenticated
  using (user_id = (select auth.uid()));

-- The reviewed provider sees pending reviews about themselves -- this is
-- what /provider/reviews served.
create policy reviews_select_target_owner
  on public.reviews for select to authenticated
  using (
    (reviewable_type = 'doctor'   and reviewable_id = public.current_doctor_id())
    or (reviewable_type = 'pharmacy' and reviewable_id = public.current_pharmacy_id())
    or (reviewable_type = 'hospital' and exists (
          select 1 from public.hospitals h
           where h.id = reviews.reviewable_id and h.user_id = (select auth.uid())))
    or (reviewable_type = 'clinic'   and exists (
          select 1 from public.clinics c
           where c.id = reviews.reviewable_id and c.user_id = (select auth.uid())))
  );

create policy reviews_select_admin
  on public.reviews for select to authenticated
  using (public.is_admin());

-- Signed-in only: an anonymous review cannot be moderated or rate-limited
-- and the PHP required a token here too.
create policy reviews_insert_own
  on public.reviews for insert to authenticated
  with check (user_id = (select auth.uid()));

-- The author may edit only while still pending. Once approved the text is
-- public and editing it would bypass moderation.
create policy reviews_update_own_pending
  on public.reviews for update to authenticated
  using (user_id = (select auth.uid()) and status = 'pending')
  with check (user_id = (select auth.uid()));

create policy reviews_update_admin
  on public.reviews for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy reviews_delete_own
  on public.reviews for delete to authenticated
  using (user_id = (select auth.uid()));

create policy reviews_delete_admin
  on public.reviews for delete to authenticated
  using (public.is_admin());

-- =====================================================================
-- PART 7 — blood bank
--
-- The most permissive area in the app, deliberately. Someone looking for
-- blood is in an emergency and the PHP did not require a login. Note that
-- donor rows carry a phone number that is public BY INTENT -- that is the
-- entire point of a donor registry -- and is_available gates it.
-- =====================================================================

create policy blood_banks_select_public
  on public.blood_banks for select to anon, authenticated
  using (status = 'active');

create policy blood_banks_select_admin
  on public.blood_banks for select to authenticated
  using (public.is_admin());

-- Managed from the admin panel only (/admin/blood-banks/save).
create policy blood_banks_insert_admin
  on public.blood_banks for insert to authenticated
  with check (public.is_admin());

create policy blood_banks_update_admin
  on public.blood_banks for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy blood_banks_delete_admin
  on public.blood_banks for delete to authenticated
  using (public.is_admin());

-- -- blood_donors -----------------------------------------------------
create policy donors_select_available
  on public.blood_donors for select to anon, authenticated
  using (is_available);

create policy donors_select_own
  on public.blood_donors for select to authenticated
  using (user_id is not null and user_id = (select auth.uid()));

create policy donors_select_admin
  on public.blood_donors for select to authenticated
  using (public.is_admin());

-- A guest may register as a donor (user_id null), matching the PHP.
create policy donors_insert_guest
  on public.blood_donors for insert to anon
  with check (user_id is null);

-- A signed-in donor registers as themselves or anonymously.
create policy donors_insert_self
  on public.blood_donors for insert to authenticated
  with check (user_id is null or user_id = (select auth.uid()));

create policy donors_update_own
  on public.blood_donors for update to authenticated
  using (user_id is not null and user_id = (select auth.uid()))
  with check (user_id is not null and user_id = (select auth.uid()));

create policy donors_update_admin
  on public.blood_donors for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy donors_delete_own
  on public.blood_donors for delete to authenticated
  using (user_id is not null and user_id = (select auth.uid()));

create policy donors_delete_admin
  on public.blood_donors for delete to authenticated
  using (public.is_admin());

-- -- blood_requests ---------------------------------------------------
-- Public: an active request needs to reach as many donors as possible.
create policy requests_select_active
  on public.blood_requests for select to anon, authenticated
  using (status = 'active');

create policy requests_select_admin
  on public.blood_requests for select to authenticated
  using (public.is_admin());

-- The table has no requester user_id column, so ownership cannot be
-- expressed. Anyone may post -- as in the PHP -- and only an admin may
-- edit or withdraw. Adding an owner column would change the schema, which
-- the "keep names identical" requirement rules out.
create policy requests_insert_anon
  on public.blood_requests for insert to anon
  with check (true);

create policy requests_insert_auth
  on public.blood_requests for insert to authenticated
  with check (true);

create policy requests_update_admin
  on public.blood_requests for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy requests_delete_admin
  on public.blood_requests for delete to authenticated
  using (public.is_admin());

-- =====================================================================
-- PART 8 — notifications and device_tokens
--
-- No INSERT policy on notifications for anyone. Rows arrive only through
-- the SECURITY DEFINER triggers in schema.sql PART 3.4. See conversion
-- note 11 -- this is the table where "the client may write rows addressed
-- to other users" had to stop being true.
-- =====================================================================

create policy notifications_select_own
  on public.notifications for select to authenticated
  using (user_id = (select auth.uid()));

-- Marking read is the only write the app performs here.
create policy notifications_update_own
  on public.notifications for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy notifications_delete_own
  on public.notifications for delete to authenticated
  using (user_id = (select auth.uid()));

-- -- device_tokens: a push token is a device identifier. Strictly owner-
-- -- only, no admin read.
create policy device_tokens_select_own
  on public.device_tokens for select to authenticated
  using (user_id = (select auth.uid()));

create policy device_tokens_insert_own
  on public.device_tokens for insert to authenticated
  with check (user_id = (select auth.uid()));

create policy device_tokens_update_own
  on public.device_tokens for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy device_tokens_delete_own
  on public.device_tokens for delete to authenticated
  using (user_id = (select auth.uid()));

-- =====================================================================
-- PART 9 — feedback, blogs, emergency
-- =====================================================================

-- Feedback is private between its author and the admins. It is never
-- public: it contains complaints naming doctors and hospitals.
create policy feedback_select_own
  on public.feedback for select to authenticated
  using (user_id is not null and user_id = (select auth.uid()));

create policy feedback_select_admin
  on public.feedback for select to authenticated
  using (public.is_admin());

-- A guest may send feedback, as the PHP allowed.
create policy feedback_insert_anon
  on public.feedback for insert to anon
  with check (user_id is null);

create policy feedback_insert_auth
  on public.feedback for insert to authenticated
  with check (user_id is null or user_id = (select auth.uid()));

-- Only admin edits: status, priority and admin_response are the
-- moderation fields, all held by aa_guard_feedback.
create policy feedback_update_admin
  on public.feedback for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy feedback_delete_admin
  on public.feedback for delete to authenticated
  using (public.is_admin());

-- -- blogs -------------------------------------------------------------
create policy blogs_select_published
  on public.blogs for select to anon, authenticated
  using (status = 'published');

-- An author sees their own drafts.
create policy blogs_select_author
  on public.blogs for select to authenticated
  using (author_id is not null and author_id = (select auth.uid()));

create policy blogs_select_admin
  on public.blogs for select to authenticated
  using (public.is_admin());

-- Authoring is an admin function in this app (/admin/blogs/save).
create policy blogs_insert_admin
  on public.blogs for insert to authenticated
  with check (public.is_admin());

create policy blogs_update_admin
  on public.blogs for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy blogs_delete_admin
  on public.blogs for delete to authenticated
  using (public.is_admin());

-- -- emergency_hotlines ------------------------------------------------
-- Public read, no exceptions: someone dialling 999 must not need a token.
create policy hotlines_select_public
  on public.emergency_hotlines for select to anon, authenticated
  using (status = 'active');

create policy hotlines_select_admin
  on public.emergency_hotlines for select to authenticated
  using (public.is_admin());

create policy hotlines_insert_admin
  on public.emergency_hotlines for insert to authenticated
  with check (public.is_admin());

create policy hotlines_update_admin
  on public.emergency_hotlines for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy hotlines_delete_admin
  on public.emergency_hotlines for delete to authenticated
  using (public.is_admin());

-- -- emergency_sms ----------------------------------------------------
-- Write-mostly log. Anyone may file one (an emergency must not require a
-- login), the filer may read their own back, admin reads all.
create policy emergency_sms_insert_anon
  on public.emergency_sms for insert to anon
  with check (user_id is null);

create policy emergency_sms_insert_auth
  on public.emergency_sms for insert to authenticated
  with check (user_id is null or user_id = (select auth.uid()));

create policy emergency_sms_select_own
  on public.emergency_sms for select to authenticated
  using (user_id is not null and user_id = (select auth.uid()));

create policy emergency_sms_select_admin
  on public.emergency_sms for select to authenticated
  using (public.is_admin());

-- No UPDATE or DELETE policy at all: this is an append-only record of
-- emergency requests. Not even admin edits it from the client.

-- =====================================================================
-- PART 10 — audit tables
--
-- Read-only to admins, and to nobody else. There is no INSERT policy on
-- audit_log because only audit_row_change() writes it, as SECURITY
-- DEFINER. app_audit_log does take client writes (the app records its own
-- login/logout events), but a user may only write rows attributed to
-- themselves -- otherwise the audit trail could be forged.
-- =====================================================================

create policy audit_log_select_admin
  on public.audit_log for select to authenticated
  using (public.is_admin());

create policy app_audit_select_own
  on public.app_audit_log for select to authenticated
  using (user_id is not null and user_id = (select auth.uid()));

create policy app_audit_select_admin
  on public.app_audit_log for select to authenticated
  using (public.is_admin());

create policy app_audit_insert_self
  on public.app_audit_log for insert to authenticated
  with check (user_id is null or user_id = (select auth.uid()));

-- No UPDATE/DELETE anywhere on either table. An audit log that can be
-- edited from the client is not an audit log.

-- -- admin_dashboard_stats ----------------------------------------------
-- One-row aggregate of the whole system. A VIEW cannot carry an RLS policy
-- in Postgres (`alter view ... enable row level security` does not exist),
-- so the admin gate lives in a SECURITY DEFINER function instead: it raises
-- for anyone who is not an admin, and direct SELECT on the view itself is
-- revoked from the client roles so the function is the only path.
revoke all on public.admin_dashboard_stats from anon, authenticated;

create or replace function public.admin_dashboard_stats()
returns setof public.admin_dashboard_stats
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;
  return query select * from public.admin_dashboard_stats;
end;
$$;

grant execute on function public.admin_dashboard_stats() to authenticated;

-- =====================================================================
-- PART 11 — VERIFICATION (read-only; run these yourself after applying)
-- =====================================================================
--
-- Every public table must have RLS on. This must return zero rows:
--
--   select tablename
--     from pg_tables
--    where schemaname = 'public' and not rowsecurity;
--
-- Every table with RLS on must have at least one policy, or it is simply
-- unreachable. This must also return zero rows:
--
--   select t.tablename
--     from pg_tables t
--    where t.schemaname = 'public'
--      and t.rowsecurity
--      and not exists (select 1 from pg_policies p
--                       where p.schemaname = 'public'
--                         and p.tablename = t.tablename);
--
-- Both views must be security_invoker, or they bypass every policy above:
--
--   select c.relname, c.reloptions
--     from pg_class c join pg_namespace n on n.oid = c.relnamespace
--    where n.nspname = 'public' and c.relkind = 'v';
--   -- expect {security_invoker=on} on doctor_directory and provider_search
--
-- Spot-check as a real user in the SQL editor:
--
--   set local role authenticated;
--   set local request.jwt.claims = '{"sub":"<some-user-uuid>"}';
--   select count(*) from public.users;   -- must NOT be the whole table
--   select count(*) from public.cart;    -- must be that user's rows only
--   reset role;

