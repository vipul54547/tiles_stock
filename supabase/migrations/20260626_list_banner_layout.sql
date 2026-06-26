-- ── Per-LIST banner: full layout system (parity with the per-brand banner) ────
-- A stock list (catalog) gets the same rich banner the brand has: a source
-- (pool / library / upload), an optional company logo or big name with 9-cell
-- placement, and a TilesDesign mark placement. Columns mirror brands.*; when a
-- list has no banner_source it falls back to the brand banner (unchanged).
-- (project_session_resume #6, project_admin_banner_system)

alter table public.stock_catalogs
  add column if not exists banner_source    text,
  add column if not exists banner_bg_url    text,
  add column if not exists company_logo_url text,
  add column if not exists company_pos      text,
  add column if not exists td_pos           text;

-- Stockist sets (or, with an empty source, clears back to the brand banner)
-- their own list's banner config. Scoped to the caller's lists.
create or replace function public.set_list_banner_config(
  p_catalog_id uuid, p_source text, p_bg_url text,
  p_company_logo_url text, p_company_pos text, p_td_pos text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_stk uuid;
  v_src text := lower(coalesce(p_source, ''));
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can set a list banner'; end if;

  -- Empty source → clear the per-list banner (revert to the brand banner).
  if v_src = '' then
    update stock_catalogs set
      banner_source = null, banner_bg_url = null, company_logo_url = null,
      company_pos = null, td_pos = null, banner_url = null
    where id = p_catalog_id and stockist_id = v_stk;
    if not found then raise exception 'List not found'; end if;
    return;
  end if;

  if v_src not in ('pool', 'library', 'upload') then
    raise exception 'Invalid banner source';
  end if;

  update stock_catalogs set
    banner_source    = v_src,
    banner_bg_url    = nullif(btrim(coalesce(p_bg_url, '')), ''),
    company_logo_url = nullif(btrim(coalesce(p_company_logo_url, '')), ''),
    company_pos      = coalesce(nullif(btrim(p_company_pos), ''), 'none'),
    td_pos           = coalesce(nullif(btrim(p_td_pos), ''), 'footer'),
    banner_url       = null   -- the rich config supersedes the legacy single image
  where id = p_catalog_id and stockist_id = v_stk;
  if not found then raise exception 'List not found'; end if;
end;
$function$;

-- Re-create public_catalog with the per-list banner branch added ahead of the
-- legacy single-image branch (which stays for lists set the old way) and the
-- brand-banner fallback. Keeps the DNA facets from 20260626_dna_public_catalog_facets.
create or replace function public.public_catalog(p_token text)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce(
    (select jsonb_build_object(
       'stockist', jsonb_build_object(
          'name', case when s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled() then s.public_display_name else s.name end,
          'id',   case when s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled() then s.public_code else s.sequential_id end,
          'phone', s.phone, 'country_code', s.country_code, 'city', s.city,
          'logo_url',    case when s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled() then null else s.logo_url end,
          'banner_url',  case when s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled() then null else s.banner_url end,
          'address',     case when s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled() then null else s.address end,
          'map_url',     case when s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled() then null else s.map_url end,
          'tagline',     s.tagline, 'brand_color', s.brand_color),
       'brand', (select case when not b.is_default
                   then jsonb_build_object('name', b.name, 'logo_url', nullif(b.logo_url, ''))
                   else null end from brands b where b.id = c.brand_id),
       'banner', case
         when nullif(btrim(coalesce(c.banner_source,'')),'') is not null then
           jsonb_build_object(
             'source', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled())
                                 or c.banner_source = 'pool' then 'pool' else c.banner_source end,
             'bg_url', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled())
                                 or c.banner_source = 'pool' then pick_generic_banner(s.id::text) else c.banner_bg_url end,
             'image_url', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled())
                                 or c.banner_source = 'pool' then pick_generic_banner(s.id::text) else c.banner_bg_url end,
             'overlay', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled())
                                 or c.banner_source = 'pool' then true else false end,
             'company_logo_url', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled()) then null else c.company_logo_url end,
             'company_pos', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled()) then 'none' else coalesce(c.company_pos,'none') end,
             'td_pos', coalesce(c.td_pos,'footer'),
             'name', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled())
                          then s.public_display_name
                          else coalesce((select nullif(b.name,'') from brands b where b.id = c.brand_id), s.name) end)
         when nullif(btrim(coalesce(c.banner_url,'')),'') is not null
         then jsonb_build_object('source','custom','bg_url',c.banner_url,'image_url',c.banner_url,'overlay',false,'company_logo_url',null,'company_pos','none','td_pos','footer','name',c.name)
         else coalesce((select jsonb_build_object(
          'source', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled())
                              or coalesce(b.banner_source,'pool') = 'pool' then 'pool' else b.banner_source end,
          'bg_url', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled())
                              or coalesce(b.banner_source,'pool') = 'pool' then pick_generic_banner(s.id::text) else b.banner_bg_url end,
          'image_url', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled())
                              or coalesce(b.banner_source,'pool') = 'pool' then pick_generic_banner(s.id::text) else b.banner_bg_url end,
          'overlay', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled())
                              or coalesce(b.banner_source,'pool') = 'pool' then true else false end,
          'company_logo_url', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled()) then null else b.company_logo_url end,
          'company_pos', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled()) then 'none' else coalesce(b.company_pos,'none') end,
          'td_pos', coalesce(b.td_pos,'footer'),
          'name', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled()) then s.public_display_name else coalesce(nullif(b.name,''), s.name) end)
         from brands b where b.id = c.brand_id),
         jsonb_build_object('source','pool','bg_url',pick_generic_banner(s.id::text),'image_url',pick_generic_banner(s.id::text),'overlay',true,'company_logo_url',null,'company_pos','none','td_pos','footer','name', s.name)) end,
       'catalog', jsonb_build_object('name', c.name, 'visibility', c.visibility),
       'dna_facets', public_dna_facets(c.stockist_id),
       'designs', coalesce((
         select jsonb_agg(jsonb_build_object(
           'id', d.id,
           'name', coalesce((select bn.brand_design_name from stockist_library_brand_names bn
                             where bn.library_id = d.library_id and bn.brand_id = c.brand_id),
                            lib.master_design_name, d.name),
           'size', d.size, 'surface', d.surface_type,
           'quality', d.quality, 'colour', lib.colour, 'tile_type', lib.tile_type,
           'boxes', greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)),
           'images', case when nullif(btrim(coalesce(lib.image_url,'')),'') is not null then array[lib.image_url] else '{}'::text[] end,
           'finish', lib.finish_label, 'weight', lib.box_weight_kg,
           'pieces', lib.pieces_per_box, 'stock_type', effective_stock_type(lib.stock_type, d.quality),
           'dna', coalesce((select jsonb_agg(distinct ld.value_id)
                            from library_dna ld
                            join dna_values dv on dv.id = ld.value_id and dv.is_active
                                               and lower(dv.name) <> 'none'
                            where ld.library_id = d.library_id), '[]'::jsonb))
           order by d.created_at desc)
         from catalog_designs cd
         join designs d on d.library_id = cd.library_id and d.stockist_id = c.stockist_id
         join stockist_library lib on lib.id = d.library_id
         where cd.catalog_id = c.id and (d.box_quantity - d.control_quantity - held_of(d.id)) > 0 and d.status <> 'out_of_stock'), '[]'::jsonb))
     from stock_catalogs c join stockists s on s.id = c.stockist_id
     where (c.share_token = p_token
            or exists (select 1 from stockist_share_links l
                       where l.catalog_id = c.id and l.token = p_token and l.is_active
                         and (l.expires_at is null or l.expires_at > now())))
       and c.is_active and s.is_active),

    (select jsonb_build_object(
       'stockist', jsonb_build_object(
          'name', case when s.is_anonymous and public_market_enabled() and exists(select 1 from stock_catalogs cc where cc.stockist_id=s.id and cc.is_anonymous and cc.show_in_marketplace and cc.is_active) then s.public_display_name else s.name end,
          'id',   case when s.is_anonymous and public_market_enabled() and exists(select 1 from stock_catalogs cc where cc.stockist_id=s.id and cc.is_anonymous and cc.show_in_marketplace and cc.is_active) then s.public_code else s.sequential_id end,
          'phone', s.phone, 'country_code', s.country_code, 'city', s.city,
          'logo_url',    case when s.is_anonymous and public_market_enabled() and exists(select 1 from stock_catalogs cc where cc.stockist_id=s.id and cc.is_anonymous and cc.show_in_marketplace and cc.is_active) then null else s.logo_url end,
          'banner_url',  case when s.is_anonymous and public_market_enabled() and exists(select 1 from stock_catalogs cc where cc.stockist_id=s.id and cc.is_anonymous and cc.show_in_marketplace and cc.is_active) then null else s.banner_url end,
          'address',     case when s.is_anonymous and public_market_enabled() and exists(select 1 from stock_catalogs cc where cc.stockist_id=s.id and cc.is_anonymous and cc.show_in_marketplace and cc.is_active) then null else s.address end,
          'map_url',     case when s.is_anonymous and public_market_enabled() and exists(select 1 from stock_catalogs cc where cc.stockist_id=s.id and cc.is_anonymous and cc.show_in_marketplace and cc.is_active) then null else s.map_url end,
          'tagline',     s.tagline, 'brand_color', s.brand_color),
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
                            join dna_values dv on dv.id = ld.value_id and dv.is_active
                                               and lower(dv.name) <> 'none'
                            where ld.library_id = d.library_id), '[]'::jsonb))
           order by d.created_at desc)
         from designs d
         join stockist_library lib on lib.id = d.library_id
         where d.stockist_id = s.id and (d.box_quantity - d.control_quantity - held_of(d.id)) > 0 and d.status <> 'out_of_stock'
           and exists (select 1 from catalog_designs cd
                       join stock_catalogs c on c.id = cd.catalog_id
                       where cd.library_id = d.library_id and c.stockist_id = s.id
                         and coalesce(c.visibility,'public') = 'public' and c.is_active)), '[]'::jsonb))
     from stockists s
     where s.is_active = true
       and (s.share_token = p_token
            or exists (select 1 from stockist_share_links l
                       where l.stockist_id = s.id and l.token = p_token and l.is_active
                         and (l.expires_at is null or l.expires_at > now()))))
  );
$function$;
