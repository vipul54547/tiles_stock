-- BOX chapter — STEP 2 of 5: pieces_per_box + box_weight_kg move onto the BOX.
-- (docs/BOX_AND_DERIVED_THICKNESS_PLAN.md)
--
-- THE BOX already exists: stockist_library_brand_names is keyed UNIQUE (library_id, brand_id)
-- = exactly product x brand, and already carries brand_design_name — the NAME stamped on that
-- brand's box. It was only ever missing the other two box facts.
--
-- WHY THEY BELONG HERE (user, 2026-07-13): "brands can pack differently" — the same print
-- under Brand A and Brand B may ship 4/box and 6/box. Pieces and weight are facts about the
-- BOX, not the tile. They sat on the product, which cannot express that.
--
-- Packing does not vary WITHIN a brand ("if the packing changes, the brand also changes"), so
-- (brand, size) supplies a PREFILL in the UI — but only a prefill. It is NOT a constraint: the
-- live data already breaks it (CURA · 800x1600 has two products at 2 and 3 pieces/box).
--
-- Measured on live data first:
--   * all 933 products already have >= 1 box  -> the specs have somewhere to land
--   * 0 products have specs but no box        -> nothing is stranded
--   * 1 holding has a (library, brand) with NO box row -> created below, or it could never
--     resolve a spec

alter table stockist_library_brand_names
  add column if not exists pieces_per_box int,
  add column if not exists box_weight_kg  numeric;

comment on table stockist_library_brand_names is
  'THE BOX: (library_id, brand_id) = product x brand. Carries everything that is genuinely '
  'per-brand — the design NAME stamped on that brand''s box, plus how that brand packs it '
  '(pieces_per_box, box_weight_kg). Thickness is DERIVED from these and lives on the product.';

-- Every holding must resolve to a box. Create the missing one(s).
insert into stockist_library_brand_names (library_id, brand_id, brand_design_name)
select distinct d.library_id, d.brand_id, l.master_design_name
  from designs d
  join stockist_library l on l.id = d.library_id
 where d.brand_id is not null
   and not exists (select 1 from stockist_library_brand_names a
                    where a.library_id = d.library_id and a.brand_id = d.brand_id)
on conflict (library_id, brand_id) do nothing;

-- Lift the spec from the product onto every box of that product. A product carried under two
-- brands gets the same spec copied to both — correct as a starting point; the stockist can
-- then make them differ, which is the whole reason for the move.
update stockist_library_brand_names a
   set pieces_per_box = l.pieces_per_box,
       box_weight_kg  = l.box_weight_kg
  from stockist_library l
 where l.id = a.library_id
   and (coalesce(l.pieces_per_box,0) > 0 or coalesce(l.box_weight_kg,0) > 0);

-- Guards.
do $$
declare v_bad int;
begin
  select count(*) into v_bad
  from designs d
  where d.brand_id is not null
    and not exists (select 1 from stockist_library_brand_names a
                     where a.library_id = d.library_id and a.brand_id = d.brand_id);
  if v_bad > 0 then
    raise exception 'step 2 failed: % holding(s) still have no box', v_bad;
  end if;

  -- Nothing that had a spec may have lost it.
  select count(*) into v_bad
  from stockist_library l
  where coalesce(l.pieces_per_box,0) > 0
    and not exists (select 1 from stockist_library_brand_names a
                     where a.library_id = l.id and coalesce(a.pieces_per_box,0) > 0);
  if v_bad > 0 then
    raise exception 'step 2 failed: % product(s) lost their pieces_per_box in the move', v_bad;
  end if;
end $$;
