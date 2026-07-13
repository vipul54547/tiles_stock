-- CHAPTER 4, step 2 — the READERS move onto the PRINT, and the duplicated columns DIE.
--
-- Step 1 (20260713q) created print_master and pointed every product at it, but changed no reader:
-- the print's name/image were still ALSO stored on stockist_library, and nothing kept the two
-- copies in sync. This finishes the job for NAME, IMAGE and COLOUR:
--
--     stockist_library.master_design_name  ->  print_master.print_name     DROPPED
--     stockist_library.image_url           ->  print_master.image_url      DROPPED
--     stockist_library.colour              ->  DNA 'Colour' on the print   DROPPED
--
-- 🔑 THE RPC OUTPUT SHAPE DOES NOT CHANGE. Every function still returns `master_design_name`,
--    `image_url` and `colour` under exactly those keys — they are just sourced from the print now.
--    So NOT ONE LINE OF DART CHANGES. The storage moved; the contract did not.
--
-- ⚠️ `size` STAYS on stockist_library for now, as a MIRROR of its print, maintained by trigger
--    (_trg_library_size_from_print). It has ONE writer and cannot drift, so it is a cache, not a
--    second source of truth. It is not dropped here because 19 further functions and BOTH public
--    views read `l.size`, and widening this migration to them is how you break the whole app in
--    one commit. It dies in its own pass.
--
-- ⚠️ colour held real data on exactly ONE row ('White'), and ZERO products are DNA-Colour tagged,
--    so nothing of value is lost. `colour` now reads from DNA, which is where the model puts it.
--
-- Identity moves with the columns: the product key can no longer say "same stockist + same name +
-- same size", because it no longer HAS a name or a size of its own. It says **same PRINT** — which
-- is the same statement, only now it cannot lie.

-- ---------------------------------------------------------------- 1. find-or-create a PRINT
create or replace function print_upsert(p_stockist uuid, p_name text, p_size text,
                                        p_image text default null)
returns uuid language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_id uuid;
        v_name text := btrim(coalesce(p_name,''));
        v_size text := btrim(coalesce(p_size,''));
        v_img  text := nullif(btrim(coalesce(p_image,'')),'');
begin
  if v_name = '' then raise exception 'Design name cannot be empty'; end if;
  if v_size = '' then raise exception 'Size is required'; end if;

  select id into v_id from print_master
   where stockist_id = p_stockist and lower(print_name) = lower(v_name) and size = v_size;

  if v_id is null then
    insert into print_master (stockist_id, print_name, size, image_url)
      values (p_stockist, v_name, v_size, v_img)
      returning id into v_id;
  elsif v_img is not null then
    -- FIRST-WRITER-WINS. A print keeps the photo it already has; an import may only FILL a blank.
    update print_master set image_url = coalesce(image_url, v_img), updated_at = now()
     where id = v_id;
  end if;
  return v_id;
end $$;

comment on function print_upsert is
  'The ONLY way a print is created. Find-or-create on (stockist, lower(name), size); the image is '
  'first-writer-wins, never overwritten.';

-- ---------------------------------------------------------------- 2. size is a MIRROR of the print
create or replace function _trg_library_size_from_print()
returns trigger language plpgsql set search_path to 'public','pg_temp' as $$
begin
  select p.size into new.size from print_master p where p.id = new.print_id;
  return new;
end $$;

comment on function _trg_library_size_from_print is
  'stockist_library.size is a CACHE of its print''s size, not a second source of truth: this is its '
  'only writer. The column is dropped once the 19 remaining l.size readers and both public views '
  'have moved to the print.';

drop trigger if exists aa_library_size_from_print on stockist_library;
create trigger aa_library_size_from_print
  before insert or update of print_id on stockist_library
  for each row execute function _trg_library_size_from_print();

-- repair any drift that predates the trigger
update stockist_library l set size = p.size
  from print_master p where p.id = l.print_id and l.size is distinct from p.size;

-- ---------------------------------------------------------------- 3. colour now comes from DNA
-- Colour is a DNA attribute (multi-value, 11 values) that belongs to the ARTWORK — so a product's
-- colour is its print's tags plus any still hanging off the product itself. Returned as text so the
-- RPC's `colour` key keeps the shape Dart already parses.
create or replace function _dna_colour(p_library uuid)
returns text language sql stable set search_path to 'public','pg_temp' as $$
  select string_agg(v.name, ', ' order by v.name)
    from (
      select ld.value_id from library_dna ld where ld.library_id = p_library
      union
      select pd.value_id from print_dna pd
        join stockist_library l on l.print_id = pd.print_id
       where l.id = p_library
    ) x
    join dna_values     v on v.id = x.value_id
    join dna_attributes a on a.id = v.attribute_id
   where a.name = 'Colour' and v.is_active and lower(v.name) <> 'none';
$$;

-- ---------------------------------------------------------------- 4. WRITERS
-- Every path that used to write a name/image onto the product now writes it to the PRINT and
-- points the product at it.

-- 4a. the sample row a new stockist is seeded with
create or replace function _stockist_default_catalog()
 returns trigger language plpgsql security definer
 set search_path to 'public','pg_temp'
as $function$
declare v_brand_id uuid; v_catalog_id uuid; v_library_id uuid; v_print_id uuid;
  v_sample_name text := 'Sample — edit or delete me';
  v_sample_size text := '600x1200 mm';
begin
  insert into public.brands (stockist_id, name, is_default, status, is_active, stock_list_limit)
  values (new.id, coalesce(nullif(trim(new.name), ''), 'My Brand'), true, 'live', true,
          greatest(coalesce(new.stock_list_limit,3),1))
  returning id into v_brand_id;
  insert into public.stock_catalogs
    (stockist_id, brand_id, name, visibility, show_in_marketplace, sort_order, is_active)
  values (new.id, v_brand_id, 'Stock_List1', 'public', coalesce(new.is_listed, false), 0, true)
  returning id into v_catalog_id;

  v_print_id := print_upsert(new.id, v_sample_name, v_sample_size, null);

  insert into public.stockist_library (stockist_id, print_id, is_sample, brand_id, surface_type)
  values (new.id, v_print_id, true, v_brand_id, 'Special') returning id into v_library_id;

  insert into public.stockist_library_brand_names (library_id, brand_id, brand_design_name)
  values (v_library_id, v_brand_id, v_sample_name);
  insert into public.designs
    (stockist_id, name, size, quality, box_quantity, status, is_sample, library_id, surface_type)
  values (new.id, v_sample_name, v_sample_size, 'Standard', 0, 'active', true, v_library_id, 'Special');
  insert into public.catalog_designs (catalog_id, library_id) values (v_catalog_id, v_library_id);
  perform _ensure_stockist_capacity(new.id);
  return new;
end; $function$;

-- 4b. sample adoption: the print carries the name now
create or replace function _adopt_sample_on_stock()
 returns trigger language plpgsql security definer
 set search_path to 'public','pg_temp'
as $function$
begin
  if old.is_sample is true and new.box_quantity > 0 then
    new.is_sample := false;
    update public.stockist_library l
       set is_sample = false
      from print_master p
     where p.id = l.print_id
       and l.stockist_id = new.stockist_id and l.is_sample = true
       and lower(p.print_name) = lower(new.name) and p.size = new.size;
  end if;
  return new;
end; $function$;

-- 4c. colour leaves the product; pieces/weight still land on the BOX (first-writer-wins)
create or replace function _library_apply_identity(p_library_id uuid, p_attrs jsonb)
 returns void language plpgsql security definer
 set search_path to 'public','pg_temp'
as $function$
declare
  v_stock   text    := nullif(btrim(coalesce(p_attrs->>'stock_type','')),'');
  v_pieces  int     := nullif(btrim(coalesce(p_attrs->>'pieces_per_box','')),'')::int;
  v_weight  numeric := nullif(btrim(coalesce(p_attrs->>'box_weight_kg','')),'')::numeric;
  v_finish  text    := nullif(btrim(coalesce(p_attrs->>'finish_label','')),'');
  v_stk uuid;
begin
  if p_library_id is null or p_attrs is null then return; end if;
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then return; end if;

  -- tile_type is NOT set here (library_map_upsert adopts it); colour is DNA now.
  update stockist_library m set
    stock_type   = case when m.stock_type in ('','Uncertain') then coalesce(v_stock, m.stock_type) else m.stock_type end,
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

-- 4d. the mapping/import upsert
create or replace function library_map_upsert(p_size text, p_master_name text, p_aliases jsonb,
                                              p_surface text default null, p_tile_type text default null)
 returns uuid language plpgsql security definer
 set search_path to 'public','pg_temp'
as $function$
declare v_stk uuid; v_id uuid; v_print uuid;
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
  v_key := coalesce(nullif(v_name,''), v_alias1);
  if coalesce(btrim(v_key),'') = '' then raise exception 'Design name cannot be empty'; end if;

  -- A brand's stamped name can find an EXISTING product of a DIFFERENT print (the same tile sold
  -- under two names), so the alias lookup still comes first.
  if p_aliases is not null then
    for r in select * from jsonb_array_elements(p_aliases) loop
      exit when v_id is not null;
      v_brand := nullif(r->>'brand_id','')::uuid;
      v_alias := btrim(coalesce(r->>'name',''));
      if v_brand is not null and v_alias <> '' then
        select m.id into v_id from stockist_library m
          join stockist_library_brand_names a on a.library_id = m.id
          join print_master p on p.id = m.print_id
         where m.stockist_id = v_stk and a.brand_id = v_brand
           and lower(a.brand_design_name) = lower(v_alias)
           and p.size = v_size and m.surface_type = v_surf
           and (v_tile is null or m.tile_type is null or m.tile_type = v_tile)
         order by (m.tile_type is not null) desc, m.created_at
         limit 1;
      end if;
    end loop;
  end if;

  -- The PRINT is found-or-created either way: a print with no product is legal, and this is the
  -- row that owns the name, the size and the photo from here on.
  v_print := print_upsert(v_stk, v_key, v_size, null);

  if v_id is null then
    select m.id into v_id from stockist_library m
     where m.stockist_id = v_stk and m.print_id = v_print and m.surface_type = v_surf
       and (v_tile is null or m.tile_type is null or m.tile_type = v_tile)
     order by (m.tile_type is not null) desc, m.created_at
     limit 1;
  end if;

  if v_id is null then
    insert into stockist_library (stockist_id, print_id, brand_id, surface_type, tile_type)
      values (v_stk, v_print, v_brand1, v_surf, v_tile)
      returning id into v_id;
  else
    -- ADOPTION: fill a BLANK body only; never overwrite a declared one.
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

-- 4e. the Library editor
create or replace function library_upsert_master(p_id uuid, p_size text, p_master_name text,
    p_image_url text, p_aliases jsonb, p_brand_id uuid default null, p_surface text default null,
    p_stock_type text default null, p_tile_type text default null, p_pieces integer default null,
    p_weight numeric default null, p_thickness numeric default null, p_colour text default null,
    p_finish text default null)
 returns uuid language plpgsql security definer
 set search_path to 'public','pg_temp'
as $function$
declare v_stk uuid; v_id uuid; v_print uuid;
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

  -- Editing the NAME or the SIZE re-points the product at a DIFFERENT print (that is what a rename
  -- IS, now that the print owns the name). The photo goes on the print, first-writer-wins.
  v_print := print_upsert(v_stk, v_name, v_size, p_image_url);

  -- A twin with NO box yet cannot be told apart by thickness, so it is a real clash.
  if exists (select 1 from stockist_library
             where stockist_id = v_stk and print_id = v_print and surface_type = v_surf
               and tile_type is not distinct from coalesce(v_tile, tile_type)
               and thickness_mm is null
               and (p_id is null or id <> p_id)) then
    raise exception '"%" (% · % · %) is already in your library and has no box yet — give that one '
                    'its pieces and box weight first, so the two can be told apart by thickness.',
      v_name, v_size, v_surf, v_tile;
  end if;

  if p_id is null then
    insert into stockist_library (stockist_id, print_id, brand_id, surface_type, tile_type)
      values (v_stk, v_print, p_brand_id, v_surf, v_tile)
      returning id into v_id;
  else
    update stockist_library set
      print_id     = v_print,
      brand_id     = coalesce(p_brand_id, brand_id),
      surface_type = v_surf,
      tile_type    = coalesce(v_tile, tile_type),
      updated_at   = now()
    where id = p_id and stockist_id = v_stk
    returning id into v_id;
    if v_id is null then raise exception 'Design not found'; end if;

    -- the holding still carries a name/size copy of its own
    update designs d
       set surface_type = v_surf, name = v_name, size = v_size, updated_at = now()
     where d.library_id = v_id and d.stockist_id = v_stk;
  end if;

  -- An explicit image ALWAYS wins on an edit: the stockist just chose it. (print_upsert only fills
  -- a blank, which is the right rule for an IMPORT, not for a human at the form.)
  if nullif(btrim(coalesce(p_image_url,'')),'') is not null then
    update print_master set image_url = btrim(p_image_url), updated_at = now()
     where id = v_print;
  end if;

  update stockist_library m set
    stock_type   = case when p_stock_type is null then m.stock_type   else coalesce(nullif(btrim(p_stock_type),''),'Uncertain') end,
    finish_label = case when p_finish     is null then m.finish_label else nullif(btrim(p_finish),'') end,
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

    delete from stockist_library_brand_names a
     where a.library_id = v_id
       and not exists (
         select 1 from jsonb_array_elements(p_aliases) e
          where nullif(e->>'brand_id','')::uuid = a.brand_id
            and btrim(coalesce(e->>'name','')) <> '');
  end if;

  -- CREATE only: seed the first box, so the thickness derives at once and the identity is complete.
  if p_id is null and (coalesce(p_pieces,0) > 0 or coalesce(p_weight,0) > 0) then
    update stockist_library_brand_names a
       set pieces_per_box = coalesce(p_pieces, a.pieces_per_box),
           box_weight_kg  = coalesce(p_weight, a.box_weight_kg)
     where a.library_id = v_id;
  end if;

  return v_id;

exception
  when exclusion_violation then
    raise exception 'You already have "%" (% · % · %) at almost this thickness. A box weight this '
                    'close is the SAME tile — thickness has to differ by more than 1 mm to be a '
                    'different product. Check the pieces and box weight.',
      v_name, v_size, v_surf, v_tile;
  when unique_violation then
    raise exception '"%" (% · % · %) is already in your library.', v_name, v_size, v_surf, v_tile;
end; $function$;

-- 4f. the admin bulk importer
create or replace function admin_library_upsert(p_seq text, p_size text, p_master_name text,
    p_brand_id uuid, p_image_url text default null, p_surface text default null,
    p_tile_type text default null, p_pieces integer default null, p_weight numeric default null,
    p_thickness numeric default null, p_aliases jsonb default null)
 returns uuid language plpgsql security definer
 set search_path to 'public','pg_temp'
as $function$
declare v_stk uuid; v_id uuid; v_print uuid;
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

  v_print := print_upsert(v_stk, v_name, v_size, p_image_url);

  select id into v_id from stockist_library
   where stockist_id = v_stk and print_id = v_print and surface_type = v_surf
   limit 1;

  if v_id is null then
    insert into stockist_library (stockist_id, print_id, brand_id, surface_type)
      values (v_stk, v_print, p_brand_id, v_surf)
      returning id into v_id;
  end if;

  update stockist_library m set
    tile_type  = case when p_tile_type is null then m.tile_type else coalesce(btrim(p_tile_type),'') end,
    updated_at = now()
  where m.id = v_id;

  if p_pieces is not null or p_weight is not null then
    update stockist_library_brand_names a set
      pieces_per_box = coalesce(p_pieces, a.pieces_per_box),
      box_weight_kg  = coalesce(p_weight, a.box_weight_kg)
    where a.library_id = v_id;
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

-- 4g. contribute a photo (never creates: it has no surface to give)
create or replace function library_contribute(p_brand_id uuid, p_name text, p_size text, p_image_url text)
 returns uuid language plpgsql security definer
 set search_path to 'public','pg_temp'
as $function$
declare v_stk uuid; v_id uuid; v_print uuid;
        v_name text := btrim(coalesce(p_name,''));
        v_size text := btrim(coalesce(p_size,''));
        v_url  text := nullif(btrim(coalesce(p_image_url,'')), '');
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then return null; end if;
  if v_name = '' or v_size = '' then return null; end if;

  select p.id into v_print from print_master p
   where p.stockist_id = v_stk and lower(p.print_name) = lower(v_name) and p.size = v_size;
  if v_print is null then return null; end if;

  select id into v_id from stockist_library
   where stockist_id = v_stk and print_id = v_print
   order by created_at limit 1;
  if v_id is null then return null; end if;

  if v_url is not null then
    -- the PHOTO is the print's, and first-writer-wins
    update print_master set image_url = coalesce(image_url, v_url), updated_at = now()
     where id = v_print;
  end if;

  if p_brand_id is not null
     and exists (select 1 from brands where id = p_brand_id and stockist_id = v_stk) then
    insert into stockist_library_brand_names (library_id, brand_id, brand_design_name)
      values (v_id, p_brand_id, v_name)
      on conflict (library_id, brand_id) do nothing;
  end if;
  return v_id;
end; $function$;

-- 4h. the box fork (Add Stock → "different pieces or box weight?")
create or replace function library_for_box(p_library_id uuid, p_brand_id uuid,
                                           p_pieces integer, p_weight numeric)
 returns jsonb language plpgsql security definer
 set search_path to 'public','pg_temp'
as $function$
declare v_stk uuid; v_lib stockist_library; v_new_mm numeric; v_print_name text; v_size text;
        v_match uuid; v_match_mm numeric; v_id uuid; v_brand uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can add stock'; end if;

  select * into v_lib from stockist_library
   where id = p_library_id and stockist_id = v_stk;
  if v_lib.id is null then raise exception 'Design is not in your library'; end if;

  select p.print_name, p.size into v_print_name, v_size
    from print_master p where p.id = v_lib.print_id;

  if coalesce(p_pieces,0) <= 0 then raise exception 'Pieces per box must be more than 0'; end if;
  if coalesce(p_weight,0) <= 0 then raise exception 'Box weight must be more than 0'; end if;

  v_new_mm := _thickness_for(v_size, v_lib.tile_type, p_pieces, p_weight);
  if v_new_mm is null then
    raise exception 'This design has no tile type set, so its thickness cannot be worked out. '
                    'Open it in your Library and set one.';
  end if;

  v_brand := coalesce(p_brand_id, v_lib.brand_id);

  -- Same PRINT + surface + body, within 1 mm? Then it IS that tile. Take the CLOSEST, so a fork can
  -- never be shadowed by a more distant sibling.
  select l.id, l.thickness_mm into v_match, v_match_mm
    from stockist_library l
   where l.stockist_id = v_stk
     and l.print_id = v_lib.print_id
     and l.surface_type = v_lib.surface_type
     and l.tile_type is not distinct from v_lib.tile_type
     and l.thickness_mm is not null
     and abs(l.thickness_mm - v_new_mm) <= 1.0
   order by abs(l.thickness_mm - v_new_mm)
   limit 1;

  if v_match is not null then
    -- SAME tile. Ordinary drift. Do NOT touch its box weight — the first weight is the reference.
    return jsonb_build_object(
      'library_id', v_match, 'forked', false,
      'thickness_mm', v_new_mm, 'matched_thickness_mm', v_match_mm);
  end if;

  -- A product of this print with NO box yet is the same design waiting for its first weight.
  select l.id into v_match from stockist_library l
   where l.stockist_id = v_stk
     and l.print_id = v_lib.print_id
     and l.surface_type = v_lib.surface_type
     and l.tile_type is not distinct from v_lib.tile_type
     and l.thickness_mm is null
   order by l.created_at limit 1;

  if v_match is not null then
    insert into stockist_library_brand_names (library_id, brand_id, brand_design_name,
                                              pieces_per_box, box_weight_kg)
    select v_match, v_brand, coalesce(
             (select brand_design_name from stockist_library_brand_names
               where library_id = p_library_id and brand_id = v_brand),
             v_print_name), p_pieces, p_weight
    on conflict (library_id, brand_id) do update
      set pieces_per_box = excluded.pieces_per_box,
          box_weight_kg  = excluded.box_weight_kg;
    return jsonb_build_object('library_id', v_match, 'forked', false,
                              'thickness_mm', v_new_mm, 'matched_thickness_mm', null);
  end if;

  -- More than 1 mm from every sibling → a genuinely DIFFERENT tile. Fork the PRODUCT — and note it
  -- keeps the SAME print_id: a fork is the same artwork on a thicker piece.
  insert into stockist_library (
    stockist_id, print_id, is_sample, brand_id,
    surface_type, surface_label, stock_type, tile_type, finish_label)
  values (v_stk, v_lib.print_id, v_lib.is_sample, v_lib.brand_id, v_lib.surface_type,
          v_lib.surface_label, v_lib.stock_type, v_lib.tile_type, v_lib.finish_label)
  returning id into v_id;

  insert into library_dna (library_id, value_id)
    select v_id, x.value_id from library_dna x where x.library_id = p_library_id;
  insert into stockist_library_brand_names (library_id, brand_id, brand_design_name)
    select v_id, x.brand_id, x.brand_design_name
      from stockist_library_brand_names x where x.library_id = p_library_id;
  insert into library_family_overrides (library_id, stockist_id, family_key)
    select v_id, x.stockist_id, x.family_key
      from library_family_overrides x where x.library_id = p_library_id;

  insert into stockist_library_brand_names (library_id, brand_id, brand_design_name,
                                            pieces_per_box, box_weight_kg)
  values (v_id, v_brand, coalesce(
            (select brand_design_name from stockist_library_brand_names
              where library_id = p_library_id and brand_id = v_brand),
            v_print_name), p_pieces, p_weight)
  on conflict (library_id, brand_id) do update
    set pieces_per_box = excluded.pieces_per_box,
        box_weight_kg  = excluded.box_weight_kg;

  return jsonb_build_object(
    'library_id', v_id, 'forked', true,
    'thickness_mm', (select thickness_mm from stockist_library where id = v_id),
    'matched_thickness_mm', null);

exception
  when exclusion_violation then
    raise exception 'A tile of this design already sits at almost this thickness. A box weight this '
                    'close is the SAME tile — check the pieces and box weight.';
end; $function$;

-- 4i. the box spec (its default stamped name comes from the print)
create or replace function library_set_box(p_library_id uuid, p_brand_id uuid,
                                           p_pieces integer default null, p_weight numeric default null)
 returns numeric language plpgsql security definer
 set search_path to 'public','pg_temp'
as $function$
declare v_stk uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can edit the library'; end if;
  if not exists (select 1 from stockist_library
                  where id = p_library_id and stockist_id = v_stk) then
    raise exception 'Design not found';
  end if;
  if p_pieces is not null and p_pieces <= 0 then
    raise exception 'Pieces per box must be more than 0';
  end if;
  if p_weight is not null and p_weight <= 0 then
    raise exception 'Box weight must be more than 0';
  end if;

  insert into stockist_library_brand_names (library_id, brand_id, brand_design_name,
                                            pieces_per_box, box_weight_kg)
  select p_library_id, p_brand_id, p.print_name, p_pieces, p_weight
    from stockist_library l join print_master p on p.id = l.print_id
   where l.id = p_library_id
  on conflict (library_id, brand_id) do update
    set pieces_per_box = coalesce(excluded.pieces_per_box, stockist_library_brand_names.pieces_per_box),
        box_weight_kg  = coalesce(excluded.box_weight_kg,  stockist_library_brand_names.box_weight_kg);

  return (select thickness_mm from stockist_library where id = p_library_id);
exception
  when unique_violation then
    raise exception 'This box weight puts the tile in a different thickness band, and you already '
                    'have that exact design at that thickness. Check the weight and pieces.';
end; $function$;

-- 4j. surface change (identity → cascades onto the holdings)
create or replace function library_set_surface(p_library_id uuid, p_surface text, p_label text default null)
 returns void language plpgsql security definer
 set search_path to 'public','pg_temp'
as $function$
declare v_stk uuid; v_print uuid; v_name text; v_size text; v_old text;
        v_surf  text := nullif(btrim(coalesce(p_surface,'')),'');
        v_label text := nullif(btrim(coalesce(p_label,'')),'');
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can edit the library'; end if;
  if v_surf is null or lower(v_surf) = 'none' then
    raise exception 'Pick a surface — it is part of the design.';
  end if;
  if not exists (select 1 from surface_types t where t.name = v_surf and t.is_active) then
    raise exception '"%" is not one of the available surfaces', v_surf;
  end if;

  select l.print_id, p.print_name, p.size, l.surface_type
    into v_print, v_name, v_size, v_old
    from stockist_library l join print_master p on p.id = l.print_id
   where l.id = p_library_id and l.stockist_id = v_stk;
  if v_print is null then raise exception 'Design not found'; end if;

  -- Moving to a surface this print already has would be two products becoming one.
  if v_surf <> v_old and exists (
       select 1 from stockist_library
        where stockist_id = v_stk and print_id = v_print and surface_type = v_surf
          and id <> p_library_id) then
    raise exception '"%" (% · %) already exists — that would be a duplicate. '
                    'Merge them in your Library instead.', v_name, v_size, v_surf;
  end if;

  update stockist_library
     set surface_type  = v_surf,
         surface_label = coalesce(v_label, surface_label),
         updated_at    = now()
   where id = p_library_id and stockist_id = v_stk;

  update designs d
     set surface_type  = v_surf,
         surface_label = coalesce(v_label, (select surface_label from stockist_library
                                             where id = p_library_id)),
         updated_at    = now()
   where d.library_id = p_library_id and d.stockist_id = v_stk;
end; $function$;

-- 4k. merge two products
create or replace function library_merge_masters(p_keep_id uuid, p_drop_id uuid)
 returns uuid language plpgsql security definer
 set search_path to 'public','pg_temp'
as $function$
declare
  v_stk uuid;
  v_keep_print uuid; v_drop_print uuid;
  v_keep_size text; v_drop_size text;
  v_keep_img text; v_drop_img text;
  v_keep_surf text; v_drop_surf text;
  rec record; v_keep_hold uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can merge the library'; end if;
  if p_keep_id = p_drop_id then raise exception 'Cannot merge a design into itself'; end if;

  select l.print_id, p.size, nullif(btrim(coalesce(p.image_url,'')),''), l.surface_type
    into v_keep_print, v_keep_size, v_keep_img, v_keep_surf
  from stockist_library l join print_master p on p.id = l.print_id
  where l.id = p_keep_id and l.stockist_id = v_stk;
  select l.print_id, p.size, nullif(btrim(coalesce(p.image_url,'')),''), l.surface_type
    into v_drop_print, v_drop_size, v_drop_img, v_drop_surf
  from stockist_library l join print_master p on p.id = l.print_id
  where l.id = p_drop_id and l.stockist_id = v_stk;
  if v_keep_size is null or v_drop_size is null then
    raise exception 'Both designs must be yours';
  end if;
  if v_keep_size <> v_drop_size then
    raise exception 'Only same-size designs can be merged (% vs %)', v_keep_size, v_drop_size;
  end if;
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

  -- the PHOTO belongs to the print: a blank keeper inherits the dropped one's
  if v_keep_img is null and v_drop_img is not null then
    update print_master set image_url = v_drop_img, updated_at = now() where id = v_keep_print;
  end if;

  delete from library_family_overrides where library_id = p_drop_id;
  delete from stockist_library where id = p_drop_id;
  return p_keep_id;
end; $function$;

-- 4l. add stock (the surface branch copies the PRINT, not the name)
create or replace function stock_add_holding(p_library_id uuid, p_quality text, p_qty integer,
    p_catalog_id uuid, p_surface text default null, p_brand_id uuid default null,
    p_surface_label text default null)
 returns uuid language plpgsql security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
declare v_stk uuid; v_design uuid; v_q text; v_surf text; v_label text;
        v_name text; v_size text; v_brand uuid; v_master_brand uuid; v_print uuid;
        v_lib uuid; v_lib_surf text; v_lib_label text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if p_library_id is null then raise exception 'Pick a design first'; end if;

  select l.print_id, p.print_name, p.size, l.brand_id, l.surface_type, l.surface_label
    into v_print, v_name, v_size, v_master_brand, v_lib_surf, v_lib_label
    from stockist_library l join print_master p on p.id = l.print_id
   where l.id = p_library_id and l.stockist_id = v_stk;
  if v_name is null then raise exception 'Design is not in your library'; end if;

  if p_catalog_id is not null and not exists (
       select 1 from stock_catalogs where id = p_catalog_id and stockist_id = v_stk) then
    raise exception 'Stock list does not belong to you';
  end if;

  v_brand := coalesce(p_brand_id, v_master_brand);
  v_q     := coalesce(nullif(btrim(p_quality),''),'Standard');

  -- No surface passed -> INHERIT the product's own. Never 'None'.
  v_surf := coalesce(nullif(btrim(p_surface),''), v_lib_surf);
  if v_surf is null or v_surf = '' or lower(v_surf) = 'none' then
    raise exception 'This design has no surface set. Open it in your Library and pick one.';
  end if;

  -- SURFACE IS PRODUCT IDENTITY: a different surface means a different product OF THE SAME PRINT.
  if v_surf = v_lib_surf then
    v_lib := p_library_id;
  else
    select id into v_lib from stockist_library
     where stockist_id = v_stk and print_id = v_print and surface_type = v_surf;

    if v_lib is null then
      insert into stockist_library (
        stockist_id, print_id, is_sample, brand_id,
        surface_type, surface_label, stock_type, tile_type, finish_label)
      select l.stockist_id, l.print_id, l.is_sample, l.brand_id,
             v_surf, nullif(btrim(coalesce(p_surface_label,'')),''),
             l.stock_type, l.tile_type, l.finish_label
        from stockist_library l where l.id = p_library_id
      returning id into v_lib;

      insert into library_dna (library_id, value_id)
        select v_lib, x.value_id from library_dna x where x.library_id = p_library_id;
      insert into stockist_library_brand_names (library_id, brand_id, brand_design_name)
        select v_lib, x.brand_id, x.brand_design_name
          from stockist_library_brand_names x where x.library_id = p_library_id;
      insert into library_family_overrides (library_id, stockist_id, family_key)
        select v_lib, x.stockist_id, x.family_key
          from library_family_overrides x where x.library_id = p_library_id;
    end if;

    select surface_label into v_lib_label from stockist_library where id = v_lib;
  end if;

  v_label := coalesce(nullif(btrim(coalesce(p_surface_label,'')),''), v_lib_label);

  if nullif(btrim(coalesce(p_surface_label,'')),'') is not null then
    update stockist_library set surface_label = v_label, updated_at = now()
     where id = v_lib and surface_label is distinct from v_label;
  end if;

  select id into v_design from designs
    where stockist_id = v_stk and library_id = v_lib
      and brand_id is not distinct from v_brand
      and quality = v_q and surface_type = v_surf;
  if v_design is null then
    insert into designs (stockist_id, name, size, quality, surface_type, surface_label,
                         box_quantity, status, library_id, brand_id)
      values (v_stk, v_name, v_size, v_q, v_surf, v_label, 0, 'active', v_lib, v_brand)
      returning id into v_design;
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

-- ---------------------------------------------------------------- 5. the IMAGE writer in the import
create or replace function import_stock_batch(p_batch_id uuid, p_catalog_id uuid, p_brand_id uuid,
    p_pdf_filename text, p_rows jsonb, p_mode text default 'add', p_wipe_all_brands boolean default false,
    p_wipe_brand_ids uuid[] default null, p_library_only boolean default false)
 returns jsonb language plpgsql security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
declare
  v_stk uuid; v_prior jsonb; r jsonb; v_brand_name text;
  v_name text; v_size text; v_quality text; v_surface text; v_label text;
  v_tile text; v_qty int; v_image text;
  v_master_name text; v_aliases jsonb; v_skip_master boolean;
  v_master uuid; v_design uuid; v_hold_brand uuid; v_row_brand uuid;
  v_attr_key text; v_attr_vals jsonb; v_attr_id uuid; v_raw text;
  v_val uuid; v_vals uuid[]; v_is_multi boolean;
  v_mode text := lower(coalesce(nullif(btrim(p_mode),''),'add'));
  v_replace boolean; v_old int; v_delta int; v_seen boolean;
  v_touched uuid[] := array[]::uuid[]; v_zeroed int := 0;
  v_masters int := 0; v_created int := 0; v_updated int := 0;
  v_stock_rows int := 0; v_skipped int := 0; v_dna_tagged int := 0;
begin
  if v_mode not in ('add','replace_all','replace_keep') then v_mode := 'add'; end if;
  v_replace := v_mode in ('replace_all','replace_keep');

  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can import stock'; end if;

  select summary into v_prior from import_batches where id = p_batch_id;
  if v_prior is not null then
    return v_prior || jsonb_build_object('already_applied', true);
  end if;

  if p_catalog_id is not null and not exists (
       select 1 from stock_catalogs where id = p_catalog_id and stockist_id = v_stk) then
    raise exception 'Stock list does not belong to you';
  end if;

  if p_brand_id is not null then
    select name into v_brand_name from brands where id = p_brand_id and stockist_id = v_stk;
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    v_name := btrim(coalesce(r->>'name',''));
    v_size := btrim(coalesce(r->>'size',''));
    if v_name = '' or v_size = '' then v_skipped := v_skipped + 1; continue; end if;

    v_quality := coalesce(nullif(btrim(coalesce(r->>'quality','')),''),'Standard');
    v_surface := coalesce(nullif(btrim(coalesce(r->>'surface','')),''),'Special');
    v_label   := nullif(btrim(coalesce(r->>'surface_label','')),'');
    v_tile    := nullif(btrim(coalesce(r->>'tile_type','')),'');
    v_qty     := coalesce((r->>'qty')::int, 0);
    v_image   := nullif(btrim(coalesce(r->>'image_url','')),'');
    v_skip_master := coalesce((r->>'skip_master')::boolean, false);
    v_master_name := coalesce(nullif(btrim(coalesce(r->>'master_name','')),''), v_name);
    v_row_brand   := nullif(r->>'brand_id','')::uuid;

    if jsonb_typeof(r->'aliases') = 'array' and jsonb_array_length(r->'aliases') > 0 then
      v_aliases := r->'aliases';
    elsif p_brand_id is not null then
      v_aliases := jsonb_build_array(jsonb_build_object('brand_id', p_brand_id::text, 'name', v_name));
    else
      v_aliases := '[]'::jsonb;
    end if;

    v_master := library_map_upsert(v_size, v_master_name, v_aliases, v_surface, v_tile);
    v_masters := v_masters + 1;

    if not v_skip_master then
      perform _library_apply_identity(v_master, jsonb_build_object(
        'stock_type', r->>'stock_type',
        'tile_type', r->>'tile_type', 'pieces_per_box', r->>'pieces_per_box',
        'box_weight_kg', r->>'box_weight_kg', 'finish_label', r->>'finish_label'));

      -- the PHOTO belongs to the PRINT now. First-writer-wins, exactly as before.
      if v_image is not null and v_master is not null then
        update print_master p
           set image_url = v_image, updated_at = now()
          from stockist_library l
         where l.id = v_master and p.id = l.print_id
           and coalesce(nullif(btrim(p.image_url),''),'') = '';
      end if;

      if v_master is not null and jsonb_typeof(r->'dna') = 'object' then
        for v_attr_key, v_attr_vals in select key, value from jsonb_each(r->'dna') loop
          begin v_attr_id := v_attr_key::uuid; exception when others then v_attr_id := null; end;
          if v_attr_id is null or jsonb_typeof(v_attr_vals) <> 'array' then continue; end if;
          v_vals := array[]::uuid[];
          for v_raw in select value from jsonb_array_elements_text(v_attr_vals) loop
            v_val := dna_resolve(v_attr_id, v_raw);
            if v_val is not null and not (v_val = any(v_vals)) then
              v_vals := array_append(v_vals, v_val);
            end if;
          end loop;
          if cardinality(v_vals) = 0 then continue; end if;

          select is_multi into v_is_multi from dna_attributes where id = v_attr_id;

          if coalesce(v_is_multi, false) then
            insert into library_dna(library_id, value_id)
              select v_master, x from unnest(v_vals) x on conflict do nothing;
            v_dna_tagged := v_dna_tagged + 1;
          else
            if not exists (
              select 1 from library_dna ld join dna_values dv on dv.id = ld.value_id
               where ld.library_id = v_master and dv.attribute_id = v_attr_id) then
              insert into library_dna(library_id, value_id)
                values (v_master, v_vals[1]) on conflict do nothing;
              v_dna_tagged := v_dna_tagged + 1;
            end if;
          end if;
        end loop;
      end if;
    end if;

    if not coalesce(p_library_only, false) and v_qty > 0 and v_master is not null then
      v_hold_brand := coalesce(v_row_brand, nullif(v_aliases->0->>'brand_id','')::uuid,
                               p_brand_id,
                               (select brand_id from stockist_library where id = v_master));

      select id into v_design from designs
        where stockist_id = v_stk and library_id = v_master
          and brand_id is not distinct from v_hold_brand
          and quality = v_quality and surface_type = v_surface;

      if v_design is null then
        insert into designs (stockist_id, name, size, quality, surface_type, surface_label, box_quantity, status, library_id, brand_id)
          values (v_stk, v_name, v_size, v_quality, v_surface, v_label, 0, 'active', v_master, v_hold_brand)
          returning id into v_design;
        v_created := v_created + 1;
      else
        if v_label is not null then
          update designs set surface_label = v_label where id = v_design;
        end if;
        v_updated := v_updated + 1;
      end if;

      if p_catalog_id is not null then
        insert into catalog_designs (catalog_id, library_id)
          values (p_catalog_id, v_master) on conflict do nothing;
      end if;

      v_seen := v_design = any(v_touched);
      if v_replace then
        if v_seen then
          update designs set box_quantity = coalesce(box_quantity,0) + v_qty,
                 status = 'active', updated_at = now() where id = v_design;
          insert into stock_in (design_id, stockist_id, quantity_added, pdf_filename, size, quality, status)
            values (v_design, v_stk, v_qty, coalesce(p_pdf_filename,''), v_size, v_quality, 'approved');
        else
          select coalesce(box_quantity,0) into v_old from designs where id = v_design;
          update designs set box_quantity = v_qty, status = 'active', updated_at = now() where id = v_design;
          v_delta := v_qty - coalesce(v_old,0);
          if v_delta > 0 then
            insert into stock_in (design_id, stockist_id, quantity_added, pdf_filename, size, quality, status)
              values (v_design, v_stk, v_delta, coalesce(p_pdf_filename,''), v_size, v_quality, 'approved');
          end if;
        end if;
      else
        perform add_stock(v_design, v_stk, v_qty, coalesce(p_pdf_filename,''), v_size, v_quality);
      end if;

      if not v_seen then v_touched := array_append(v_touched, v_design); end if;
      v_stock_rows := v_stock_rows + 1;
    end if;
  end loop;

  if v_mode = 'replace_all'
     and (p_wipe_all_brands or p_wipe_brand_ids is not null or p_brand_id is not null) then
    with z as (
      update designs set box_quantity = 0, updated_at = now()
       where stockist_id = v_stk and box_quantity <> 0 and not (id = any(v_touched))
         and (
           p_wipe_all_brands
           or (not p_wipe_all_brands and p_wipe_brand_ids is not null
               and brand_id = any(p_wipe_brand_ids))
           or (not p_wipe_all_brands and p_wipe_brand_ids is null
               and brand_id is not distinct from p_brand_id)
         )
      returning 1)
    select count(*) into v_zeroed from z;
  end if;

  insert into import_batches (id, stockist_id, summary)
  values (p_batch_id, v_stk, jsonb_build_object(
    'masters', v_masters, 'created', v_created, 'updated', v_updated,
    'stock_rows', v_stock_rows, 'skipped', v_skipped, 'dna_tagged', v_dna_tagged,
    'zeroed', v_zeroed, 'mode', v_mode));

  return jsonb_build_object('masters', v_masters, 'created', v_created,
    'updated', v_updated, 'stock_rows', v_stock_rows, 'skipped', v_skipped,
    'dna_tagged', v_dna_tagged, 'zeroed', v_zeroed, 'mode', v_mode, 'already_applied', false);
end; $function$;

-- ---------------------------------------------------------------- 6. READERS
-- Same output keys, sourced from the print.

create or replace function _family_effective_key(p_lib uuid)
 returns text language sql stable set search_path to 'public','pg_temp'
as $function$
  select coalesce(
    (select o.family_key from library_family_overrides o where o.library_id = p_lib),
    family_key_of((select p.print_name from stockist_library l
                     join print_master p on p.id = l.print_id where l.id = p_lib))
  );
$function$;

create or replace function _family_members(p_stockist uuid, p_size text, p_key text, p_current uuid)
 returns jsonb language sql stable set search_path to 'public','extensions','pg_temp'
as $function$
  select coalesce(jsonb_agg(x order by length(x->>'name'), lower(x->>'name')), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'library_id', m.id,
      'name', pm.print_name,
      'size', pm.size,
      'image_url', pm.image_url,
      'f_stock', coalesce((
        select sum(greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)))
        from designs d
        where d.library_id = m.id and d.stockist_id = p_stockist), 0),
      'is_current', (m.id = p_current)
    ) as x
    from stockist_library m
    join print_master pm on pm.id = m.print_id
    where m.stockist_id = p_stockist and pm.size = p_size
      and _family_effective_key(m.id) = p_key
  ) t;
$function$;

create or replace function admin_stockist_library(p_seq text)
 returns table(master_design_name text, size text, brand_id uuid)
 language plpgsql security definer set search_path to 'public','pg_temp'
as $function$
begin
  if current_user_role() <> 'admin' then
    raise exception 'Only admins can read another stockist''s library';
  end if;
  return query
    select p.print_name, p.size, l.brand_id
    from stockist_library l
    join print_master p on p.id = l.print_id
    join stockists s on s.id = l.stockist_id
    where s.sequential_id = p_seq;
end; $function$;

create or replace function library_image_for(p_brand_id uuid, p_name text, p_size text)
 returns text language plpgsql security definer set search_path to 'public','pg_temp'
as $function$
declare v_stk uuid; v_url text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then return null; end if;
  select p.image_url into v_url
  from stockist_library m
  join print_master p on p.id = m.print_id
  join stockist_library_brand_names a on a.library_id = m.id
  where m.stockist_id = v_stk and a.brand_id = p_brand_id
    and lower(a.brand_design_name) = lower(btrim(coalesce(p_name,'')))
    and p.size = btrim(coalesce(p_size,''))
  limit 1;
  return v_url;
end; $function$;

create or replace function choices_availability(p_stockist_key text default null)
 returns jsonb language sql stable security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'design_id',     d.id,
      'stockist_key',  s.sequential_id,
      'name',          d.name,
      'size',          d.size,
      'quality',       d.quality,
      'surface_type',  d.surface_type,
      'surface_label', d.surface_label,
      'image_url',     coalesce(pm.image_url, ''),
      'wanted',        mc.quantity,
      'available',     f.free,
      'status',        case
                         when f.free = 0           then 'out'
                         when f.free < mc.quantity then 'reduced'
                         else 'ok'
                       end
    ) order by d.name), '[]'::jsonb)
  from my_choices mc
  join end_users e on e.id = mc.end_user_id
  join designs   d on d.id = mc.design_id
  join stockists s on s.id = d.stockist_id
  left join stockist_library lib on lib.id = d.library_id
  left join print_master pm on pm.id = lib.print_id
  cross join lateral (
    select greatest(0, d.box_quantity - d.control_quantity - held_of(d.id))::int as free
  ) f
  where e.user_id = auth.uid()
    and (p_stockist_key is null or s.sequential_id = p_stockist_key);
$function$;

create or replace function inquiry_detail(p_id uuid)
 returns jsonb language plpgsql stable security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
declare v_eu uuid; v_st uuid; v_lines jsonb;
begin
  select end_user_id, stockist_id into v_eu, v_st from inquiries where id = p_id;
  if v_st is null then raise exception 'Order not found'; end if;
  if not (
    v_eu in (select id from end_users where user_id = auth.uid())
    or v_st in (select id from stockists where user_id = auth.uid())
    or current_user_role() = 'admin') then
    raise exception 'Not allowed';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'design_id', d.id, 'design_name', d.name, 'size', d.size,
    'surface', d.surface_type, 'quality', d.quality,
    'image', nullif(btrim(coalesce(pm.image_url,'')),''),
    'quantity', it.quantity, 'dispatched_qty', it.dispatched_qty, 'available', d.box_quantity,
    'held', held_of(d.id), 'line_held', it.held_qty)
    order by d.name), '[]'::jsonb)
  into v_lines
  from inquiry_items it join designs d on d.id = it.design_id
  left join stockist_library lib on lib.id = d.library_id
  left join print_master pm on pm.id = lib.print_id
  where it.inquiry_id = p_id;

  return (select jsonb_build_object(
    'id', i.id, 'token', i.token, 'status', i.status,
    'connection_code', i.connection_code, 'customer_hint', i.customer_hint,
    'source', i.source,
    'created_at', i.created_at, 'updated_at', i.updated_at,
    'confirmed_at', i.confirmed_at, 'locked_at', i.locked_at,
    'guarantee_until', i.guarantee_until, 'accepted_at', i.accepted_at,
    'guarantee_days', i.guarantee_days,
    'lines', v_lines)
    from inquiries i where i.id = p_id);
end; $function$;

create or replace function my_customer_history(p_customer_id uuid)
 returns jsonb language sql stable security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
  with cust as (
    select c.*
    from stockist_customers c
    where c.id = p_customer_id
      and c.stockist_id in (select id from stockists where user_id = auth.uid())
  ),
  notes as (
    select dn.*
    from dispatch_notes dn
    where dn.customer_id = p_customer_id
      and dn.stockist_id in (select id from stockists where user_id = auth.uid())
  )
  select case
    when not exists (select 1 from cust) then null
    else jsonb_build_object(
      'customer', (select jsonb_build_object(
          'id', id, 'name', name, 'phone', phone, 'country_code', country_code,
          'city', city, 'district', district, 'state', state, 'pincode', pincode)
        from cust),
      'summary', jsonb_build_object(
          'dispatch_count', (select count(*) from notes),
          'total_boxes', (select coalesce(sum(dp.quantity_dispatched), 0)
                          from dispatches dp
                          where dp.dispatch_note_id in (select id from notes)),
          'last_dispatched_on', (select max(dispatched_on) from notes)),
      'dispatches', coalesce((
        select jsonb_agg(row order by row->>'dispatched_on' desc, row->>'created_at' desc)
        from (
          select jsonb_build_object(
            'id', dn.id, 'dispatch_no', dn.dispatch_no, 'dispatched_on', dn.dispatched_on,
            'created_at', dn.created_at, 'invoice_no', dn.invoice_no, 'vehicle_no', dn.vehicle_no,
            'transporter', dn.transporter, 'note', dn.note, 'token', i.token,
            'total_boxes', (select coalesce(sum(dp.quantity_dispatched), 0)
                            from dispatches dp where dp.dispatch_note_id = dn.id),
            'lines', (
              select coalesce(jsonb_agg(jsonb_build_object(
                'design_id', d.id,
                'design_name', d.name,
                'size', d.size,
                'brand', br.name,
                'quality', d.quality,
                'surface_label', d.surface_label,
                'surface_type', d.surface_type,
                'image', nullif(btrim(coalesce(pm.image_url,'')),''),
                'quantity', dp.quantity_dispatched) order by d.name), '[]'::jsonb)
              from dispatches dp
              join designs d on d.id = dp.design_id
              left join stockist_library lib on lib.id = d.library_id
              left join print_master pm on pm.id = lib.print_id
              left join brands br on br.id = d.brand_id
              where dp.dispatch_note_id = dn.id)
          ) as row
          from notes dn
          left join inquiries i on i.id = dn.inquiry_id
        ) t), '[]'::jsonb)
    )
  end;
$function$;

create or replace function my_dispatches()
 returns jsonb language sql stable security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
  select coalesce(
    jsonb_agg(row order by row->>'dispatched_on' desc, row->>'created_at' desc),
    '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', dn.id, 'dispatch_no', dn.dispatch_no, 'dispatched_on', dn.dispatched_on,
      'created_at', dn.created_at, 'invoice_no', dn.invoice_no, 'vehicle_no', dn.vehicle_no,
      'transporter', dn.transporter, 'note', dn.note, 'token', i.token,
      'stockist_name', s.name,
      'lines', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'design_id', d.id, 'design_name', d.name, 'size', d.size,
          'surface', d.surface_type,
          'image', nullif(btrim(coalesce(pm.image_url,'')),''),
          'quantity', dp.quantity_dispatched) order by d.name), '[]'::jsonb)
        from dispatches dp join designs d on d.id = dp.design_id
        left join stockist_library lib on lib.id = d.library_id
        left join print_master pm on pm.id = lib.print_id
        where dp.dispatch_note_id = dn.id),
      'total_boxes', (select coalesce(sum(dp.quantity_dispatched), 0)
        from dispatches dp where dp.dispatch_note_id = dn.id)
    ) as row
    from dispatch_notes dn
    join stockists s on s.id = dn.stockist_id
    left join inquiries i on i.id = dn.inquiry_id
    where dn.end_user_id in (select id from end_users where user_id = auth.uid())
  ) t;
$function$;

create or replace function my_library()
 returns jsonb language plpgsql security definer set search_path to 'public','pg_temp'
as $function$
declare v_stk uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists have a library'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id,
      'brand_id', m.brand_id,
      'brand_name', coalesce((select b.name from brands b where b.id = m.brand_id), ''),
      -- name · size · photo all come from the PRINT now. The keys are unchanged.
      'size', pm.size,
      'master_design_name', pm.print_name,
      'image_url', pm.image_url,
      'print_id', m.print_id,
      'surface_type', m.surface_type,
      'surface_label', m.surface_label,
      'stock_type', m.stock_type,
      'tile_type', m.tile_type,
      'pieces_per_box', (select a.pieces_per_box from stockist_library_brand_names a
                          where a.library_id = m.id and coalesce(a.pieces_per_box,0) > 0
                          order by a.created_at limit 1),
      'box_weight_kg',  (select a.box_weight_kg from stockist_library_brand_names a
                          where a.library_id = m.id and coalesce(a.box_weight_kg,0) > 0
                          order by a.created_at limit 1),
      'thickness_mm', m.thickness_mm,
      'created_at', m.created_at,
      'colour', _dna_colour(m.id),
      'finish_label', m.finish_label,
      'aliases', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'brand_id', a.brand_id,
                 'name', a.brand_design_name,
                 'pieces_per_box', a.pieces_per_box,
                 'box_weight_kg', a.box_weight_kg))
        from stockist_library_brand_names a where a.library_id = m.id), '[]'::jsonb)
    ) order by pm.print_name, pm.size)
    from stockist_library m
    join print_master pm on pm.id = m.print_id
    where m.stockist_id = v_stk
  ), '[]'::jsonb);
end; $function$;

create or replace function my_private_designs()
 returns table(id uuid, name text, size text, surface_type text, surface_label text, quality text,
   colour text, stock_type text, box_quantity integer, pieces_per_box integer, box_weight_kg numeric,
   thickness_mm numeric, face_image_urls text[], status text, created_at timestamp with time zone,
   updated_at timestamp with time zone, finish_label text, tile_type text, catalog_ids uuid[],
   stockist_priority numeric, stockist_key text, stockist_display_name text, stockist_city text,
   brand_name text, library_id uuid, family_key text)
 language sql security definer set search_path to 'public','extensions','pg_temp'
as $function$
  select d.id,
         coalesce((select bn.brand_design_name from stockist_library_brand_names bn
                   where bn.library_id = d.library_id
                     and bn.brand_id = coalesce(d.brand_id, lib.brand_id)),
                  pm.print_name, d.name) as name,
         d.size, d.surface_type, d.surface_label, d.quality, _dna_colour(lib.id),
         public.effective_stock_type(lib.stock_type, d.quality) as stock_type,
         greatest(0, d.box_quantity - d.control_quantity - held_of(d.id))::int as box_quantity,
         _box_pieces(d.library_id, d.brand_id),
         _box_weight(d.library_id, d.brand_id)::numeric(8,2), lib.thickness_mm::numeric(6,2),
         case when nullif(btrim(coalesce(pm.image_url,'')),'') is not null
              then array[pm.image_url] else '{}'::text[] end,
         d.status, d.created_at, d.updated_at, lib.finish_label, lib.tile_type,
         cat.ids as catalog_ids,
         s.priority as stockist_priority,
         s.sequential_id as stockist_key, s.name as stockist_display_name,
         s.city as stockist_city, br.name as brand_name,
         d.library_id, public._family_effective_key(d.library_id) as family_key
  from designs d
  join stockists s on s.id = d.stockist_id
  join stockist_library lib on lib.id = d.library_id
  join print_master pm on pm.id = lib.print_id
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
    and (d.box_quantity - d.control_quantity - held_of(d.id)) > 0
    and d.status <> 'out_of_stock'
    and cat.ids is not null;
$function$;

create or replace function my_stock()
 returns jsonb language sql security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', d.id, 'name', d.name, 'size', d.size, 'quality', d.quality,
    'box_quantity', d.box_quantity, 'status', d.status, 'is_sample', d.is_sample,
    'control_quantity', d.control_quantity,
    'held_quantity', held_of(d.id),
    'f_stock', greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)),
    'library_id', d.library_id, 'created_at', d.created_at, 'updated_at', d.updated_at,
    'surface_type', d.surface_type, 'surface_label', d.surface_label, 'stock_type', lib.stock_type,
    'tile_type', lib.tile_type, 'pieces_per_box', _box_pieces(d.library_id, d.brand_id),
    'box_weight_kg', _box_weight(d.library_id, d.brand_id), 'thickness_mm', lib.thickness_mm,
    'colour', _dna_colour(lib.id), 'finish_label', lib.finish_label,
    'library_created_at', lib.created_at,
    'image_url', pm.image_url, 'master_design_name', pm.print_name,
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
  left join print_master pm on pm.id = lib.print_id
  where d.stockist_id = (select id from stockists where user_id = auth.uid());
$function$;

create or replace function public_dispatch(p_token text)
 returns jsonb language plpgsql stable security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
declare v_note uuid;
begin
  select l.dispatch_note_id into v_note
  from stockist_share_links l
  join dispatch_notes dn on dn.id = l.dispatch_note_id
  join stockists s on s.id = dn.stockist_id
  where l.token = p_token and l.is_active and l.dispatch_note_id is not null
    and (l.expires_at is null or l.expires_at > now()) and s.is_active;
  if v_note is null then return null; end if;

  return (select jsonb_build_object(
    'dispatch_no', dn.dispatch_no,
    'dispatched_on', dn.dispatched_on,
    'invoice_no', dn.invoice_no, 'vehicle_no', dn.vehicle_no,
    'transporter', dn.transporter, 'note', dn.note,
    'order_token', i.token,
    'buyer', coalesce(nullif(btrim(e.company_name), ''),
                      (select buyer_name from dispatches where dispatch_note_id = dn.id
                        and nullif(btrim(coalesce(buyer_name,'')),'') is not null limit 1), ''),
    'stockist', jsonb_build_object(
        'name', s.name, 'phone', s.phone, 'country_code', s.country_code,
        'city', s.city, 'brand_color', s.brand_color),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', coalesce(pm.print_name, d.name),
        'size', d.size, 'surface', d.surface_type,
        'image', nullif(btrim(coalesce(pm.image_url,'')),''),
        'quantity', dp.quantity_dispatched)
        order by d.name)
      from dispatches dp
      join designs d on d.id = dp.design_id
      left join stockist_library lib on lib.id = d.library_id
      left join print_master pm on pm.id = lib.print_id
      where dp.dispatch_note_id = dn.id), '[]'::jsonb),
    'total', coalesce((select sum(quantity_dispatched) from dispatches where dispatch_note_id = dn.id), 0)
  )
  from dispatch_notes dn
  join stockists s on s.id = dn.stockist_id
  left join inquiries i on i.id = dn.inquiry_id
  left join end_users e on e.id = dn.end_user_id
  where dn.id = v_note);
end; $function$;

create or replace function public_order(p_token text)
 returns jsonb language plpgsql stable security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
declare v_id uuid; v_st uuid;
begin
  select l.inquiry_id, i.stockist_id into v_id, v_st
  from stockist_share_links l
  join inquiries i on i.id = l.inquiry_id
  join stockists s on s.id = i.stockist_id
  where l.token = p_token and l.is_active and l.inquiry_id is not null
    and (l.expires_at is null or l.expires_at > now())
    and i.status in ('draft','sent','confirmed','locked') and s.is_active;
  if v_id is null then return null; end if;

  return (select jsonb_build_object(
    'token', i.token, 'connection_code', i.connection_code, 'status', i.status,
    'stockist', jsonb_build_object(
      'name', s.name, 'phone', s.phone, 'country_code', s.country_code,
      'city', s.city, 'brand_color', s.brand_color),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'design_id', d.id,
        'name', coalesce(pm.print_name, d.name),
        'size', d.size, 'surface', d.surface_type, 'quality', d.quality,
        'image', nullif(btrim(coalesce(pm.image_url,'')),''),
        'quantity', it.quantity,
        'available', greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)))
        order by d.name)
      from inquiry_items it
      join designs d on d.id = it.design_id
      left join stockist_library lib on lib.id = d.library_id
      left join print_master pm on pm.id = lib.print_id
      where it.inquiry_id = v_id), '[]'::jsonb))
    from inquiries i join stockists s on s.id = i.stockist_id where i.id = v_id);
end; $function$;

create or replace function public_catalog(p_token text)
 returns jsonb language sql stable security definer
 set search_path to 'public','extensions','pg_temp'
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
             pm.print_name, d.name),
           'size', d.size, 'surface', d.surface_type, 'surface_label', d.surface_label,
           'quality', d.quality, 'colour', _dna_colour(lib.id), 'tile_type', lib.tile_type,
           'boxes', greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)),
           'images', case when nullif(btrim(coalesce(pm.image_url,'')),'') is not null then array[pm.image_url] else '{}'::text[] end,
           'finish', lib.finish_label, 'weight', _box_weight(d.library_id, d.brand_id),
           'pieces', _box_pieces(d.library_id, d.brand_id), 'stock_type', effective_stock_type(lib.stock_type, d.quality),
           'dna', coalesce((select jsonb_agg(distinct ld.value_id)
                            from library_dna ld
                            join dna_values dv on dv.id = ld.value_id and dv.is_active and lower(dv.name) <> 'none'
                            where ld.library_id = d.library_id), '[]'::jsonb))
           order by d.created_at desc)
         from designs d
         join stockist_library lib on lib.id = d.library_id
         join print_master pm on pm.id = lib.print_id
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
           'name', coalesce(pm.print_name, d.name), 'size', d.size,
           'surface', d.surface_type, 'surface_label', d.surface_label, 'quality', d.quality,
           'colour', _dna_colour(lib.id),
           'tile_type', lib.tile_type, 'boxes', greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)),
           'images', case when nullif(btrim(coalesce(pm.image_url,'')),'') is not null then array[pm.image_url] else '{}'::text[] end,
           'finish', lib.finish_label, 'weight', _box_weight(d.library_id, d.brand_id),
           'pieces', _box_pieces(d.library_id, d.brand_id), 'stock_type', effective_stock_type(lib.stock_type, d.quality),
           'dna', coalesce((select jsonb_agg(distinct ld.value_id)
                            from library_dna ld
                            join dna_values dv on dv.id = ld.value_id and dv.is_active and lower(dv.name) <> 'none'
                            where ld.library_id = d.library_id), '[]'::jsonb))
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

-- ---------------------------------------------------------------- 7. the two public VIEWS
-- They read lib.colour and lib.image_url, so they block the DROP. Same columns out, print in.
drop view if exists market_designs;
create view market_designs as
  select d.id, d.name, d.size, d.surface_type, d.quality,
    _dna_colour(lib.id) as colour,
    effective_stock_type(lib.stock_type, d.quality) as stock_type,
    greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) as box_quantity,
    _box_pieces(d.library_id, d.brand_id) as pieces_per_box,
    _box_weight(d.library_id, d.brand_id)::numeric(8,2) as box_weight_kg,
    lib.thickness_mm::numeric(6,2) as thickness_mm,
    case when nullif(btrim(coalesce(pm.image_url, '')), '') is not null
         then array[pm.image_url] else '{}'::text[] end as face_image_urls,
    d.status, d.created_at, d.updated_at, lib.finish_label, lib.tile_type,
    null::uuid as catalog_id,
    s.priority as stockist_priority, s.sequential_id as stockist_key,
    s.name as stockist_display_name, s.city as stockist_city,
    br.name as brand_name, d.library_id,
    _family_effective_key(d.library_id) as family_key, d.surface_label
  from designs d
    join stockists s on s.id = d.stockist_id
    left join stockist_library lib on lib.id = d.library_id
    left join print_master pm on pm.id = lib.print_id
    left join brands br on br.id = lib.brand_id
  where s.is_active and s.is_listed and d.status <> 'out_of_stock'
    and (d.box_quantity - d.control_quantity - held_of(d.id)) > 0
    and exists (
      select 1 from stock_catalogs c
      where c.stockist_id = d.stockist_id and c.visibility = 'public'
        and c.show_in_marketplace and c.is_active
        and (coalesce(c.list_type,'permanent') = 'temporary' and exists (
               select 1 from catalog_designs cd
                where cd.catalog_id = c.id and cd.library_id = d.library_id)
             or coalesce(c.list_type,'permanent') = 'permanent'
               and (array_length(c.filter_brand_ids,1) is null or coalesce(d.brand_id, lib.brand_id) = any(c.filter_brand_ids))
               and (array_length(c.filter_qualities,1) is null or d.quality = any(c.filter_qualities))
               and (array_length(c.filter_surfaces,1) is null or d.surface_type = any(c.filter_surfaces))
               and (array_length(c.filter_sizes,1) is null or d.size = any(c.filter_sizes))
               and (array_length(c.filter_tile_types,1) is null or lib.tile_type = any(c.filter_tile_types))
               and (array_length(c.filter_stock_types,1) is null or effective_stock_type(lib.stock_type, d.quality) = any(c.filter_stock_types))
               and (c.filter_box_min is null or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) >= c.filter_box_min)
               and (c.filter_box_max is null or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) <= c.filter_box_max)));

drop view if exists public_designs;
create view public_designs as
  select d.id, d.stockist_id, d.name, d.size, d.surface_type, d.quality,
    _dna_colour(lib.id) as colour,
    effective_stock_type(lib.stock_type, d.quality) as stock_type,
    d.box_quantity,
    _box_pieces(d.library_id, d.brand_id) as pieces_per_box,
    _box_weight(d.library_id, d.brand_id)::numeric(8,2) as box_weight_kg,
    lib.thickness_mm::numeric(6,2) as thickness_mm,
    case when nullif(btrim(coalesce(pm.image_url, '')), '') is not null
         then array[pm.image_url] else '{}'::text[] end as face_image_urls,
    d.status, d.created_at, d.updated_at, lib.finish_label,
    s.priority as stockist_priority, lib.tile_type
  from designs d
    join stockists s on s.id = d.stockist_id
    left join stockist_library lib on lib.id = d.library_id
    left join print_master pm on pm.id = lib.print_id
  where s.is_active and d.status <> 'out_of_stock' and d.box_quantity > 0
    and exists (
      select 1 from stock_catalogs c
      where c.stockist_id = d.stockist_id and c.visibility = 'public'
        and c.show_in_marketplace and c.is_active
        and (coalesce(c.list_type,'permanent') = 'temporary' and exists (
               select 1 from catalog_designs cd
                where cd.catalog_id = c.id and cd.library_id = d.library_id)
             or coalesce(c.list_type,'permanent') = 'permanent'
               and (array_length(c.filter_brand_ids,1) is null or coalesce(d.brand_id, lib.brand_id) = any(c.filter_brand_ids))
               and (array_length(c.filter_qualities,1) is null or d.quality = any(c.filter_qualities))
               and (array_length(c.filter_surfaces,1) is null or d.surface_type = any(c.filter_surfaces))
               and (array_length(c.filter_sizes,1) is null or d.size = any(c.filter_sizes))
               and (array_length(c.filter_tile_types,1) is null or lib.tile_type = any(c.filter_tile_types))
               and (array_length(c.filter_stock_types,1) is null or effective_stock_type(lib.stock_type, d.quality) = any(c.filter_stock_types))
               and (c.filter_box_min is null or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) >= c.filter_box_min)
               and (c.filter_box_max is null or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) <= c.filter_box_max)));

-- Supabase hands anon/authenticated DML on a fresh view. These are read-only projections; the app
-- reaches them through RPCs. Restore exactly the grants they had.
revoke all on market_designs from anon, authenticated;
revoke all on public_designs from anon, authenticated;
grant select on market_designs to anon, authenticated;
grant select on public_designs to anon, authenticated;

-- ---------------------------------------------------------------- 8. identity now keys on the PRINT
-- (stockist, lower(name), size) IS (print_id). The new key says the same thing, but it cannot drift
-- from the print, because there is nothing left to drift.
alter table stockist_library drop constraint if exists stockist_library_thickness_apart;
alter table stockist_library add constraint stockist_library_thickness_apart
  exclude using gist (
    print_id with =,
    surface_type with =,
    coalesce(tile_type, ''::text) with =,
    numrange(thickness_mm - 0.5, thickness_mm + 0.5) with &&
  ) where (thickness_mm is not null);

drop index if exists stockist_library_uniq_no_thickness;
create unique index stockist_library_uniq_no_thickness
  on stockist_library (print_id, surface_type, tile_type)
  nulls not distinct
  where (thickness_mm is null);

-- ---------------------------------------------------------------- 9. the columns die
alter table stockist_library drop column master_design_name;
alter table stockist_library drop column image_url;
alter table stockist_library drop column colour;

comment on column stockist_library.size is
  'MIRROR of print_master.size, maintained by _trg_library_size_from_print. NOT a second source of '
  'truth - it has exactly one writer. Dropped once the remaining l.size readers move to the print.';

-- ---------------------------------------------------------------- 10. self-check
do $$
declare v_left int; v_orphan int; v_prints int;
begin
  -- No function may still READ a column that no longer exists. Postgres does NOT check function
  -- bodies on DROP COLUMN, so this text sweep is the only guard there is — it is what would have
  -- caught 1b47acd, where my_library still selected a column I had dropped and every stockist's
  -- Library came back EMPTY.
  --
  -- The quoted 'master_design_name' is stripped first: my_library and my_stock still EMIT it as a
  -- JSON KEY (that is the Dart contract, and it is deliberate — the storage moved, the shape did
  -- not). admin_stockist_library declares it as a RETURNS TABLE column name, which is likewise a
  -- name, not a read.
  select count(*) into v_left
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and regexp_replace(pg_get_functiondef(p.oid), '''master_design_name''', '', 'g')
           ~* 'master_design_name'
     and p.proname <> 'admin_stockist_library';

  select count(*) into v_orphan from stockist_library where print_id is null;
  select count(*) into v_prints from print_master;

  if v_orphan > 0 then
    raise exception 'FAILED: % products have no print', v_orphan;
  end if;
  if v_left > 0 then
    raise exception 'FAILED: % functions still reference master_design_name', v_left;
  end if;
  raise notice 'OK: name/image/colour now live on the print (% prints)', v_prints;
end $$;
