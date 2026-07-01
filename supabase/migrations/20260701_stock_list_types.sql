-- Permanent vs temporary stock list types with condition-based filtering.
-- Permanent: auto-updates from filter conditions (brand/quality/surface/size).
-- Temporary: manual design picks via catalog_designs (existing behavior).

-- 1. Schema
alter table public.stock_catalogs
  add column if not exists list_type text not null default 'permanent',
  add column if not exists filter_brand_id uuid references public.brands(id) on delete set null,
  add column if not exists filter_quality text,
  add column if not exists filter_surface text,
  add column if not exists filter_size text;

-- All existing lists use catalog_designs picks → mark them temporary.
update public.stock_catalogs set list_type = 'temporary' where list_type = 'permanent';

-- 2. Updated stock_list_save: stores list_type + filter conditions.
create or replace function public.stock_list_save(
  p_id uuid,
  p_name text,
  p_description text default '',
  p_list_type text default 'permanent',
  p_filter_brand_id uuid default null,
  p_filter_quality text default null,
  p_filter_surface text default null,
  p_filter_size text default null
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
       sort_order, is_anonymous, list_type, filter_brand_id, filter_quality, filter_surface, filter_size)
    values (v_stk, null, v_name, v_desc, 'private', false, v_order, false,
            v_type, p_filter_brand_id,
            nullif(btrim(coalesce(p_filter_quality,'')), ''),
            nullif(btrim(coalesce(p_filter_surface,'')), ''),
            nullif(btrim(coalesce(p_filter_size,'')), ''))
    returning id into v_id;
    return v_id;
  else
    update stock_catalogs set
      name = v_name, description = v_desc,
      list_type = v_type,
      filter_brand_id = p_filter_brand_id,
      filter_quality  = nullif(btrim(coalesce(p_filter_quality,'')), ''),
      filter_surface  = nullif(btrim(coalesce(p_filter_surface,'')), ''),
      filter_size     = nullif(btrim(coalesce(p_filter_size,'')), '')
    where id = p_id and stockist_id = v_stk;
    if not found then raise exception 'List not found'; end if;
    return p_id;
  end if;
end;
$function$;

-- 3. Updated public_catalog: permanent lists use filter conditions directly;
--    temporary lists use catalog_designs membership (unchanged).
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
                and bn.brand_id = coalesce(c.filter_brand_id, c.brand_id)),
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
               (c.filter_brand_id is null or d.brand_id = c.filter_brand_id)
               and (c.filter_quality is null or d.quality = c.filter_quality)
               and (c.filter_surface is null or d.surface_type = c.filter_surface)
               and (c.filter_size is null or d.size = c.filter_size)
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
                      and (c2.filter_brand_id is null or d.brand_id = c2.filter_brand_id)
                      and (c2.filter_quality is null or d.quality = c2.filter_quality)
                      and (c2.filter_surface is null or d.surface_type = c2.filter_surface)
                      and (c2.filter_size is null or d.size = c2.filter_size))
           )), '[]'::jsonb))
     from stockists s
     where s.is_active = true
       and (s.share_token = p_token
            or exists (select 1 from stockist_share_links l
                       where l.stockist_id = s.id and l.token = p_token and l.is_active
                         and (l.expires_at is null or l.expires_at > now()))))
  );
$function$;
