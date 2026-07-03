-- Expose each holding's concept-family key on my_stock so the stockist dashboard
-- can group variants (1801-A / 1801-B / ...) inside one thin family boundary.
-- Key = _family_effective_key(library_id) (auto name-root or stockist override).
-- Grouping is per (size + family_key); the client draws the band. (design family P2)
CREATE OR REPLACE FUNCTION public.my_stock()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', d.id, 'name', d.name, 'size', d.size, 'quality', d.quality,
    'box_quantity', d.box_quantity, 'status', d.status, 'is_sample', d.is_sample,
    'control_quantity', d.control_quantity,
    'held_quantity', held_of(d.id),
    'f_stock', greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)),
    'library_id', d.library_id, 'created_at', d.created_at, 'updated_at', d.updated_at,
    'surface_type', d.surface_type, 'stock_type', lib.stock_type,
    'tile_type', lib.tile_type, 'pieces_per_box', lib.pieces_per_box,
    'box_weight_kg', lib.box_weight_kg, 'thickness_mm', lib.thickness_mm,
    'colour', lib.colour, 'finish_label', lib.finish_label,
    'image_url', lib.image_url, 'master_design_name', lib.master_design_name,
    'family_key', _family_effective_key(d.library_id),
    'brand_id', coalesce(d.brand_id, lib.brand_id),
    'stockist_key', s.sequential_id, 'stockist_priority', s.priority,
    'catalog_ids', (
      select coalesce(jsonb_agg(cid), '[]'::jsonb) from (
        select cd.catalog_id as cid
        from catalog_designs cd
        join stock_catalogs c on c.id = cd.catalog_id
        where cd.library_id = d.library_id and c.stockist_id = d.stockist_id
          and coalesce(c.list_type,'permanent') = 'temporary'
          and (c.brand_id is null or c.brand_id is not distinct from coalesce(d.brand_id, lib.brand_id))
        union
        select c.id as cid
        from stock_catalogs c
        where c.stockist_id = d.stockist_id and c.is_active
          and coalesce(c.list_type,'permanent') = 'permanent'
          and (array_length(c.filter_brand_ids,1) is null or d.brand_id = any(c.filter_brand_ids))
          and (array_length(c.filter_qualities,1) is null or d.quality = any(c.filter_qualities))
          and (array_length(c.filter_surfaces,1) is null or d.surface_type = any(c.filter_surfaces))
          and (array_length(c.filter_sizes,1) is null or d.size = any(c.filter_sizes))
          and (array_length(c.filter_tile_types,1) is null or lib.tile_type = any(c.filter_tile_types))
          and (array_length(c.filter_stock_types,1) is null or effective_stock_type(lib.stock_type, d.quality) = any(c.filter_stock_types))
          and (c.filter_box_min is null or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) >= c.filter_box_min)
          and (c.filter_box_max is null or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) <= c.filter_box_max)
      ) t
    )
  ) order by d.created_at desc), '[]'::jsonb)
  from designs d
  join stockists s on s.id = d.stockist_id
  left join stockist_library lib on lib.id = d.library_id
  where d.stockist_id = (select id from stockists where user_id = auth.uid());
$function$;
