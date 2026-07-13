-- ADD STOCK is where a different box weight actually shows up — not Add-design.
--
-- A stockist never opens "Add design" for a tile already in the library. They open ADD STOCK,
-- because what is new is a BATCH. So the moment they notice "these boxes are 26 kg, not 28" is
-- during Add stock, and that is where the fork has to be offered.
--
-- The stockist reports a FACT OFF THE BOX (pieces + weight). They never pick a thickness and never
-- decide whether it is a new product. The 1 mm rule decides:
--
--   ≤ 1 mm apart  → the SAME tile. Ordinary weight drift (a 600x1200 2-pc box went 28 kg → 26 kg =
--                   0.62 mm). The stock joins the existing product. Nothing forks.
--   > 1 mm apart  → a genuinely DIFFERENT tile. Fork a new product off the same print (same size,
--                   surface, body), give it its own box, and put this batch's stock there.
--
-- 🔑 The matched product's box weight is NEVER overwritten. If 28 quietly became 26, then a later
-- 24 kg batch would be only 0.6 mm from 26 and would stay the same product — yet it is 1.24 mm from
-- the original 28 and SHOULD have forked. The stored weight would creep and drag the threshold with
-- it. The first weight stays the reference.

-- Thickness from explicit box facts (the same formula as _derive_thickness, which reads a stored
-- box). Needed because we must know the thickness BEFORE deciding which product the stock belongs to.
create or replace function public._thickness_for(
  p_size text, p_tile_type text, p_pieces integer, p_weight numeric)
returns numeric
language plpgsql
stable
set search_path to 'public', 'pg_temp'
as $function$
declare v_area numeric; v_density numeric;
begin
  if coalesce(p_pieces,0) <= 0 or coalesce(p_weight,0) <= 0 then return null; end if;
  select _tile_area_m2(p_size) into v_area;
  select density_kg_m3 into v_density from tile_types where name = p_tile_type;
  if v_area is null or v_area <= 0 or v_density is null or v_density <= 0 then
    return null;                       -- unknown size or body -> unknowable
  end if;
  return round(p_weight / (p_pieces * v_area * v_density) * 1000, 2);
end; $function$;

-- Which PRODUCT does a box of these pieces/weight belong to? Returns the existing one when the
-- thickness is within 1 mm, otherwise FORKS a new product off the same print.
create or replace function public.library_for_box(
  p_library_id uuid, p_brand_id uuid, p_pieces integer, p_weight numeric)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_lib stockist_library; v_new_mm numeric;
        v_match uuid; v_match_mm numeric; v_id uuid; v_brand uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can add stock'; end if;

  select * into v_lib from stockist_library
   where id = p_library_id and stockist_id = v_stk;
  if v_lib.id is null then raise exception 'Design is not in your library'; end if;

  if coalesce(p_pieces,0) <= 0 then raise exception 'Pieces per box must be more than 0'; end if;
  if coalesce(p_weight,0) <= 0 then raise exception 'Box weight must be more than 0'; end if;

  v_new_mm := _thickness_for(v_lib.size, v_lib.tile_type, p_pieces, p_weight);
  if v_new_mm is null then
    raise exception 'This design has no tile type set, so its thickness cannot be worked out. '
                    'Open it in your Library and set one.';
  end if;

  v_brand := coalesce(p_brand_id, v_lib.brand_id);

  -- Is there already a product of this print+size+surface+body within 1 mm? Then it IS that tile.
  -- Take the CLOSEST, so a fork can never be shadowed by a more distant sibling.
  select l.id, l.thickness_mm into v_match, v_match_mm
    from stockist_library l
   where l.stockist_id = v_stk
     and lower(l.master_design_name) = lower(v_lib.master_design_name)
     and l.size = v_lib.size
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

  -- A product with this print but NO box yet is the same design waiting for its first weight:
  -- give it this one rather than forking a twin beside it.
  select l.id into v_match from stockist_library l
   where l.stockist_id = v_stk
     and lower(l.master_design_name) = lower(v_lib.master_design_name)
     and l.size = v_lib.size and l.surface_type = v_lib.surface_type
     and l.tile_type is not distinct from v_lib.tile_type
     and l.thickness_mm is null
   order by l.created_at limit 1;

  if v_match is not null then
    insert into stockist_library_brand_names (library_id, brand_id, brand_design_name,
                                              pieces_per_box, box_weight_kg)
    select v_match, v_brand, coalesce(
             (select brand_design_name from stockist_library_brand_names
               where library_id = p_library_id and brand_id = v_brand),
             v_lib.master_design_name), p_pieces, p_weight
    on conflict (library_id, brand_id) do update
      set pieces_per_box = excluded.pieces_per_box,
          box_weight_kg  = excluded.box_weight_kg;
    return jsonb_build_object('library_id', v_match, 'forked', false,
                              'thickness_mm', v_new_mm, 'matched_thickness_mm', null);
  end if;

  -- More than 1 mm from every sibling → a genuinely DIFFERENT tile. Fork the print.
  insert into stockist_library (
    stockist_id, size, master_design_name, image_url, is_sample, brand_id,
    surface_type, surface_label, stock_type, tile_type, colour, finish_label)
  values (v_stk, v_lib.size, v_lib.master_design_name, v_lib.image_url, v_lib.is_sample,
          v_lib.brand_id, v_lib.surface_type, v_lib.surface_label, v_lib.stock_type,
          v_lib.tile_type, v_lib.colour, v_lib.finish_label)
  returning id into v_id;

  -- the fork is the same PRINT: it carries the same DNA, the same brand names, the same family
  insert into library_dna (library_id, value_id)
    select v_id, x.value_id from library_dna x where x.library_id = p_library_id;
  insert into stockist_library_brand_names (library_id, brand_id, brand_design_name)
    select v_id, x.brand_id, x.brand_design_name
      from stockist_library_brand_names x where x.library_id = p_library_id;
  insert into library_family_overrides (library_id, stockist_id, family_key)
    select v_id, x.stockist_id, x.family_key
      from library_family_overrides x where x.library_id = p_library_id;

  -- ...but THIS batch's box is what makes it a different tile
  insert into stockist_library_brand_names (library_id, brand_id, brand_design_name,
                                            pieces_per_box, box_weight_kg)
  values (v_id, v_brand, coalesce(
            (select brand_design_name from stockist_library_brand_names
              where library_id = p_library_id and brand_id = v_brand),
            v_lib.master_design_name), p_pieces, p_weight)
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

revoke all on function public.library_for_box(uuid, uuid, integer, numeric) from anon;
