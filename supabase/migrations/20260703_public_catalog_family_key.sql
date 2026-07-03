-- Add family_key + library_id to each design on the public /s/ catalog so the
-- buyer share page can group concept variants (1801-A / 1801-B) into one thin
-- coloured family band. library_id lets the client avoid treating a design's own
-- Premium/Standard split as a family. (design family P2 · buyer surfaces)
CREATE OR REPLACE FUNCTION public.public_catalog(p_token text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  select coalesce(
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
           'library_id', d.library_id,
           'family_key', _family_effective_key(d.library_id),
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
           'id', d.id,
           'library_id', d.library_id,
           'family_key', _family_effective_key(d.library_id),
           'name', coalesce(lib.master_design_name, d.name), 'size', d.size,
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
                         and (l.expires_at is null or l.expires_at > now())))));
$function$;
