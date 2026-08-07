-- =====================================================================
-- 20260806000004_guard_session_user_fix.sql
--
-- Fixes a systemic no-op in every client-guard trigger, discovered while
-- testing the payment/review rework from migration 0003.
--
-- THE BUG
--   Every guard trigger (guard_reviews_insert, guard_appointments_insert,
--   guard_payments_insert, guard_provider_insert, guard_orders_insert,
--   guard_order_items_insert, guard_admin_only_columns) starts with:
--
--     if current_user not in ('authenticated', 'anon') then
--       return new;
--     end if;
--
--   Those functions are SECURITY DEFINER, so inside them `current_user` is
--   the function OWNER (postgres), never 'authenticated'/'anon'. The check
--   was therefore always true and the guards silently returned `new` for
--   every client request. Consequences: the "review only after the
--   consultation" gate from 0003 never fired, a provider could PATCH their
--   own commission_percentage / verification_status, a patient could set
--   orders.payment_status and mint a payout, etc.
--
-- THE FIX
--   Discriminate on `session_user` = 'authenticator'. Supabase's PostgREST
--   connects to Postgres as the dedicated `authenticator` role and then
--   SET ROLEs to anon / authenticated per request based on the JWT, so app
--   traffic — anonymous or signed-in — always arrives with
--   session_user = 'authenticator', while internal writers (postgres,
--   cli_login_postgres, service_role) see anything else. An RPC probe on
--   this very database confirmed: current_user = postgres and
--   session_user = authenticator for both an anon and a signed-in request.
--
-- ALSO FIXED HERE
--   1. appointments_refund_on_cancel is SECURITY INVOKER and now writes
--      provider_payouts (added in 0003); under RLS a cancelling patient
--      (no UPDATE grant on provider_payouts) would silently reverse zero
--      rows. Made it SECURITY DEFINER.
--   2. aa_guard_orders did not guard the money columns: a patient could
--      UPDATE their own order SET payment_status = 'paid', which would
--      fire orders_apply_verification and mint a pharmacy payout. Now
--      payment_status / admin_share / provider_share are admin-only.
--   3. orders_apply_verification / payments_apply_verification get the
--      ON CONFLICT clause so re-verification cannot mint a duplicate
--      payout (matches the canonical schema.sql; 0003 already had it live).
--
-- Idempotent: the DO block skips functions already using session_user,
-- and every other statement is CREATE OR REPLACE / DROP IF EXISTS.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Rebuild the seven client guards on session_user = 'authenticator'
-- ---------------------------------------------------------------------
-- PostgREST connects as the dedicated `authenticator` role and SET ROLEs to
-- anon/authenticated per request. So both anon AND signed-in app traffic
-- arrive with session_user = 'authenticator' (verified live by an RPC
-- probe); anything else (postgres, cli_login_postgres, service_role) is
-- internal. This patch replaces whichever broken role-check a guard
-- currently carries with the authenticator test, and is idempotent.
do $$
declare
  r   record;
  def text;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind  = 'f'
       and p.proname in (
         'guard_provider_insert',
         'guard_appointments_insert',
         'guard_payments_insert',
         'guard_reviews_insert',
         'guard_orders_insert',
         'guard_order_items_insert',
         'guard_admin_only_columns'
       )
  loop
    def := pg_get_functiondef(r.sig);
    def := replace(def,
      'current_user not in (''authenticated'', ''anon'')',
      'session_user <> ''authenticator''');
    def := replace(def,
      'session_user not in (''authenticated'', ''anon'')',
      'session_user <> ''authenticator''');
    if position('session_user <> ''authenticator''' in def) > 0
       and position('current_user not in' in def) = 0 then
      execute def;
      raise notice 'guard patched: %', r.sig;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Refund reversal must survive RLS when a patient cancels
-- ---------------------------------------------------------------------
create or replace function public.appointments_refund_on_cancel()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'cancelled'
     and old.status <> 'cancelled'
     and new.payment_status = 'paid' then
    new.payment_status := 'refunded';

    -- The provider never earned this money: reverse the payout for the
    -- appointment's verified payment so the pending balance stops counting
    -- it. SECURITY DEFINER so this write survives RLS when the cancelling
    -- patient (who holds no UPDATE grant on provider_payouts) triggers it.
    update public.provider_payouts pp
       set status = 'reversed',
           updated_at = now()
      from public.payments p
     where pp.payment_id = p.id
       and p.appointment_id = new.id
       and pp.status <> 'reversed';
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. orders money columns are admin-only (was: patient-writable)
-- ---------------------------------------------------------------------
drop trigger if exists aa_guard_orders on public.orders;
create trigger aa_guard_orders
  before update on public.orders
  for each row execute function
    public.guard_admin_only_columns('order_number', 'subtotal', 'delivery_fee', 'total',
      'payment_status', 'admin_share', 'provider_share');

-- ---------------------------------------------------------------------
-- 4. Reconcile split inserters to the canonical ON CONFLICT form
-- ---------------------------------------------------------------------
create or replace function public.payments_apply_verification()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_commission numeric(5,2);
  v_admin      numeric(10,2);
  v_provider   numeric(10,2);
  v_doctor_user uuid;
begin
  if new.payment_status = 'verified'
     and old.payment_status is distinct from 'verified' then

    new.rejection_reason := null;
    new.verified_at      := coalesce(new.verified_at, now());
    new.verified_by      := coalesce(new.verified_by, auth.uid());

    -- Money split. The doctor's commission is read at verification time, so a
    -- later commission change only affects future payments. Amount stays the
    -- patient-paid total; admin_share + provider_share always equals it.
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

create or replace function public.orders_apply_verification()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_commission numeric(5,2);
  v_admin      numeric(10,2);
  v_provider   numeric(10,2);
  v_pharmacy_user uuid;
begin
  if new.payment_status = 'paid'
     and old.payment_status is distinct from 'paid'
     and new.pharmacy_id is not null then

    select ph.commission_percentage, u.id
      into v_commission, v_pharmacy_user
      from public.pharmacies ph
      join public.users u on u.id = ph.user_id
     where ph.id = new.pharmacy_id;

    if v_pharmacy_user is not null then
      v_admin    := round(new.total * coalesce(v_commission, 0) / 100.0, 2);
      v_provider := new.total - v_admin;
      new.admin_share    := v_admin;
      new.provider_share := v_provider;

      insert into public.provider_payouts
        (provider_user_id, order_id, amount, commission_percentage, status)
      values (v_pharmacy_user, new.id, v_provider, coalesce(v_commission, 0), 'pending')
      on conflict (order_id) where order_id is not null do nothing;
    end if;
  end if;

  return new;
end;
$$;
