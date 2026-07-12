-- Fix: a holding must inherit the product's surface LABEL too, not just its surface_type.
--
-- REGRESSION this closes (user caught it on device): STANZA GREEN showed as TWO cards —
-- Premium 217 and Standard 45 — instead of one card reading P(217+45).
--
-- The data was never wrong: ONE product (Matt), TWO holdings on it. But since Add Stock
-- stopped asking for a surface (surface_mode != 'attribute'), it also stopped sending a
-- surface_label — so the new Standard holding was written with surface_label = NULL while
-- the older Premium one still said 'MATT'. The dashboard groups its cards on
--     library_id | surface_type | surface_label
-- so NULL vs 'MATT' hashed to two different cards.
--
-- Two things were wrong and both are fixed:
--   1. HERE — stock_add_holding now inherits the product's surface_label when the caller
--      sends none, exactly as it already inherits surface_type. A holding of a product
--      should carry that product's word.
--   2. In the app — the dashboard must not key a group on surface_label at all. CLAUDE.md
--      already says "surface_label is display-only, NOT part of the key", and the surface
--      now lives on the PRODUCT, so library_id alone determines it.

-- Repair the holdings that already lost their word.
update designs d
   set surface_label = l.surface_label,
       updated_at    = now()
  from stockist_library l
 where l.id = d.library_id
   and nullif(btrim(coalesce(d.surface_label, '')), '') is null
   and nullif(btrim(coalesce(l.surface_label, '')), '') is not null;

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
        surface_type, surface_label, stock_type, tile_type, pieces_per_box,
        box_weight_kg, thickness_mm, colour, finish_label)
      select l.stockist_id, l.size, l.master_design_name, l.image_url, l.is_sample,
             l.brand_id, v_surf, nullif(btrim(coalesce(p_surface_label,'')),''),
             l.stock_type, l.tile_type, l.pieces_per_box,
             l.box_weight_kg, l.thickness_mm, l.colour, l.finish_label
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
