-- CONDITION-BASED (permanent) lists were invisible to half the schema.
--
-- A stock list is one of two kinds ([[project_permanent_temporary_lists]]):
--   temporary — MANUAL. Membership = rows in catalog_designs.
--   permanent — CONDITION-BASED. Membership = the list's own filters. It holds
--               NO catalog_designs rows, by design.
--
-- Anything that resolved membership by joining catalog_designs alone therefore
-- treated every permanent list as EMPTY. my_stock, my_private_designs,
-- public_catalog and (as of 20260711_claimed_catalogs_count_permanent_lists)
-- my_claimed_catalogs all handle both kinds. These four did not:
--
--   1. market_designs  (view) — a PUBLIC permanent list never reached the buyer
--      marketplace at all. The stockist ticks "show in marketplace", and nothing
--      appears. THE REAL BUG.
--   2. public_designs  (view) — same blind spot. Currently unread by the app,
--      fixed so it cannot become a trap later.
--   3. design_lists / set_design_lists — the stockist's per-design "which lists
--      is this in" tick-boxes. A permanent list was offered as TICKABLE, and
--      ticking it wrote a catalog_designs row that the list then ignored: a
--      silent no-op. Membership there is the conditions, not a tick.
--   4. my_inquiries — an order's `brands` were derived by walking
--      catalog_designs, so they came back EMPTY for designs that only live in a
--      condition-based list.
--
-- The membership predicate below is the same one my_private_designs uses, so no
-- two places can disagree about what is in a list.

-- ── 1) market_designs: a public CONDITION-BASED list reaches the marketplace ──
CREATE OR REPLACE VIEW public.market_designs AS
 SELECT d.id,
    d.name,
    d.size,
    d.surface_type,
    d.quality,
    lib.colour,
    effective_stock_type(lib.stock_type, d.quality) AS stock_type,
    GREATEST(0, d.box_quantity - d.control_quantity - held_of(d.id)) AS box_quantity,
    lib.pieces_per_box,
    lib.box_weight_kg::numeric(8,2) AS box_weight_kg,
    lib.thickness_mm::numeric(6,2) AS thickness_mm,
        CASE
            WHEN NULLIF(btrim(COALESCE(lib.image_url, ''::text)), ''::text) IS NOT NULL THEN ARRAY[lib.image_url]
            ELSE '{}'::text[]
        END AS face_image_urls,
    d.status,
    d.created_at,
    d.updated_at,
    lib.finish_label,
    lib.tile_type,
    NULL::uuid AS catalog_id,
    s.priority AS stockist_priority,
    s.sequential_id AS stockist_key,
    s.name AS stockist_display_name,
    s.city AS stockist_city,
    br.name AS brand_name,
    d.library_id,
    _family_effective_key(d.library_id) AS family_key,
    d.surface_label
   FROM designs d
     JOIN stockists s ON s.id = d.stockist_id
     LEFT JOIN stockist_library lib ON lib.id = d.library_id
     LEFT JOIN brands br ON br.id = lib.brand_id
  WHERE s.is_active = true
    AND s.is_listed = true
    AND d.status <> 'out_of_stock'::text
    AND (d.box_quantity - d.control_quantity - held_of(d.id)) > 0
    AND EXISTS (
          SELECT 1
            FROM stock_catalogs c
           WHERE c.stockist_id = d.stockist_id
             AND c.visibility = 'public'::text
             AND c.show_in_marketplace = true
             AND c.is_active = true
             AND (
               (COALESCE(c.list_type,'permanent') = 'temporary' AND EXISTS (
                  SELECT 1 FROM catalog_designs cd
                   WHERE cd.catalog_id = c.id AND cd.library_id = d.library_id))
               OR
               (COALESCE(c.list_type,'permanent') = 'permanent'
                 AND (array_length(c.filter_brand_ids,1) IS NULL
                      OR COALESCE(d.brand_id, lib.brand_id) = ANY(c.filter_brand_ids))
                 AND (array_length(c.filter_qualities,1) IS NULL
                      OR d.quality = ANY(c.filter_qualities))
                 AND (array_length(c.filter_surfaces,1) IS NULL
                      OR d.surface_type = ANY(c.filter_surfaces))
                 AND (array_length(c.filter_sizes,1) IS NULL
                      OR d.size = ANY(c.filter_sizes))
                 AND (array_length(c.filter_tile_types,1) IS NULL
                      OR lib.tile_type = ANY(c.filter_tile_types))
                 AND (array_length(c.filter_stock_types,1) IS NULL
                      OR effective_stock_type(lib.stock_type, d.quality) = ANY(c.filter_stock_types))
                 AND (c.filter_box_min IS NULL
                      OR GREATEST(0, d.box_quantity - d.control_quantity - held_of(d.id)) >= c.filter_box_min)
                 AND (c.filter_box_max IS NULL
                      OR GREATEST(0, d.box_quantity - d.control_quantity - held_of(d.id)) <= c.filter_box_max))
             ));

-- ── 2) public_designs: same membership rule (view is currently unread) ────────
CREATE OR REPLACE VIEW public.public_designs AS
 SELECT d.id,
    d.stockist_id,
    d.name,
    d.size,
    d.surface_type,
    d.quality,
    lib.colour,
    effective_stock_type(lib.stock_type, d.quality) AS stock_type,
    d.box_quantity,
    lib.pieces_per_box,
    lib.box_weight_kg::numeric(8,2) AS box_weight_kg,
    lib.thickness_mm::numeric(6,2) AS thickness_mm,
        CASE
            WHEN NULLIF(btrim(COALESCE(lib.image_url, ''::text)), ''::text) IS NOT NULL THEN ARRAY[lib.image_url]
            ELSE '{}'::text[]
        END AS face_image_urls,
    d.status,
    d.created_at,
    d.updated_at,
    lib.finish_label,
    s.priority AS stockist_priority,
    lib.tile_type
   FROM designs d
     JOIN stockists s ON s.id = d.stockist_id
     LEFT JOIN stockist_library lib ON lib.id = d.library_id
  WHERE s.is_active = true
    AND d.status <> 'out_of_stock'::text
    AND d.box_quantity > 0
    AND EXISTS (
          SELECT 1
            FROM stock_catalogs c
           WHERE c.stockist_id = d.stockist_id
             AND c.visibility = 'public'::text
             AND c.show_in_marketplace = true
             AND c.is_active = true
             AND (
               (COALESCE(c.list_type,'permanent') = 'temporary' AND EXISTS (
                  SELECT 1 FROM catalog_designs cd
                   WHERE cd.catalog_id = c.id AND cd.library_id = d.library_id))
               OR
               (COALESCE(c.list_type,'permanent') = 'permanent'
                 AND (array_length(c.filter_brand_ids,1) IS NULL
                      OR COALESCE(d.brand_id, lib.brand_id) = ANY(c.filter_brand_ids))
                 AND (array_length(c.filter_qualities,1) IS NULL
                      OR d.quality = ANY(c.filter_qualities))
                 AND (array_length(c.filter_surfaces,1) IS NULL
                      OR d.surface_type = ANY(c.filter_surfaces))
                 AND (array_length(c.filter_sizes,1) IS NULL
                      OR d.size = ANY(c.filter_sizes))
                 AND (array_length(c.filter_tile_types,1) IS NULL
                      OR lib.tile_type = ANY(c.filter_tile_types))
                 AND (array_length(c.filter_stock_types,1) IS NULL
                      OR effective_stock_type(lib.stock_type, d.quality) = ANY(c.filter_stock_types))
                 AND (c.filter_box_min IS NULL
                      OR GREATEST(0, d.box_quantity - d.control_quantity - held_of(d.id)) >= c.filter_box_min)
                 AND (c.filter_box_max IS NULL
                      OR GREATEST(0, d.box_quantity - d.control_quantity - held_of(d.id)) <= c.filter_box_max))
             ));

-- ── 3) design_lists: tell the truth about condition-based lists ───────────────
-- `auto` = this list is condition-based; its membership is its filters, so the
-- UI must show it as read-only. `member` is now computed the right way for both
-- kinds, so a stockist can SEE that a design is in an auto list without being
-- offered a tick that does nothing.
CREATE OR REPLACE FUNCTION public.design_lists(p_design_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  with me as (select id as stk from stockists where user_id = auth.uid()),
  dd as (
    select d.id, d.library_id, d.brand_id, d.quality, d.size, d.surface_type,
           d.box_quantity, d.control_quantity,
           l.brand_id as lib_brand, l.tile_type as lib_tile, l.stock_type as lib_stock
    from designs d
    join stockist_library l on l.id = d.library_id
    where d.id = p_design_id and d.stockist_id = (select stk from me)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'catalog_id', c.id,
           'name', c.name,
           'brand_id', c.brand_id,
           'brand_name', coalesce(b.name, ''),
           'is_default', coalesce(b.is_default, false),
           'auto', coalesce(c.list_type,'permanent') = 'permanent',
           'member', case
             when coalesce(c.list_type,'permanent') = 'temporary' then
               exists (select 1 from catalog_designs cd
                        where cd.catalog_id = c.id and cd.library_id = dd.library_id)
             else
               (array_length(c.filter_brand_ids,1) is null
                 or coalesce(dd.brand_id, dd.lib_brand) = any(c.filter_brand_ids))
               and (array_length(c.filter_qualities,1) is null
                 or dd.quality = any(c.filter_qualities))
               and (array_length(c.filter_surfaces,1) is null
                 or dd.surface_type = any(c.filter_surfaces))
               and (array_length(c.filter_sizes,1) is null
                 or dd.size = any(c.filter_sizes))
               and (array_length(c.filter_tile_types,1) is null
                 or dd.lib_tile = any(c.filter_tile_types))
               and (array_length(c.filter_stock_types,1) is null
                 or effective_stock_type(dd.lib_stock, dd.quality) = any(c.filter_stock_types))
               and (c.filter_box_min is null
                 or greatest(0, dd.box_quantity - dd.control_quantity - held_of(dd.id)) >= c.filter_box_min)
               and (c.filter_box_max is null
                 or greatest(0, dd.box_quantity - dd.control_quantity - held_of(dd.id)) <= c.filter_box_max)
           end)
         order by coalesce(b.is_default, false) desc, b.sort_order nulls last, c.sort_order), '[]'::jsonb)
  from stock_catalogs c
  cross join dd
  left join brands b on b.id = c.brand_id
  where c.stockist_id = (select stk from me) and c.is_active
    and (c.brand_id is null
         or c.brand_id = dd.lib_brand
         or exists (select 1 from stockist_library_brand_names a
                    where a.library_id = dd.library_id and a.brand_id = c.brand_id));
$function$;

-- ── 4) set_design_lists: never write manual membership into an auto list ──────
-- Defence in depth: even an out-of-date client cannot put catalog_designs rows
-- into a condition-based list (they would be silently ignored anyway).
CREATE OR REPLACE FUNCTION public.set_design_lists(p_design_id uuid, p_catalog_ids uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_stk uuid; v_lib uuid; v_lib_brand uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  select library_id into v_lib from designs where id = p_design_id and stockist_id = v_stk;
  if v_lib is null then raise exception 'Not your design'; end if;
  select brand_id into v_lib_brand from stockist_library where id = v_lib;

  delete from catalog_designs cd
  where cd.library_id = v_lib
    and not (cd.catalog_id = any(coalesce(p_catalog_ids, '{}'::uuid[])))
    and exists (select 1 from stock_catalogs c
                where c.id = cd.catalog_id and c.stockist_id = v_stk
                  and coalesce(c.list_type,'permanent') = 'temporary'
                  and (c.brand_id is null or c.brand_id = v_lib_brand
                       or exists (select 1 from stockist_library_brand_names a
                                  where a.library_id = v_lib and a.brand_id = c.brand_id)));

  insert into catalog_designs (catalog_id, library_id)
  select c.id, v_lib
  from stock_catalogs c
  where c.stockist_id = v_stk
    and c.id = any(coalesce(p_catalog_ids, '{}'::uuid[]))
    and coalesce(c.list_type,'permanent') = 'temporary'
    and (c.brand_id is null or c.brand_id = v_lib_brand
         or exists (select 1 from stockist_library_brand_names a
                    where a.library_id = v_lib and a.brand_id = c.brand_id))
  on conflict do nothing;
end; $function$;

-- ── 5) my_inquiries: an order's brands come from its DESIGNS, not from lists ──
-- Walking catalog_designs meant a design that lives only in a condition-based
-- list contributed NO brand. Stock is per-brand (designs.brand_id), so read it
-- from the design. Rest of the function is byte-identical to what was live.
CREATE OR REPLACE FUNCTION public.my_inquiries()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  select coalesce(jsonb_agg(row order by row->>'updated_at' desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', i.id, 'token', i.token, 'status', i.status,
      'connection_code', i.connection_code, 'customer_hint', i.customer_hint,
      'source', i.source,
      'created_at', i.created_at, 'updated_at', i.updated_at,
      'confirmed_at', i.confirmed_at, 'locked_at', i.locked_at,
      'guarantee_until', i.guarantee_until, 'accepted_at', i.accepted_at,
      'guarantee_days', i.guarantee_days,
      'end_user_id', i.end_user_id,
      'company', coalesce(e.company_name, ''), 'contact', coalesce(e.contact_person, ''),
      'phone', coalesce(e.phone, ''), 'country_code', coalesce(e.country_code, '+91'),
      'city', coalesce(e.city, ''),
      'held_boxes', (select coalesce(sum(it.held_qty),0) from inquiry_items it where it.inquiry_id=i.id),
      'line_count', (select count(*) from inquiry_items it where it.inquiry_id=i.id),
      'total_boxes', (select coalesce(sum(it.quantity),0) from inquiry_items it where it.inquiry_id=i.id),
      'designs', coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'name',d.name) order by d.name)
             from inquiry_items it join designs d on d.id=it.design_id where it.inquiry_id=i.id), '[]'::jsonb),
      -- The order's brands come from the DESIGNS on it (stock is per-brand:
      -- designs.brand_id), not from whichever list happened to contain them.
      -- The old catalog_designs route went blank for CONDITION-BASED lists,
      -- which hold no catalog_designs rows at all.
      'brands', coalesce((select jsonb_agg(distinct b.name)
             from inquiry_items it
             join designs d on d.id=it.design_id
             left join stockist_library lib on lib.id = d.library_id
             join brands b on b.id = coalesce(d.brand_id, lib.brand_id) and not b.is_default
             where it.inquiry_id=i.id), '[]'::jsonb)
    ) as row
    from inquiries i left join end_users e on e.id = i.end_user_id
    where i.stockist_id in (select id from stockists where user_id = auth.uid())
      and not (i.end_user_id is not null and i.status = 'draft')
  ) t;
$function$
;

-- ── 6) set_list_designs: a condition-based list has no manual membership ──────
-- Writing catalog_designs rows into a permanent list was a silent no-op (the
-- list resolves its contents from its filters and never reads them). Say so
-- instead of pretending it worked. The UI only calls this for lists it just
-- created as 'temporary', so this is a guard, not a behaviour change.
CREATE OR REPLACE FUNCTION public.set_list_designs(p_catalog_id uuid, p_library_ids uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_stk uuid; v_n int; v_type text; v_ids uuid[] := coalesce(p_library_ids, '{}'::uuid[]);
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can manage stock lists'; end if;
  select coalesce(list_type,'permanent') into v_type
    from stock_catalogs where id = p_catalog_id and stockist_id = v_stk;
  if v_type is null then raise exception 'List not found'; end if;
  if v_type <> 'temporary' then
    raise exception 'This list fills itself from its conditions — edit the conditions, not the designs';
  end if;

  delete from catalog_designs
    where catalog_id = p_catalog_id and not (library_id = any(v_ids));
  insert into catalog_designs (catalog_id, library_id)
    select p_catalog_id, x from unnest(v_ids) x
    on conflict do nothing;
  select count(*) into v_n from catalog_designs where catalog_id = p_catalog_id;
  return v_n;
end;
$function$;
