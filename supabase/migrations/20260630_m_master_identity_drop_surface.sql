-- M master identity = name + size ONLY (brand-agnostic). Surface is a stored
-- attribute, NOT an identity key — using it to match was fragmenting one design
-- into duplicate masters (e.g. "1001" Matt from the admin image import vs "1001"
-- Sugar from the stock Excel), orphaning the brand alias names from the stock.
-- Surface is now overwritten from the imported data (data wins). T/W unchanged
-- (already brand-scoped, never matched on surface). See project_per_brand_stock.

-- ── Excel/PDF import matcher ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.library_map_upsert(p_size text, p_master_name text, p_aliases jsonb, p_surface text DEFAULT 'None'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_stk uuid; v_id uuid; v_type text;
        v_name text := btrim(coalesce(p_master_name,''));
        v_size text := btrim(coalesce(p_size,''));
        v_surf text := lower(coalesce(nullif(btrim(p_surface),''),'none'));
        r jsonb; v_brand uuid; v_alias text;
        v_brand1 uuid; v_alias1 text; v_key text;
begin
  select id, business_type into v_stk, v_type from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can edit the library'; end if;
  if v_size = '' then raise exception 'Size is required'; end if;

  if p_aliases is not null and jsonb_array_length(p_aliases) > 0 then
    v_brand1 := nullif(p_aliases->0->>'brand_id','')::uuid;
    v_alias1 := btrim(coalesce(p_aliases->0->>'name',''));
  end if;
  v_key := lower(coalesce(nullif(v_name,''), v_alias1));
  if v_key = '' then raise exception 'Design name cannot be empty'; end if;

  -- Match by an existing brand-alias name (name+size); surface is NOT a key.
  if p_aliases is not null then
    for r in select * from jsonb_array_elements(p_aliases) loop
      exit when v_id is not null;
      v_brand := nullif(r->>'brand_id','')::uuid;
      v_alias := btrim(coalesce(r->>'name',''));
      if v_brand is not null and v_alias <> '' then
        select m.id into v_id from stockist_library m
        join stockist_library_brand_names a on a.library_id = m.id
        where m.stockist_id = v_stk and a.brand_id = v_brand
          and lower(a.brand_design_name) = lower(v_alias) and m.size = v_size
        order by m.created_at
        limit 1;
      end if;
    end loop;
  end if;

  if v_id is null then
    if v_type = 'M' then
      -- M: brand-agnostic, keyed by name+size only.
      select id into v_id from stockist_library
      where stockist_id = v_stk
        and lower(master_design_name) = v_key and size = v_size
      order by created_at
      limit 1;
    elsif v_brand1 is not null then
      select id into v_id from stockist_library
      where stockist_id = v_stk and brand_id = v_brand1
        and lower(master_design_name) = v_key and size = v_size
      limit 1;
    else
      select id into v_id from stockist_library
      where stockist_id = v_stk and brand_id is null
        and lower(master_design_name) = v_key and size = v_size
      limit 1;
    end if;
  end if;

  if v_id is null then
    insert into stockist_library (stockist_id, size, master_design_name, brand_id, surface_type)
      values (v_stk, v_size, coalesce(nullif(v_name,''), v_alias1),
              case when v_type = 'M' then null else v_brand1 end,
              coalesce(nullif(btrim(p_surface),''),'None'))
      returning id into v_id;
  elsif v_surf <> 'none' then
    -- Surface is an attribute — the imported value wins (data is authoritative).
    update stockist_library
       set surface_type = coalesce(nullif(btrim(p_surface),''),'None')
     where id = v_id;
  end if;

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

-- ── Admin image-folder import matcher ─────────────────────────────────────────
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

  -- M = ONE box per name+size (brand-agnostic; surface is an attribute, not a key).
  -- T/W = brand silo.
  if v_type = 'M' then
    select id into v_id from stockist_library
    where stockist_id = v_stk and lower(master_design_name) = lower(v_name)
      and size = v_size
    limit 1;
  else
    select id into v_id from stockist_library
    where stockist_id = v_stk and lower(master_design_name) = lower(v_name)
      and size = v_size and brand_id is not distinct from p_brand_id
    limit 1;
  end if;

  if v_id is null then
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
