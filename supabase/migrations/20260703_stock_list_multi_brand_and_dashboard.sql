-- Two fixes for the permanent (condition-based) stock-list feature:
--   Q1  Multi-brand: replace single filter_brand_id uuid with filter_brand_ids uuid[]
--       so a permanent list can target several brands at once.
--   Q2  Dashboard visibility: my_stock().catalog_ids now also includes permanent
--       lists whose conditions a design matches (they carry no catalog_designs
--       rows, so previously they never showed in the stockist's own dashboard).

-- ── 1. Schema: single brand → brand array ────────────────────────────────────
alter table public.stock_catalogs
  add column if not exists filter_brand_ids uuid[] not null default '{}';

-- Migrate the existing single value into the array.
update public.stock_catalogs
   set filter_brand_ids = array[filter_brand_id]
 where filter_brand_id is not null
   and (filter_brand_ids is null or array_length(filter_brand_ids, 1) is null);

-- Retire the old single-brand overloads (they reference filter_brand_id).
drop function if exists public.stock_list_save(
  uuid, text, text, text, uuid, text, text, text);
drop function if exists public.stock_list_save(
  uuid, text, text, text, uuid, text[], text[], text[], text[], text[], int, int);

-- ── 2. stock_list_save: brand array param ────────────────────────────────────
create or replace function public.stock_list_save(
  p_id uuid,
  p_name text,
  p_description text default '',
  p_list_type text default 'permanent',
  p_filter_brand_ids   uuid[] default '{}',
  p_filter_qualities   text[] default '{}',
  p_filter_surfaces    text[] default '{}',
  p_filter_sizes       text[] default '{}',
  p_filter_tile_types  text[] default '{}',
  p_filter_stock_types text[] default '{}',
  p_filter_box_min     int default null,
  p_filter_box_max     int default null
) returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_stk uuid; v_limit int; v_count int; v_order int; v_id uuid;
  v_name text := trim(coalesce(p_name, ''));
  v_desc text := nullif(trim(coalesce(p_description, '')), '');
  v_type text := case when coalesce(btrim(p_list_type),'') = 'temporary' then 'temporary' else 'permanent' end;
begin
  select id, coalesce(stock_list_limit, 3) into v_stk, v_limit
    from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can manage stock lists'; end if;
  if v_name = '' then raise exception 'Stock list name cannot be empty'; end if;

  if p_id is null then
    select count(*) into v_count from stock_catalogs
      where stockist_id = v_stk and brand_id is null and is_active;
    if v_count >= v_limit then
      raise exception 'Stock list limit reached (%). Ask the admin to allow more.', v_limit;
    end if;
    if exists (select 1 from stock_catalogs
               where stockist_id = v_stk and brand_id is null
                 and is_active and lower(name) = lower(v_name)) then
      raise exception 'You already have a stock list with that name';
    end if;
    select coalesce(max(sort_order), 0) + 10 into v_order
      from stock_catalogs where stockist_id = v_stk;
    insert into stock_catalogs
      (stockist_id, brand_id, name, description, visibility, show_in_marketplace,
       sort_order, is_anonymous, list_type, filter_brand_ids,
       filter_qualities, filter_surfaces, filter_sizes,
       filter_tile_types, filter_stock_types, filter_box_min, filter_box_max)
    values (v_stk, null, v_name, v_desc, 'private', false, v_order, false,
            v_type,
            coalesce(p_filter_brand_ids, '{}'),
            coalesce(p_filter_qualities,  '{}'),
            coalesce(p_filter_surfaces,   '{}'),
            coalesce(p_filter_sizes,      '{}'),
            coalesce(p_filter_tile_types, '{}'),
            coalesce(p_filter_stock_types,'{}'),
            p_filter_box_min, p_filter_box_max)
    returning id into v_id;
    return v_id;
  else
    update stock_catalogs set
      name = v_name, description = v_desc,
      list_type          = v_type,
      filter_brand_ids   = coalesce(p_filter_brand_ids, '{}'),
      filter_qualities   = coalesce(p_filter_qualities,  '{}'),
      filter_surfaces    = coalesce(p_filter_surfaces,   '{}'),
      filter_sizes       = coalesce(p_filter_sizes,      '{}'),
      filter_tile_types  = coalesce(p_filter_tile_types, '{}'),
      filter_stock_types = coalesce(p_filter_stock_types,'{}'),
      filter_box_min     = p_filter_box_min,
      filter_box_max     = p_filter_box_max
    where id = p_id and stockist_id = v_stk;
    if not found then raise exception 'List not found'; end if;
    return p_id;
  end if;
end;
$function$;

-- ── 3. public_catalog: brand-array matching (web share path) ──────────────────
CREATE OR REPLACE FUNCTION public.public_catalog(p_token text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  select coalesce(
    -- Path 1: token → specific catalog (catalog-level share link)
    (select jsonb_build_object(
       'stockist', jsonb_build_object(
          'name', case when s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled() then s.public_display_name else s.name end,
          'id',   case when s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled() then s.public_code else s.sequential_id end,
          'phone', s.phone, 'country_code', s.country_code, 'city', s.city,
          'logo_url',   case when s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled() then null else s.logo_url end,
          'banner_url', case when s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled() then null else s.banner_url end,
          'address',    case when s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled() then null else s.address end,
          'map_url',    case when s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled() then null else s.map_url end,
          'tagline', s.tagline, 'brand_color', s.brand_color),
       'brand', (select case when not b.is_default
                   then jsonb_build_object('name', b.name, 'logo_url', nullif(b.logo_url, ''))
                   else null end from brands b where b.id = c.brand_id),
       'banner', case
         when nullif(btrim(coalesce(c.banner_source,'')),'') is not null then
           jsonb_build_object(
             'source', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled()) or c.banner_source = 'pool' then 'pool' else c.banner_source end,
             'bg_url',  case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled()) or c.banner_source = 'pool' then pick_generic_banner(s.id::text) else c.banner_bg_url end,
             'image_url', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled()) or c.banner_source = 'pool' then pick_generic_banner(s.id::text) else c.banner_bg_url end,
             'overlay', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled()) or c.banner_source = 'pool' then true else false end,
             'company_logo_url', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled()) then null else c.company_logo_url end,
             'company_pos', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled()) then 'none' else coalesce(c.company_pos,'none') end,
             'td_pos', coalesce(c.td_pos,'footer'),
             'name', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled())
                          then s.public_display_name
                          else coalesce((select nullif(b.name,'') from brands b where b.id = c.brand_id), s.name) end)
         when nullif(btrim(coalesce(c.banner_url,'')),'') is not null
         then jsonb_build_object('source','custom','bg_url',c.banner_url,'image_url',c.banner_url,'overlay',false,'company_logo_url',null,'company_pos','none','td_pos','footer','name',c.name)
         else jsonb_build_object('source','pool','bg_url',pick_generic_banner(s.id::text),'image_url',pick_generic_banner(s.id::text),'overlay',true,'company_logo_url',null,'company_pos','none','td_pos','footer','name', s.name) end,
       'catalog', jsonb_build_object('name', c.name, 'visibility', c.visibility),
       'dna_facets', public_dna_facets(c.stockist_id),
       'designs', coalesce((
         select jsonb_agg(jsonb_build_object(
           'id', d.id,
           'name', coalesce(
             (select bn.brand_design_name from stockist_library_brand_names bn
              where bn.library_id = d.library_id
                and bn.brand_id = coalesce(d.brand_id, c.brand_id)),
             lib.master_design_name, d.name),
           'size', d.size, 'surface', d.surface_type,
           'quality', d.quality, 'colour', lib.colour, 'tile_type', lib.tile_type,
           'boxes', greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)),
           'images', case when nullif(btrim(coalesce(lib.image_url,'')),'') is not null then array[lib.image_url] else '{}'::text[] end,
           'finish', lib.finish_label, 'weight', lib.box_weight_kg,
           'pieces', lib.pieces_per_box, 'stock_type', effective_stock_type(lib.stock_type, d.quality),
           'dna', coalesce((select jsonb_agg(distinct ld.value_id)
                            from library_dna ld
                            join dna_values dv on dv.id = ld.value_id and dv.is_active and lower(dv.name) <> 'none'
                            where ld.library_id = d.library_id), '[]'::jsonb))
           order by d.created_at desc)
         from designs d
         join stockist_library lib on lib.id = d.library_id
         where d.stockist_id = c.stockist_id
           and (d.box_quantity - d.control_quantity - held_of(d.id)) > 0
           and d.status <> 'out_of_stock'
           and case
             when coalesce(c.list_type,'permanent') = 'permanent' then
               (array_length(c.filter_brand_ids,1) is null or d.brand_id = any(c.filter_brand_ids))
               and (array_length(c.filter_qualities,1) is null or d.quality = any(c.filter_qualities))
               and (array_length(c.filter_surfaces,1) is null or d.surface_type = any(c.filter_surfaces))
               and (array_length(c.filter_sizes,1) is null or d.size = any(c.filter_sizes))
               and (array_length(c.filter_tile_types,1) is null or lib.tile_type = any(c.filter_tile_types))
               and (array_length(c.filter_stock_types,1) is null or effective_stock_type(lib.stock_type, d.quality) = any(c.filter_stock_types))
               and (c.filter_box_min is null or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) >= c.filter_box_min)
               and (c.filter_box_max is null or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) <= c.filter_box_max)
             else
               exists (select 1 from catalog_designs cd
                       where cd.catalog_id = c.id and cd.library_id = d.library_id)
           end), '[]'::jsonb))
     from stock_catalogs c join stockists s on s.id = c.stockist_id
     where (c.share_token = p_token
            or exists (select 1 from stockist_share_links l
                       where l.catalog_id = c.id and l.token = p_token and l.is_active
                         and (l.expires_at is null or l.expires_at > now())))
       and c.is_active and s.is_active),

    -- Path 2: token → stockist (stockist-level share link)
    (select jsonb_build_object(
       'stockist', jsonb_build_object(
          'name', case when s.is_anonymous and public_market_enabled() and exists(select 1 from stock_catalogs cc where cc.stockist_id=s.id and cc.is_anonymous and cc.show_in_marketplace and cc.is_active) then s.public_display_name else s.name end,
          'id',   case when s.is_anonymous and public_market_enabled() and exists(select 1 from stock_catalogs cc where cc.stockist_id=s.id and cc.is_anonymous and cc.show_in_marketplace and cc.is_active) then s.public_code else s.sequential_id end,
          'phone', s.phone, 'country_code', s.country_code, 'city', s.city,
          'logo_url',   case when s.is_anonymous and public_market_enabled() and exists(select 1 from stock_catalogs cc where cc.stockist_id=s.id and cc.is_anonymous and cc.show_in_marketplace and cc.is_active) then null else s.logo_url end,
          'banner_url', case when s.is_anonymous and public_market_enabled() and exists(select 1 from stock_catalogs cc where cc.stockist_id=s.id and cc.is_anonymous and cc.show_in_marketplace and cc.is_active) then null else s.banner_url end,
          'address',    case when s.is_anonymous and public_market_enabled() and exists(select 1 from stock_catalogs cc where cc.stockist_id=s.id and cc.is_anonymous and cc.show_in_marketplace and cc.is_active) then null else s.address end,
          'map_url',    case when s.is_anonymous and public_market_enabled() and exists(select 1 from stock_catalogs cc where cc.stockist_id=s.id and cc.is_anonymous and cc.show_in_marketplace and cc.is_active) then null else s.map_url end,
          'tagline', s.tagline, 'brand_color', s.brand_color),
       'banner', jsonb_build_object(
          'source','pool','bg_url',pick_generic_banner(s.id::text),
          'image_url', pick_generic_banner(s.id::text), 'overlay', true,
          'company_logo_url', null, 'company_pos','none','td_pos','footer',
          'name', case when s.is_anonymous and public_market_enabled() and exists(select 1 from stock_catalogs cc where cc.stockist_id=s.id and cc.is_anonymous and cc.show_in_marketplace and cc.is_active) then s.public_display_name else s.name end),
       'dna_facets', public_dna_facets(s.id),
       'designs', coalesce((
         select jsonb_agg(jsonb_build_object(
           'id', d.id, 'name', coalesce(lib.master_design_name, d.name), 'size', d.size,
           'surface', d.surface_type, 'quality', d.quality, 'colour', lib.colour,
           'tile_type', lib.tile_type, 'boxes', greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)),
           'images', case when nullif(btrim(coalesce(lib.image_url,'')),'') is not null then array[lib.image_url] else '{}'::text[] end,
           'finish', lib.finish_label, 'weight', lib.box_weight_kg,
           'pieces', lib.pieces_per_box, 'stock_type', effective_stock_type(lib.stock_type, d.quality),
           'dna', coalesce((select jsonb_agg(distinct ld.value_id)
                            from library_dna ld
                            join dna_values dv on dv.id = ld.value_id and dv.is_active and lower(dv.name) <> 'none'
                            where ld.library_id = d.library_id), '[]'::jsonb))
           order by d.created_at desc)
         from designs d
         join stockist_library lib on lib.id = d.library_id
         where d.stockist_id = s.id
           and (d.box_quantity - d.control_quantity - held_of(d.id)) > 0
           and d.status <> 'out_of_stock'
           and (
             exists (select 1 from catalog_designs cd
                    join stock_catalogs c2 on c2.id = cd.catalog_id
                    where cd.library_id = d.library_id and c2.stockist_id = s.id
                      and coalesce(c2.visibility,'public') = 'public' and c2.is_active
                      and coalesce(c2.list_type,'permanent') = 'temporary')
             or
             exists (select 1 from stock_catalogs c2
                    where c2.stockist_id = s.id and c2.is_active
                      and coalesce(c2.visibility,'public') = 'public'
                      and coalesce(c2.list_type,'permanent') = 'permanent'
                      and (array_length(c2.filter_brand_ids,1) is null or d.brand_id = any(c2.filter_brand_ids))
                      and (array_length(c2.filter_qualities,1) is null or d.quality = any(c2.filter_qualities))
                      and (array_length(c2.filter_surfaces,1) is null or d.surface_type = any(c2.filter_surfaces))
                      and (array_length(c2.filter_sizes,1) is null or d.size = any(c2.filter_sizes))
                      and (array_length(c2.filter_tile_types,1) is null or lib.tile_type = any(c2.filter_tile_types))
                      and (array_length(c2.filter_stock_types,1) is null or effective_stock_type(lib.stock_type, d.quality) = any(c2.filter_stock_types))
                      and (c2.filter_box_min is null or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) >= c2.filter_box_min)
                      and (c2.filter_box_max is null or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) <= c2.filter_box_max))
           )), '[]'::jsonb))
     from stockists s
     where s.is_active = true
       and (s.share_token = p_token
            or exists (select 1 from stockist_share_links l
                       where l.stockist_id = s.id and l.token = p_token and l.is_active
                         and (l.expires_at is null or l.expires_at > now()))))
  );
$function$;

-- ── 4. my_stock: attach permanent-list ids to each design (dashboard Q2) ──────
-- catalog_ids now = temporary lists via explicit catalog_designs membership
-- (unchanged) UNION permanent lists whose auto-filter conditions this design
-- matches — so condition-based lists show in the stockist's own dashboard.
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
    'brand_id', coalesce(d.brand_id, lib.brand_id),
    'stockist_key', s.sequential_id, 'stockist_priority', s.priority,
    'catalog_ids', (
      select coalesce(jsonb_agg(cid), '[]'::jsonb) from (
        -- temporary lists: explicit design picks
        select cd.catalog_id as cid
        from catalog_designs cd
        join stock_catalogs c on c.id = cd.catalog_id
        where cd.library_id = d.library_id and c.stockist_id = d.stockist_id
          and coalesce(c.list_type,'permanent') = 'temporary'
          and (c.brand_id is null or c.brand_id is not distinct from coalesce(d.brand_id, lib.brand_id))
        union
        -- permanent lists: this design matches the auto-filter conditions
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

-- ── 5. Drop the retired single-brand column ──────────────────────────────────
alter table public.stock_catalogs drop column if exists filter_brand_id;

notify pgrst, 'reload schema';
