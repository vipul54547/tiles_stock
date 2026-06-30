-- Admin bulk image-import treated M masters as brand-scoped, but the canonical M
-- model (library_upsert_master) is brand-agnostic: ONE box per stockist keyed by
-- name+size+surface (brand_id NULL), per-brand names stored as aliases. Two bugs:
--   1. admin_library_upsert matched the existing master by name+size+brand_id, so
--      importing the same tile under a 2nd brand MISSED the default-brand master and
--      would CREATE DUPLICATE masters.
--   2. admin_stockist_library returned only each master's own brand_id (default/null),
--      never the alias table — so the bulk-import "already in library" (EXISTS vs NEW)
--      badge showed 0 for designs that exist under a non-default brand.
-- Fix: branch on business_type. M = brand-agnostic match + master brand_id NULL,
-- brand folds in as alias. T/W = unchanged (brand-scoped silos). admin_stockist_library
-- now UNIONs master rows + per-brand alias rows.

-- FIX 1 ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_library_upsert(
  p_seq text, p_size text, p_master_name text, p_brand_id uuid,
  p_image_url text DEFAULT NULL::text, p_surface text DEFAULT NULL::text,
  p_tile_type text DEFAULT NULL::text, p_pieces integer DEFAULT NULL::integer,
  p_weight numeric DEFAULT NULL::numeric, p_thickness numeric DEFAULT NULL::numeric,
  p_aliases jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_stk uuid; v_id uuid; v_type text;
        v_name text := btrim(coalesce(p_master_name,''));
        v_size text := btrim(coalesce(p_size,''));
        v_surf text := coalesce(nullif(btrim(coalesce(p_surface,'')),''),'None');
        r jsonb; v_brand uuid; v_alias text;
begin
  if current_user_role() <> 'admin' then
    raise exception 'Only admins can bulk-import on behalf of a stockist';
  end if;
  select id, business_type into v_stk, v_type from stockists where sequential_id = p_seq;
  if v_stk is null then raise exception 'Stockist not found'; end if;
  if v_name = '' then raise exception 'Design name cannot be empty'; end if;
  if v_size = '' then raise exception 'Size is required'; end if;

  -- Match an existing master. M = ONE box across all brands, keyed by
  -- name+size+surface (brand-agnostic). T/W = brand silo, keyed incl. brand.
  if v_type = 'M' then
    select id into v_id from stockist_library
    where stockist_id = v_stk and lower(master_design_name) = lower(v_name)
      and size = v_size and coalesce(surface_type,'None') = v_surf
    limit 1;
  else
    select id into v_id from stockist_library
    where stockist_id = v_stk and lower(master_design_name) = lower(v_name)
      and size = v_size and brand_id is not distinct from p_brand_id
    limit 1;
  end if;

  if v_id is null then
    -- M boxes are brand-agnostic (brand_id NULL); T/W are brand-bound.
    insert into stockist_library (stockist_id, size, master_design_name, image_url, brand_id)
      values (v_stk, v_size, v_name,
              nullif(btrim(coalesce(p_image_url,'')),''),
              case when v_type = 'M' then null else p_brand_id end)
      returning id into v_id;
  else
    update stockist_library set
      image_url = coalesce(nullif(btrim(coalesce(p_image_url,'')),''), image_url),
      updated_at = now()
    where id = v_id;
  end if;

  update stockist_library m set
    surface_type   = case when p_surface   is null then m.surface_type   else v_surf end,
    tile_type      = case when p_tile_type is null then m.tile_type      else coalesce(btrim(p_tile_type),'') end,
    pieces_per_box = case when p_pieces    is null then m.pieces_per_box else coalesce(p_pieces,0) end,
    box_weight_kg  = case when p_weight    is null then m.box_weight_kg  else coalesce(p_weight,0) end,
    thickness_mm   = case when p_thickness is null then m.thickness_mm   else coalesce(p_thickness,0) end,
    updated_at = now()
  where m.id = v_id;

  if p_aliases is not null then
    for r in select * from jsonb_array_elements(p_aliases) loop
      v_brand := nullif(r->>'brand_id','')::uuid;
      v_alias := btrim(coalesce(r->>'name',''));
      if v_alias <> '' and v_brand is not null
         and exists (select 1 from brands where id = v_brand and stockist_id = v_stk) then
        insert into stockist_library_brand_names (library_id, brand_id, brand_design_name)
          values (v_id, v_brand, v_alias)
          on conflict (library_id, brand_id) do update set brand_design_name = excluded.brand_design_name;
      end if;
    end loop;
  end if;
  return v_id;
end; $function$;

-- FIX 2 ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_stockist_library(p_seq text)
 RETURNS TABLE(master_design_name text, size text, brand_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if current_user_role() <> 'admin' then
    raise exception 'Only admins can read another stockist''s library';
  end if;
  return query
    select l.master_design_name, l.size, l.brand_id
    from stockist_library l
    join stockists s on s.id = l.stockist_id
    where s.sequential_id = p_seq
    union
    select a.brand_design_name, l.size, a.brand_id
    from stockist_library_brand_names a
    join stockist_library l on l.id = a.library_id
    join stockists s on s.id = l.stockist_id
    where s.sequential_id = p_seq;
end; $function$;
