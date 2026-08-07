-- =====================================================================
-- AYUR — migration 0006: escrow payment flow (showcase)
--
-- The platform's money model is now explicitly "patient pays the PLATFORM,
-- admin verifies, platform keeps the commission, provider gets the rest,
-- provider confirms the booking once the money is theirs."
--
-- What this changes:
--   1. commission_percentage defaults to 2.00 (was 0.00) on
--      doctors/hospitals/clinics/pharmacies, and existing rows are
--      backfilled to 2.00 so the split is live immediately. Blood banks
--      have no fee and no commission column — excluded by design.
--   2. payments_apply_verification no longer auto-confirms the appointment
--      when a payment is verified. It still marks the appointment paid and
--      writes the admin/provider split + provider_payouts, but the booking
--      stays `pending` until the PROVIDER confirms it — which is the point
--      of the escrow flow: the provider confirms only after their 98% is
--      credited.
--   3. appointments_guard_confirm — a BEFORE UPDATE trigger that refuses a
--      transition to `confirmed` while the appointment still carries a fee
--      (> 0) and has not been paid, and restricts confirming to the owning
--      doctor or an admin. Free consultations can be confirmed at once.
--
-- Idempotent: safe to run on top of 0000–0005.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. commission_percentage default + backfill
-- ---------------------------------------------------------------------
alter table public.doctors    alter column commission_percentage set default 2.00;
alter table public.hospitals  alter column commission_percentage set default 2.00;
alter table public.clinics    alter column commission_percentage set default 2.00;
alter table public.pharmacies alter column commission_percentage set default 2.00;

update public.doctors    set commission_percentage = 2.00 where commission_percentage = 0.00;
update public.hospitals  set commission_percentage = 2.00 where commission_percentage = 0.00;
update public.clinics    set commission_percentage = 2.00 where commission_percentage = 0.00;
update public.pharmacies set commission_percentage = 2.00 where commission_percentage = 0.00;

-- ---------------------------------------------------------------------
-- 2. payments_apply_verification — no more auto-confirm
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

    -- Money split. The provider's commission is read at verification time, so
    -- a later commission change only affects future payments. Amount stays the
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

      -- One payout per verified payment (unique index backstops a
      -- re-verification edge).
      insert into public.provider_payouts
        (provider_user_id, payment_id, amount, commission_percentage, status)
      values (v_doctor_user, new.id, v_provider, coalesce(v_commission, 0), 'pending')
      on conflict (payment_id) where payment_id is not null do nothing;
    end if;

    -- Mark the appointment paid, but DO NOT move its status: the provider
    -- confirms the booking once the 98% payout is credited to them
    -- (appointments_guard_confirm enforces that order).
    update public.appointments
       set payment_status      = 'paid',
           payment_verified_at = now(),
           payment_verified_by = coalesce(new.verified_by, auth.uid())
     where id = new.appointment_id;
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. appointments_guard_confirm — confirm only after payment
-- ---------------------------------------------------------------------
create or replace function public.appointments_guard_confirm()
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

  -- Only the owning doctor may confirm a booking.
  if new.status = 'confirmed'
     and old.status is distinct from 'confirmed'
     and new.doctor_id is distinct from public.current_doctor_id() then
    raise exception 'Only the doctor for this appointment can confirm it.'
      using errcode = '42501';
  end if;

  -- Escrow flow: the doctor confirms only after the patient's payment is
  -- verified (the fee minus commission is credited to them as a pending
  -- payout). Free consultations have no gate.
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

drop trigger if exists aa_guard_confirm on public.appointments;
create trigger aa_guard_confirm
  before update of status on public.appointments
  for each row execute function public.appointments_guard_confirm();
