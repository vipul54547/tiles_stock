-- Per-brand surface mode (project_per_brand_surface_mode).
-- The surface convention is a property of the BRAND / manufacturer:
--   'attribute' → surface is a real, REQUIRED attribute (Famous: "Satva White" +
--                 Glossy/Matt/Carving); part of identity (name+size+surface);
--                 shown next to the name. "None" is never a valid surface here.
--   'in_name'   → surface is baked into the design name (Cura: "cr satva white");
--                 no separate surface field; identity = name+size. (= today)
-- Per-BRAND (not per-stockist) because a T/W stockist carries many brands at once
-- and takes each manufacturer's data as-is. Default 'in_name' so nothing existing
-- changes; admin opts a brand into 'attribute'.
alter table public.brands
  add column if not exists surface_mode text not null default 'in_name'
    check (surface_mode in ('attribute', 'in_name'));

-- Expose surface_mode to the stockist app.
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
           'surface_mode', b.surface_mode,
           'catalog_count', (select count(*) from stock_catalogs c where c.brand_id = b.id))
         order by b.sort_order, b.created_at), '[]'::jsonb)
  from brands b
  where b.stockist_id in (select id from stockists where user_id = auth.uid())
    and b.status <> 'off';
$function$;

-- Admin sets a brand's surface mode.
create or replace function public.admin_set_brand_surface_mode(p_brand_id uuid, p_mode text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
begin
  if current_user_role() <> 'admin' then
    raise exception 'Only admins can set the surface mode';
  end if;
  if p_mode not in ('attribute', 'in_name') then
    raise exception 'Invalid surface mode';
  end if;
  update brands set surface_mode = p_mode where id = p_brand_id;
end;
$function$;

grant execute on function public.admin_set_brand_surface_mode(uuid, text) to authenticated;
