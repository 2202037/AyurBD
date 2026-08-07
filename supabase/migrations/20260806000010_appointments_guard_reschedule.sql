-- =====================================================================
-- 20260806000010_appointments_guard_reschedule.sql
--
-- Closes the "reschedule without validation" gap.
--
-- THE BUG
--   Booking INSERT paths validate the slot server-side (appointments_book,
--   guard_appointments_insert), but the RLS policy appointments_update_patient
--   allows a patient to PATCH their own appointment_date / appointment_time
--   directly, and no UPDATE-time guard re-validated them. A patient could
--   move a booking to a past slot, an off-duty day, outside the published
--   window, or (racing another patient) onto a slot that is already taken.
--
-- THE FIX
--   appointments_guard_reschedule — a BEFORE UPDATE trigger that:
--     * runs only for client traffic (session_user = 'authenticator'),
--     * lets admins and internal writers through,
--     * only lets a 'pending' appointment change its date/time, and
--     * re-checks the new slot through available_slots() (which encodes
--       the day/window/past rules and excludes taken slots). The partial
--       unique index uq_appointments_doctor_slot backstops the race.
--
-- Idempotent: CREATE OR REPLACE + DROP IF EXISTS / CREATE trigger.
-- =====================================================================

create or replace function public.appointments_guard_reschedule()
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

  if new.appointment_date is distinct from old.appointment_date
     or new.appointment_time is distinct from old.appointment_time then

    -- A confirmed/completed/cancelled booking is not a moveable object:
    -- the doctor may have confirmed a specific slot, and a cancelled one
    -- is history.
    if old.status <> 'pending' then
      raise exception 'Only a pending appointment can be rescheduled.'
        using errcode = 'P0001';
    end if;

    -- available_slots() encodes the day/window/past rules and excludes
    -- taken slots; the partial unique index backstops the race.
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

drop trigger if exists aa_guard_reschedule on public.appointments;
create trigger aa_guard_reschedule
  before update on public.appointments
  for each row execute function public.appointments_guard_reschedule();
