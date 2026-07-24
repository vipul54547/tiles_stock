-- 20260724i — 🖼️ MEDIA PORTFOLIO: catalogue SPACE facet (re-applies public_catalog).
--
-- Adds the SPACE facet to a portfolio catalogue (catalog-token permanent branch): with
-- filter_spaces set, a design shows only when it has media tagged in one of those spaces —
-- artwork-bound (a mockup/360 on the design's print) or a shown close-look on the tile. Empty
-- filter_spaces = no space filter (stock lists never set it → no-op for them). Surface/size/tile-type
-- facets were already applied by the permanent branch; this closes the gap for space.
-- (Builds on 20260724f; the rest of the function is identical.)

create or replace function public.public_catalog(p_token text)
 returns jsonb
 language sql stable security definer set search_path to 'public','extensions','pg_temp'
as $function$
  select coalesce(
    (select jsonb_build_object(
       'stockist', jsonb_build_object(
          'name', s.name, 'id',   s.sequential_id,
          'phone', s.phone, 'country_code', s.country_code, 'city', s.city,
          'logo_url', s.logo_url, 'banner_url', s.banner_url,
          'address', s.address, 'map_url', s.map_url,
          'tagline', s.tagline, 'brand_color', s.brand_color),
       'brand', (select case when not b.is_default
                   then jsonb_build_object('name', b.name, 'logo_url', nullif(b.logo_url, ''))
                   else null end from brands b where b.id = coalesce(c.catalogue_brand_id, c.brand_id)),
       'banner', case
         when nullif(btrim(coalesce(c.banner_source,'')),'') is not null then
           jsonb_build_object(
             'source', case when c.banner_source = 'pool' then 'pool' else c.banner_source end,
             'bg_url',  case when c.banner_source = 'pool' then pick_generic_banner(s.id::text) else c.banner_bg_url end,
             'image_url', case when c.banner_source = 'pool' then pick_generic_banner(s.id::text) else c.banner_bg_url end,
             'overlay', case when c.banner_source = 'pool' then true else false end,
             'company_logo_url', c.company_logo_url,
             'company_pos', coalesce(c.company_pos,'none'),
             'td_pos', case when coalesce(nullif(btrim(c.td_pos),''),'none') = 'none' then 'top-right' else c.td_pos end,
             'td_show', s.td_show,
             'banner_heading', c.banner_heading,
             'banner_text', c.banner_text, 'banner_heading_size', c.banner_heading_size, 'banner_heading_color', c.banner_heading_color, 'banner_msg_size', c.banner_msg_size, 'banner_msg_color', c.banner_msg_color, 'banner_text_align', c.banner_text_align, 'banner_text_valign', c.banner_text_valign,
             'name', coalesce((select nullif(b.name,'') from brands b where b.id = coalesce(c.catalogue_brand_id, c.brand_id)), s.name))
         when nullif(btrim(coalesce(c.banner_url,'')),'') is not null
         then jsonb_build_object('source','custom','bg_url',c.banner_url,'image_url',c.banner_url,'overlay',false,'company_logo_url',null,'company_pos','none','td_pos', case when coalesce(nullif(btrim(c.td_pos),''),'none') = 'none' then 'top-right' else c.td_pos end,'td_show', s.td_show,'banner_heading', c.banner_heading,'banner_text', c.banner_text,'name',c.name)
         else jsonb_build_object('source','pool','bg_url',pick_generic_banner(s.id::text),'image_url',pick_generic_banner(s.id::text),'overlay',true,'company_logo_url',null,'company_pos','none','td_pos', case when coalesce(nullif(btrim(c.td_pos),''),'none') = 'none' then 'top-right' else c.td_pos end,'td_show', s.td_show,'banner_heading', c.banner_heading,'banner_text', c.banner_text,'name', s.name) end,
       'catalog', jsonb_build_object('name', c.name, 'visibility', c.visibility, 'kind', coalesce(c.kind,'stock')),
       'dna_facets', public_dna_facets(c.stockist_id),
       'designs', coalesce((
         select jsonb_agg(jsonb_build_object(
           'id', d.id,
           'library_id', d.library_id,
           'family_key', _family_effective_key(d.library_id),
           'name', coalesce(
             (select bn.brand_design_name from stockist_library_brand_names bn
              where bn.library_id = d.library_id
                and bn.brand_id = coalesce(c.catalogue_brand_id, d.brand_id, c.brand_id)),
             pm.print_name, d.name),
           'size', d.size, 'surface', d.surface_type, 'surface_label', d.surface_label,
           'quality', d.quality, 'colour', _dna_colour(lib.id), 'tile_type', lib.tile_type,
           'boxes', greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)),
           'images', case when nullif(btrim(coalesce(pm.image_url,'')),'') is not null then array[pm.image_url] else '{}'::text[] end,
           'finish', lib.finish_label, 'weight', _box_weight_of(d.box_id),
           'pieces', _box_pieces_of(d.box_id), 'stock_type', effective_stock_type(lib.stock_type, d.quality),
           'dna', coalesce((select jsonb_agg(distinct ld.value_id)
                            from _dna_of_library(d.library_id) ld
                            join dna_values dv on dv.id = ld.value_id and dv.is_active and lower(dv.name) <> 'none'
                           ), '[]'::jsonb))
           order by d.created_at desc)
         from designs d
         join stockist_library lib on lib.id = d.library_id
         join print_master pm on pm.id = lib.print_id
         where d.stockist_id = c.stockist_id
           and (d.box_quantity - d.control_quantity - held_of(d.id)) > 0
           and d.status <> 'out_of_stock'
           and (coalesce(c.kind,'stock') <> 'portfolio' or d.brand_id = c.catalogue_brand_id)
           and case
             when coalesce(c.list_type,'permanent') = 'permanent' then
               (array_length(c.filter_brand_ids,1) is null or d.brand_id = any(c.filter_brand_ids))
               and (array_length(c.filter_qualities,1) is null or d.quality = any(c.filter_qualities))
               and (array_length(c.filter_surfaces,1) is null or d.surface_type = any(c.filter_surfaces) or d.surface_label = any(c.filter_surfaces))
               and (array_length(c.filter_sizes,1) is null or d.size = any(c.filter_sizes))
               and (array_length(c.filter_tile_types,1) is null or lib.tile_type = any(c.filter_tile_types))
               and (array_length(c.filter_spaces,1) is null or exists (
                 select 1 from media_asset a
                  where a.space = any(c.filter_spaces)
                    and (exists (select 1 from media_asset_artwork ma
                                  where ma.asset_id = a.id and ma.print_id = lib.print_id)
                      or exists (select 1 from media_asset_tile mt
                                  where mt.asset_id = a.id and mt.library_id = d.library_id and mt.shown))))
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
          'name', s.name, 'id', s.sequential_id,
          'phone', s.phone, 'country_code', s.country_code, 'city', s.city,
          'logo_url', s.logo_url, 'banner_url', s.banner_url,
          'address', s.address, 'map_url', s.map_url,
          'tagline', s.tagline, 'brand_color', s.brand_color),
       'banner', jsonb_build_object(
          'source','pool','bg_url',pick_generic_banner(s.id::text),
          'image_url', pick_generic_banner(s.id::text), 'overlay', true,
          'company_logo_url', null, 'company_pos','none','td_pos','top-right','td_show', s.td_show,
          'banner_heading', null, 'banner_text', null, 'name', s.name),
       'dna_facets', public_dna_facets(s.id),
       'designs', coalesce((
         select jsonb_agg(jsonb_build_object(
           'id', d.id,
           'library_id', d.library_id,
           'family_key', _family_effective_key(d.library_id),
           'name', coalesce(pm.print_name, d.name), 'size', d.size,
           'surface', d.surface_type, 'surface_label', d.surface_label, 'quality', d.quality,
           'colour', _dna_colour(lib.id),
           'tile_type', lib.tile_type, 'boxes', greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)),
           'images', case when nullif(btrim(coalesce(pm.image_url,'')),'') is not null then array[pm.image_url] else '{}'::text[] end,
           'finish', lib.finish_label, 'weight', _box_weight_of(d.box_id),
           'pieces', _box_pieces_of(d.box_id), 'stock_type', effective_stock_type(lib.stock_type, d.quality),
           'dna', coalesce((select jsonb_agg(distinct ld.value_id)
                            from _dna_of_library(d.library_id) ld
                            join dna_values dv on dv.id = ld.value_id and dv.is_active and lower(dv.name) <> 'none'
                           ), '[]'::jsonb))
           order by d.created_at desc)
         from designs d
         join stockist_library lib on lib.id = d.library_id
         join print_master pm on pm.id = lib.print_id
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
                      and (array_length(c2.filter_surfaces,1) is null or d.surface_type = any(c2.filter_surfaces) or d.surface_label = any(c2.filter_surfaces))
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
