-- =====================================================================
-- 20260806000015_payments_transaction_ref_check.sql
--
-- Backend half of "every non-Cash payment needs a transaction reference".
--
-- WHY
--   payments.transaction_id is nullable and nothing enforced that a
--   bKash/Nagad/Rocket/card/bank-transfer payment actually carried one,
--   so a patient could submit the appointment fee "paid" with no way for
--   the admin to match it against a mobile-banking statement. The Flutter
--   sheet already collects (and server-422s on) the reference — see
--   my_appointments_screen.dart: "the server 422s any method except Cash
--   that arrives without one" — but the schema itself never refused it.
--
-- THE FIX
--   A CHECK that requires a non-blank transaction_id for every method
--   except Cash and sslcommerz:
--     * Cash is settled at the chamber, no reference exists.
--     * sslcommerz rows are written by the payment provider (service
--       role) and carry the gateway's own gateway_transaction_id instead.
--   The unique index uq_payments_gateway_txn already dedupes those.
--
--   Only the `payments` table is constrained. orders.transaction_id is
--   left alone because place_order() never collects a reference and the
--   pharmacy-confirm flow (orders_apply_verification) must not break.
--
-- Idempotent: drop constraint if exists, then re-add.
-- =====================================================================

alter table public.payments drop constraint if exists payments_transaction_ref_check;

alter table public.payments
  add constraint payments_transaction_ref_check check (
    payment_method in ('Cash', 'sslcommerz')
    or (transaction_id is not null and btrim(transaction_id) <> ''));
