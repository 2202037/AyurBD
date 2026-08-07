-- =====================================================================
-- 20260806000009_payments_guard_dead_appointment.sql
--
-- Closes the "verify a dead booking" money hole.
--
-- THE BUG
--   payments_apply_verification() split the money, wrote the
--   provider_payouts ledger and marked the appointment paid with no check
--   on the appointment's own status. If a patient cancelled (or the
--   expire sweep expired) an unpaid appointment and the admin verified its
--   payment afterwards, the platform minted a payout for a booking that
--   no longer exists and the money was already meant to go back to the
--   patient.
--
-- THE FIX
--   Refuse the transition to 'verified' when the appointment is already
--   cancelled or expired. The trigger is BEFORE UPDATE, so raising here
--   aborts the verification write entirely (the admin sees 422).
--
-- Idempotent: CREATE OR REPLACE.
-- =====================================================================

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
  v_appt_status public.appointment_status;
begin
  if new.payment_status = 'verified'
     and old.payment_status is distinct from 'verified' then

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

      -- One payout per verified payment (unique index backstops a
      -- re-verification edge).
      insert into public.provider_payouts
        (provider_user_id, payment_id, amount, commission_percentage, status)
      values (v_doctor_user, new.id, v_provider, coalesce(v_commission, 0), 'pending')
      on conflict (payment_id) where payment_id is not null do nothing;
    end if;

    -- Mark the appointment paid, but DO NOT move its status: the provider
    -- confirms the booking once the payout is credited to them
    -- (appointments_guard_confirm enforces that order). The confirmation
    -- code is filled by appointments_set_confirmation_code when the provider
    -- later confirms.
    update public.appointments
       set payment_status      = 'paid',
           payment_verified_at = now(),
           payment_verified_by = coalesce(new.verified_by, auth.uid())
     where id = new.appointment_id;
  end if;

  return new;
end;
$$;
