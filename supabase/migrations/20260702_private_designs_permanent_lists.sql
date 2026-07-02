-- Bug: my_private_designs() (buyer-facing "My Suppliers" design grid) only
-- resolved designs via an explicit catalog_designs membership row. Permanent
-- stock lists carry NO catalog_designs rows (they're condition-based:
-- filter_brand_ids/qualities/surfaces/sizes/tile_types/stock_types/box range,
-- evaluated per design at read time) — so a buyer who claims a permanent
-- list's share link gets the claim recorded (my_claimed_catalogs still shows
-- it, hence the success toast) but zero designs ever show. This mirrors the
-- exact fix already applied to the stockist's own my_stock() in
-- 20260703_stock_list_multi_brand_and_dashboard.sql, applied here too.
create or replace function public.my_private_designs()
 returns setof market_designs
 language sql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  select d.id,
         coalesce((select bn.brand_design_name from stockist_library_brand_names bn
                   where bn.library_id = d.library_id and bn.brand_id = c.brand_id),
                  lib.master_design_name, d.name) as name,
         d.size, d.surface_type, d.quality, lib.colour,
         public.effective_stock_type(lib.stock_type, d.quality) as stock_type,
         d.box_quantity, lib.pieces_per_box,
         lib.box_weight_kg::numeric(8,2), lib.thickness_mm::numeric(6,2),
         case when nullif(btrim(coalesce(lib.image_url,'')),'') is not null
              then array[lib.image_url] else '{}'::text[] end,
         d.status, d.created_at, d.updated_at, lib.finish_label, lib.tile_type,
         c.id as catalog_id, s.priority as stockist_priority,
         s.sequential_id as stockist_key, s.name as stockist_display_name,
         s.city as stockist_city, br.name as brand_name
  from dealer_catalog_access a
  join stock_catalogs c on c.id = a.catalog_id
  join designs d on d.stockist_id = a.stockist_id
  join stockists s on s.id = a.stockist_id
  join stockist_library lib on lib.id = d.library_id
  left join brands br on br.id = c.brand_id
  where a.end_user_id = (select id from end_users where user_id = auth.uid())
    and a.is_active and s.is_active and c.is_active
    and d.box_quantity > 0 and d.status <> 'out_of_stock'
    and (
      (coalesce(c.list_type,'permanent') = 'temporary' and exists (
        select 1 from catalog_designs cd
        where cd.catalog_id = c.id and cd.library_id = d.library_id
      ))
      or
      (coalesce(c.list_type,'permanent') = 'permanent'
        and (array_length(c.filter_brand_ids,1) is null
             or coalesce(d.brand_id, lib.brand_id) = any(c.filter_brand_ids))
        and (array_length(c.filter_qualities,1) is null or d.quality = any(c.filter_qualities))
        and (array_length(c.filter_surfaces,1) is null or d.surface_type = any(c.filter_surfaces))
        and (array_length(c.filter_sizes,1) is null or d.size = any(c.filter_sizes))
        and (array_length(c.filter_tile_types,1) is null or lib.tile_type = any(c.filter_tile_types))
        and (array_length(c.filter_stock_types,1) is null
             or effective_stock_type(lib.stock_type, d.quality) = any(c.filter_stock_types))
        and (c.filter_box_min is null
             or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) >= c.filter_box_min)
        and (c.filter_box_max is null
             or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) <= c.filter_box_max)
      )
    );
$function$;
