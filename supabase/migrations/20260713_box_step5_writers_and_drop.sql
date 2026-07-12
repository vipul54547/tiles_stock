-- BOX chapter — STEP 5 of 5: the writers target the BOX, and the product columns are DROPPED.
-- (docs/BOX_AND_DERIVED_THICKNESS_PLAN.md)
--
-- Step 4 moved every READ to the box and left a bridge trigger so the writers — which still
-- set the spec on the PRODUCT — kept working. That bridge has a sting: it pushes ONE value to
-- ALL of a product's boxes. So the moment a stockist gives Brand A 4/box and Brand B 6/box,
-- the next Library save would flatten both back to one number. Harmless today (no per-brand
-- spec exists yet), fatal the day the box chip ships. Close it now.
--
-- After this:
--   * stockist_library has NO pieces_per_box / box_weight_kg. They were always at the wrong
--     level — a product cannot express "Brand A packs 4, Brand B packs 6".
--   * thickness_mm stays on the product but is DERIVED (trigger, step 3). Never typed.
--   * p_thickness params survive on the signatures but are IGNORED — dropping a param would
--     create an OVERLOAD, and the old call shape would then die with 42725.
--     ([[feedback_rpc_param_add_creates_overload]])

-- ── the per-brand setter the Library's box chip will call ────────────────────────────────
create or replace function public.library_set_box(
  p_library_id uuid,
  p_brand_id   uuid,
  p_pieces     integer default null::integer,
  p_weight     numeric default null::numeric)
 returns numeric                       -- the newly DERIVED thickness, for the UI to show
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
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
  select p_library_id, p_brand_id, l.master_design_name, p_pieces, p_weight
    from stockist_library l where l.id = p_library_id
  on conflict (library_id, brand_id) do update
    set pieces_per_box = coalesce(excluded.pieces_per_box, stockist_library_brand_names.pieces_per_box),
        box_weight_kg  = coalesce(excluded.box_weight_kg,  stockist_library_brand_names.box_weight_kg);

  -- the trigger from step 3 has already re-derived it
  return (select thickness_mm from stockist_library where id = p_library_id);
end; $function$;


-- ── _library_apply_identity: pieces/weight go to the BOX now (fill-blanks, as before) ────
-- It has no brand, so it applies to EVERY box of the product — which is exactly its old
-- behaviour (one spec per product). Fill-blanks means an import can never clobber a
-- per-brand spec a stockist has deliberately set.
-- thickness is no longer written at all: it is derived.
create or replace function public._library_apply_identity(p_library_id uuid, p_attrs jsonb)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_stock   text    := nullif(btrim(coalesce(p_attrs->>'stock_type','')),'');
  v_tile    text    := nullif(btrim(coalesce(p_attrs->>'tile_type','')),'');
  v_pieces  int     := nullif(btrim(coalesce(p_attrs->>'pieces_per_box','')),'')::int;
  v_weight  numeric := nullif(btrim(coalesce(p_attrs->>'box_weight_kg','')),'')::numeric;
  v_colour  text    := nullif(btrim(coalesce(p_attrs->>'colour','')),'');
  v_finish  text    := nullif(btrim(coalesce(p_attrs->>'finish_label','')),'');
  v_stk uuid;
begin
  if p_library_id is null or p_attrs is null then return; end if;
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then return; end if;

  update stockist_library m set
    stock_type   = case when m.stock_type in ('','Uncertain') then coalesce(v_stock, m.stock_type) else m.stock_type end,
    tile_type    = case when coalesce(m.tile_type,'') = '' then coalesce(v_tile, m.tile_type) else m.tile_type end,
    colour       = case when coalesce(m.colour,'')    = '' then coalesce(v_colour, m.colour)   else m.colour end,
    finish_label = case when m.finish_label is null then coalesce(v_finish, m.finish_label) else m.finish_label end,
    updated_at   = now()
  where m.id = p_library_id and m.stockist_id = v_stk;

  -- the BOX spec — fill blanks only
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

-- ── my_library: the Library screen reads PRODUCTS, so it has no brand to resolve with ─────
-- (This is the one the first attempt missed — the guard at the bottom caught it and rolled the
--  whole migration back rather than half-applying. That is what the guard is for.)
--
-- A product can have several boxes. So:
--   * `pieces_per_box` / `box_weight_kg` at the top level = the FIRST box's — the product's
--     de-facto default, and what the existing Dart LibraryEntry expects.
--   * each entry in `aliases` (which is the BOX) now also carries its OWN pieces/weight, so the
--     Library's box chip can show and edit them PER BRAND.
create or replace function public.my_library()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
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
      'size', m.size,
      'master_design_name', m.master_design_name,
      'image_url', m.image_url,
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
      'colour', m.colour,
      'finish_label', m.finish_label,
      -- an alias IS a box: name + how that brand packs it
      'aliases', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'brand_id', a.brand_id,
                 'name', a.brand_design_name,
                 'pieces_per_box', a.pieces_per_box,
                 'box_weight_kg', a.box_weight_kg))
        from stockist_library_brand_names a where a.library_id = m.id), '[]'::jsonb)
    ) order by m.master_design_name, m.size)
    from stockist_library m where m.stockist_id = v_stk
  ), '[]'::jsonb);
end; $function$;


-- ── library_upsert_master: the spec goes to the BOX ──
CREATE OR REPLACE FUNCTION public.library_upsert_master(p_id uuid, p_size text, p_master_name text, p_image_url text, p_aliases jsonb, p_brand_id uuid DEFAULT NULL::uuid, p_surface text DEFAULT NULL::text, p_stock_type text DEFAULT NULL::text, p_tile_type text DEFAULT NULL::text, p_pieces integer DEFAULT NULL::integer, p_weight numeric DEFAULT NULL::numeric, p_thickness numeric DEFAULT NULL::numeric, p_colour text DEFAULT NULL::text, p_finish text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

    -- CASCADE: the stock follows its product's surface (and name/size, which are copied
    -- onto the holding for display).
    update designs d
       set surface_type = v_surf,
           name         = v_name,
           size         = v_size,
           updated_at   = now()
     where d.library_id = v_id and d.stockist_id = v_stk;
  end if;

  update stockist_library m set
    stock_type     = case when p_stock_type is null then m.stock_type     else coalesce(nullif(btrim(p_stock_type),''),'Uncertain') end,
    tile_type      = case when p_tile_type  is null then m.tile_type      else coalesce(btrim(p_tile_type),'') end,
    colour         = case when p_colour     is null then m.colour         else coalesce(btrim(p_colour),'') end,
    finish_label   = case when p_finish     is null then m.finish_label   else nullif(btrim(p_finish),'') end,
    updated_at = now()
  where m.id = v_id;

  -- pieces/weight are BOX facts now. This entry point has one value for the whole product,
  -- so it applies to every box of it (its old behaviour). Per-brand differences are set with
  -- library_set_box. thickness is DERIVED — p_thickness is accepted and ignored.
  if p_pieces is not null or p_weight is not null then
    update stockist_library_brand_names a set
      pieces_per_box = coalesce(p_pieces, a.pieces_per_box),
      box_weight_kg  = coalesce(p_weight, a.box_weight_kg)
    where a.library_id = v_id;
  end if;


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

-- ── admin_library_upsert: the spec goes to the BOX ──
CREATE OR REPLACE FUNCTION public.admin_library_upsert(p_seq text, p_size text, p_master_name text, p_brand_id uuid, p_image_url text DEFAULT NULL::text, p_surface text DEFAULT NULL::text, p_tile_type text DEFAULT NULL::text, p_pieces integer DEFAULT NULL::integer, p_weight numeric DEFAULT NULL::numeric, p_thickness numeric DEFAULT NULL::numeric, p_aliases jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
    updated_at = now()
  where m.id = v_id;

  -- pieces/weight are BOX facts now. This entry point has one value for the whole product,
  -- so it applies to every box of it (its old behaviour). Per-brand differences are set with
  -- library_set_box. thickness is DERIVED — p_thickness is accepted and ignored.
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

-- ── stock_add_holding: a surface split no longer copies the product's specs ──
-- It already copies the BOX rows (stockist_library_brand_names), which now CARRY the spec —
-- so the new product's packing comes across for free, and its thickness re-derives by trigger.
CREATE OR REPLACE FUNCTION public.stock_add_holding(p_library_id uuid, p_quality text, p_qty integer, p_catalog_id uuid, p_surface text DEFAULT NULL::text, p_brand_id uuid DEFAULT NULL::uuid, p_surface_label text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_stk uuid; v_design uuid; v_q text; v_surf text; v_label text;
        v_name text; v_size text; v_brand uuid; v_master_brand uuid;
        v_lib uuid; v_lib_surf text; v_lib_label text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if p_library_id is null then raise exception 'Pick a design first'; end if;

  select master_design_name, size, brand_id, surface_type, surface_label
    into v_name, v_size, v_master_brand, v_lib_surf, v_lib_label
    from stockist_library where id = p_library_id and stockist_id = v_stk;
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

  -- SURFACE IS PRODUCT IDENTITY: a different surface means a different product of the same
  -- print. Find it, or create it by copying the print. (Only an attribute-mode M is asked
  -- for a surface at all, so only they can reach the create branch.)
  if v_surf = v_lib_surf then
    v_lib := p_library_id;
  else
    select id into v_lib from stockist_library
     where stockist_id = v_stk and lower(master_design_name) = lower(v_name)
       and size = v_size and surface_type = v_surf;

    if v_lib is null then
      -- thickness_band is GENERATED — never list it.
      insert into stockist_library (
        stockist_id, size, master_design_name, image_url, is_sample, brand_id,
        surface_type, surface_label, stock_type, tile_type, colour, finish_label)
      select l.stockist_id, l.size, l.master_design_name, l.image_url, l.is_sample,
             l.brand_id, v_surf, nullif(btrim(coalesce(p_surface_label,'')),''),
             l.stock_type, l.tile_type, l.colour, l.finish_label
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

    -- the surface we actually landed on owns the word from here
    select surface_label into v_lib_label from stockist_library where id = v_lib;
  end if;

  -- THE WORD: use what the caller sent; otherwise INHERIT the product's. It must never be
  -- left empty — every holding of a product carries that product's word, or the dashboard
  -- splits one design into two cards.
  v_label := coalesce(nullif(btrim(coalesce(p_surface_label,'')),''), v_lib_label);

  -- A caller-supplied word refreshes the product's (display-only; never a key).
  if nullif(btrim(coalesce(p_surface_label,'')),'') is not null then
    update stockist_library set surface_label = v_label, updated_at = now()
     where id = v_lib and surface_label is distinct from v_label;
  end if;

  -- Holding identity: (stockist, library, brand, quality, surface_type). NOT the label.
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

-- ── the bridge from step 4 is no longer needed ──
drop trigger if exists zz_sync_product_spec_to_boxes on stockist_library;
drop function if exists public._trg_sync_product_spec_to_boxes();

-- ── and finally: the columns leave the product ──
alter table stockist_library
  drop column if exists pieces_per_box,
  drop column if exists box_weight_kg;

comment on column stockist_library.thickness_mm is
  'DERIVED, never typed: box_weight / (pieces x area x density_of(tile_type)). Recomputed by '
  'trigger whenever a box spec, the size or the tile_type changes. No manual override.';

-- Guard: nothing anywhere may still reference the dropped columns.
do $$
declare v_bad text;
begin
  select string_agg(p.proname, ', ') into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prokind = 'f'
    and pg_get_functiondef(p.oid) ~* '(stockist_library|m|l|lib)\.(pieces_per_box|box_weight_kg)';
  if v_bad is not null then
    raise exception 'these still reference the dropped product columns: %', v_bad;
  end if;
end $$;
