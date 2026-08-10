-- =====================================================================
-- AYUR — migration: Stripe Payment Integration  (SUPERSEDED — no-op)
-- =====================================================================
--
-- This file is intentionally empty of DDL. Its original contents could
-- never have been applied to any database.
--
-- WHY
--   The original body contained eight `end if` statements without the
--   terminating semicolon, inside public.payment_health_check() — for
--   example:
--
--       if not v_stripe_secret_exists then v_overall_status := 'unhealthy' end if;
--
--   That is a hard PL/pgSQL parse error. Postgres raises it while
--   compiling the CREATE FUNCTION statement, and because Supabase runs
--   each migration file inside a single transaction, the failure rolled
--   the WHOLE file back. Nothing in it — not the Stripe columns, not the
--   enum value, not record_payment_split(), confirm_appointment(),
--   handle_failed_payment() or payment_health_check() — ever reached the
--   database. The Edge Functions were calling RPCs that did not exist.
--
--   The file had three further defects that would have bitten even after
--   the syntax was corrected:
--
--     1. `alter type public.appointment_status add value 'pending_payment'`
--        appeared at the top and the value was then used later in the
--        same file. Postgres forbids that ("unsafe use of new value of
--        enum type"), so the file could not succeed as one transaction
--        under any circumstances.
--
--     2. record_payment_split() selected a.fee / a.status into
--        v_payment.fee / v_payment.status against a
--        public.payments%rowtype. That table has `amount` and
--        `payment_status`; it has no `fee` and no `status`. Runtime error.
--        It also INSERTed a row with payment_status = 'verified' while the
--        settlement trigger was wired `before update of payment_status`,
--        so the commission split, the provider payout and the
--        "appointment is paid" write would never have fired.
--
--     3. confirm_appointment() did `select d.user_id into v_appt.doctor_id`
--        — a uuid into a bigint column.
--
--   Finally it granted record_payment_split / confirm_appointment /
--   handle_failed_payment to `authenticated`, which would have let any
--   signed-in user mark their own appointment paid.
--
-- WHERE THE WORK LIVES NOW
--   20260809000001_appointment_status_pending_payment.sql
--       the enum value, alone in its own transaction.
--   20260809000002_payment_architecture_fix.sql
--       the Stripe columns and indexes, corrected and idempotent
--       record_payment_split / confirm_appointment / handle_failed_payment,
--       a payment_health_check that parses, and the grants tightened to
--       service_role only.
--
-- The file is kept rather than deleted so the migration ledger of any
-- database that recorded it stays consistent. It is safe to run.
-- =====================================================================

do $$
begin
  raise notice
    '20260808000001_stripe_payment_integration is a no-op; superseded by 20260809000001 and 20260809000002.';
end;
$$;
