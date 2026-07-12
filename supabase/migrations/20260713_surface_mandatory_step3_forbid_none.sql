-- Surface becomes MANDATORY — step 3 of 3: make 'None' IMPOSSIBLE.
--
-- Steps 1-2 removed every 'None' product and taught stock to inherit. But the writers could
-- still MAKE one: library_map_upsert / library_upsert_master / admin_library_upsert /
-- library_contribute all defaulted a missing surface to 'None', and both importers still
-- offer 'None' in their pickers. One PDF import would undo the whole chapter.
--
-- So the database now refuses it outright, rather than trusting every caller to behave.
-- A loud, immediate error beats a silent phantom product (see the swallowed-errors sweep).

-- 1. Retire the 'None' row itself. It is is_system so it cannot be deleted — deactivate it,
--    which removes it from every picker at once: getActiveFinishNames() and
--    getSurfaceTypes(activeOnly: true) both filter on is_active.
update surface_types set is_active = false where name = 'None';

-- 2. The hard guarantee. A product without a real surface cannot exist.
alter table stockist_library
  drop constraint if exists stockist_library_surface_not_none;

alter table stockist_library
  add constraint stockist_library_surface_not_none
  check (surface_type is not null and btrim(surface_type) <> '' and surface_type <> 'None');

-- 3. The writers must ASK, not invent. Each raises a message the UI can show verbatim
--    instead of silently creating a 'None' product.
--    (Signatures unchanged — create-or-replace only, no overloads.)

create or replace function public.library_map_upsert(
  p_size text, p_master_name text, p_aliases jsonb, p_surface text default null::text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_id uuid;
        v_name text := btrim(coalesce(p_master_name,''));
        v_size text := btrim(coalesce(p_size,''));
        v_surf text := nullif(btrim(coalesce(p_surface,'')),'');
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
        v_surf text := nullif(btrim(coalesce(p_surface,'')),'');
        r jsonb; v_brand uuid; v_alias text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can edit the library'; end if;
  if v_name = '' then raise exception 'Master design name cannot be empty'; end if;
  if v_size = '' then raise exception 'Size is required'; end if;
  if v_surf is null or lower(v_surf) = 'none' then
    raise exception 'Pick a surface — it is part of the design.';
  end if;

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
        v_surf text := nullif(btrim(coalesce(p_surface,'')),'');
        r jsonb; v_brand uuid; v_alias text;
begin
  if current_user_role() <> 'admin' then
    raise exception 'Only admins can bulk-import on behalf of a stockist';
  end if;
  select id into v_stk from stockists where sequential_id = p_seq;
  if v_stk is null then raise exception 'Stockist not found'; end if;
  if v_name = '' then raise exception 'Design name cannot be empty'; end if;
  if v_size = '' then raise exception 'Size is required'; end if;
  if v_surf is null or lower(v_surf) = 'none' then
    raise exception 'A surface is required for "%" (%)', v_name, v_size;
  end if;

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


-- library_contribute knows no surface at all, so it can no longer create a product.
-- It becomes image-fill-only for a product that already exists. (No app caller today.)
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

  -- Cannot CREATE: it has no surface to give, and a product without one may not exist.
  select id into v_id from stockist_library
   where stockist_id = v_stk and lower(master_design_name) = lower(v_name)
     and size = v_size
   order by created_at limit 1;
  if v_id is null then return null; end if;

  if v_url is not null then
    update stockist_library set image_url = coalesce(image_url, v_url), updated_at = now()
     where id = v_id;  -- first-writer-wins
  end if;

  if p_brand_id is not null
     and exists (select 1 from brands where id = p_brand_id and stockist_id = v_stk) then
    insert into stockist_library_brand_names (library_id, brand_id, brand_design_name)
      values (v_id, p_brand_id, v_name)
      on conflict (library_id, brand_id) do nothing;
  end if;
  return v_id;
end; $function$;
