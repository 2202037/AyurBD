-- =====================================================================
-- 20260806000018_payments_verified_immutable.sql
--
-- Makes a verified payment a financial record the admin cannot rewrite.
--
-- WHY
--   payments UPDATE/DELETE is admin-only (payments_update_admin /
--   payments_delete_admin), but nothing stopped an admin from editing or
--   deleting a payment that had already been verified. A verified row has
--   minted admin_share/provider_share, marked the appointment paid and
--   recorded a provider payout — rewriting amount/method/reference or
--   deleting the row corrupts that ledger. The correct reversal exists:
--   cancel the appointment (appointments_refund_on_cancel flips
--   appointments.payment_status to 'refunded' and reverses the payout);
--   the payments row itself is terminal (payment_verification_status has
--   no 'refunded' value).
--
--   'rejected' is deliberately left mutable — an admin may re-verify a
--   rejected payment (payments_apply_verification supports rejected →
--   verified).
--
-- Idempotent: drop function/trigger if exists, then re-create.
-- =====================================================================

drop function if exists public.payments_verified_immutable();
create or replace function public.payments_verified_immutable()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if old.payment_status = 'verified' then
      raise exception 'verified payments cannot be deleted; refund the appointment instead'
        using errcode = 'P0001';
    end if;
    return old;
  end if;

  if old.payment_status = 'verified' then
    if new.payment_status is distinct from old.payment_status
       or new.amount                 is distinct from old.amount
       or new.payment_method         is distinct from old.payment_method
       or new.transaction_id         is distinct from old.transaction_id
       or new.sender_number          is distinct from old.sender_number
       or new.gateway                is distinct from old.gateway
       or new.gateway_transaction_id is distinct from old.gateway_transaction_id
       or new.admin_share            is distinct from old.admin_share
       or new.provider_share         is distinct from old.provider_share
       or new.verified_by            is distinct from old.verified_by
       or new.verified_at            is distinct from old.verified_at
       or new.refunded_at            is distinct from old.refunded_at
       or new.rejection_reason       is distinct from old.rejection_reason
       or new.notes                  is distinct from old.notes then
      raise exception 'verified payments are immutable; refund the appointment instead'
        using errcode = 'P0001';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists payments_verified_immutable_trg on public.payments;
create trigger payments_verified_immutable_trg
  before update or delete on public.payments
  for each row execute function public.payments_verified_immutable();
