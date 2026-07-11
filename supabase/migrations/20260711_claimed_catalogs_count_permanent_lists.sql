-- "My Stock Lists" showed every permanent list as "0 designs".
--
-- A stock list is one of two kinds ([[project_permanent_temporary_lists]]):
--   temporary — MANUAL. Membership is rows in catalog_designs.
--   permanent — CONDITION-BASED. Membership is the filters on the list itself
--               (brand / quality / surface / size / tile type / stock type /
--               box min-max). It has NO catalog_designs rows, by design.
--
-- my_claimed_catalogs.design_count only ever counted catalog_designs:
--
--   (select count(distinct cd.library_id) from catalog_designs cd
--      join designs d on d.library_id = cd.library_id ...
--     where cd.catalog_id = c.id ...)
--
-- so a permanent list — which never has those rows — always counted ZERO. Both
-- of the buyer's lists ('Livok Full', all filters empty = everything; and
-- 'Full Stock', filtered to one brand) are permanent, hence "0 designs" on both.
--
-- Display-only bug: my_private_designs (the Private tab grid) and public_catalog
-- both already resolve permanent lists through the filters, so the designs were
-- really there — the COUNT was the only liar.
--
-- Fix: count through the same membership rule the grid uses. The predicate below
-- is copied from my_private_designs so the number can never disagree with what
-- the buyer then sees. Still counts DISTINCT library_id (prints, not holdings) —
-- unchanged from before.

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
         (select count(distinct d.library_id)
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
               -- An empty filter array means "no condition on this facet".
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
