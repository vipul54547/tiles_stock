-- CHAPTER 3, STEP 2 of 3 — the Library editor declares thickness + body.
-- (docs/THICKNESS_AND_BODY_IDENTITY_PLAN.md)
--
-- library_upsert_master ALREADY has p_tile_type and p_thickness — both were accepted and IGNORED
-- (thickness was derived; tile_type was a plain attribute). They now carry IDENTITY, so no new
-- parameter is needed and no overload is created. Only their MEANING changes:
--
--   p_thickness  -> the DECLARED nominal (validated against thickness_options), part of the key
--   p_tile_type  -> mandatory, part of the key

-- Shared validator: the list is fixed on purpose. A free number would make 8 and 8.0 two products.
create or replace function public._nominal_thickness(p_mm numeric)
returns numeric
language plpgsql
immutable
set search_path to 'public', 'pg_temp'
as $function$
begin
  if p_mm is null then return null; end if;
  if not exists (select 1 from thickness_options where mm = p_mm and is_active) then
    raise exception 'Thickness % mm is not one we recognise. Pick from: %',
      p_mm, (select string_agg(mm::text, ', ' order by sort) from thickness_options where is_active);
  end if;
  return p_mm;
end; $function$;

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
        v_thk  numeric;
        r jsonb; v_brand uuid; v_alias text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can edit the library'; end if;
  if v_name = '' then raise exception 'Master design name cannot be empty'; end if;
  if v_size = '' then raise exception 'Size is required'; end if;
  if v_surf is null or lower(v_surf) = 'none' then
    raise exception 'Pick a surface — it is part of the design.';
  end if;

  v_thk := _nominal_thickness(p_thickness);

  -- On CREATE, body and thickness are mandatory: they are IDENTITY, and a product created without
  -- them is a product we cannot tell apart from a different one. On EDIT they are only applied when
  -- supplied, so a legacy row (thickness still NULL) can still have its image or name fixed.
  if p_id is null then
    if v_tile is null then
      raise exception 'Pick a tile type — it is part of the design.';
    end if;
    if v_thk is null then
      raise exception 'Pick a thickness — it is part of the design.';
    end if;
  end if;

  -- The duplicate check must use the WHOLE key, or an 8 mm and a 12 mm of the same print would
  -- look like a clash instead of the two products they are.
  if exists (select 1 from stockist_library
             where stockist_id = v_stk
               and lower(master_design_name) = lower(v_name)
               and size = v_size and surface_type = v_surf
               and tile_type is not distinct from coalesce(v_tile, tile_type)
               and nominal_thickness_mm is not distinct from
                   coalesce(v_thk, nominal_thickness_mm)
               and (p_id is null or id <> p_id)) then
    raise exception '"%" (% · % · % · % mm) is already in your library',
      v_name, v_size, v_surf, v_tile, v_thk;
  end if;

  if p_id is null then
    insert into stockist_library (stockist_id, size, master_design_name, image_url,
                                  brand_id, surface_type, tile_type, nominal_thickness_mm)
      values (v_stk, v_size, v_name, nullif(btrim(coalesce(p_image_url,'')), ''),
              p_brand_id, v_surf, v_tile, v_thk)
      returning id into v_id;
  else
    update stockist_library set
      size = v_size, master_design_name = v_name,
      image_url = nullif(btrim(coalesce(p_image_url,'')), ''),
      brand_id = coalesce(p_brand_id, brand_id),
      surface_type = v_surf,
      tile_type            = coalesce(v_tile, tile_type),
      nominal_thickness_mm = coalesce(v_thk,  nominal_thickness_mm),
      updated_at = now()
    where id = p_id and stockist_id = v_stk
    returning id into v_id;
    if v_id is null then raise exception 'Design not found'; end if;

    -- CASCADE: the stock follows its product's surface (and name/size, copied for display).
    update designs d
       set surface_type = v_surf,
           name         = v_name,
           size         = v_size,
           updated_at   = now()
     where d.library_id = v_id and d.stockist_id = v_stk;
  end if;

  update stockist_library m set
    stock_type   = case when p_stock_type is null then m.stock_type   else coalesce(nullif(btrim(p_stock_type),''),'Uncertain') end,
    colour       = case when p_colour     is null then m.colour       else coalesce(btrim(p_colour),'') end,
    finish_label = case when p_finish     is null then m.finish_label else nullif(btrim(p_finish),'') end,
    updated_at = now()
  where m.id = v_id;

  -- The brand-name rows ARE THE BOXES: they carry pieces_per_box and box_weight_kg, so they are
  -- SYNCED in place — deleting and re-inserting them would throw away every brand's packing.
  -- p_pieces / p_weight are still accepted and IGNORED (library_set_box owns the packing).
  if p_aliases is not null then
    for r in select * from jsonb_array_elements(p_aliases) loop
      v_brand := nullif(r->>'brand_id','')::uuid;
      v_alias := btrim(coalesce(r->>'name',''));
      if v_alias <> '' and v_brand is not null
         and exists (select 1 from brands where id = v_brand and stockist_id = v_stk) then
        if exists (
          select 1 from stockist_library m2
          join stockist_library_brand_names a2 on a2.library_id = m2.id
          where m2.stockist_id = v_stk and m2.id <> v_id
            and a2.brand_id = v_brand and lower(a2.brand_design_name) = lower(v_alias)
            and m2.size = v_size and m2.surface_type = v_surf
            and m2.tile_type is not distinct from coalesce(v_tile, m2.tile_type)
            and m2.nominal_thickness_mm is not distinct from
                coalesce(v_thk, m2.nominal_thickness_mm)
        ) then
          raise exception 'Design name "%" is already used for another tile in that brand at % · %',
            v_alias, v_size, v_surf;
        end if;
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

  return v_id;
end; $function$;

-- _library_apply_identity must stop back-filling tile_type: it is IDENTITY now, so the creator sets
-- it and a later "fill the blank" update would silently move a product to a different key.
create or replace function public._library_apply_identity(p_library_id uuid, p_attrs jsonb)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_stock   text    := nullif(btrim(coalesce(p_attrs->>'stock_type','')),'');
  v_pieces  int     := nullif(btrim(coalesce(p_attrs->>'pieces_per_box','')),'')::int;
  v_weight  numeric := nullif(btrim(coalesce(p_attrs->>'box_weight_kg','')),'')::numeric;
  v_colour  text    := nullif(btrim(coalesce(p_attrs->>'colour','')),'');
  v_finish  text    := nullif(btrim(coalesce(p_attrs->>'finish_label','')),'');
  v_stk uuid;
begin
  if p_library_id is null or p_attrs is null then return; end if;
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then return; end if;

  -- tile_type is deliberately NOT set here any more — see above.
  update stockist_library m set
    stock_type   = case when m.stock_type in ('','Uncertain') then coalesce(v_stock, m.stock_type) else m.stock_type end,
    colour       = case when coalesce(m.colour,'') = '' then coalesce(v_colour, m.colour) else m.colour end,
    finish_label = case when m.finish_label is null then coalesce(v_finish, m.finish_label) else m.finish_label end,
    updated_at   = now()
  where m.id = p_library_id and m.stockist_id = v_stk;

  if v_pieces is not null or v_weight is not null then
    update stockist_library_brand_names a set
      pieces_per_box = case when coalesce(a.pieces_per_box,0) = 0
                            then coalesce(v_pieces, a.pieces_per_box) else a.pieces_per_box end,
      box_weight_kg  = case when coalesce(a.box_weight_kg,0) = 0
                            then coalesce(v_weight, a.box_weight_kg)  else a.box_weight_kg end
    where a.library_id = p_library_id
      and exists (select 1 from stockist_library l
                   where l.id = a.library_id and l.stockist_id = v_stk);
  end if;
end; $function$;
