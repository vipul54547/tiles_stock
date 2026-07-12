-- Product identity migration — STEP 3 of 5: swap the product key.
-- (docs/PRODUCT_IDENTITY_MIGRATION_PLAN.md)
--
--   FROM  (stockist_id, brand_id, lower(master_design_name), size)      brand IN,  surface OUT
--   TO    (stockist_id, lower(master_design_name), size, surface_type)  brand OUT, surface IN
--
-- WHY BRAND IS OUT: for an M, a different brand is only a different NAME for the same
-- print. Brand belongs to the BOX, not the product. The alias table that expresses this —
-- stockist_library_brand_names (library_id, brand_id, brand_design_name) — has existed all
-- along, but brand_id sitting in the product key re-split the master by brand and defeated
-- it. All 1001 alias rows currently have brand_design_name = master_design_name: the
-- mechanism is populated but degenerate, and it has not bitten only because nobody has yet
-- entered a genuinely different per-brand name.
--
-- WHY SURFACE IS IN: surface IS product identity. Glossy Ant Bianco and Matt Ant Bianco are
-- two different products made from one print. With surface out of the key they collapse
-- into a single row whose surface_type is overwritten by whichever was written last — which
-- has ALREADY happened in production: famous "1001" carries a stale 'Sugar' stamp while its
-- holdings are Carving/GHR/Matt.
--
-- ORDER MATTERS: this MUST run BEFORE the split (step 4). The old index has no surface
-- column, so inserting a split sibling (same brand+name+size, different surface) would
-- violate it for every brand-stamped row (livok's DELTON_8_A, 3209).
--
-- Measured on live data 2026-07-12, after steps 1+2: the new key has 0 collisions across
-- all 924 products. Nothing merges, nothing is lost.

do $$
declare v_dupes int;
begin
  select count(*) into v_dupes from (
    select 1 from stockist_library
    group by stockist_id, lower(master_design_name), size, surface_type
    having count(*) > 1
  ) t;
  if v_dupes > 0 then
    raise exception 'refusing to swap the key: % group(s) would collide on '
                    '(stockist, lower(name), size, surface_type)', v_dupes;
  end if;
end $$;

drop index if exists stockist_library_uniq;

create unique index stockist_library_uniq
  on stockist_library (stockist_id, lower(master_design_name), size, surface_type);

-- brand_id stays as a COLUMN (a "first seen / default brand" hint) but no longer carries
-- identity. The BOX chapter (product x brand -> pieces_per_box, box_weight) will decide
-- its final fate; dropping it now would be churn for no gain.
comment on column stockist_library.brand_id is
  'Default/first-seen brand hint only. NOT identity — brand lives on the box + '
  'stockist_library_brand_names aliases. See docs/PRODUCT_IDENTITY_MIGRATION_PLAN.md';

comment on column stockist_library.surface_type is
  'Part of the product identity. Glossy and Matt of one print are two products.';
