-- Backfill the four RPC bodies that were applied to the live database via MCP
-- but never written to supabase/migrations/. The database has been correct
-- since 2026-07-09; the REPO could not rebuild it. This is the migration that
-- 20260709_surface_label_payloads.sql pointed at with:
--
--   "my_stock + my_library also carry surface_label (see the applied migration
--    'surface_label_my_stock_library' for their full bodies)."
--
-- Without this file, replaying migrations from scratch produced a schema where
-- my_library did not exist at all, and public_catalog / my_stock /
-- my_private_designs returned no surface_label -- so every buyer card and
-- stockist stock row would have lost the stockist's own surface word.
--
-- Bodies are reproduced verbatim from pg_get_functiondef() against the live
-- schema, not reconstructed from call sites. Re-running this file against the
-- current database is a no-op. my_private_designs needs a DROP before its
-- CREATE (its return type changed) -- see the note there.
--
-- Grants at the bottom mirror the live ACL exactly, including EXECUTE to anon.
-- See the note there before "fixing" that.

-- ---------------------------------------------------------------------------
-- my_library() -- the signed-in stockist's identity rows (Stockist_Library),
-- with per-brand alias names. Carries BOTH surface_type and surface_label.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.my_library()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_stk uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists have a library'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id,
      'brand_id', m.brand_id,
      'brand_name', coalesce((select b.name from brands b where b.id = m.brand_id), ''),
      'size', m.size,
      'master_design_name', m.master_design_name,
      'image_url', m.image_url,
      'surface_type', m.surface_type,
      'surface_label', m.surface_label,
      'stock_type', m.stock_type,
      'tile_type', m.tile_type,
      'pieces_per_box', m.pieces_per_box,
      'box_weight_kg', m.box_weight_kg,
      'thickness_mm', m.thickness_mm,
      'colour', m.colour,
      'finish_label', m.finish_label,
      'aliases', coalesce((
        select jsonb_agg(jsonb_build_object('brand_id', a.brand_id, 'name', a.brand_design_name))
        from stockist_library_brand_names a where a.library_id = m.id), '[]'::jsonb)
    ) order by m.master_design_name, m.size)
    from stockist_library m where m.stockist_id = v_stk
  ), '[]'::jsonb);
end; $function$;

-- ---------------------------------------------------------------------------
-- my_stock() -- the signed-in stockist's P_Stock rows (holding), plus the
-- temporary/permanent catalog ids each row currently falls into.
-- ---------------------------------------------------------------------------
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
    'surface_type', d.surface_type, 'surface_label', d.surface_label, 'stock_type', lib.stock_type,
    'tile_type', lib.tile_type, 'pieces_per_box', lib.pieces_per_box,
    'box_weight_kg', lib.box_weight_kg, 'thickness_mm', lib.thickness_mm,
    'colour', lib.colour, 'finish_label', lib.finish_label,
    'image_url', lib.image_url, 'master_design_name', lib.master_design_name,
    'family_key', _family_effective_key(d.library_id),
    'brand_id', coalesce(d.brand_id, lib.brand_id),
    'stockist_key', s.sequential_id, 'stockist_priority', s.priority,
    'catalog_ids', (
      select coalesce(jsonb_agg(cid), '[]'::jsonb) from (
        select cd.catalog_id as cid
        from catalog_designs cd
        join stock_catalogs c on c.id = cd.catalog_id
        where cd.library_id = d.library_id and c.stockist_id = d.stockist_id
          and coalesce(c.list_type,'permanent') = 'temporary'
          and (c.brand_id is null or c.brand_id is not distinct from coalesce(d.brand_id, lib.brand_id))
        union
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

-- ---------------------------------------------------------------------------
-- my_private_designs() -- rows a signed-in dealer/end_user can see through the
-- catalogs shared with them (dealer_catalog_access).
--
-- DROP first, not CREATE OR REPLACE: this adds surface_label to the RETURNS
-- TABLE, and Postgres refuses to replace a function whose output columns
-- changed ("cannot change return type of existing function"). On a clean replay
-- 20260703_my_private_designs_dedup_catalog_ids.sql has already created the
-- older, surface_label-less signature. Same drop+create the 07-03 file used.
-- ---------------------------------------------------------------------------
drop function if exists public.my_private_designs();

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
         d.box_quantity, lib.pieces_per_box,
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
    and d.box_quantity > 0 and d.status <> 'out_of_stock'
    and cat.ids is not null;
$function$;

-- ---------------------------------------------------------------------------
-- public_catalog(p_token) -- the anonymous buyer read path behind /s/:token.
-- Two arms: a specific stock_catalog by token, else the stockist's whole
-- public surface by their share_token.
--
-- Note the surface filter matches EITHER canonical or word:
--   d.surface_type = any(c.filter_surfaces) or d.surface_label = any(...)
-- Permanent lists saved before the surface split stored the canonical; ones
-- saved after can store the stockist's word. Both must keep resolving.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.public_catalog(p_token text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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
                   else null end from brands b where b.id = c.brand_id),
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
             'name', coalesce((select nullif(b.name,'') from brands b where b.id = c.brand_id), s.name))
         when nullif(btrim(coalesce(c.banner_url,'')),'') is not null
         then jsonb_build_object('source','custom','bg_url',c.banner_url,'image_url',c.banner_url,'overlay',false,'company_logo_url',null,'company_pos','none','td_pos', case when coalesce(nullif(btrim(c.td_pos),''),'none') = 'none' then 'top-right' else c.td_pos end,'td_show', s.td_show,'banner_heading', c.banner_heading,'banner_text', c.banner_text,'name',c.name)
         else jsonb_build_object('source','pool','bg_url',pick_generic_banner(s.id::text),'image_url',pick_generic_banner(s.id::text),'overlay',true,'company_logo_url',null,'company_pos','none','td_pos', case when coalesce(nullif(btrim(c.td_pos),''),'none') = 'none' then 'top-right' else c.td_pos end,'td_show', s.td_show,'banner_heading', c.banner_heading,'banner_text', c.banner_text,'name', s.name) end,
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
           'size', d.size, 'surface', d.surface_type, 'surface_label', d.surface_label,
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
               and (array_length(c.filter_surfaces,1) is null or d.surface_type = any(c.filter_surfaces) or d.surface_label = any(c.filter_surfaces))
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
           'name', coalesce(lib.master_design_name, d.name), 'size', d.size,
           'surface', d.surface_type, 'surface_label', d.surface_label, 'quality', d.quality, 'colour', lib.colour,
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

-- ---------------------------------------------------------------------------
-- Grants: mirrors the live ACL exactly, so a rebuilt database matches prod.
--
-- public_catalog is the anonymous buyer read path -- anon EXECUTE is correct.
--
-- The three my_* functions ALSO carry EXECUTE for anon (and PUBLIC) on the live
-- database. That is not a data leak: each resolves the caller through
-- auth.uid(), so anon gets an exception (my_library) or an empty result
-- (my_stock, my_private_designs) -- unlike the legacy add_stock/dispatch_stock
-- revoked in 20260710_revoke_legacy_stock_rpcs.sql, which took the stockist id
-- as an argument and checked nothing. Reproduced as-is rather than silently
-- tightened: this file's job is repo/DB parity. Narrowing the my_* grants to
-- `authenticated` is a separate, deliberate change.
-- ---------------------------------------------------------------------------
grant execute on function public.my_library()           to anon, authenticated, service_role;
grant execute on function public.my_stock()             to anon, authenticated, service_role;
grant execute on function public.my_private_designs()   to anon, authenticated, service_role;
grant execute on function public.public_catalog(text)   to anon, authenticated, service_role;
