-- =====================================================================
-- 20260806000014_dhaka_timezone_fix.sql
--
-- Fixes every place that compares a wall-clock appointment slot against
-- "now" using the session timezone.
--
-- WHY
--   appointment_date / appointment_time store the appointment in the
--   Bangladesh wall clock (the app is Dhaka-only). But `now()`,
--   `current_date` and `localtime` resolve in the session timezone, which
--   on Supabase is UTC. For 6 hours every day (18:00–24:00 UTC, i.e.
--   00:00–06:00 Dhaka) the two disagree, which caused three concrete
--   bugs:
--
--   1. available_slots() compared generated slot times against UTC now,
--      so a slot that had *already passed* in Dhaka could stay bookable
--      for up to 6 hours.
--   2. guard_reviews_insert() would not allow a review for a consultation
--      that happened at 23:30 Dhaka until ~6 hours after it ended.
--   3. expire_stale_appointments() kept "expiring" nothing during those
--      6 hours, leaving a no-show slot squatting on the unique index.
--
--   users_ban_enforce() had the same UTC boundary in its future-query.
--
-- THE FIX
--   Convert `now()` to the Dhaka wall clock with
--   `now() at time zone 'Asia/Dhaka'` and compare the naive
--   date+time against it. Idempotent: create or replace.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. available_slots — slot must not be in the Dhaka past.
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

  if v_doc is null
     or v_doc.available_days is null
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

grant execute on function public.available_slots(bigint, date) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. guard_reviews_insert — consultation must already have happened in
--    Dhaka time.
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
  if session_user <> 'authenticator' then
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
         and (a.appointment_date + a.appointment_time)
             < (now() at time zone 'Asia/Dhaka')
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

-- ---------------------------------------------------------------------
-- 3. expire_stale_appointments — slot considered stale in Dhaka time.
-- ---------------------------------------------------------------------
create or replace function public.expire_stale_appointments()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if current_setting('appointments.expire_lock', true) is not null then
    return null;
  end if;
  perform set_config('appointments.expire_lock', '1', true);

  update public.appointments
     set status = 'expired'
   where status in ('pending', 'confirmed')
     and payment_status = 'pending'
     and (appointment_date + appointment_time)
         < (now() at time zone 'Asia/Dhaka');

  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. users_ban_enforce — "future" means future in Dhaka.
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
         and appointment_date >= (now() at time zone 'Asia/Dhaka')::date;

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
