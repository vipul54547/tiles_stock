-- 20260720a — DROP surface_mode. It decided nothing.
--
-- `stockists.surface_mode` / `brands.surface_mode` ('attribute' | 'in_name') described how a factory
-- STAMPS ITS BOXES — the physical box, nothing else. It never had any influence on identity, and
-- both jobs it was ever given were workarounds that are now gone:
--
--   1. It stamped a surface onto `stockist_library` — a workaround for the old broken product key.
--      Surface became real product identity (`surface_type` NOT NULL), so that went.
--   2. It gated the surface question at Add Stock — a workaround for a design picker that showed
--      only the PRINT's name (`1001`) and could not tell that print's three pieces apart. The picker
--      names the PIECE now (`1001 — MATTE`, utils/piece_label.dart), so the question is answered at
--      the point of choosing. Deleted 14 Jul (20260714c_stock_add_holding_never_creates_a_product).
--
-- What tells two pieces of one print apart is NOT predictable from the mode: famous is 'attribute'
-- and forks by SURFACE; cura is 'in_name' and forks by THICKNESS. Any code that branches on it gets
-- one of them wrong — so no code branches on it, and none should be able to again.
--
-- Reader sweep (pg_proc + information_schema.views): exactly 4 functions, no views. Two are the
-- setters below; two only echoed the column out in their JSON payload. Nothing branched on it.

-- 1. The setters. Nothing writes it any more (the admin toggle is deleted).
drop function if exists public.admin_set_stockist_surface_mode(text, text);
drop function if exists public.admin_set_brand_surface_mode(uuid, text);

-- 2. The two readers, with the key removed from the payload.
create or replace function public.admin_stockist_brands(p_seq text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
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

create or replace function public.my_brands()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', b.id, 'name', b.name, 'logo_url', b.logo_url,
           'sort_order', b.sort_order, 'is_active', b.is_active,
           'is_default', b.is_default, 'status', b.status,
           'hidden_by_stockist', b.hidden_by_stockist,
           'delete_scheduled_at', b.delete_scheduled_at,
           'catalog_count', (select count(*) from stock_catalogs c where c.brand_id = b.id))
         order by b.sort_order, b.created_at), '[]'::jsonb)
  from brands b
  where b.stockist_id in (select id from stockists where user_id = auth.uid())
    and b.status <> 'off';
$function$;

-- 3. The columns themselves.
alter table public.stockists drop column if exists surface_mode;
alter table public.brands    drop column if exists surface_mode;

-- Self-check: no function body may mention it any more.
do $$
declare n int;
begin
  select count(*) into n
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.prosrc ilike '%surface_mode%';
  if n > 0 then
    raise exception 'surface_mode still referenced by % function(s)', n;
  end if;
end $$;
