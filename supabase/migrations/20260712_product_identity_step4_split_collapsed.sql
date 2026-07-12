-- Product identity migration — STEP 4 of 5: split the collapsed masters.
-- (docs/PRODUCT_IDENTITY_MIGRATION_PLAN.md)
--
-- A product whose HOLDINGS span several surfaces is not one product. It is the collapse
-- bug: surface was never in the product key, so Glossy and Matt of one print were forced
-- into a single row. Six such rows exist in production. Each becomes one product PER
-- surface, and each holding is re-pointed at the product it actually belongs to.
--
-- MUST run AFTER step 3 (the key swap) — the old brand-bearing, surface-less index would
-- reject these inserts.
--
-- The 6 targets, measured 2026-07-12 (6 masters -> 15 products, 9 new):
--   famous 1001  300x450   product says 'Sugar' (STALE — no Sugar holding!)  ->  Carving, GHR, Matt
--   famous 1004  300x450   product says 'None'                               ->  Carving, Sugar
--   famous 1006  300x450   product says 'None'                               ->  Carving, Glossy
--   cura   BIANCO SYDNEY   product says 'Glossy'                             ->  Glossy, P.Glossy, Sugar
--   livok  3209  300x450   product says 'None'                               ->  Carving, P.Glossy
--   livok  DELTON_8_A      product says 'None'                               ->  Carving, Matt, Sugar
--
-- KEEPER SURFACE = the surface with the most holdings; ties broken by surface_types
-- .sort_order. The existing row keeps its id (so nothing else in the DB dangles) and is
-- re-stamped with the keeper surface — which DISCARDS any stale stamp, e.g. 1001's 'Sugar'.
--
-- Each NEW product carries the character across, because it is the same artwork:
--   library_dna                     (DNA tags)   -> copied
--   stockist_library_brand_names    (aliases)    -> copied
--   library_family_overrides        (family_key) -> copied
-- Per the user's decision (2026-07-12), DNA is per PRODUCT — there is no PRINT table — so
-- copying is correct and final, not a temporary seed.

do $$
declare
  rec   record;
  s     record;
  v_keep text;
  v_new  uuid;
  v_split int := 0;
  v_made  int := 0;
begin
  for rec in
    select l.id, l.stockist_id
      from stockist_library l
     where (select count(distinct d.surface_type)
              from designs d where d.library_id = l.id) > 1
  loop
    -- keeper = most holdings, tie -> admin sort order, then name (fully deterministic)
    select d.surface_type
      into v_keep
      from designs d
      left join surface_types t on t.name = d.surface_type
     where d.library_id = rec.id
     group by d.surface_type, t.sort_order
     order by count(*) desc, coalesce(t.sort_order, 9999), d.surface_type
     limit 1;

    -- re-stamp the surviving row with the surface it REALLY is (drops any stale stamp)
    update stockist_library l
       set surface_type  = v_keep,
           surface_label = coalesce(
             (select min(d.surface_label) from designs d
               where d.library_id = rec.id and d.surface_type = v_keep),
             l.surface_label),
           updated_at    = now()
     where l.id = rec.id;

    v_split := v_split + 1;

    -- one new product per OTHER surface
    for s in
      select distinct d.surface_type as sf
        from designs d
       where d.library_id = rec.id and d.surface_type <> v_keep
    loop
      -- thickness_band is GENERATED ALWAYS from thickness_mm — it must NOT be listed here;
      -- it recomputes itself on the new row.
      insert into stockist_library (
        stockist_id, size, master_design_name, image_url, is_sample, brand_id,
        surface_type, surface_label, stock_type, tile_type, pieces_per_box,
        box_weight_kg, thickness_mm, colour, finish_label)
      select l.stockist_id, l.size, l.master_design_name, l.image_url, l.is_sample,
             l.brand_id,
             s.sf,
             (select min(d.surface_label) from designs d
               where d.library_id = rec.id and d.surface_type = s.sf),
             l.stock_type, l.tile_type, l.pieces_per_box,
             l.box_weight_kg, l.thickness_mm, l.colour, l.finish_label
        from stockist_library l
       where l.id = rec.id
      returning id into v_new;

      insert into library_dna (library_id, value_id)
        select v_new, x.value_id from library_dna x where x.library_id = rec.id;

      insert into stockist_library_brand_names (library_id, brand_id, brand_design_name)
        select v_new, x.brand_id, x.brand_design_name
          from stockist_library_brand_names x where x.library_id = rec.id;

      insert into library_family_overrides (library_id, stockist_id, family_key)
        select v_new, x.stockist_id, x.family_key
          from library_family_overrides x where x.library_id = rec.id;

      -- the holdings of THIS surface now point at their real product
      update designs d
         set library_id = v_new,
             updated_at = now()
       where d.library_id = rec.id and d.surface_type = s.sf;

      v_made := v_made + 1;
    end loop;
  end loop;

  raise notice 'split % master(s), created % new product(s)', v_split, v_made;
end $$;

-- GUARD 1: no product may still hold stock in more than one surface.
do $$
declare v_bad int;
begin
  select count(*) into v_bad from (
    select d.library_id from designs d
     group by d.library_id having count(distinct d.surface_type) > 1
  ) t;
  if v_bad > 0 then
    raise exception 'split failed: % product(s) still span multiple surfaces', v_bad;
  end if;
end $$;

-- GUARD 2: every holding's surface must equal its product's surface. This is the whole
-- point of the chapter — the holding and the product can no longer disagree.
do $$
declare v_bad int;
begin
  select count(*) into v_bad
    from designs d
    join stockist_library l on l.id = d.library_id
   where d.surface_type is distinct from l.surface_type;
  if v_bad > 0 then
    raise exception 'split failed: % holding(s) disagree with their product''s surface', v_bad;
  end if;
end $$;
