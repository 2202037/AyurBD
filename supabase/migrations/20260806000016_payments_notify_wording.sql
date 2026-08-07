-- =====================================================================
-- 20260806000016_payments_notify_wording.sql
--
-- Fixes the "Payment verified" notification copy.
--
-- WHAT WAS WRONG
--   payments_notify() read appointments.confirmation_code and appended
--   "Confirmation code: …" to the verified message. But the code does not
--   exist at verification time: it is minted by
--   appointments_set_confirmation_code() only when the provider later
--   confirms the booking (payments_apply_verification marks the
--   appointment paid and deliberately does NOT move its status). The
--   select ran, found nothing, coalesce'd to '', and the patient got a
--   message that *promised* a confirmation code that had not been issued.
--   The inline comment claiming the code was set before this trigger was
--   stale (it described an older flow where verification issued the code).
--
-- THE FIX
--   State the actual transition and where the code comes from, and drop
--   the dead select / v_code variable.
--
-- Idempotent: create or replace.
-- =====================================================================

create or replace function public.payments_notify()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform public.notify(new.user_id, 'Payment submitted',
      'Your payment details were received and are awaiting verification.',
      'payment', '/appointments', new.appointment_id);
    return null;
  end if;

  if new.payment_status is distinct from old.payment_status then
    if new.payment_status = 'verified' then
      perform public.notify(new.user_id, 'Payment verified',
        'Your payment was verified and your appointment is marked as paid. '
          || 'Your confirmation code will be sent once the provider confirms your booking.',
        'payment', '/appointments', new.appointment_id);

    elsif new.payment_status = 'rejected' then
      perform public.notify(new.user_id, 'Payment rejected',
        'Your payment was rejected: '
          || coalesce(new.rejection_reason, 'no reason given'),
        'payment', '/appointments', new.appointment_id);
    end if;
  end if;

  return null;
end;
$$;
