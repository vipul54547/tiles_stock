-- Scenario-2 buyer merge · Step 1.
-- my_private_designs() previously JOINed each in-stock design to every claimed
-- catalog that contained it, so a design published in N claimed lists produced N
-- identical buyer rows (the same tile duplicated on every buyer surface). Rewrite
-- so each holding (design row) appears EXACTLY ONCE: the set of claimed lists it
-- belongs to is folded into a catalog_ids uuid[] via a lateral aggregate, and the
-- single catalog_id column is dropped. Return type therefore changes from
-- `SETOF market_designs` to an explicit table, so the old function must be
-- dropped first.
--
-- Also: brand identity (the alias name shown + brand_name) is now keyed on the
-- HOLDING's own brand (coalesce(d.brand_id, lib.brand_id)) rather than the
-- catalog's brand — per-brand stock means a design's brand is intrinsic, and a
-- permanent list may carry many brands or none. This makes brand_name a reliable
-- client merge key (Scenario-2 step 5: merge only within the same stockist+brand).
drop function if exists public.my_private_designs();

create function public.my_private_designs()
returns table (
  id uuid, name text, size text, surface_type text, quality text, colour text,
  stock_type text, box_quantity integer, pieces_per_box integer,
  box_weight_kg numeric, thickness_mm numeric, face_image_urls text[],
  status text, created_at timestamptz, updated_at timestamptz,
  finish_label text, tile_type text, catalog_ids uuid[],
  stockist_priority numeric, stockist_key text, stockist_display_name text,
  stockist_city text, brand_name text, library_id uuid, family_key text
)
language sql security definer
set search_path to 'public','extensions','pg_temp'
as $function$
  select d.id,
         coalesce((select bn.brand_design_name from stockist_library_brand_names bn
                   where bn.library_id = d.library_id
                     and bn.brand_id = coalesce(d.brand_id, lib.brand_id)),
                  lib.master_design_name, d.name) as name,
         d.size, d.surface_type, d.quality, lib.colour,
         public.effective_stock_type(lib.stock_type, d.quality) as stock_type,
         d.box_quantity, lib.pieces_per_box,
         lib.box_weight_kg::numeric(8,2), lib.thickness_mm::numeric(6,2),
         case when nullif(btrim(coalesce(lib.image_url,'')),'') is not null
              then array[lib.image_url] else '{}'::text[] end,
         d.status, d.created_at, d.updated_at, lib.finish_label, lib.tile_type,
         cat.ids as catalog_ids,
         s.priority as stockist_priority,
         s.sequential_id as stockist_key, s.name as stockist_display_name,
         s.city as stockist_city, br.name as brand_name,
         d.library_id, public._family_effective_key(d.library_id) as family_key
  from designs d
  join stockists s on s.id = d.stockist_id
  join stockist_library lib on lib.id = d.library_id
  left join brands br on br.id = coalesce(d.brand_id, lib.brand_id)
  cross join lateral (
    select array_agg(distinct c.id) as ids
    from dealer_catalog_access a
    join stock_catalogs c on c.id = a.catalog_id
    where a.end_user_id = (select id from end_users where user_id = auth.uid())
      and a.is_active and c.is_active and c.stockist_id = d.stockist_id
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
      )
  ) cat
  where s.is_active
    and d.box_quantity > 0 and d.status <> 'out_of_stock'
    and cat.ids is not null;
$function$;

grant execute on function public.my_private_designs() to authenticated;
