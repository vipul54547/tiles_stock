-- Phase B of project_per_brand_surface_mode: expose brands.surface_mode to the
-- admin brand screen so the per-brand attribute/in-name toggle can read it.
-- 20260708_brand_surface_mode.sql added the column + my_brands() + the setter;
-- admin_stockist_brands() (the admin-side reader) was left untouched, so the
-- admin UI had no current value to render. Same shape as
-- 20260630_fix_admin_stockist_brands_drop_banner_cols.sql, plus 'surface_mode'.
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
      'surface_mode', b.surface_mode,
      'list_count', (select count(*) from stock_catalogs c where c.brand_id = b.id),
      'list_names', coalesce((select jsonb_agg(c.name order by c.sort_order)
                              from stock_catalogs c where c.brand_id = b.id), '[]'::jsonb))
      order by b.sort_order, b.created_at)
    from brands b where b.stockist_id = v_stk
  ), '[]'::jsonb);
end; $function$;
