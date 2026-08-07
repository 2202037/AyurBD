-- Reset the public schema to empty before the rebuild.
--
-- The linked project carries a stale schema from earlier ad-hoc runs, so
-- `20260806000001_schema.sql` cannot `create table` over it. This drops
-- everything in `public` and recreates the schema with the grants Supabase
-- applies by default. Run this ONLY on a project whose data is disposable —
-- it erases every public table, view, function and trigger.
drop schema if exists public cascade;
create schema public;

alter default privileges revoke execute on functions from public;
alter default privileges grant execute on functions to postgres, anon, authenticated, service_role;

grant all on schema public to postgres, anon, authenticated, service_role;
