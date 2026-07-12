-- Surface becomes MANDATORY — step 2 of 3: stock INHERITS the product's surface.
--
-- THE RULE (user, 2026-07-13):
--   * surface_mode = 'attribute'  (an M whose box stamp carries name AND surface as two
--     separate fields — e.g. famous ceramic) -> stock entry SHOWS a surface field, because
--     one stamped name genuinely covers several surfaces. These stockists are RARE.
--   * everyone else -> stock entry shows NO surface field. Their design name already
--     identifies exactly one product (they only make one surface, or they encode it in the
--     number range: 10001-19999 = Glossy, 20001-29999 = Matt). Forcing them to re-state the
--     surface on every entry is noise.
--
-- So when the caller passes NO surface, it does not mean 'None' — it means
-- "use the product's own surface". Defaulting to 'None' would look up (name, size, 'None'),
-- MISS the real product, and CREATE a placeholder beside it: the same tile, twice, in the
-- Library. That is the bug this closes.
--
-- 'None' is no longer a surface. It is never written again.

create or replace function public.stock_add_holding(
  p_library_id uuid, p_quality text, p_qty integer, p_catalog_id uuid,
  p_surface text default null::text, p_brand_id uuid default null::uuid,
  p_surface_label text default null::text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_stk uuid; v_design uuid; v_q text; v_surf text; v_label text;
        v_name text; v_size text; v_brand uuid; v_master_brand uuid;
        v_lib uuid; v_lib_surf text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if p_library_id is null then raise exception 'Pick a design first'; end if;

  select master_design_name, size, brand_id, surface_type
    into v_name, v_size, v_master_brand, v_lib_surf
    from stockist_library where id = p_library_id and stockist_id = v_stk;
  if v_name is null then raise exception 'Design is not in your library'; end if;

  if p_catalog_id is not null and not exists (
       select 1 from stock_catalogs where id = p_catalog_id and stockist_id = v_stk) then
    raise exception 'Stock list does not belong to you';
  end if;

  v_brand := coalesce(p_brand_id, v_master_brand);
  v_q     := coalesce(nullif(btrim(p_quality),''),'Standard');
  v_label := nullif(btrim(p_surface_label),'');

  -- No surface passed -> INHERIT the product's own. Never 'None'.
  v_surf := coalesce(nullif(btrim(p_surface),''), v_lib_surf);
  if v_surf is null or v_surf = '' or lower(v_surf) = 'none' then
    raise exception 'This design has no surface set. Open it in your Library and pick one.';
  end if;

  -- SURFACE IS PRODUCT IDENTITY: a different surface means a different product of the same
  -- print. Find it, or create it by copying the print. (Only an attribute-mode M can reach
  -- this branch, because only they are asked for a surface at all.)
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
        surface_type, surface_label, stock_type, tile_type, pieces_per_box,
        box_weight_kg, thickness_mm, colour, finish_label)
      select l.stockist_id, l.size, l.master_design_name, l.image_url, l.is_sample,
             l.brand_id, v_surf, v_label, l.stock_type, l.tile_type, l.pieces_per_box,
             l.box_weight_kg, l.thickness_mm, l.colour, l.finish_label
        from stockist_library l where l.id = p_library_id
      returning id into v_lib;

      -- Same artwork -> same character. DNA is per PRODUCT, so it is COPIED.
      insert into library_dna (library_id, value_id)
        select v_lib, x.value_id from library_dna x where x.library_id = p_library_id;
      insert into stockist_library_brand_names (library_id, brand_id, brand_design_name)
        select v_lib, x.brand_id, x.brand_design_name
          from stockist_library_brand_names x where x.library_id = p_library_id;
      insert into library_family_overrides (library_id, stockist_id, family_key)
        select v_lib, x.stockist_id, x.family_key
          from library_family_overrides x where x.library_id = p_library_id;
    end if;
  end if;

  -- Refresh the stockist's WORD for this canonical surface (display-only, never a key).
  if v_label is not null then
    update stockist_library set surface_label = v_label, updated_at = now()
     where id = v_lib and surface_label is distinct from v_label;
  end if;

  -- Holding identity unchanged: (stockist, library, brand, quality, surface_type).
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


-- add_inventory_batch: pass the surface THROUGH as null when absent, so stock_add_holding
-- can inherit. It must no longer coerce a missing surface to 'None'.
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
    -- null (not 'None') = "the product knows its own surface"
    v_surf  := nullif(btrim(coalesce(e->>'surface','')), '');
    if lower(coalesce(v_surf,'')) = 'none' then v_surf := null; end if;
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
