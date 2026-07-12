-- Product identity migration — STEP 5 of 5: teach the writers the new key.
-- (docs/PRODUCT_IDENTITY_MIGRATION_PLAN.md)
--
-- Steps 1-4 changed the product key to
--     (stockist_id, lower(master_design_name), size, surface_type)
-- but every function that WRITES stockist_library still keys on brand and does not know
-- surface carries identity. Until this lands the DB is half-migrated and Add Stock / the
-- Library editor / import can throw unique violations or find the wrong product.
--
-- Two live breakages this fixes:
--   * library_upsert_master BLOCKS an M from having the same name+size twice — so a
--     stockist literally cannot add "Ant Bianco / Matt" once "Ant Bianco / Glossy" exists.
--     Its own comment said "surface is an attribute, not identity". That is now false.
--   * Its INSERT never set surface_type (a later UPDATE patched it), so it inserts a
--     'None' row that can collide before the patch runs.
--
-- Every function keeps its EXACT signature — `create or replace` only. No new params, so
-- no overloads. (See [[feedback_rpc_param_add_creates_overload]]: adding a defaulted param
-- does NOT replace, it overloads, and the old call shape then dies with 42725.)
--
-- import_stock_batch needs NO change: it already calls
--     library_map_upsert(v_size, v_master_name, v_aliases, v_surface)
-- passing the surface. Fixing library_map_upsert fixes the whole import path for free.


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. stock_add_holding — resolve the PRODUCT for the requested surface.
--
-- The caller hands us a product + a surface. If that surface is not this product's, they
-- mean a DIFFERENT product of the same print — so find it, or create it by copying the
-- print's attributes. This is what stops a holding's surface and its product's surface
-- from ever disagreeing again (the invariant step 4 established).
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.stock_add_holding(
  p_library_id uuid, p_quality text, p_qty integer, p_catalog_id uuid,
  p_surface text default 'None'::text, p_brand_id uuid default null::uuid,
  p_surface_label text default null::text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_stk uuid; v_design uuid; v_q text; v_surf text; v_label text;
        v_name text; v_size text; v_brand uuid; v_master_brand uuid; v_lib uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if p_library_id is null then raise exception 'Pick a design first'; end if;

  select master_design_name, size, brand_id into v_name, v_size, v_master_brand
    from stockist_library where id = p_library_id and stockist_id = v_stk;
  if v_name is null then raise exception 'Design is not in your library'; end if;

  if p_catalog_id is not null and not exists (
       select 1 from stock_catalogs where id = p_catalog_id and stockist_id = v_stk) then
    raise exception 'Stock list does not belong to you';
  end if;

  v_brand := coalesce(p_brand_id, v_master_brand);
  v_q     := coalesce(nullif(btrim(p_quality),''),'Standard');
  v_surf  := coalesce(nullif(btrim(p_surface),''),'None');
  v_label := nullif(btrim(p_surface_label),'');

  -- SURFACE IS PRODUCT IDENTITY.
  select id into v_lib from stockist_library
   where stockist_id = v_stk and lower(master_design_name) = lower(v_name)
     and size = v_size and surface_type = v_surf;

  if v_lib is null then
    -- thickness_band is GENERATED — never list it.
    insert into stockist_library (
      stockist_id, size, master_design_name, image_url, is_sample, brand_id,
      surface_type, surface_label, stock_type, tile_type, pieces_per_box,
      box_weight_kg, thickness_mm, colour, finish_label)
    select l.stockist_id, l.size, l.master_design_name, l.image_url, l.is_sample,
           l.brand_id, v_surf, v_label, l.stock_type, l.tile_type, l.pieces_per_box,
           l.box_weight_kg, l.thickness_mm, l.colour, l.finish_label
      from stockist_library l where l.id = p_library_id
    returning id into v_lib;

    -- Same artwork -> same character. DNA is per PRODUCT (user decision 2026-07-12,
    -- there is no PRINT table), so it is COPIED, not shared.
    insert into library_dna (library_id, value_id)
      select v_lib, x.value_id from library_dna x where x.library_id = p_library_id;
    insert into stockist_library_brand_names (library_id, brand_id, brand_design_name)
      select v_lib, x.brand_id, x.brand_design_name
        from stockist_library_brand_names x where x.library_id = p_library_id;
    insert into library_family_overrides (library_id, stockist_id, family_key)
      select v_lib, x.stockist_id, x.family_key
        from library_family_overrides x where x.library_id = p_library_id;

  elsif v_label is not null then
    -- Refresh the stockist's WORD for this canonical surface (display-only, never key).
    update stockist_library set surface_label = v_label, updated_at = now()
     where id = v_lib and surface_label is distinct from v_label;
  end if;

  -- Holding identity is unchanged: (stockist, library, brand, quality, surface_type).
  select id into v_design from designs
    where stockist_id = v_stk and library_id = v_lib
      and brand_id is not distinct from v_brand
      and quality = v_q and surface_type = v_surf;
  if v_design is null then
    insert into designs (stockist_id, name, size, quality, surface_type, surface_label,
                         box_quantity, status, library_id, brand_id)
      values (v_stk, v_name, v_size, v_q, v_surf, v_label, 0, 'active', v_lib, v_brand)
      returning id into v_design;
  elsif v_label is not null then
    update designs set surface_label = v_label where id = v_design;
  end if;

  if p_catalog_id is not null then
    insert into catalog_designs (catalog_id, library_id)
      values (p_catalog_id, v_lib) on conflict do nothing;
  end if;

  if coalesce(p_qty,0) > 0 then
    perform add_stock(v_design, v_stk, p_qty, '', v_size, v_q);
  end if;
  return v_design;
end; $function$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. add_inventory_batch — DELETE the surface stamp and the surface_mode branch.
--
-- The old code did:
--     if v_biz = 'M' and v_mode <> 'attribute' and lower(v_surf) <> 'none' then
--       update stockist_library set surface_type = v_surf where id = v_lib;
--
-- That UPDATE is now a landmine: re-stamping a product's surface would collide with the
-- real product of that surface. And it is unnecessary — stock_add_holding now RESOLVES
-- the product by surface. surface_mode stops influencing identity entirely; it survives
-- only as an import/parser hint (where to READ the surface from), which is all it ever
-- legitimately was.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.add_inventory_batch(p_entries jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  e jsonb; v_id uuid; v_count int := 0; v_boxes int := 0; v_q int;
  v_stk uuid; v_lib uuid; v_brand uuid; v_surf text; v_label text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;

  for e in select * from jsonb_array_elements(coalesce(p_entries, '[]'::jsonb)) loop
    v_q     := greatest(coalesce((e->>'quantity')::int, 0), 0);
    v_lib   := (e->>'library_id')::uuid;
    v_brand := nullif(btrim(coalesce(e->>'brand_id', '')), '')::uuid;
    v_surf  := coalesce(nullif(btrim(e->>'surface'), ''), 'None');
    v_label := nullif(btrim(coalesce(e->>'surface_label','')), '');

    v_id := public.stock_add_holding(
      v_lib,
      coalesce(nullif(btrim(e->>'quality'), ''), 'Standard'),
      v_q, null, v_surf, v_brand, v_label);

    if v_id is not null then
      v_count := v_count + 1;
      v_boxes := v_boxes + v_q;
    end if;
  end loop;
  return jsonb_build_object('count', v_count, 'boxes', v_boxes);
end; $function$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. library_map_upsert — key on surface, not brand. (Also fixes import_stock_batch.)
--
-- The M / T-W brand branching is gone: brand never splits a product. A brand alias only
-- tells us WHICH PRINT, never which product — the surface decides that.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.library_map_upsert(
  p_size text, p_master_name text, p_aliases jsonb, p_surface text default 'None'::text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_id uuid;
        v_name text := btrim(coalesce(p_master_name,''));
        v_size text := btrim(coalesce(p_size,''));
        v_surf text := coalesce(nullif(btrim(coalesce(p_surface,'')),''),'None');
        r jsonb; v_brand uuid; v_alias text; v_brand1 uuid; v_alias1 text; v_key text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can edit the library'; end if;
  if v_size = '' then raise exception 'Size is required'; end if;

  if p_aliases is not null and jsonb_array_length(p_aliases) > 0 then
    v_brand1 := nullif(p_aliases->0->>'brand_id','')::uuid;
    v_alias1 := btrim(coalesce(p_aliases->0->>'name',''));
  end if;
  v_key := lower(coalesce(nullif(v_name,''), v_alias1));
  if v_key = '' then raise exception 'Design name cannot be empty'; end if;

  -- 1) by a brand's alias name + size + SURFACE
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
         order by m.created_at limit 1;
      end if;
    end loop;
  end if;

  -- 2) by the master name + size + SURFACE  (== stockist_library_uniq)
  if v_id is null then
    select id into v_id from stockist_library
     where stockist_id = v_stk and lower(master_design_name) = v_key
       and size = v_size and surface_type = v_surf
     order by created_at limit 1;
  end if;

  if v_id is null then
    -- brand_id is a first-seen HINT only; it carries no identity.
    insert into stockist_library (stockist_id, size, master_design_name, brand_id, surface_type)
      values (v_stk, v_size, coalesce(nullif(v_name,''), v_alias1), v_brand1, v_surf)
      returning id into v_id;
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


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. library_upsert_master — the duplicate guard must include SURFACE.
--
-- Was: an M could not have the same name+size twice ("surface is an attribute, not
-- identity"). That blocked Glossy + Matt of one print. Now the guard is exactly the new
-- key, and the INSERT sets surface_type instead of leaving it to default to 'None'.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.library_upsert_master(
  p_id uuid, p_size text, p_master_name text, p_image_url text, p_aliases jsonb,
  p_brand_id uuid default null::uuid, p_surface text default null::text,
  p_stock_type text default null::text, p_tile_type text default null::text,
  p_pieces integer default null::integer, p_weight numeric default null::numeric,
  p_thickness numeric default null::numeric, p_colour text default null::text,
  p_finish text default null::text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_id uuid;
        v_name text := btrim(coalesce(p_master_name,''));
        v_size text := btrim(coalesce(p_size,''));
        v_surf text := coalesce(nullif(btrim(coalesce(p_surface,'')),''),'None');
        r jsonb; v_brand uuid; v_alias text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can edit the library'; end if;
  if v_name = '' then raise exception 'Master design name cannot be empty'; end if;
  if v_size = '' then raise exception 'Size is required'; end if;

  -- Duplicate guard == the product key. Same print in another SURFACE is a different
  -- product and is allowed; the same print in the SAME surface is a duplicate.
  if exists (select 1 from stockist_library
             where stockist_id = v_stk
               and lower(master_design_name) = lower(v_name)
               and size = v_size and surface_type = v_surf
               and (p_id is null or id <> p_id)) then
    raise exception '"%" (% · %) is already in your library', v_name, v_size, v_surf;
  end if;

  if p_id is null then
    insert into stockist_library (stockist_id, size, master_design_name, image_url,
                                  brand_id, surface_type)
      values (v_stk, v_size, v_name, nullif(btrim(coalesce(p_image_url,'')), ''),
              p_brand_id, v_surf)
      returning id into v_id;
  else
    update stockist_library set
      size = v_size, master_design_name = v_name,
      image_url = nullif(btrim(coalesce(p_image_url,'')), ''),
      brand_id = coalesce(p_brand_id, brand_id),
      surface_type = v_surf,
      updated_at = now()
    where id = p_id and stockist_id = v_stk
    returning id into v_id;
    if v_id is null then raise exception 'Design not found'; end if;
  end if;

  update stockist_library m set
    stock_type     = case when p_stock_type is null then m.stock_type     else coalesce(nullif(btrim(p_stock_type),''),'Uncertain') end,
    tile_type      = case when p_tile_type  is null then m.tile_type      else coalesce(btrim(p_tile_type),'') end,
    pieces_per_box = case when p_pieces     is null then m.pieces_per_box else coalesce(p_pieces,0) end,
    box_weight_kg  = case when p_weight     is null then m.box_weight_kg  else coalesce(p_weight,0) end,
    thickness_mm   = case when p_thickness  is null then m.thickness_mm   else coalesce(p_thickness,0) end,
    colour         = case when p_colour     is null then m.colour         else coalesce(btrim(p_colour),'') end,
    finish_label   = case when p_finish     is null then m.finish_label   else nullif(btrim(p_finish),'') end,
    updated_at = now()
  where m.id = v_id;

  delete from stockist_library_brand_names where library_id = v_id;
  if p_aliases is not null then
    for r in select * from jsonb_array_elements(p_aliases) loop
      v_brand := nullif(r->>'brand_id','')::uuid;
      v_alias := btrim(coalesce(r->>'name',''));
      if v_alias <> '' and v_brand is not null
         and exists (select 1 from brands where id = v_brand and stockist_id = v_stk) then
        -- A brand's name may not point at two different PRODUCTS of the same size AND
        -- surface. Across surfaces it is fine — that is the point.
        if exists (
          select 1 from stockist_library m2
          join stockist_library_brand_names a2 on a2.library_id = m2.id
          where m2.stockist_id = v_stk and m2.id <> v_id
            and a2.brand_id = v_brand and lower(a2.brand_design_name) = lower(v_alias)
            and m2.size = v_size and m2.surface_type = v_surf
        ) then
          raise exception 'Design name "%" is already used for another tile in that brand at size % · %',
            v_alias, v_size, v_surf;
        end if;
        insert into stockist_library_brand_names (library_id, brand_id, brand_design_name)
          values (v_id, v_brand, v_alias)
          on conflict (library_id, brand_id) do update set brand_design_name = excluded.brand_design_name;
      end if;
    end loop;
  end if;
  return v_id;
end; $function$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. admin_library_upsert — same treatment: key on surface, insert with surface.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_library_upsert(
  p_seq text, p_size text, p_master_name text, p_brand_id uuid,
  p_image_url text default null::text, p_surface text default null::text,
  p_tile_type text default null::text, p_pieces integer default null::integer,
  p_weight numeric default null::numeric, p_thickness numeric default null::numeric,
  p_aliases jsonb default null::jsonb)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_id uuid;
        v_name text := btrim(coalesce(p_master_name,''));
        v_size text := btrim(coalesce(p_size,''));
        v_surf text := coalesce(nullif(btrim(coalesce(p_surface,'')),''),'None');
        r jsonb; v_brand uuid; v_alias text;
begin
  if current_user_role() <> 'admin' then
    raise exception 'Only admins can bulk-import on behalf of a stockist';
  end if;
  select id into v_stk from stockists where sequential_id = p_seq;
  if v_stk is null then raise exception 'Stockist not found'; end if;
  if v_name = '' then raise exception 'Design name cannot be empty'; end if;
  if v_size = '' then raise exception 'Size is required'; end if;

  select id into v_id from stockist_library
   where stockist_id = v_stk and lower(master_design_name) = lower(v_name)
     and size = v_size and surface_type = v_surf
   limit 1;

  if v_id is null then
    insert into stockist_library (stockist_id, size, master_design_name, image_url,
                                  brand_id, surface_type)
      values (v_stk, v_size, v_name,
              nullif(btrim(coalesce(p_image_url,'')),''), p_brand_id, v_surf)
      returning id into v_id;
  else
    update stockist_library set
      image_url = coalesce(nullif(btrim(coalesce(p_image_url,'')),''), image_url),
      updated_at = now()
    where id = v_id;
  end if;

  update stockist_library m set
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


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. library_contribute — stop keying on brand. (No app caller today, but it must not be
--    able to violate the new key if it is ever revived.)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.library_contribute(
  p_brand_id uuid, p_name text, p_size text, p_image_url text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_id uuid;
        v_name text := btrim(coalesce(p_name,''));
        v_size text := btrim(coalesce(p_size,''));
        v_url  text := nullif(btrim(coalesce(p_image_url,'')), '');
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then return null; end if;
  if v_name = '' or v_size = '' then return null; end if;
  if p_brand_id is null
     or not exists (select 1 from brands where id = p_brand_id and stockist_id = v_stk) then
    return null;
  end if;

  -- This entry point knows no surface, so it can only ever mean the 'None' product.
  select id into v_id from stockist_library
   where stockist_id = v_stk and lower(master_design_name) = lower(v_name)
     and size = v_size and surface_type = 'None'
   limit 1;

  if v_id is null then
    insert into stockist_library (stockist_id, size, master_design_name, image_url,
                                  brand_id, surface_type)
      values (v_stk, v_size, v_name, v_url, p_brand_id, 'None') returning id into v_id;
  elsif v_url is not null then
    update stockist_library set image_url = coalesce(image_url, v_url), updated_at = now()
     where id = v_id;  -- first-writer-wins
  end if;

  insert into stockist_library_brand_names (library_id, brand_id, brand_design_name)
    values (v_id, p_brand_id, v_name)
    on conflict (library_id, brand_id) do nothing;
  return v_id;
end; $function$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. library_merge_masters — refuse to merge across SURFACES.
--    Same size was already required. Two surfaces are two products; merging them would
--    re-create exactly the collapse bug step 4 just repaired.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.library_merge_masters(p_keep_id uuid, p_drop_id uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_stk uuid;
  v_keep_size text; v_drop_size text;
  v_keep_img text; v_drop_img text;
  v_keep_surf text; v_drop_surf text;
  rec record; v_keep_hold uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can merge the library'; end if;
  if p_keep_id = p_drop_id then raise exception 'Cannot merge a design into itself'; end if;

  select size, nullif(btrim(coalesce(image_url,'')),''), surface_type
    into v_keep_size, v_keep_img, v_keep_surf
  from stockist_library where id = p_keep_id and stockist_id = v_stk;
  select size, nullif(btrim(coalesce(image_url,'')),''), surface_type
    into v_drop_size, v_drop_img, v_drop_surf
  from stockist_library where id = p_drop_id and stockist_id = v_stk;
  if v_keep_size is null or v_drop_size is null then
    raise exception 'Both designs must be yours';
  end if;
  if v_keep_size <> v_drop_size then
    raise exception 'Only same-size designs can be merged (% vs %)', v_keep_size, v_drop_size;
  end if;

  -- NEW: surface is product identity. Merging a Glossy into a Matt would re-create the
  -- exact collapse bug step 4 repaired.
  if v_keep_surf <> v_drop_surf then
    raise exception 'Cannot merge across surfaces (% vs %) — they are different products',
      v_keep_surf, v_drop_surf;
  end if;

  update stockist_library_brand_names d
     set library_id = p_keep_id
   where d.library_id = p_drop_id
     and not exists (select 1 from stockist_library_brand_names k
                     where k.library_id = p_keep_id and k.brand_id = d.brand_id);
  delete from stockist_library_brand_names where library_id = p_drop_id;

  insert into library_dna (library_id, value_id)
    select p_keep_id, d.value_id
    from library_dna d
    where d.library_id = p_drop_id
      and not exists (select 1 from library_dna k
                      where k.library_id = p_keep_id and k.value_id = d.value_id);

  update catalog_designs c set library_id = p_keep_id
   where c.library_id = p_drop_id
     and not exists (select 1 from catalog_designs k
                     where k.catalog_id = c.catalog_id and k.library_id = p_keep_id);

  for rec in select * from designs where library_id = p_drop_id and stockist_id = v_stk loop
    select id into v_keep_hold from designs
     where library_id = p_keep_id and stockist_id = v_stk
       and quality = rec.quality and surface_type = rec.surface_type;
    if v_keep_hold is null then
      update designs set library_id = p_keep_id, updated_at = now() where id = rec.id;
    else
      update designs
         set box_quantity = coalesce(box_quantity,0) + coalesce(rec.box_quantity,0),
             updated_at = now()
       where id = v_keep_hold;
      update stock_in          set design_id = v_keep_hold where design_id = rec.id;
      update stock_adjustments set design_id = v_keep_hold where design_id = rec.id;
      update dispatches        set design_id = v_keep_hold where design_id = rec.id;
      update inquiry_items     set design_id = v_keep_hold where design_id = rec.id;
      delete from my_choices   where design_id = rec.id;
      delete from designs      where id = rec.id;
    end if;
  end loop;

  if v_keep_img is null and v_drop_img is not null then
    update stockist_library set image_url = v_drop_img where id = p_keep_id;
  end if;

  delete from library_family_overrides where library_id = p_drop_id;
  delete from stockist_library where id = p_drop_id;
  return p_keep_id;
end; $function$;
