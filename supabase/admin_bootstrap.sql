-- AYUR Supabase admin bootstrap
--
-- Usage:
-- 1) Create a user first in Supabase Dashboard -> Authentication -> Users.
-- 2) Replace the email below.
-- 3) Run this script in Supabase SQL Editor.
--
-- Note: SQL cannot create a passworded auth user directly in this project flow.
-- The password is the one you set in Authentication -> Users.

-- Set the target admin email.
-- Change this value before running.
with target as (
  select 'Admin@ayur.com'::text as email
)
update public.users u
set role = 'admin', updated_at = now()
from target t
where lower(u.email) = lower(t.email);

-- Verify target user role.
select id, email, role, created_at, updated_at
from public.users
where lower(email) = lower('Admin@ayur.com');

-- Optional: list all current admins.
select id, email, role
from public.users
where role = 'admin'
order by created_at;
