-- Fix appointments_book to set status = 'pending_payment' for Stripe Checkout compatibility

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
         'pending_payment'::public.appointment_status,
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

grant execute on function public.appointments_book(bigint, date, time, public.appointment_type, text, text) to authenticated;