-- Add library_id + family_key to market_designs (guest/member buyer reads) and
-- my_private_designs (claimed lists, RETURNS SETOF market_designs) so the in-app
-- buyer grids (stockist portfolio) can group concept variants into a thin
-- coloured family band. Columns appended at the end (backward compatible).
-- (design family P2 · buyer surfaces)
create or replace view public.market_designs as
 SELECT d.id, d.name, d.size, d.surface_type, d.quality, lib.colour,
    effective_stock_type(lib.stock_type, d.quality) AS stock_type,
    GREATEST(0, d.box_quantity - d.control_quantity) AS box_quantity,
    lib.pieces_per_box,
    lib.box_weight_kg::numeric(8,2) AS box_weight_kg,
    lib.thickness_mm::numeric(6,2) AS thickness_mm,
    CASE WHEN NULLIF(btrim(COALESCE(lib.image_url, ''::text)), ''::text) IS NOT NULL THEN ARRAY[lib.image_url] ELSE '{}'::text[] END AS face_image_urls,
    d.status, d.created_at, d.updated_at, lib.finish_label, lib.tile_type,
    NULL::uuid AS catalog_id,
    s.priority AS stockist_priority,
    s.sequential_id AS stockist_key,
    s.name AS stockist_display_name,
    s.city AS stockist_city,
    br.name AS brand_name,
    d.library_id,
    _family_effective_key(d.library_id) AS family_key
   FROM designs d
     JOIN stockists s ON s.id = d.stockist_id
     LEFT JOIN stockist_library lib ON lib.id = d.library_id
     LEFT JOIN brands br ON br.id = lib.brand_id
  WHERE s.is_active = true AND s.is_listed = true AND d.status <> 'out_of_stock'::text AND (d.box_quantity - d.control_quantity) > 0 AND (EXISTS ( SELECT 1
           FROM catalog_designs cd
             JOIN stock_catalogs c ON c.id = cd.catalog_id
          WHERE cd.library_id = d.library_id AND c.stockist_id = d.stockist_id AND c.visibility = 'public'::text AND c.show_in_marketplace = true AND c.is_active = true));

create or replace function public.my_private_designs()
 returns setof market_designs
 language sql security definer
 set search_path to 'public','extensions','pg_temp'
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
         s.city as stockist_city, br.name as brand_name,
         d.library_id, _family_effective_key(d.library_id) as family_key
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
