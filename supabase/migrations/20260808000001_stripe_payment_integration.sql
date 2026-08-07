-- =====================================================================
-- AYUR — migration: Stripe Payment Integration
-- =====================================================================
-- Adds Stripe Checkout support to the existing escrow payment flow.
-- Reuses existing architecture: payments_apply_verification trigger,
-- appointments_guard_confirm trigger, provider_payouts ledger.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Add 'pending_payment' to appointment_status enum
-- ---------------------------------------------------------------------
alter type public.appointment_status add value if not exists 'pending_payment';

-- ---------------------------------------------------------------------
-- 2. Add Stripe columns to payments table
-- ---------------------------------------------------------------------
alter table public.payments
  add column if not exists stripe_session_id varchar(100),
  add column if not exists stripe_payment_intent_id varchar(100),
  add column if not exists stripe_customer_id varchar(100),
  add column if not exists gateway varchar(30) default 'stripe';

-- Idempotency: one Stripe session maps to one payment row
create unique index if not exists uq_payments_stripe_session
  on public.payments (stripe_session_id)
  where stripe_session_id is not null;

create unique index if not exists uq_payments_stripe_pi
  on public.payments (stripe_payment_intent_id)
  where stripe_payment_intent_id is not null;

-- ---------------------------------------------------------------------
-- 3. record_payment_split — called by Stripe webhook on success
-- ---------------------------------------------------------------------
-- Creates the payment row, computes commission split, creates provider_payouts.
-- Mirrors the logic in payments_apply_verification but for Stripe-initiated payments.
create or replace function public.record_payment_split(
  p_appointment_id    bigint,
  p_amount            numeric(10,2),
  p_stripe_session_id varchar(100),
  p_patient_id        uuid,
  p_stripe_pi_id      varchar(100) default null,
  p_stripe_customer_id varchar(100) default null
)
returns public.payments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment public.payments;
  v_commission numeric(5,2);
  v_doctor_user uuid;
  v_admin_share numeric(10,2);
  v_provider_share numeric(10,2);
  v_doctor_id bigint;
begin
  -- Validate appointment exists, belongs to patient, and is in pending_payment state
  select a.doctor_id, a.fee, a.status, a.payment_status
    into v_doctor_id, v_payment.fee, v_payment.status, v_payment.payment_status
    from public.appointments a
   where a.id = p_appointment_id
     and a.patient_id = p_patient_id;

  if not found then
    raise exception 'Appointment not found or access denied' using errcode = '404';
  end if;

  if v_payment.status <> 'pending_payment' then
    raise exception 'Appointment is not awaiting payment' using errcode = 'P0001';
  end if;

  if v_payment.fee <> p_amount then
    raise exception 'Amount mismatch' using errcode = 'P0001';
  end if;

  -- Check if payment already exists for this Stripe session (idempotency)
  select * into v_payment
    from public.payments
   where stripe_session_id = p_stripe_session_id;

  if found then
    return v_payment;
  end if;

  -- Get doctor's commission percentage and user_id
  select d.commission_percentage, u.id
    into v_commission, v_doctor_user
    from public.doctors d
    join public.users u on u.id = d.user_id
   where d.id = v_doctor_id;

  if v_doctor_user is null then
    raise exception 'Doctor not found' using errcode = '404';
  end if;

  -- Calculate split
  v_admin_share    := round(p_amount * coalesce(v_commission, 0) / 100.0, 2);
  v_provider_share := p_amount - v_admin_share;

  -- Insert payment row with verified status (triggers payments_apply_verification)
  insert into public.payments (
    appointment_id,
    user_id,
    amount,
    payment_method,
    payment_status,
    transaction_id,
    stripe_session_id,
    stripe_payment_intent_id,
    stripe_customer_id,
    gateway,
    admin_share,
    provider_share,
    verified_at,
    verified_by
  ) values (
    p_appointment_id,
    p_patient_id,
    p_amount,
    'Credit/Debit Card',
    'verified',
    p_stripe_pi_id,
    p_stripe_session_id,
    p_stripe_pi_id,
    p_stripe_customer_id,
    'stripe',
    v_admin_share,
    v_provider_share,
    now(),
    p_patient_id
  ) returning * into v_payment;

  -- The payments_apply_verification trigger will fire automatically and:
  -- 1. Update appointment.payment_status = 'paid'
  -- 2. Create provider_payouts entry
  -- But we need to manually update appointment status to 'pending_payment' -> 'confirmed'
  -- This is done by confirm_appointment() called after this function

  return v_payment;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. confirm_appointment — called by Stripe webhook after record_payment_split
-- ---------------------------------------------------------------------
-- Confirms the appointment (status = 'confirmed') and generates confirmation code.
-- Reuses existing generate_confirmation_code() and appointments_set_confirmation_code() trigger.
create or replace function public.confirm_appointment(
  p_appointment_id bigint
)
returns public.appointments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt public.appointments;
begin
  -- Validate appointment exists and payment is verified
  select * into v_appt
    from public.appointments
   where id = p_appointment_id;

  if not found then
    raise exception 'Appointment not found' using errcode = '404';
  end if;

  if v_appt.payment_status <> 'paid' then
    raise exception 'Payment not verified' using errcode = 'P0001';
  end if;

  if v_appt.status = 'confirmed' then
    return v_appt;
  end if;

  -- Update status to confirmed (appointments_set_confirmation_code trigger will generate code)
  update public.appointments
     set status = 'confirmed'::public.appointment_status,
         updated_at = now()
   where id = p_appointment_id
 returning * into v_appt;

  -- Notify patient
  perform public.notify(
    v_appt.patient_id,
    'Appointment Confirmed',
    'Your appointment with ' || v_appt.doctor_name || ' on ' || v_appt.appointment_date || ' at ' || v_appt.appointment_time || ' has been confirmed. Confirmation code: ' || v_appt.confirmation_code,
    'appointment',
    '/appointments/' || v_appt.id,
    v_appt.id
  );

  -- Notify doctor
  select d.user_id into v_appt.doctor_id
    from public.doctors d
   where d.id = v_appt.doctor_id;

  if v_appt.doctor_id is not null then
    perform public.notify(
      v_appt.doctor_id,
      'New Appointment Confirmed',
      'Patient has confirmed appointment for ' || v_appt.appointment_date || ' at ' || v_appt.appointment_time || '. Confirmation code: ' || v_appt.confirmation_code,
      'appointment',
      '/doctor/appointments/' || v_appt.id,
      v_appt.id
    );
  end if;

  -- Notify admin
  perform public.notify(
    (select id from public.users where role = 'admin' limit 1),
    'Payment Recorded',
    'Stripe payment received for appointment #' || v_appt.id || ' (৳' || v_appt.fee || '). Appointment confirmed.',
    'payment',
    '/admin/appointments/' || v_appt.id,
    v_appt.id
  );

  return v_appt;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. handle_failed_payment — called by Stripe webhook on failure/expiry
-- ---------------------------------------------------------------------
create or replace function public.handle_failed_payment(
  p_appointment_id    bigint,
  p_stripe_session_id varchar(100),
  p_failure_reason    text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt public.appointments;
begin
  select * into v_appt
    from public.appointments
   where id = p_appointment_id;

  if not found then
    raise exception 'Appointment not found' using errcode = '404';
  end if;

  -- Only handle if still pending_payment
  if v_appt.status <> 'pending_payment' then
    return;
  end if;

  -- Insert failed payment record for audit trail
  insert into public.payments (
    appointment_id,
    user_id,
    amount,
    payment_method,
    payment_status,
    transaction_id,
    stripe_session_id,
    gateway,
    rejection_reason,
    verified_at,
    verified_by
  ) values (
    p_appointment_id,
    v_appt.patient_id,
    v_appt.fee,
    'Credit/Debit Card',
    'rejected',
    p_stripe_session_id,
    p_stripe_session_id,
    'stripe',
    p_failure_reason,
    now(),
    v_appt.patient_id
  ) on conflict (stripe_session_id) where stripe_session_id is not null do nothing;

  -- Appointment stays in pending_payment for retry
  -- Optionally notify patient
  perform public.notify(
    v_appt.patient_id,
    'Payment Failed',
    'Your payment for appointment #' || p_appointment_id || ' could not be processed. Reason: ' || p_failure_reason || '. Please try again.',
    'payment',
    '/appointments/' || p_appointment_id,
    p_appointment_id
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Grant execute permissions
-- ---------------------------------------------------------------------
grant execute on function public.record_payment_split(bigint, numeric, varchar, uuid, varchar, varchar) to authenticated;
grant execute on function public.confirm_appointment(bigint) to authenticated;
grant execute on function public.handle_failed_payment(bigint, varchar, text) to authenticated;

-- Service role needs execute for webhook (bypasses RLS)
grant execute on function public.record_payment_split(bigint, numeric, varchar, uuid, varchar, varchar) to service_role;
grant execute on function public.confirm_appointment(bigint) to service_role;
grant execute on function public.handle_failed_payment(bigint, varchar, text) to service_role;