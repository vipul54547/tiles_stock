-- Phase 4 of project_unified_dispatch_customers: the admin opt-in toggle.
-- 20260708_customers_and_walkin_dispatch.sql added stockists.customers_enabled
-- (default false) and gated upsert_customer on it, but nothing could flip it —
-- so every stockist was stuck with the plain-text Customer field on dispatch.
--
-- Trust-first: OFF means nothing about a customer is stored. Admin-only, and
-- mirrors admin_set_stockist_td.
create or replace function public.admin_set_stockist_customers(p_seq text, p_enabled boolean)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
begin
  if current_user_role() <> 'admin' then
    raise exception 'admin only';
  end if;
  update public.stockists set customers_enabled = coalesce(p_enabled, false)
   where sequential_id = p_seq;
end;
$function$;

revoke execute on function public.admin_set_stockist_customers(text, boolean) from public;
grant  execute on function public.admin_set_stockist_customers(text, boolean) to authenticated;
