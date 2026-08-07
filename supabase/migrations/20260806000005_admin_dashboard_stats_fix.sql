-- ---------------------------------------------------------------------
-- Fix admin_dashboard_stats() gate.
--
-- `RETURN QUERY` in plpgsql appends rows and continues execution; it does
-- NOT exit the function. The old body fell through to the `raise exception
-- 'admin only'` line after returning the dashboard row, so EVERY caller got
-- 42501 -- even a genuine admin (is_admin() itself was fine; a plain RPC
-- call returned true). Restructure to gate-first / raise-first so the query
-- is returned only for admins.
-- ---------------------------------------------------------------------
create or replace function public.admin_dashboard_stats()
returns setof public.admin_dashboard_stats
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;
  return query select * from public.admin_dashboard_stats;
end;
$$;

grant execute on function public.admin_dashboard_stats() to authenticated;
