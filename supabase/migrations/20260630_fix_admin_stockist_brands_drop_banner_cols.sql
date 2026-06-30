-- The brand-banner removal (20260629_remove_brand_banner.sql) dropped
-- brands.{banner_source,banner_bg_url,company_logo_url,company_pos,td_pos} but left
-- admin_stockist_brands() still SELECTing them → it raised 42703 (column does not
-- exist); the service's try/catch swallowed it to [], so the admin Bulk-image-import
-- Brand dropdown came up empty and "Pick folder & scan" stayed disabled.
-- Fix: drop the dead column keys from the jsonb (only admin_stockist_brands was
-- orphaned; public_catalog / set_list_banner_config reference these names on
-- stock_catalogs, where per-list banner config still lives — those are fine).
CREATE OR REPLACE FUNCTION public.admin_stockist_brands(p_seq text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_stk uuid;
begin
  if current_user_role() <> 'admin' then raise exception 'Only admins'; end if;
  select id into v_stk from stockists where sequential_id = p_seq;
  if v_stk is null then raise exception 'Stockist not found'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', b.id, 'name', b.name, 'is_default', b.is_default,
      'status', b.status, 'stock_list_limit', b.stock_list_limit,
      'list_count', (select count(*) from stock_catalogs c where c.brand_id = b.id),
      'list_names', coalesce((select jsonb_agg(c.name order by c.sort_order)
                              from stock_catalogs c where c.brand_id = b.id), '[]'::jsonb))
      order by b.sort_order, b.created_at)
    from brands b where b.stockist_id = v_stk
  ), '[]'::jsonb);
end; $function$;
