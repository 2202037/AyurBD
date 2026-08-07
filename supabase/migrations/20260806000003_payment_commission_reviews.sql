-- =====================================================================
-- AYUR — migration 0003: platform commission payments + review gating
--
-- What this changes:
--   1. commission_percentage on doctors/hospitals/clinics/pharmacies —
--      the admin-settable platform cut per provider.
--   2. payments.admin_share / provider_share and orders.admin_share /
--      provider_share — the money split computed at verification time.
--   3. provider_payouts — the ledger of what the platform owes each
--      provider (pending | paid | reversed), written only by the
--      verification triggers, paid out by the admin offline.
--   4. payments_apply_verification splits appointment payments and
--      records the payout; orders_apply_verification does the same for
--      paid pharmacy orders; appointments_refund_on_cancel reverses the
--      payout when a paid appointment is refunded.
--   5. guard_reviews_insert now requires the consultation to have
--      happened: a doctor review is accepted only after the appointment
--      slot is in the past and the appointment is not cancelled/expired.
--   6. uq_payments_pending_appt — one pending payment per appointment.
--   7. RLS: verification is admin-only (payments_update_doctor removed),
--      provider_payouts is provider-read / admin-update.
--
-- Idempotent: safe to run against a DB that already has 0000-0002.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. commission_percentage
-- ---------------------------------------------------------------------
alter table public.doctors
  add column if not exists commission_percentage numeric(5,2) not null default 0.00;
alter table public.hospitals
  add column if not exists commission_percentage numeric(5,2) not null default 0.00;
alter table public.clinics
  add column if not exists commission_percentage numeric(5,2) not null default 0.00;
alter table public.pharmacies
  add column if not exists commission_percentage numeric(5,2) not null default 0.00;

alter table public.doctors    drop constraint if exists doctors_commission_check;
alter table public.hospitals  drop constraint if exists hospitals_commission_check;
alter table public.clinics    drop constraint if exists clinics_commission_check;
alter table public.pharmacies drop constraint if exists pharmacies_commission_check;

alter table public.doctors
  add constraint doctors_commission_check
    check (commission_percentage >= 0 and commission_percentage <= 100);
alter table public.hospitals
  add constraint hospitals_commission_check
    check (commission_percentage >= 0 and commission_percentage <= 100);
alter table public.clinics
  add constraint clinics_commission_check
    check (commission_percentage >= 0 and commission_percentage <= 100);
alter table public.pharmacies
  add constraint pharmacies_commission_check
    check (commission_percentage >= 0 and commission_percentage <= 100);

-- ---------------------------------------------------------------------
-- 2. money-split columns
-- ---------------------------------------------------------------------
alter table public.payments
  add column if not exists admin_share    numeric(10,2),
  add column if not exists provider_share numeric(10,2);

alter table public.payments drop constraint if exists payments_split_check;
alter table public.payments
  add constraint payments_split_check check (
    (admin_share is null and provider_share is null)
    or (admin_share is not null and provider_share is not null
        and admin_share + provider_share = amount));

alter table public.orders
  add column if not exists admin_share    numeric(10,2),
  add column if not exists provider_share numeric(10,2);

alter table public.orders drop constraint if exists orders_split_check;
alter table public.orders
  add constraint orders_split_check check (
    (admin_share is null and provider_share is null)
    or (admin_share is not null and provider_share is not null
        and admin_share + provider_share = total));

-- ---------------------------------------------------------------------
-- 3. provider_payouts
-- ---------------------------------------------------------------------
create table if not exists public.provider_payouts (
  id                    bigint generated always as identity primary key,
  provider_user_id      uuid    not null references public.users (id) on delete cascade,
  payment_id            bigint  references public.payments (id) on delete cascade,
  order_id              bigint  references public.orders (id) on delete cascade,
  amount                numeric(10,2) not null,
  commission_percentage numeric(5,2)  not null default 0.00,
  status                varchar(20)   not null default 'pending',
  paid_at               timestamptz,
  paid_by               uuid references public.users (id) on delete set null,
  payout_note           text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint provider_payouts_source_check check (
    (payment_id is not null and order_id is null)
    or (payment_id is null and order_id is not null)),
  constraint provider_payouts_amount_check check (amount >= 0),
  constraint provider_payouts_commission_check
    check (commission_percentage >= 0 and commission_percentage <= 100),
  constraint provider_payouts_status_check
    check (status in ('pending', 'paid', 'reversed'))
);

create index if not exists idx_provider_payouts_user   on public.provider_payouts (provider_user_id);
create index if not exists idx_provider_payouts_status on public.provider_payouts (status);
create unique index if not exists uq_provider_payouts_payment
  on public.provider_payouts (payment_id) where payment_id is not null;
create unique index if not exists uq_provider_payouts_order
  on public.provider_payouts (order_id) where order_id is not null;

-- ---------------------------------------------------------------------
-- 4. functions
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
-- 4b. review gating: only after the consultation
-- ---------------------------------------------------------------------
create or replace function public.guard_reviews_insert()returns trigger
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
         and a.status not in ('cancelled', 'expired')
         and (a.appointment_date < current_date
              or (a.appointment_date = current_date
                  and a.appointment_time < localtime))
    ) into v_owned;
    if not v_owned then
      raise exception
        'You can review this doctor only after the consultation has taken place.'
        using errcode = 'P0001';
    end if;
  end if;

  return new;
end;
$$;

-- Return type changed (gained revenue/pending_payout/platform_fee), so a
-- plain CREATE OR REPLACE is refused: drop first, then recreate.
drop function if exists public.doctor_stats();
create or replace function public.doctor_stats()
returns table (
  appointments_total     bigint,
  appointments_pending   bigint,
  appointments_confirmed bigint,
  appointments_completed bigint,
  appointments_cancelled bigint,
  payments_pending       bigint,
  payments_verified      bigint,
  revenue                numeric(12,2),
  pending_payout         numeric(12,2),
  platform_fee           numeric(12,2)
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
    (select coalesce(sum(p.provider_share), 0) from public.payments p join public.appointments a on a.id = p.appointment_id where a.doctor_id = d.id and p.payment_status = 'verified')::numeric(12,2),
    (select coalesce(sum(pp.amount), 0) from public.provider_payouts pp where pp.provider_user_id = d.user_id and pp.status = 'pending')::numeric(12,2),
    (select coalesce(sum(p.admin_share), 0) from public.payments p join public.appointments a on a.id = p.appointment_id where a.doctor_id = d.id and p.payment_status = 'verified')::numeric(12,2)
  from public.doctors d
  where d.user_id = (select auth.uid());
$$;

-- ---------------------------------------------------------------------
-- 5. triggers + index
-- ---------------------------------------------------------------------
drop trigger if exists orders_apply_verification_trg on public.orders;
create trigger orders_apply_verification_trg
  before update of payment_status on public.orders
  for each row execute function public.orders_apply_verification();

create unique index if not exists uq_payments_pending_appt
  on public.payments (appointment_id)
  where payment_status = 'pending';

-- ---------------------------------------------------------------------
-- 6. RLS
-- ---------------------------------------------------------------------
alter table public.provider_payouts enable row level security;

drop policy if exists payments_update_doctor on public.payments;

drop policy if exists provider_payouts_select_own on public.provider_payouts;
create policy provider_payouts_select_own
  on public.provider_payouts for select to authenticated
  using (provider_user_id = (select auth.uid()));

drop policy if exists provider_payouts_select_admin on public.provider_payouts;
create policy provider_payouts_select_admin
  on public.provider_payouts for select to authenticated
  using (public.is_admin());

drop policy if exists provider_payouts_update_admin on public.provider_payouts;
create policy provider_payouts_update_admin
  on public.provider_payouts for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- admin-only commission on the provider tables
drop trigger if exists aa_guard_doctors on public.doctors;
create trigger aa_guard_doctors
  before update on public.doctors
  for each row execute function
    public.guard_admin_only_columns('verification_status', 'status', 'rating', 'total_reviews', 'rejection_reason', 'is_deleted', 'commission_percentage');

drop trigger if exists aa_guard_hospitals on public.hospitals;
create trigger aa_guard_hospitals
  before update on public.hospitals
  for each row execute function
    public.guard_admin_only_columns('verification_status', 'status', 'rating', 'total_reviews', 'rejection_reason', 'is_deleted', 'commission_percentage');

drop trigger if exists aa_guard_clinics on public.clinics;
create trigger aa_guard_clinics
  before update on public.clinics
  for each row execute function
    public.guard_admin_only_columns('verification_status', 'status', 'rating', 'total_reviews', 'rejection_reason', 'is_deleted', 'commission_percentage');

drop trigger if exists aa_guard_pharmacies on public.pharmacies;
create trigger aa_guard_pharmacies
  before update on public.pharmacies
  for each row execute function
    public.guard_admin_only_columns('verification_status', 'status', 'rating', 'total_reviews', 'rejection_reason', 'is_deleted', 'commission_percentage');

grant select, update on public.provider_payouts to authenticated;

-- ---------------------------------------------------------------------
-- 7. backfill: existing verified payments/paid orders
--
-- Before this migration nothing recorded a split. Verified payments and
-- paid orders already in the DB get the current default commission (0),
-- i.e. the whole amount is owed to the provider, and a pending payout is
-- created so the provider dashboard's balance is complete.
-- ---------------------------------------------------------------------
update public.payments p
   set admin_share = 0, provider_share = p.amount
 where p.payment_status = 'verified'
   and p.admin_share is null;

insert into public.provider_payouts (provider_user_id, payment_id, amount, commission_percentage, status)
select u.id, p.id, p.provider_share, 0, 'pending'
  from public.payments p
  join public.appointments a on a.id = p.appointment_id
  join public.doctors d on d.id = a.doctor_id
  join public.users u on u.id = d.user_id
 where p.payment_status = 'verified'
   and p.provider_share is not null
on conflict (payment_id) where payment_id is not null do nothing;

update public.orders o
   set admin_share = 0, provider_share = o.total
 where o.payment_status = 'paid'
   and o.admin_share is null;

insert into public.provider_payouts (provider_user_id, order_id, amount, commission_percentage, status)
select u.id, o.id, o.provider_share, 0, 'pending'
  from public.orders o
  join public.pharmacies ph on ph.id = o.pharmacy_id
  join public.users u on u.id = ph.user_id
 where o.payment_status = 'paid'
   and o.provider_share is not null
on conflict (order_id) where order_id is not null do nothing;
