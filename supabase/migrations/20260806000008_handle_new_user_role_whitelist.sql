-- =====================================================================
-- 20260806000008_handle_new_user_role_whitelist.sql
--
-- CRITICAL privilege-escalation fix.
--
-- THE BUG
--   handle_new_user() copied the signup request's `role` metadata into
--   public.users.role with only an enum cast as its guard:
--
--     v_role := coalesce((new.raw_user_meta_data ->> 'role')::public.user_role,
--                        'patient');
--
--   `user_role` is an enum that CONTAINS 'admin' (schema.sql), and
--   raw_user_meta_data is entirely client-supplied (the app's own Dart
--   whitelist is not a security boundary). A patched client or a direct
--   GoTrue signUp call with user_metadata={"role":"admin"} created a
--   public.users row with role='admin', making is_admin() true and
--   granting full admin RLS bypass. The aa_guard_users trigger only blocks
--   changing role afterwards; it never sees the initial insert.
--
-- THE FIX
--   Whitelist the five self-registerable roles. Any other value — missing,
--   invalid, or 'admin' — clamps to 'patient'. Admin accounts are created
--   only by supabase/admin_bootstrap.sql (or manually), never by signup.
--
-- Idempotent: CREATE OR REPLACE.
-- =====================================================================

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.user_role;
begin
  begin
    v_role := case
      when (new.raw_user_meta_data ->> 'role') in
        ('patient', 'doctor', 'hospital', 'clinic', 'pharmacy')
      then (new.raw_user_meta_data ->> 'role')::public.user_role
      else 'patient'::public.user_role
    end;
  exception when invalid_text_representation or others then
    v_role := 'patient';
  end;

  insert into public.users (id, email, name, phone, gender, role, city)
  values (
    new.id,
    new.email,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'name'), ''), split_part(new.email, '@', 1)),
    nullif(trim(new.raw_user_meta_data ->> 'phone'), ''),
    case
      when (new.raw_user_meta_data ->> 'gender') in ('male', 'female', 'other')
      then (new.raw_user_meta_data ->> 'gender')::public.gender_type
    end,
    v_role,
    nullif(trim(new.raw_user_meta_data ->> 'city'), '')
  )
  on conflict (id) do nothing;

  return new;
end;
$$;
