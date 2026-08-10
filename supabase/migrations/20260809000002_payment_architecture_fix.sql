-- =====================================================================
-- 20260809000002_payment_architecture_fix.sql
--
-- The permanent fix for the two reported failures:
--
--   1. "orders must be created through public.place_order()" on checkout
--   2. "Appointment is not awaiting payment" (400) on appointment payment
--
-- Both are symptoms of ONE architectural defect plus a handful of
-- independently broken objects around it. This migration repairs the
-- architecture; it does not silence the errors.
--
-- ---------------------------------------------------------------------
-- ROOT CAUSE (the one defect)
-- ---------------------------------------------------------------------
-- Every write guard needs to answer one question: "is this write coming
-- from a client, or from a trusted server-side path?"
--
--   * schema.sql asked `current_user not in ('authenticated','anon')`.
--     Inside a SECURITY DEFINER function current_user is the OWNER, so
--     the test was always true and every guard was a no-op.
--
--   * 20260806000004_guard_session_user_fix.sql replaced that with
--     `session_user <> 'authenticator'`. That correctly re-armed the
--     guards against direct client traffic -- but it over-fires, because
--     PostgREST connects as `authenticator` and SET ROLEs per request.
--     A SECURITY DEFINER RPC does NOT change session_user, so
--     place_order(), appointments_book(), the payment triggers and the
--     service-role webhook all still look like raw client traffic.
--
--     -> guard_orders_insert raises inside place_order()   => error 1
--     -> guard_appointments_insert re-stamps status:='pending'
--        over the 'pending_payment' appointments_book() wrote => error 2
--     -> guard_admin_only_columns blocks
--        payments_apply_verification's own UPDATE of
--        appointments.payment_status => the webhook could never settle.
--
-- Neither `current_user` nor `session_user` can answer the question:
-- one is destroyed by SECURITY DEFINER, the other is identical for every
-- request that arrives through the API. The discriminator has to be
-- something the trusted path sets DELIBERATELY.
--
-- ---------------------------------------------------------------------
-- THE FIX: an explicit transaction-local trusted-path marker
-- ---------------------------------------------------------------------
-- public.trusted_path_begin() sets a transaction-local GUC
-- (`ayur.trusted_path`) that the guards read. Only the SECURITY DEFINER
-- entry points set it, and EXECUTE on the setter is revoked from anon,
-- authenticated and service_role, so no API caller can set it.
--
-- Why this is safe even if the revoke were bypassed: PostgREST runs each
-- request in its own transaction with a single statement. `set_config(...,
-- true)` is transaction-local, so a client cannot set the marker in one
-- request and piggyback a raw INSERT on it in the next. The same
-- transaction-local trick is already used by expire_stale_appointments()
-- (`appointments.expire_lock`), so this is an established pattern in this
-- schema rather than a new invention.
--
-- Guards are NOT weakened: every guard still raises for real client
-- traffic. What changes is that the trusted path is now correctly
-- recognised instead of being caught in its own net.
--
-- ---------------------------------------------------------------------
-- ALSO FIXED HERE
-- ---------------------------------------------------------------------
--   * INSERT privilege on orders / order_items / appointments / payments
--     is REVOKED from anon+authenticated, so the RPCs are the only way in
--     structurally, not merely by trigger convention.
--   * A real appointment status state machine
--     (public.appointments_guard_transition) with an explicit legal
--     transition table.
--   * place_order() gains an idempotency key, an advisory lock and a
--     duplicate-submission error, so double taps / retries / refreshes
--     cannot mint two orders.
--   * submit_manual_payment() replaces the client's direct INSERT into
--     payments (the last direct write to a money table from Dart).
--   * gateway_payment_begin()/_attach()/_settle() make Stripe checkout
--     idempotent through the existing payment_sessions table.
--   * payments_apply_verification() now fires on INSERT as well as
--     UPDATE, so the webhook's payment row actually settles the booking.
--   * record_payment_split / confirm_appointment / handle_failed_payment /
--     payment_health_check are rewritten (the originals in
--     20260808000001 never applied -- see that file's header).
--   * expire_stale_appointments() sweeps 'pending_payment' too.
--
-- No INSERT statements. No data migration. Structure only.
-- Idempotent: safe to run more than once.
-- =====================================================================


-- =====================================================================
-- PART 1 -- The trusted-path marker
-- =====================================================================

-- Read-only test used by every guard. STABLE, not IMMUTABLE: the marker
-- can change within a transaction.
create or replace function public.trusted_path_active()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(current_setting('ayur.trusted_path', true), '') = '1';
$$;

comment on function public.trusted_path_active() is
  'True while control is inside a trusted server-side entry point (an RPC or trigger that called trusted_path_begin). Transaction-local; cannot survive a request.';

-- Arms the marker and returns the PREVIOUS value so callers can nest.
-- Nesting is real: place_order -> trigger, record_payment_split ->
-- payments_apply_verification -> UPDATE appointments -> more triggers.
create or replace function public.trusted_path_begin()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev text := coalesce(current_setting('ayur.trusted_path', true), '');
begin
  perform set_config('ayur.trusted_path', '1', true);
  return v_prev;
end;
$$;

create or replace function public.trusted_path_end(p_prev text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform set_config('ayur.trusted_path', coalesce(p_prev, ''), true);
end;
$$;

-- Nobody who talks to the API may arm the marker. The default privileges
-- set in 20260806000000_reset_public.sql grant EXECUTE on new functions to
-- anon/authenticated/service_role, so these revokes are mandatory, not
-- decorative.
revoke all on function public.trusted_path_begin()      from public, anon, authenticated, service_role;
revoke all on function public.trusted_path_end(text)    from public, anon, authenticated, service_role;
grant execute on function public.trusted_path_active()  to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- The single question every guard asks.
--
--   1. trusted_path_active()  -- we are inside our own RPC/trigger
--   2. session_user <> 'authenticator' -- psql, a migration, the dashboard
--   3. is_admin()             -- an administrator acting through the API
--
-- Anything else is ordinary client traffic and stays fully guarded.
-- ---------------------------------------------------------------------
create or replace function public.write_is_trusted()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.trusted_path_active()
      or session_user <> 'authenticator'
      or public.is_admin();
$$;

comment on function public.write_is_trusted() is
  'The one discriminator used by every write guard. Replaces the broken current_user / session_user tests: SECURITY DEFINER destroys current_user, and session_user is authenticator for ALL PostgREST traffic including service_role.';

grant execute on function public.write_is_trusted() to anon, authenticated, service_role;


-- =====================================================================
-- PART 2 -- Re-point every guard at write_is_trusted()
--
-- Bodies are otherwise unchanged from their latest versions, so no rule
-- is relaxed. guard_appointments_insert is the one exception and it is
-- called out inline.
-- =====================================================================

create or replace function public.guard_provider_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.write_is_trusted() then
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
-- guard_appointments_insert
--
-- Two changes:
--   1. write_is_trusted() instead of session_user.
--   2. It no longer forces `status := 'pending'`. Forcing the status was
--      what silently destroyed 'pending_payment' and produced error 2.
--      The status a booking starts in is a business decision that belongs
--      to appointments_book(), the only path that may create one. What
--      the guard still does is refuse a client-chosen status: it accepts
--      only the two legal opening states and otherwise falls back to the
--      correct one for the fee. Everything else it stamped -- fee,
--      doctor_name, payment_status, the verification columns -- is
--      stamped exactly as before, so price and payment state are still
--      never client-controlled.
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
  if public.write_is_trusted() then
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

  new.fee                 := v_fee;
  new.doctor_name         := v_name;
  new.payment_status      := 'pending';
  new.payment_verified_at := null;
  new.payment_verified_by := null;

  -- Opening state: a paid consultation must be paid for, a free one is
  -- immediately awaiting the doctor. A client-supplied anything-else is
  -- overwritten rather than trusted.
  if new.status is null
     or new.status not in ('pending', 'pending_payment') then
    new.status := case when coalesce(v_fee, 0) > 0
                       then 'pending_payment'::public.appointment_status
                       else 'pending'::public.appointment_status end;
  end if;
  if coalesce(v_fee, 0) <= 0 then
    new.status := 'pending';
  end if;

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

create or replace function public.guard_payments_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt public.appointments%rowtype;
begin
  if public.write_is_trusted() then
    return new;
  end if;

  -- Reached only if someone still holds INSERT on public.payments, which
  -- PART 3 revokes. Kept as defence in depth.
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
    raise exception 'This appointment is no longer available for payment.'
      using errcode = 'P0001';
  end if;
  if v_appt.payment_status in ('paid', 'refunded') then
    raise exception 'You have already paid for this appointment.'
      using errcode = 'P0001';
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

create or replace function public.guard_reviews_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owned boolean;
begin
  if public.write_is_trusted() then
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

create or replace function public.guard_orders_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.write_is_trusted() then
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
  if public.write_is_trusted() then
    return new;
  end if;
  raise exception 'order items are written only by public.place_order()'
    using errcode = 'P0001';
end;
$$;

-- The comment this function carried in 20260806000002 described exactly
-- the behaviour that 0004 removed: internal trigger paths (notably
-- payments_apply_verification setting appointments.payment_status) must
-- pass through. write_is_trusted() restores that, correctly this time.
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
  if public.write_is_trusted() then
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

create or replace function public.appointments_guard_confirm()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.write_is_trusted() then
    return new;
  end if;

  -- Only the owning doctor may confirm a booking.
  if new.status = 'confirmed'
     and old.status is distinct from 'confirmed'
     and new.doctor_id is distinct from public.current_doctor_id() then
    raise exception 'Only the doctor for this appointment can confirm it.'
      using errcode = '42501';
  end if;

  -- Only the owning doctor may complete a booking.
  if new.status = 'completed'
     and old.status is distinct from 'completed'
     and new.doctor_id is distinct from public.current_doctor_id() then
    raise exception 'Only the doctor for this appointment can complete it.'
      using errcode = '42501';
  end if;

  -- Escrow flow: the doctor confirms only after the patient's payment is
  -- verified. Free consultations have no gate.
  if new.status = 'confirmed'
     and old.status is distinct from 'confirmed'
     and new.fee > 0
     and new.payment_status is distinct from 'paid' then
    raise exception
      'This booking can be confirmed only after the patient payment is '
      'verified. The fee is held by the platform until then.'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

create or replace function public.appointments_guard_reschedule()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.write_is_trusted() then
    return new;
  end if;

  if new.appointment_date is distinct from old.appointment_date
     or new.appointment_time is distinct from old.appointment_time then

    -- An unpaid booking is still moveable; a confirmed/completed/cancelled
    -- one is not. 'pending_payment' joins 'pending' here because it is the
    -- same pre-confirmation state, just with the fee outstanding.
    if old.status not in ('pending', 'pending_payment') then
      raise exception 'Only a pending appointment can be rescheduled.'
        using errcode = 'P0001';
    end if;

    if not exists (
      select 1 from public.available_slots(new.doctor_id, new.appointment_date) s
       where s.slot_time = new.appointment_time
    ) then
      raise exception 'That time slot is not available.'
        using errcode = '23505';
    end if;
  end if;

  return new;
end;
$$;


-- =====================================================================
-- PART 3 -- Structural hardening
--
-- Guards are a behaviour. Privileges are a structure. With INSERT
-- revoked, "orders are created only by place_order()" stops depending on
-- a trigger being correct and starts depending on the grant table.
-- SELECT / UPDATE / DELETE and every RLS policy are untouched.
-- =====================================================================

revoke insert on public.orders       from anon, authenticated;
revoke insert on public.order_items  from anon, authenticated;
revoke insert on public.appointments from anon, authenticated;
revoke insert on public.payments     from anon, authenticated;

comment on table public.orders is
  'Created only by public.place_order(). INSERT is revoked from anon/authenticated; the orders_guard_insert trigger is the second line of defence.';
comment on table public.payments is
  'Created only by public.submit_manual_payment() (patient, manual method) or public.record_payment_split() (gateway webhook). INSERT is revoked from anon/authenticated.';


-- =====================================================================
-- PART 4 -- Columns the payment flow needs
-- =====================================================================

-- Stripe identifiers on payments. `gateway` already exists in the base
-- schema; the drop default undoes 20260808000001's `default 'stripe'`,
-- which would have mislabelled every manual payment had it applied.
alter table public.payments
  add column if not exists stripe_session_id        varchar(100),
  add column if not exists stripe_payment_intent_id varchar(100),
  add column if not exists stripe_customer_id       varchar(100),
  add column if not exists gateway                  varchar(30);

alter table public.payments alter column gateway drop default;

-- Idempotency backstops: one Stripe session and one payment intent can
-- each produce at most one payment row, no matter how many times Stripe
-- redelivers the webhook.
create unique index if not exists uq_payments_stripe_session
  on public.payments (stripe_session_id)
  where stripe_session_id is not null;

create unique index if not exists uq_payments_stripe_pi
  on public.payments (stripe_payment_intent_id)
  where stripe_payment_intent_id is not null;

-- One verified payment per appointment. This is the hard stop against
-- double payment: two concurrent settlements race, one wins, the other
-- gets 23505 -> "You have already paid for this appointment."
--
-- Built inside a DO block on purpose. If the database already holds two
-- verified payments for one booking -- which is precisely the bug this
-- index prevents -- a bare CREATE UNIQUE INDEX would abort the entire
-- migration and leave every other fix unapplied. Instead the duplicates
-- are named loudly and the rest of the migration proceeds; clear them and
-- re-run this file to arm the index.
do $$
declare
  v_dupes text;
begin
  begin
    create unique index if not exists uq_payments_verified_appointment
      on public.payments (appointment_id)
      where payment_status = 'verified';
  exception when unique_violation then
    select string_agg(x.appointment_id::text, ', ' order by x.appointment_id)
      into v_dupes
      from (select appointment_id
              from public.payments
             where payment_status = 'verified'
             group by appointment_id
            having count(*) > 1) x;
    raise warning
      'uq_payments_verified_appointment NOT created: appointments with more than one verified payment: %. Resolve the duplicates, then re-run this migration.',
      coalesce(v_dupes, 'unknown');
  end;
end;
$$;

-- Orders idempotency. The key is supplied by the client per checkout
-- ATTEMPT (not per tap), so a retry after a dropped response returns the
-- original order instead of creating a second one.
alter table public.orders
  add column if not exists idempotency_key varchar(64);

create unique index if not exists uq_orders_idempotency
  on public.orders (user_id, idempotency_key)
  where idempotency_key is not null;

comment on column public.orders.idempotency_key is
  'Client-generated per checkout attempt. Re-running place_order() with the same key returns the existing order instead of creating another.';

-- payment_sessions is already "one live gateway attempt per appointment"
-- (uq_payment_sessions_active_appt). It just needs somewhere to keep the
-- checkout URL so a repeat tap can be handed the SAME Stripe page.
alter table public.payment_sessions
  add column if not exists gateway      varchar(30),
  add column if not exists checkout_url text,
  add column if not exists expires_at   timestamptz;

comment on column public.payment_sessions.checkout_url is
  'The gateway-hosted payment page for this attempt. Re-initialising an appointment returns this URL rather than opening a second session.';
comment on column public.payment_sessions.expires_at is
  'When this attempt stops being reusable. Past it, gateway_payment_begin() retires the row and opens a fresh session.';


-- =====================================================================
-- PART 5 -- The appointment state machine
--
-- Until now "which status may follow which" lived nowhere: it was
-- implied by scattered triggers and by whatever the client happened to
-- PATCH. This makes it explicit and enforces it in the database, for
-- clients AND for our own RPCs.
--
--   book, fee > 0            ->  pending_payment
--   book, fee = 0            ->  pending
--   pending_payment          ->  pending    (manual payment verified;
--                                            provider still must confirm)
--   pending_payment          ->  confirmed  (gateway payment verified)
--   pending_payment          ->  cancelled | expired
--   pending                  ->  confirmed  (owning doctor)
--   pending                  ->  cancelled | expired
--   confirmed                ->  completed  (owning doctor)
--   confirmed                ->  cancelled | expired
--   completed | cancelled
--            | expired       ->  (terminal)
--
-- Actor rules stay where they already were (appointments_guard_confirm
-- for confirm/complete, RLS for ownership). This trigger owns legality
-- only, so the two concerns do not drift apart.
-- =====================================================================

create or replace function public.appointments_guard_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ok boolean;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  -- An administrator and a direct database session may repair anything;
  -- everyone else -- including this application's own RPCs -- obeys the
  -- table. A state machine our own server code can sidestep is not a
  -- state machine.
  if session_user <> 'authenticator' or public.is_admin() then
    return new;
  end if;

  v_ok := case old.status
    when 'pending_payment' then new.status in ('pending', 'confirmed', 'cancelled', 'expired')
    when 'pending'         then new.status in ('confirmed', 'cancelled', 'expired')
    when 'confirmed'       then new.status in ('completed', 'cancelled', 'expired')
    else false
  end;

  if not v_ok then
    raise exception 'This appointment cannot move from % to %.', old.status, new.status
      using errcode = 'P0001',
            detail  = format('appointment %s: illegal status transition', old.id);
  end if;

  -- Cancelling is the only status change a client may make directly, and
  -- only the patient who owns the booking or its doctor may do it.
  if not public.trusted_path_active() then
    if new.status <> 'cancelled' and new.status <> 'confirmed' and new.status <> 'completed' then
      raise exception 'This appointment status is set by the system.'
        using errcode = '42501';
    end if;
    if new.status = 'cancelled'
       and old.patient_id is distinct from (select auth.uid())
       and old.doctor_id  is distinct from public.current_doctor_id() then
      raise exception 'Only the patient or the doctor can cancel this appointment.'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

comment on function public.appointments_guard_transition() is
  'The appointment status state machine. Legality is enforced for clients and for the application''s own RPCs alike; only an administrator or a direct database session may bypass it.';

drop trigger if exists aa_guard_status_transition on public.appointments;
create trigger aa_guard_status_transition
  before update of status on public.appointments
  for each row execute function public.appointments_guard_transition();


-- =====================================================================
-- PART 6 -- Booking: one authoritative creation path
-- =====================================================================

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
  v_prev    text;
  v_fee     numeric(10,2);
  v_appt    public.appointments;
begin
  if v_patient is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.users u where u.id = v_patient and u.is_active) then
    raise exception 'account is not active' using errcode = '42501';
  end if;

  select d.consultation_fee into v_fee
    from public.doctors d
   where d.id = p_doctor_id
     and d.status = 'active'
     and d.verification_status = 'verified'
     and not d.is_deleted;
  if not found then
    raise exception 'this doctor is not accepting appointments'
      using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.available_slots(p_doctor_id, p_appointment_date) s
     where s.slot_time = p_appointment_time
  ) then
    raise exception 'this slot is not available' using errcode = '23505';
  end if;

  v_prev := public.trusted_path_begin();

  -- The opening status is decided HERE and nowhere else. A paid booking
  -- opens in 'pending_payment' -- the single state a payment may start
  -- from -- and a free one opens in 'pending', waiting on the doctor.
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
         case when coalesce(d.consultation_fee, 0) > 0
              then 'pending_payment'::public.appointment_status
              else 'pending'::public.appointment_status end,
         'pending'::public.payment_state
    from public.doctors d
    join public.users u on u.id = d.user_id
   where d.id = p_doctor_id
     and d.status = 'active'
     and d.verification_status = 'verified'
     and not d.is_deleted
  returning * into v_appt;

  perform public.trusted_path_end(v_prev);

  if v_appt.id is null then
    raise exception 'this doctor is not accepting appointments'
      using errcode = '42501';
  end if;

  return v_appt;
end;
$$;


-- =====================================================================
-- PART 7 -- Payability: one predicate, used everywhere
--
-- The Edge Function used to decide payability on its own by comparing
-- status to a hard-coded 'pending_payment'. That is how a client-visible
-- 400 came to depend on a trigger's side effect. Payability is now a
-- database predicate, and the Edge Function asks the database.
--
-- 'pending' is accepted alongside 'pending_payment' on purpose: a
-- booking that is unpaid, unfulfilled and carries a fee IS awaiting
-- payment, and every row created before this migration is in exactly
-- that state. This grandfathers existing bookings without a data
-- migration and without loosening anything -- payment_status = 'pending'
-- and fee > 0 remain required.
-- =====================================================================

create or replace function public.appointment_payability(p_appointment_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  a public.appointments%rowtype;
begin
  select * into a from public.appointments where id = p_appointment_id;

  if not found then
    return jsonb_build_object(
      'payable', false, 'code', 'APPOINTMENT_NOT_FOUND',
      'message', 'This appointment could not be found.');
  end if;

  -- SECURITY DEFINER reads past RLS, so this function has to reimpose the
  -- boundary itself or it becomes an enumeration oracle for other
  -- people's bookings. A stranger gets the same answer as a bad id.
  if not public.write_is_trusted()
     and a.patient_id is distinct from (select auth.uid())
     and a.doctor_id  is distinct from public.current_doctor_id() then
    return jsonb_build_object(
      'payable', false, 'code', 'APPOINTMENT_NOT_FOUND',
      'message', 'This appointment could not be found.');
  end if;

  if a.status in ('cancelled', 'expired') then
    return jsonb_build_object(
      'payable', false, 'code', 'APPOINTMENT_NOT_PAYABLE',
      'status', a.status,
      'message', 'This appointment is no longer available for payment.');
  end if;

  if a.payment_status = 'paid' then
    return jsonb_build_object(
      'payable', false, 'code', 'ALREADY_PAID',
      'status', a.status,
      'message', 'You have already paid for this appointment.');
  end if;

  if a.payment_status = 'refunded' then
    return jsonb_build_object(
      'payable', false, 'code', 'ALREADY_REFUNDED',
      'status', a.status,
      'message', 'This appointment has been refunded and cannot be paid again.');
  end if;

  if coalesce(a.fee, 0) <= 0 then
    return jsonb_build_object(
      'payable', false, 'code', 'NO_FEE',
      'status', a.status,
      'message', 'This appointment has no fee to pay.');
  end if;

  if a.status not in ('pending_payment', 'pending') then
    return jsonb_build_object(
      'payable', false, 'code', 'APPOINTMENT_NOT_PAYABLE',
      'status', a.status,
      'message', 'This appointment is no longer available for payment.');
  end if;

  if exists (select 1 from public.payments p
              where p.appointment_id = a.id and p.payment_status = 'verified') then
    return jsonb_build_object(
      'payable', false, 'code', 'ALREADY_PAID',
      'status', a.status,
      'message', 'You have already paid for this appointment.');
  end if;

  return jsonb_build_object(
    'payable', true, 'code', 'PAYABLE',
    'status', a.status,
    'amount', a.fee,
    'patient_id', a.patient_id,
    'doctor_id', a.doctor_id,
    'doctor_name', a.doctor_name,
    'appointment_date', a.appointment_date,
    'appointment_time', a.appointment_time,
    'message', 'This appointment is awaiting payment.');
end;
$$;

grant execute on function public.appointment_payability(bigint) to authenticated, service_role;

-- Raises the payability failure as a proper error. Used by the write
-- paths so no caller can forget to check.
create or replace function public.assert_appointment_payable(p_appointment_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v jsonb := public.appointment_payability(p_appointment_id);
begin
  if not (v ->> 'payable')::boolean then
    raise exception '%', v ->> 'message'
      using errcode = case when v ->> 'code' = 'APPOINTMENT_NOT_FOUND'
                           then 'PGRST116' else 'P0001' end,
            detail  = v ->> 'code';
  end if;
  return v;
end;
$$;


-- =====================================================================
-- PART 8 -- Manual payment submission (replaces the Dart INSERT)
--
-- appointment_repository.pay() used to INSERT into public.payments
-- directly. That was the last place the client wrote to a money table,
-- and it had no idempotency at all: two taps produced two pending
-- payments for the same booking.
-- =====================================================================

create or replace function public.submit_manual_payment(
  p_appointment_id bigint,
  p_payment_method public.payment_method,
  p_transaction_id text default null,
  p_sender_number  text default null,
  p_notes          text default null
)
returns public.payments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user    uuid := (select auth.uid());
  v_appt    public.appointments%rowtype;
  v_payment public.payments%rowtype;
  v_prev    text;
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.users u where u.id = v_user and u.is_active) then
    raise exception 'account is not active' using errcode = '42501';
  end if;
  if p_payment_method = 'sslcommerz' then
    raise exception 'gateway payments are written only by the payment provider'
      using errcode = '42501';
  end if;

  -- Serialise every concurrent attempt on this appointment. Two taps now
  -- queue instead of racing, and the second one sees the first one's row.
  perform pg_advisory_xact_lock(hashtext('ayur:appointment_payment:' || p_appointment_id::text));

  select * into v_appt from public.appointments where id = p_appointment_id;
  if not found then
    raise exception 'This appointment could not be found.' using errcode = 'PGRST116';
  end if;
  if v_appt.patient_id is distinct from v_user then
    raise exception 'This appointment belongs to another patient.' using errcode = '42501';
  end if;

  -- Idempotency: a submission already awaiting verification is the
  -- answer, not a reason to write a second one.
  select * into v_payment
    from public.payments
   where appointment_id = p_appointment_id
     and user_id        = v_user
     and payment_status = 'pending'
   order by id desc
   limit 1;
  if found then
    return v_payment;
  end if;

  perform public.assert_appointment_payable(p_appointment_id);

  v_prev := public.trusted_path_begin();

  -- amount comes from the appointment, never from the caller.
  insert into public.payments
    (appointment_id, user_id, amount, payment_method, transaction_id,
     sender_number, notes, payment_status, gateway, gateway_transaction_id,
     verified_at, verified_by, rejection_reason)
  values
    (p_appointment_id, v_user, v_appt.fee, p_payment_method,
     nullif(btrim(coalesce(p_transaction_id, '')), ''),
     nullif(btrim(coalesce(p_sender_number, '')), ''),
     nullif(btrim(coalesce(p_notes, '')), ''),
     'pending', null, null, null, null, null)
  returning * into v_payment;

  perform public.trusted_path_end(v_prev);

  return v_payment;
end;
$$;

grant execute on function public.submit_manual_payment(bigint, public.payment_method, text, text, text)
  to authenticated;


-- =====================================================================
-- PART 9 -- Settlement: one function, fired by INSERT and by UPDATE
--
-- payments_apply_verification was wired only to `before update of
-- payment_status`. record_payment_split INSERTs a row that is already
-- 'verified', so the trigger never fired: no split, no payout, the
-- appointment never marked paid, and confirm_appointment then raised
-- "Payment not verified". Same function, now on both events, with an
-- explicit TG_OP test so an UPDATE that merely touches a verified row
-- does not settle it twice.
-- =====================================================================

create or replace function public.payments_apply_verification()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_commission  numeric(5,2);
  v_admin       numeric(10,2);
  v_provider    numeric(10,2);
  v_doctor_user uuid;
  v_appt_status public.appointment_status;
  v_is_gateway  boolean;
  v_prev        text;
begin
  if new.payment_status <> 'verified' then
    return new;
  end if;

  -- Nested rather than `tg_op = 'UPDATE' and old.payment_status = ...`:
  -- OLD is unassigned in a BEFORE INSERT trigger and PL/pgSQL evaluates a
  -- compound condition as one SQL expression, so touching OLD there would
  -- raise "record old is not assigned yet".
  if tg_op = 'UPDATE' then
    if old.payment_status = 'verified' then
      return new;   -- already settled; nothing to do
    end if;
  end if;

  -- A cancelled or expired appointment is no longer a payable booking:
  -- verifying its payment would mint a payout for money on a dead row.
  select status into v_appt_status
    from public.appointments where id = new.appointment_id;
  if v_appt_status in ('cancelled', 'expired') then
    raise exception 'This appointment is cancelled or expired and can no longer be verified.'
      using errcode = 'P0001';
  end if;

  new.rejection_reason := null;
  new.verified_at      := coalesce(new.verified_at, now());
  new.verified_by      := coalesce(new.verified_by, auth.uid());

  -- Money split. The doctor's commission is read at verification time, so
  -- a later commission change only affects future payments. Amount stays
  -- the patient-paid total; admin_share + provider_share equals it.
  select d.commission_percentage, u.id
    into v_commission, v_doctor_user
    from public.appointments a
    join public.doctors d on d.id = a.doctor_id
    join public.users   u on u.id = d.user_id
   where a.id = new.appointment_id;

  if v_doctor_user is not null then
    v_admin    := round(new.amount * coalesce(v_commission, 0) / 100.0, 2);
    v_provider := new.amount - v_admin;
    new.admin_share    := v_admin;
    new.provider_share := v_provider;

    insert into public.provider_payouts
      (provider_user_id, payment_id, amount, commission_percentage, status)
    values (v_doctor_user, new.id, v_provider, coalesce(v_commission, 0), 'pending')
    on conflict (payment_id) where payment_id is not null do nothing;
  end if;

  -- Where the booking goes next depends on WHO took the money.
  --
  --   gateway (Stripe): the platform has the funds and the patient has
  --     been shown "Appointment Confirmed" -- the booking is confirmed.
  --   manual (bKash/Nagad/bank): an administrator has just eyeballed a
  --     transaction reference. The escrow rule from 0006/0007 stands --
  --     the PROVIDER confirms. The booking leaves 'pending_payment' for
  --     'pending', which is precisely "paid, awaiting the doctor".
  v_is_gateway := coalesce(new.gateway, '') <> '' or new.stripe_session_id is not null;

  v_prev := public.trusted_path_begin();

  update public.appointments
     set payment_status      = 'paid',
         payment_verified_at = now(),
         payment_verified_by = coalesce(new.verified_by, auth.uid()),
         status              = case
                                 when v_is_gateway and status in ('pending_payment', 'pending')
                                   then 'confirmed'::public.appointment_status
                                 when status = 'pending_payment'
                                   then 'pending'::public.appointment_status
                                 else status
                               end
   where id = new.appointment_id;

  update public.payment_sessions
     set status = 'paid', updated_at = now()
   where appointment_id = new.appointment_id
     and status = 'initiated';

  perform public.trusted_path_end(v_prev);

  return new;
end;
$$;

-- Fires AFTER payments_guard_insert alphabetically ('v' > 'g'), so a
-- client-supplied payment_status has already been forced back to
-- 'pending' by the guard before this trigger ever looks at it. Trigger
-- name order is load-bearing here; do not rename it to something earlier
-- in the alphabet.
drop trigger if exists payments_verify_insert_trg on public.payments;
create trigger payments_verify_insert_trg
  before insert on public.payments
  for each row execute function public.payments_apply_verification();


-- =====================================================================
-- PART 10 -- Stripe webhook RPCs (rewritten)
--
-- The originals in 20260808000001 never applied -- that file has eight
-- `end if` without a semicolon inside payment_health_check, which is a
-- hard PL/pgSQL parse error, so the whole migration rolled back. Beyond
-- the syntax they also had real defects, noted per function below.
-- =====================================================================

-- Signatures are dropped first: the parameter lists change, and leaving
-- an old overload behind makes PostgREST's function resolution ambiguous.
drop function if exists public.record_payment_split(bigint, numeric, varchar, uuid, varchar, varchar);
drop function if exists public.confirm_appointment(bigint);
drop function if exists public.handle_failed_payment(bigint, varchar, text);
drop function if exists public.payment_health_check(bigint, uuid);

-- ---------------------------------------------------------------------
-- record_payment_split
--
-- Fixed: the original selected a.fee / a.status into v_payment.fee /
-- v_payment.status on a public.payments%rowtype -- that table has
-- `amount` and `payment_status` and neither of those columns, so it
-- failed at runtime. It also inserted payment_status='verified' expecting
-- an UPDATE trigger to fire (PART 9 fixes that side).
--
-- Idempotent by construction: Stripe redelivers webhooks, and the second
-- delivery must be harmless. The lookup by stripe_session_id runs first,
-- uq_payments_stripe_session backs it up, and the advisory lock keeps two
-- simultaneous deliveries from both passing the lookup.
-- ---------------------------------------------------------------------
create or replace function public.record_payment_split(
  p_appointment_id     bigint,
  p_amount             numeric(10,2),
  p_stripe_session_id  varchar(100),
  p_patient_id         uuid,
  p_stripe_pi_id       varchar(100) default null,
  p_stripe_customer_id varchar(100) default null
)
returns public.payments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt    public.appointments%rowtype;
  v_payment public.payments%rowtype;
  v_prev    text;
begin
  if p_stripe_session_id is null or btrim(p_stripe_session_id) = '' then
    raise exception 'a gateway payment needs its session id' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext('ayur:appointment_payment:' || p_appointment_id::text));

  -- Replay of a webhook we have already handled.
  select * into v_payment
    from public.payments
   where stripe_session_id = p_stripe_session_id;
  if found then
    return v_payment;
  end if;

  -- Some other verified payment already settled this booking (manual
  -- payment verified while the card was in flight, say). Return it rather
  -- than taking the money twice.
  select * into v_payment
    from public.payments
   where appointment_id = p_appointment_id
     and payment_status = 'verified'
   order by id
   limit 1;
  if found then
    return v_payment;
  end if;

  select * into v_appt
    from public.appointments
   where id = p_appointment_id
   for update;
  if not found then
    raise exception 'This appointment could not be found.' using errcode = 'PGRST116';
  end if;
  if v_appt.patient_id is distinct from p_patient_id then
    raise exception 'This payment does not belong to this appointment.' using errcode = '42501';
  end if;
  if v_appt.status in ('cancelled', 'expired') then
    raise exception 'This appointment is no longer available for payment.' using errcode = 'P0001';
  end if;

  v_prev := public.trusted_path_begin();

  -- Any pending manual submission for this booking is superseded.
  update public.payments
     set payment_status   = 'rejected',
         rejection_reason = 'Superseded by an online card payment.',
         updated_at       = now()
   where appointment_id = p_appointment_id
     and payment_status = 'pending';

  -- The amount is the appointment's own fee. p_amount is what Stripe
  -- reports it collected; if the two disagree the gateway and the booking
  -- have drifted and a human needs to look, so refuse rather than guess.
  if p_amount is not null and round(p_amount, 2) <> round(v_appt.fee, 2) then
    raise exception 'The amount paid does not match this appointment''s fee.'
      using errcode = 'P0001',
            detail  = format('appointment %s: fee %s, gateway reported %s',
                             p_appointment_id, v_appt.fee, p_amount);
  end if;

  -- payment_status is 'verified' at insert time: PART 9's INSERT trigger
  -- performs the split, writes provider_payouts and settles the booking.
  insert into public.payments
    (appointment_id, user_id, amount, payment_method, transaction_id,
     payment_status, verified_at, verified_by, gateway, gateway_transaction_id,
     stripe_session_id, stripe_payment_intent_id, stripe_customer_id, notes)
  values
    (p_appointment_id, v_appt.patient_id, v_appt.fee, 'Credit/Debit Card',
     coalesce(p_stripe_pi_id, p_stripe_session_id),
     'verified', now(), null, 'stripe', coalesce(p_stripe_pi_id, p_stripe_session_id),
     p_stripe_session_id, p_stripe_pi_id, p_stripe_customer_id,
     'Paid online via Stripe Checkout.')
  returning * into v_payment;

  perform public.trusted_path_end(v_prev);

  return v_payment;
end;
$$;

-- ---------------------------------------------------------------------
-- confirm_appointment
--
-- Fixed: the original did `select d.user_id into v_appt.doctor_id`,
-- assigning a uuid to a bigint. It is now what the webhook actually
-- needs -- an idempotent assertion that the booking is settled, returning
-- the row. The confirmation itself happens inside the settlement trigger,
-- in the same transaction as the payment, so there is no window where
-- money is taken and the booking is not confirmed.
-- ---------------------------------------------------------------------
create or replace function public.confirm_appointment(p_appointment_id bigint)
returns public.appointments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt public.appointments%rowtype;
  v_prev text;
begin
  select * into v_appt from public.appointments where id = p_appointment_id;
  if not found then
    raise exception 'This appointment could not be found.' using errcode = 'PGRST116';
  end if;

  if v_appt.payment_status <> 'paid' then
    raise exception 'This appointment has no verified payment yet.' using errcode = 'P0001';
  end if;

  if v_appt.status = 'confirmed' then
    return v_appt;   -- already there; webhook redelivery is harmless
  end if;

  if v_appt.status not in ('pending_payment', 'pending') then
    return v_appt;   -- cancelled/completed/expired: not ours to move
  end if;

  v_prev := public.trusted_path_begin();
  update public.appointments
     set status = 'confirmed'
   where id = p_appointment_id
  returning * into v_appt;
  perform public.trusted_path_end(v_prev);

  return v_appt;
end;
$$;

-- ---------------------------------------------------------------------
-- handle_failed_payment
--
-- Changed deliberately: the original INSERTed a 'rejected' payment row
-- with verified_by set to the PATIENT. A checkout the patient abandoned
-- is not a rejected payment -- it is an attempt that did not happen. It
-- pollutes the admin's rejected-payments queue and the payout ledger for
-- no gain. What actually needs to change is the SESSION, so a fresh
-- attempt can be started. The appointment stays exactly where it was,
-- which is what makes "Payment was not completed. You can try again."
-- true.
-- ---------------------------------------------------------------------
create or replace function public.handle_failed_payment(
  p_appointment_id    bigint,
  p_stripe_session_id varchar(100),
  p_failure_reason    text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt    public.appointments%rowtype;
  v_touched integer := 0;
  v_prev    text;
begin
  select * into v_appt from public.appointments where id = p_appointment_id;
  if not found then
    raise exception 'This appointment could not be found.' using errcode = 'PGRST116';
  end if;

  -- A late failure notice for a booking that has since been paid must not
  -- undo the payment.
  if v_appt.payment_status = 'paid' then
    return jsonb_build_object(
      'handled', false, 'reason', 'already_paid',
      'appointment_id', p_appointment_id, 'status', v_appt.status);
  end if;

  v_prev := public.trusted_path_begin();

  update public.payment_sessions
     set status     = 'failed',
         updated_at = now()
   where appointment_id = p_appointment_id
     and (gateway_ref = p_stripe_session_id
          or gateway_txn_id = p_stripe_session_id
          or p_stripe_session_id is null)
     and status = 'initiated';
  get diagnostics v_touched = row_count;

  perform public.trusted_path_end(v_prev);

  return jsonb_build_object(
    'handled', true,
    'appointment_id', p_appointment_id,
    'sessions_closed', v_touched,
    'reason', coalesce(p_failure_reason, 'Payment was not completed.'),
    'status', v_appt.status,
    'message', 'Payment was not completed. You can try again.');
end;
$$;


-- =====================================================================
-- PART 11 -- Gateway session lifecycle (checkout idempotency)
--
-- create-checkout-session used to build a brand new Stripe Customer AND
-- a brand new Checkout Session on every tap, guarded by nothing but a
-- Dart bool. payment_sessions already exists for exactly this problem
-- (uq_payment_sessions_active_appt: one live attempt per appointment);
-- it simply was not wired to Stripe.
-- =====================================================================

alter table public.payment_sessions
  add column if not exists notes_hint text;

create or replace function public.gateway_payment_begin(
  p_appointment_id bigint,
  p_gateway        text default 'stripe',
  p_reuse_window   interval default interval '25 minutes'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user    uuid := (select auth.uid());
  v_pay     jsonb;
  v_session public.payment_sessions%rowtype;
  v_appt    public.appointments%rowtype;
  v_prev    text;
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select * into v_appt from public.appointments where id = p_appointment_id;
  if not found then
    raise exception 'This appointment could not be found.' using errcode = 'PGRST116';
  end if;
  -- The RLS boundary in function form: a patient may only pay their own
  -- booking, and this is checked in the database rather than in the Edge
  -- Function.
  if v_appt.patient_id is distinct from v_user then
    raise exception 'This appointment belongs to another patient.' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('ayur:appointment_payment:' || p_appointment_id::text));

  v_pay := public.assert_appointment_payable(p_appointment_id);

  v_prev := public.trusted_path_begin();

  -- Retire anything that has gone stale so the partial unique index does
  -- not block a legitimate fresh attempt.
  update public.payment_sessions
     set status = 'expired', updated_at = now()
   where appointment_id = p_appointment_id
     and status = 'initiated'
     and (created_at < now() - p_reuse_window
          or (expires_at is not null and expires_at < now()));

  -- A live attempt is reused, not duplicated: the same tap twice gets the
  -- same Stripe page, so there is never more than one payable session.
  select * into v_session
    from public.payment_sessions
   where appointment_id = p_appointment_id
     and status = 'initiated'
     and checkout_url is not null
   order by created_at desc
   limit 1;

  if found then
    perform public.trusted_path_end(v_prev);
    return jsonb_build_object(
      'reuse', true,
      'session_row_id', v_session.id,
      'checkout_url', v_session.checkout_url,
      'gateway_ref', v_session.gateway_ref,
      'amount', v_session.amount,
      'appointment', v_pay);
  end if;

  -- Drop an incomplete placeholder (created but never attached) so the
  -- unique index stays satisfied.
  update public.payment_sessions
     set status = 'expired', updated_at = now()
   where appointment_id = p_appointment_id
     and status = 'initiated'
     and checkout_url is null;

  insert into public.payment_sessions
    (user_id, appointment_id, amount, gateway, status, expires_at)
  values
    (v_user, p_appointment_id, v_appt.fee, coalesce(p_gateway, 'stripe'),
     'initiated', now() + p_reuse_window)
  returning * into v_session;

  perform public.trusted_path_end(v_prev);

  return jsonb_build_object(
    'reuse', false,
    'session_row_id', v_session.id,
    'checkout_url', null,
    'amount', v_session.amount,
    'appointment', v_pay);
end;
$$;

grant execute on function public.gateway_payment_begin(bigint, text, interval) to authenticated;

-- Records the gateway's identifiers once the hosted page exists. Called
-- by the Edge Function with the service role; a patient never needs it.
create or replace function public.gateway_payment_attach(
  p_session_row_id uuid,
  p_gateway_ref    varchar(100),
  p_checkout_url   text,
  p_expires_at     timestamptz default null
)
returns public.payment_sessions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session public.payment_sessions%rowtype;
  v_prev    text;
begin
  v_prev := public.trusted_path_begin();
  update public.payment_sessions
     set gateway_ref  = p_gateway_ref,
         gateway_txn_id = coalesce(gateway_txn_id, p_gateway_ref),
         checkout_url = p_checkout_url,
         expires_at   = coalesce(p_expires_at, expires_at),
         updated_at   = now()
   where id = p_session_row_id
  returning * into v_session;
  perform public.trusted_path_end(v_prev);

  if v_session.id is null then
    raise exception 'no such payment session' using errcode = 'PGRST116';
  end if;
  return v_session;
end;
$$;

revoke all on function public.gateway_payment_attach(uuid, varchar, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.gateway_payment_attach(uuid, varchar, text, timestamptz)
  to service_role;


-- =====================================================================
-- PART 12 -- place_order(): idempotent, locked, single authoritative path
--
-- The old 7-argument signature is dropped rather than replaced: adding a
-- defaulted parameter creates a second overload, and PostgREST cannot
-- choose between two functions whose JSON keys both match.
-- =====================================================================

drop function if exists public.place_order(text, text, text, text, public.payment_method, text, text);

create or replace function public.place_order(
  p_delivery_name    text,
  p_delivery_phone   text,
  p_delivery_address text,
  p_delivery_city    text default null,
  p_payment_method   public.payment_method default 'Cash',
  p_sender_number    text default null,
  p_notes            text default null,
  p_idempotency_key  text default null
)
returns public.orders
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user      uuid := (select auth.uid());
  v_key       text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_subtotal  numeric(10,2) := 0;
  v_delivery  numeric(10,2);
  v_total     numeric(10,2);
  v_pharmacy  bigint;
  v_order     public.orders;
  v_item      record;
  v_recent    boolean;
  v_prev      text;
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.users u where u.id = v_user and u.is_active) then
    raise exception 'account is not active' using errcode = '42501';
  end if;

  -- Layer 1 -- the idempotency key. A retry after a dropped response
  -- returns the order that was already created, so the patient sees the
  -- success they paid for instead of a second order.
  if v_key is not null then
    select * into v_order
      from public.orders
     where user_id = v_user and idempotency_key = v_key;
    if found then
      return v_order;
    end if;
  end if;

  -- Layer 2 -- serialise this user's checkouts. Two taps that arrive at
  -- the same instant queue here instead of both reading a full cart.
  perform pg_advisory_xact_lock(hashtext('ayur:place_order:' || v_user::text));

  -- Re-check under the lock: the first caller may have finished while we
  -- waited.
  if v_key is not null then
    select * into v_order
      from public.orders
     where user_id = v_user and idempotency_key = v_key;
    if found then
      return v_order;
    end if;
  end if;

  -- Totals come from the products table, never from the client.
  select coalesce(sum(p.price * c.quantity), 0)
    into v_subtotal
    from public.cart c
    join public.pharmacy_products p on p.id = c.product_id
   where c.user_id = v_user
     and p.status = 'active';

  if v_subtotal = 0 then
    -- Layer 3 -- tell a duplicate submission apart from a genuinely empty
    -- basket. place_order() empties the cart, so the second of two taps
    -- always finds it empty; if this user also has a brand-new order, the
    -- empty cart is this call's own doing.
    select exists (
      select 1 from public.orders o
       where o.user_id = v_user
         and o.created_at > now() - interval '2 minutes'
    ) into v_recent;

    if v_recent then
      raise exception 'Your previous order is already being processed.'
        using errcode = 'P0001', detail = 'DUPLICATE_ORDER';
    end if;

    raise exception 'Your cart is empty.'
      using errcode = 'P0001', detail = 'CART_EMPTY';
  end if;

  -- Free delivery over BDT 500, otherwise BDT 60 -- the same rule the
  -- basket screen shows, so the quoted figure and the written figure
  -- cannot disagree.
  v_delivery := case when v_subtotal >= 500.00 then 0.00 else 60.00 end;

  -- A single-pharmacy basket records which pharmacy; a mixed basket stays
  -- null (that is what the nullable FK is for).
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
  -- WHERE stock >= quantity makes a stock race a raised error rather than
  -- a negative inventory. Ordering by product_id (not cart id) gives every
  -- concurrent checkout the same lock order, so two baskets sharing two
  -- products cannot deadlock each other.
  for v_item in
    select c.product_id, c.quantity, p.name as product_name
      from public.cart c
      join public.pharmacy_products p on p.id = c.product_id
     where c.user_id = v_user
       and p.status = 'active'
     order by c.product_id
  loop
    update public.pharmacy_products
       set stock = stock - v_item.quantity
     where id = v_item.product_id
       and stock >= v_item.quantity;
    if not found then
      raise exception '% is out of stock.', v_item.product_name
        using errcode = 'P0001', detail = 'OUT_OF_STOCK';
    end if;
  end loop;

  v_total := v_subtotal + v_delivery;

  v_prev := public.trusted_path_begin();

  insert into public.orders
    (user_id, pharmacy_id, subtotal, delivery_fee, total, payment_method,
     payment_status, transaction_id, sender_number, status, delivery_name,
     delivery_phone, delivery_address, delivery_city, notes, idempotency_key)
  values
    (v_user, v_pharmacy, v_subtotal, v_delivery, v_total, p_payment_method,
     'pending', null, p_sender_number, 'pending', p_delivery_name,
     p_delivery_phone, p_delivery_address, p_delivery_city, p_notes, v_key)
  returning * into v_order;

  insert into public.order_items
    (order_id, product_id, product_name, unit_price, quantity, line_total)
  select v_order.id, c.product_id, p.name, p.price, c.quantity, p.price * c.quantity
    from public.cart c
    join public.pharmacy_products p on p.id = c.product_id
   where c.user_id = v_user
     and p.status = 'active';

  delete from public.cart where user_id = v_user;

  perform public.trusted_path_end(v_prev);

  return v_order;
end;
$$;

grant execute on function public.place_order(text, text, text, text, public.payment_method, text, text, text)
  to authenticated;


-- =====================================================================
-- PART 13 -- The stale sweep learns about 'pending_payment'
--
-- Without this an unpaid booking squats its slot forever: the sweep only
-- looked at 'pending' and 'confirmed'. It also now runs on the trusted
-- path, because its own UPDATE has to pass the state machine and the
-- admin-only column guard.
-- =====================================================================

create or replace function public.expire_stale_appointments()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev text;
begin
  -- Re-entrancy guard: this is a FOR EACH STATEMENT trigger and its own
  -- UPDATE below would otherwise fire it again, recursing until the stack
  -- limit.
  if current_setting('appointments.expire_lock', true) is not null then
    return null;
  end if;
  perform set_config('appointments.expire_lock', '1', true);

  v_prev := public.trusted_path_begin();

  update public.appointments
     set status = 'expired'
   where status in ('pending', 'pending_payment', 'confirmed')
     and payment_status = 'pending'
     and (appointment_date < current_date
          or (appointment_date = current_date
              and appointment_time < localtime));

  perform public.trusted_path_end(v_prev);

  return null;
end;
$$;


-- =====================================================================
-- PART 14 -- payment_health_check (rewritten)
--
-- The original is the reason 20260808000001 never applied: eight `end if`
-- without a terminating semicolon. It also claimed to verify environment
-- variables it cannot see from SQL. This version checks what SQL can
-- actually check and reports the rest honestly, keeping the JSON shape
-- PaymentHealthReport.fromJson already reads
-- ({overall_status, checks:[{check,status,message}]}).
-- =====================================================================

create or replace function public.payment_health_check(
  p_appointment_id bigint default null,
  p_patient_id     uuid   default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_checks  jsonb := '[]'::jsonb;
  v_overall text  := 'healthy';
  v_missing text[];
  v_found   int;
  v_appt    public.appointments%rowtype;
  v_pay     jsonb;
begin
  -- 1. Every RPC the payment flow depends on exists.
  select array_agg(f.name order by f.name)
    into v_missing
    from unnest(array[
           'place_order', 'appointments_book', 'submit_manual_payment',
           'record_payment_split', 'confirm_appointment',
           'handle_failed_payment', 'gateway_payment_begin',
           'appointment_payability'
         ]) as f(name)
   where not exists (
     select 1 from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = f.name);

  v_checks := v_checks || jsonb_build_object(
    'check',   'rpc_functions_exist',
    'status',  case when v_missing is null then 'pass' else 'fail' end,
    'message', case when v_missing is null
                    then 'All payment RPCs are present.'
                    else 'Missing RPCs: ' || array_to_string(v_missing, ', ') end);
  if v_missing is not null then v_overall := 'unhealthy'; end if;

  -- 2. Every table the payment flow writes exists.
  select array_agg(t.name order by t.name)
    into v_missing
    from unnest(array[
           'appointments', 'payments', 'payment_sessions',
           'orders', 'order_items', 'provider_payouts'
         ]) as t(name)
   where to_regclass('public.' || t.name) is null;

  v_checks := v_checks || jsonb_build_object(
    'check',   'tables_exist',
    'status',  case when v_missing is null then 'pass' else 'fail' end,
    'message', case when v_missing is null
                    then 'All payment tables are present.'
                    else 'Missing tables: ' || array_to_string(v_missing, ', ') end);
  if v_missing is not null then v_overall := 'unhealthy'; end if;

  -- 3. The 'pending_payment' status exists. Without it a booking cannot
  --    enter the only state a payment may start from.
  select count(*) into v_found
    from pg_enum e
    join pg_type t on t.oid = e.enumtypid
    join pg_namespace n on n.oid = t.typnamespace
   where n.nspname = 'public'
     and t.typname = 'appointment_status'
     and e.enumlabel = 'pending_payment';

  v_checks := v_checks || jsonb_build_object(
    'check',   'appointment_status_pending_payment',
    'status',  case when v_found > 0 then 'pass' else 'fail' end,
    'message', case when v_found > 0
                    then 'appointment_status includes pending_payment.'
                    else 'appointment_status is missing pending_payment.' end);
  if v_found = 0 then v_overall := 'unhealthy'; end if;

  -- 4. Stripe columns on payments.
  select count(*) into v_found
    from information_schema.columns
   where table_schema = 'public' and table_name = 'payments'
     and column_name in ('stripe_session_id', 'stripe_payment_intent_id', 'stripe_customer_id');

  v_checks := v_checks || jsonb_build_object(
    'check',   'stripe_columns_present',
    'status',  case when v_found = 3 then 'pass' else 'fail' end,
    'message', case when v_found = 3
                    then 'payments carries the Stripe identifiers.'
                    else 'payments is missing Stripe identifier columns.' end);
  if v_found <> 3 then v_overall := 'unhealthy'; end if;

  -- 5. Settlement is wired to INSERT as well as UPDATE -- the defect that
  --    stopped gateway payments from ever settling.
  select count(*) into v_found
    from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'payments'
     and not tg.tgisinternal
     and tg.tgname in ('payments_apply_verification_trg', 'payments_verify_insert_trg');

  v_checks := v_checks || jsonb_build_object(
    'check',   'settlement_triggers_wired',
    'status',  case when v_found = 2 then 'pass' else 'fail' end,
    'message', case when v_found = 2
                    then 'Payment settlement fires on insert and on update.'
                    else 'Payment settlement triggers are incomplete.' end);
  if v_found <> 2 then v_overall := 'unhealthy'; end if;

  -- 6. The idempotency backstops are in place.
  select count(*) into v_found
    from pg_indexes
   where schemaname = 'public'
     and indexname in ('uq_payments_stripe_session', 'uq_payments_stripe_pi',
                       'uq_payments_verified_appointment', 'uq_orders_idempotency',
                       'uq_payment_sessions_active_appt');

  v_checks := v_checks || jsonb_build_object(
    'check',   'idempotency_indexes',
    'status',  case when v_found = 5 then 'pass' else 'fail' end,
    'message', format('%s of 5 idempotency indexes present.', v_found));
  if v_found <> 5 then v_overall := 'degraded'; end if;

  -- 7. Gateway credentials live in Edge Function secrets, which SQL
  --    cannot read. Saying so is more useful than guessing.
  v_checks := v_checks || jsonb_build_object(
    'check',   'gateway_secrets_configured',
    'status',  'unknown',
    'message', 'STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET and APP_URL are Edge Function secrets and cannot be read from SQL. Check them with: supabase secrets list.');

  -- 8. Per-appointment diagnostics, when asked for one.
  if p_appointment_id is not null then
    select * into v_appt from public.appointments where id = p_appointment_id;
    if not found then
      v_checks := v_checks || jsonb_build_object(
        'check', 'appointment_state', 'status', 'fail',
        'message', 'That appointment does not exist.');
      v_overall := 'unhealthy';
    else
      v_pay := public.appointment_payability(p_appointment_id);
      v_checks := v_checks || jsonb_build_object(
        'check',   'appointment_state',
        'status',  case when (v_pay ->> 'payable')::boolean then 'pass' else 'warn' end,
        'message', format('status=%s, payment_status=%s, fee=%s -- %s',
                          v_appt.status, v_appt.payment_status, v_appt.fee,
                          v_pay ->> 'message'));
    end if;
  end if;

  return jsonb_build_object(
    'overall_status', v_overall,
    'timestamp',      now(),
    'appointment_id', p_appointment_id,
    'patient_id',     p_patient_id,
    'checks',         v_checks);
end;
$$;


-- =====================================================================
-- PART 15 -- Grants
--
-- record_payment_split / confirm_appointment / handle_failed_payment move
-- money and settle bookings. 20260808000001 granted them to
-- `authenticated`, which would have let any signed-in user mark their own
-- appointment paid. They belong to the webhook alone.
-- =====================================================================

revoke all on function public.record_payment_split(bigint, numeric, varchar, uuid, varchar, varchar)
  from public, anon, authenticated;
revoke all on function public.confirm_appointment(bigint)
  from public, anon, authenticated;
revoke all on function public.handle_failed_payment(bigint, varchar, text)
  from public, anon, authenticated;

grant execute on function public.record_payment_split(bigint, numeric, varchar, uuid, varchar, varchar) to service_role;
grant execute on function public.confirm_appointment(bigint)                                            to service_role;
grant execute on function public.handle_failed_payment(bigint, varchar, text)                           to service_role;

grant execute on function public.payment_health_check(bigint, uuid) to authenticated, service_role;
grant execute on function public.assert_appointment_payable(bigint) to service_role;

-- Client-callable RPCs.
grant execute on function public.appointments_book(bigint, date, time, public.appointment_type, text, text)
  to authenticated;
