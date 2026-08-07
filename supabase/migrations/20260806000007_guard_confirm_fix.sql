-- =====================================================================
-- 20260806000007_guard_confirm_fix.sql
--
-- Fixes the escrow guard left no-op by the same systemic bug that 0004
-- repaired in the other seven client guards.
--
-- THE BUG
--   appointments_guard_confirm was created in 0006 — AFTER 0004 ran — so
--   it still opened with the old role test:
--
--     if current_user not in ('authenticated', 'anon') then return new;
--
--   The function is SECURITY DEFINER, so inside it `current_user` is the
--   function OWNER (postgres), never 'authenticated'/'anon'. The check was
--   therefore always true and the guard silently returned `new` for every
--   client request. Consequences:
--     * a patient could PATCH their own appointment status to
--       'confirmed'/'completed' (the appointments RLS UPDATE policy allows
--       the owning patient), and
--     * the transition fired appointments_set_confirmation_code, minting a
--       confirmation code the doctor never issued — breaking the business
--       rule "doctor confirmation is the only action that generates a
--       confirmation code", with the money still unpaid.
--
-- THE FIX
--   1. Discriminate on `session_user` = 'authenticator' (0004's pattern):
--      PostgREST connects as that role and SET ROLEs per request, so both
--      anon AND signed-in app traffic arrive with session_user =
--      'authenticator'; internal writers (postgres, cli_login_postgres,
--      service_role) see anything else.
--   2. Also gate the transition to 'completed' on the owning doctor or an
--      admin. The doctor is the one who marks a booking done; a patient
--      must not be able to complete their own appointment.
--   3. The admin bypass and the escrow payment gate are unchanged.
--
-- Idempotent: CREATE OR REPLACE + DROP IF EXISTS / CREATE trigger.
-- =====================================================================

create or replace function public.appointments_guard_confirm()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if session_user <> 'authenticator' then
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

  -- Only the owning doctor may complete a booking.
  if new.status = 'completed'
     and old.status is distinct from 'completed'
     and new.doctor_id is distinct from public.current_doctor_id() then
    raise exception 'Only the doctor for this appointment can complete it.'
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
