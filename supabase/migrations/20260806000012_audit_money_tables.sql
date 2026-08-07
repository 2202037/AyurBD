-- =====================================================================
-- 20260806000012_audit_money_tables.sql
--
-- Closes the audit gap on the commerce tables.
--
-- BACKGROUND
--   audit_row_change() is attached to 13 tables. provider_payouts was not
--   among them — yet it is the table where money actually changes hands
--   (admin marks a payout paid), and orders/order_items/payment_sessions
--   carry money or gateway activity that is also currently unlogged. A
--   settlement (or a suspicious one) left no trail.
--
-- THE FIX
--   Attach the existing generic audit trigger to provider_payouts,
--   orders, order_items, payment_sessions, cart and notifications. The
--   function is unchanged; audit_log already records old/new values and
--   the changed fields, and its SELECT grant already covers the admin
--   audit-log screen.
--
-- Idempotent: DROP IF EXISTS / CREATE per table.
-- =====================================================================

drop trigger if exists provider_payouts_audit on public.provider_payouts;
create trigger provider_payouts_audit
  after insert or update or delete on public.provider_payouts
  for each row execute function public.audit_row_change();

drop trigger if exists orders_audit on public.orders;
create trigger orders_audit
  after insert or update or delete on public.orders
  for each row execute function public.audit_row_change();

drop trigger if exists order_items_audit on public.order_items;
create trigger order_items_audit
  after insert or update or delete on public.order_items
  for each row execute function public.audit_row_change();

drop trigger if exists payment_sessions_audit on public.payment_sessions;
create trigger payment_sessions_audit
  after insert or update or delete on public.payment_sessions
  for each row execute function public.audit_row_change();

drop trigger if exists cart_audit on public.cart;
create trigger cart_audit
  after insert or update or delete on public.cart
  for each row execute function public.audit_row_change();

drop trigger if exists notifications_audit on public.notifications;
create trigger notifications_audit
  after insert or update or delete on public.notifications
  for each row execute function public.audit_row_change();
