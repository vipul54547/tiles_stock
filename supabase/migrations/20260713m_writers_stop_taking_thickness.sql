-- The writers stop accepting a thickness. It is DERIVED from the BOX — nobody may hand one in.
-- (Companion to 20260713l.)
--
-- `tile_type` is still declared by hand and stays: it supplies the DENSITY the derivation needs,
-- and it is genuinely a fact the stockist knows about the tile. Thickness is not.

-- ── the Library editor ───────────────────────────────────────────────────────────────────────
-- p_thickness stays in the signature (dropping it would break every caller) but is ACCEPTED AND
-- IGNORED: the trigger owns thickness.
--
-- 🔑 p_pieces / p_weight are now USED — but ONLY when CREATING. A new design has no box, so it has
-- no thickness and therefore no complete identity. Add-design asks for the three things a stockist
-- can actually read off the box — TILE TYPE, BOX WEIGHT, PIECES — and the thickness falls out of
-- them at once. On EDIT they are still ignored: by then the product may be boxed by several brands
-- that pack it differently, and this form has only one value, so writing it would flatten them all.
-- (The Library card's per-brand BOX CHIP owns them from then on.)
create or replace function public.library_upsert_master(
  p_id uuid, p_size text, p_master_name text, p_image_url text, p_aliases jsonb,
  p_brand_id uuid default null, p_surface text default null, p_stock_type text default null,
  p_tile_type text default null, p_pieces integer default null, p_weight numeric default null,
  p_thickness numeric default null, p_colour text default null, p_finish text default null)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_id uuid;
        v_name text := btrim(coalesce(p_master_name,''));
        v_size text := btrim(coalesce(p_size,''));
        v_surf text := nullif(btrim(coalesce(p_surface,'')),'');
        v_tile text := nullif(btrim(coalesce(p_tile_type,'')),'');
        r jsonb; v_brand uuid; v_alias text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can edit the library'; end if;
  if v_name = '' then raise exception 'Master design name cannot be empty'; end if;
  if v_size = '' then raise exception 'Size is required'; end if;
  if v_surf is null or lower(v_surf) = 'none' then
    raise exception 'Pick a surface — it is part of the design.';
  end if;
  if p_id is null and v_tile is null then
    raise exception 'Pick a tile type — it is part of the design.';
  end if;

  -- The thickness BAND is derived and cannot be known here (a new product has no box yet), so the
  -- duplicate check stops at the part a human supplies. The unique index enforces the rest: once
  -- both products have a box, their bands separate them — or, if the bands match, they really are
  -- the same product.
  if exists (select 1 from stockist_library
             where stockist_id = v_stk
               and lower(master_design_name) = lower(v_name)
               and size = v_size and surface_type = v_surf
               and tile_type is not distinct from coalesce(v_tile, tile_type)
               and thickness_band is null            -- only a BANDLESS twin is a real clash
               and (p_id is null or id <> p_id)) then
    raise exception '"%" (% · % · %) is already in your library, and has no box yet — give that one '
                    'its pieces and box weight first, so the two can be told apart by thickness.',
      v_name, v_size, v_surf, v_tile;
  end if;

  if p_id is null then
    insert into stockist_library (stockist_id, size, master_design_name, image_url,
                                  brand_id, surface_type, tile_type)
      values (v_stk, v_size, v_name, nullif(btrim(coalesce(p_image_url,'')), ''),
              p_brand_id, v_surf, v_tile)
      returning id into v_id;
  else
    update stockist_library set
      size = v_size, master_design_name = v_name,
      image_url = nullif(btrim(coalesce(p_image_url,'')), ''),
      brand_id = coalesce(p_brand_id, brand_id),
      surface_type = v_surf,
      tile_type    = coalesce(v_tile, tile_type),
      updated_at = now()
    where id = p_id and stockist_id = v_stk
    returning id into v_id;
    if v_id is null then raise exception 'Design not found'; end if;

    update designs d
       set surface_type = v_surf, name = v_name, size = v_size, updated_at = now()
     where d.library_id = v_id and d.stockist_id = v_stk;
  end if;

  update stockist_library m set
    stock_type   = case when p_stock_type is null then m.stock_type   else coalesce(nullif(btrim(p_stock_type),''),'Uncertain') end,
    colour       = case when p_colour     is null then m.colour       else coalesce(btrim(p_colour),'') end,
    finish_label = case when p_finish     is null then m.finish_label else nullif(btrim(p_finish),'') end,
    updated_at = now()
  where m.id = v_id;

  -- The brand-name rows ARE THE BOXES — synced in place, never deleted and re-inserted, or every
  -- brand's packing (and therefore the thickness) would be thrown away on each save.
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

    delete from stockist_library_brand_names a
     where a.library_id = v_id
       and not exists (
         select 1 from jsonb_array_elements(p_aliases) e
          where nullif(e->>'brand_id','')::uuid = a.brand_id
            and btrim(coalesce(e->>'name','')) <> '');
  end if;

  -- CREATE only: seed the first box, so the thickness derives right away and the product's identity
  -- is complete from birth. The trigger fires on this write and fills thickness_mm → thickness_band.
  if p_id is null and (coalesce(p_pieces,0) > 0 or coalesce(p_weight,0) > 0) then
    update stockist_library_brand_names a
       set pieces_per_box = coalesce(p_pieces, a.pieces_per_box),
           box_weight_kg  = coalesce(p_weight, a.box_weight_kg)
     where a.library_id = v_id;
  end if;

  return v_id;

exception
  -- The band is derived, so a box weight can land this product exactly on top of another one.
  -- Postgres would throw a raw 23505 naming an index; say what actually happened.
  when unique_violation then
    raise exception 'You already have "%" at % · % · % in that thickness. The box weight and pieces '
                    'put it in the same band — if this is a different tile, check them.',
      v_name, v_size, v_surf, v_tile;
end; $function$;

-- ── the import ──────────────────────────────────────────────────────────────────────────────
-- ⚠️ p_thickness is REMOVED, so the 6-arg signature must be DROPPED or it lingers as an overload
-- and the 5-arg call dies with 42725.
drop function if exists public.library_map_upsert(text, text, jsonb, text, text, numeric);

create or replace function public.library_map_upsert(
  p_size text, p_master_name text, p_aliases jsonb,
  p_surface text default null, p_tile_type text default null)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_id uuid;
        v_name text := btrim(coalesce(p_master_name,''));
        v_size text := btrim(coalesce(p_size,''));
        v_surf text := nullif(btrim(coalesce(p_surface,'')),'');
        v_tile text := nullif(btrim(coalesce(p_tile_type,'')),'');
        r jsonb; v_brand uuid; v_alias text; v_brand1 uuid; v_alias1 text; v_key text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can edit the library'; end if;
  if v_size = '' then raise exception 'Size is required'; end if;
  if v_surf is null or lower(v_surf) = 'none' then
    raise exception 'Pick a surface — every design must have one.';
  end if;

  if p_aliases is not null and jsonb_array_length(p_aliases) > 0 then
    v_brand1 := nullif(p_aliases->0->>'brand_id','')::uuid;
    v_alias1 := btrim(coalesce(p_aliases->0->>'name',''));
  end if;
  v_key := lower(coalesce(nullif(v_name,''), v_alias1));
  if v_key = '' then raise exception 'Design name cannot be empty'; end if;

  -- ADOPTION still applies to tile_type: a legacy row with no body is taught one rather than
  -- duplicated. Thickness needs no adoption at all — it derives from the box either way.
  if p_aliases is not null then
    for r in select * from jsonb_array_elements(p_aliases) loop
      exit when v_id is not null;
      v_brand := nullif(r->>'brand_id','')::uuid;
      v_alias := btrim(coalesce(r->>'name',''));
      if v_brand is not null and v_alias <> '' then
        select m.id into v_id from stockist_library m
          join stockist_library_brand_names a on a.library_id = m.id
         where m.stockist_id = v_stk and a.brand_id = v_brand
           and lower(a.brand_design_name) = lower(v_alias)
           and m.size = v_size and m.surface_type = v_surf
           and (v_tile is null or m.tile_type is null or m.tile_type = v_tile)
         order by (m.tile_type is not null) desc, m.created_at
         limit 1;
      end if;
    end loop;
  end if;

  if v_id is null then
    select id into v_id from stockist_library m
     where m.stockist_id = v_stk and lower(m.master_design_name) = v_key
       and m.size = v_size and m.surface_type = v_surf
       and (v_tile is null or m.tile_type is null or m.tile_type = v_tile)
     order by (m.tile_type is not null) desc, m.created_at
     limit 1;
  end if;

  if v_id is null then
    insert into stockist_library (stockist_id, size, master_design_name, brand_id,
                                  surface_type, tile_type)
      values (v_stk, v_size, coalesce(nullif(v_name,''), v_alias1), v_brand1, v_surf, v_tile)
      returning id into v_id;
  else
    -- fill a BLANK body only; never overwrite a declared one.
    update stockist_library m
       set tile_type = coalesce(m.tile_type, v_tile), updated_at = now()
     where m.id = v_id and m.tile_type is null and v_tile is not null;
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
