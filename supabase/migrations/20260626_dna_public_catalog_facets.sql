-- ── DNA "special search" on the public web catalog ───────────────────────────
-- Add Design-DNA facets to the login-free /s/ catalog so buyers can filter by
-- the admin attributes (Punch/Glaze/Look/…) the same way the in-app dashboard
-- and market views do. Two additions to public_catalog:
--   • per design  → 'dna'        : the canonical value ids tagged on its master
--   • per branch  → 'dna_facets' : the facetable attribute/value catalog (names)
-- (project_design_dna_engine, project_session_resume #3)

-- Facet catalog for an anonymous viewer of a stockist's catalog: global
-- canonical values plus that stockist's own aliases. Free-text attributes
-- (e.g. Range) are excluded — they aren't chip facets.
create or replace function public.public_dna_facets(p_stockist uuid)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', a.id, 'name', a.name, 'is_multi', a.is_multi,
      'is_free_text', a.is_free_text, 'sort_order', a.sort_order,
      'values', coalesce((
        select jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name)
                         order by v.sort_order, lower(v.name))
        from dna_values v
        where v.attribute_id = a.id and v.is_active
          and lower(v.name) <> 'none'
          and (v.stockist_id is null or v.stockist_id = p_stockist)), '[]'::jsonb)
    ) order by a.sort_order
  ), '[]'::jsonb)
  from dna_attributes a
  where a.is_active and not a.is_free_text;
$function$;

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
       'banner', case when nullif(btrim(coalesce(c.banner_url,'')),'') is not null
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
