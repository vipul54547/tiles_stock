-- My Stock Lists said 41 designs; the grid then showed 46. Both were "right",
-- and that is the bug: they counted different things.
--
--   my_claimed_catalogs.design_count : count(distinct library_id)  -> PRINTS
--   the buyer's grid (mergeByQuality) : one card per
--                                       (stockist, library, brand, surface)
--
-- A print stocked in three surfaces is ONE print but THREE cards — the buyer
-- buys a surface, not a print. So the list count under-reported by exactly the
-- number of extra surfaces (cura +2, livok +3 = the missing 5).
--
-- A count is a promise about what you are about to see. Count CARDS, using the
-- same key lib/utils/quality_merge.dart _mergeKey uses:
--     stockist | library_id | brand | surface_type
-- (stockist is already fixed per row here, and Premium+Standard fold into one
-- card, so they must NOT split the count — hence no quality in the key.)
--
-- Membership still resolves through both list kinds (manual via catalog_designs,
-- condition-based via the filters) — see 20260711_permanent_lists_everywhere.sql.

CREATE OR REPLACE FUNCTION public.my_claimed_catalogs()
 RETURNS TABLE(catalog_id uuid, catalog_name text, visibility text, stockist_key text, stockist_display_name text, stockist_city text, brand_name text, brand_logo text, design_count bigint, claimed_at timestamp with time zone)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  select c.id, c.name, c.visibility,
         s.sequential_id, s.name, s.city,
         case when b.id is not null and not b.is_default then b.name else null end,
         case when b.id is not null and not b.is_default then nullif(b.logo_url,'') else null end,
         (select count(distinct (d.library_id,
                                 coalesce(d.brand_id, lib.brand_id),
                                 d.surface_type))
            from designs d
            join stockist_library lib on lib.id = d.library_id
           where d.stockist_id = c.stockist_id
             and d.box_quantity > 0
             and d.status <> 'out_of_stock'
             and (
               -- MANUAL list: the rows the stockist ticked.
               (coalesce(c.list_type,'permanent') = 'temporary' and exists (
                  select 1 from catalog_designs cd
                   where cd.catalog_id = c.id and cd.library_id = d.library_id))
               or
               -- CONDITION-BASED list: whatever currently matches the filters.
               (coalesce(c.list_type,'permanent') = 'permanent'
                 and (array_length(c.filter_brand_ids,1) is null
                      or coalesce(d.brand_id, lib.brand_id) = any(c.filter_brand_ids))
                 and (array_length(c.filter_qualities,1) is null
                      or d.quality = any(c.filter_qualities))
                 and (array_length(c.filter_surfaces,1) is null
                      or d.surface_type = any(c.filter_surfaces))
                 and (array_length(c.filter_sizes,1) is null
                      or d.size = any(c.filter_sizes))
                 and (array_length(c.filter_tile_types,1) is null
                      or lib.tile_type = any(c.filter_tile_types))
                 and (array_length(c.filter_stock_types,1) is null
                      or effective_stock_type(lib.stock_type, d.quality) = any(c.filter_stock_types))
                 and (c.filter_box_min is null
                      or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) >= c.filter_box_min)
                 and (c.filter_box_max is null
                      or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) <= c.filter_box_max))
             )),
         a.claimed_at
  from dealer_catalog_access a
  join stock_catalogs c on c.id = a.catalog_id
  join stockists s      on s.id = a.stockist_id
  left join brands b    on b.id = c.brand_id
  where a.end_user_id = (select id from end_users where user_id = auth.uid())
    and a.is_active and c.is_active and s.is_active
  order by a.claimed_at desc;
$function$;
