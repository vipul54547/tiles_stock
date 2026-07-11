-- The buyer's PRIVATE grid was still advertising stock held for someone else.
--
-- F_Stock: free = max(0, P - C - H).  P = box_quantity, C = the hidden control
-- reserve, H = held_of() = boxes booked by other buyers' locked orders.
--
--   public_catalog     (/s/ link)     free   OK
--   market_designs     (open market)  free   OK  (fixed in 9c1c73a)
--   my_private_designs (a claimed supplier's list -- the buyer's
--                       "My Suppliers / All Design" grid)   RAW  *** WRONG ***
--
-- Live proof before this fix: 3202 Premium advertised 585 boxes with only 85
-- free, and CANYON 03_A Premium advertised 345 with ZERO free (fully held for
-- another order). A buyer picking from a claimed list was still choosing against
-- a fake number -- the very root cause the Send-time check exists to catch. Fix
-- the number they choose against, not just the gate at the end.
--
-- Rows with nothing free are now hidden, matching market_designs and
-- public_catalog: a fully-held design is not orderable, so it must not sit in
-- the grid inviting a click. If it is ALREADY in the basket it still appears in
-- My Choice as "Out of stock now" -- choices_availability reads the base table
-- for exactly this reason -- so no line is ever silently dropped.
--
-- my_claimed_catalogs must count by the SAME rule or the count and the grid
-- drift apart again (the 41-vs-46 bug). Both now count only what is free.

-- 1) my_private_designs: advertise FREE stock, hide what has none.
CREATE OR REPLACE FUNCTION public.my_private_designs()
 RETURNS TABLE(id uuid, name text, size text, surface_type text, surface_label text, quality text, colour text, stock_type text, box_quantity integer, pieces_per_box integer, box_weight_kg numeric, thickness_mm numeric, face_image_urls text[], status text, created_at timestamp with time zone, updated_at timestamp with time zone, finish_label text, tile_type text, catalog_ids uuid[], stockist_priority numeric, stockist_key text, stockist_display_name text, stockist_city text, brand_name text, library_id uuid, family_key text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  select d.id,
         coalesce((select bn.brand_design_name from stockist_library_brand_names bn
                   where bn.library_id = d.library_id
                     and bn.brand_id = coalesce(d.brand_id, lib.brand_id)),
                  lib.master_design_name, d.name) as name,
         d.size, d.surface_type, d.surface_label, d.quality, lib.colour,
         public.effective_stock_type(lib.stock_type, d.quality) as stock_type,
         greatest(0, d.box_quantity - d.control_quantity - held_of(d.id))::int as box_quantity,
         lib.pieces_per_box,
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
    and (d.box_quantity - d.control_quantity - held_of(d.id)) > 0
    and d.status <> 'out_of_stock'
    and cat.ids is not null;
$function$
;

-- 2) my_claimed_catalogs: count only what the grid will actually show.
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
             and (d.box_quantity - d.control_quantity - held_of(d.id)) > 0
             and d.status <> 'out_of_stock'
             and (
               (coalesce(c.list_type,'permanent') = 'temporary' and exists (
                  select 1 from catalog_designs cd
                   where cd.catalog_id = c.id and cd.library_id = d.library_id))
               or
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
