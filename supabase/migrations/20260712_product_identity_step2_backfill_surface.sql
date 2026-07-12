-- Product identity migration — STEP 2 of 5: backfill surface onto the product.
-- (docs/PRODUCT_IDENTITY_MIGRATION_PLAN.md)
--
-- Surface is becoming part of the product key, but 96% of products carry no surface —
-- because `add_inventory_batch` only ever stamped it for an M in `in_name` mode, and
-- never for a T/W or an `attribute` M.
--
-- The holdings, however, DO know the surface: `designs_holding_uniq` has always included
-- surface_type. So the truth is already in the database, one level down. Lift it up.
--
-- ONLY for products whose holdings agree on exactly ONE surface. A product whose holdings
-- span several surfaces is not one product at all — it is the collapse bug, and step 3
-- splits it. Do not guess here.
--
-- Measured on live data 2026-07-12 (trial write, rolled back):
--   44 products have exactly one surface in stock; 18 already correct, 26 change.
--   ZERO products contradict their holdings — this fills gaps, it never overwrites a
--   real answer. Result: 924 = 863 'None' + 61 with a real surface (was 889 + 35).
--
-- The remaining 874 products have NO holdings at all (Sri Balaji 258, saanvi 131,
-- Gracias 75, ...). Their surface stays 'None' — we genuinely do not know it, and an
-- honest 'None' beats an invented surface. It will be set when stock is added or edited.

update stockist_library l
   set surface_type  = h.sf,
       surface_label = coalesce(h.lbl, l.surface_label),
       updated_at    = now()
  from (
    select d.library_id,
           min(d.surface_type)  as sf,
           min(d.surface_label) as lbl
    from designs d
    group by d.library_id
    having count(distinct d.surface_type) = 1
  ) h
 where l.id = h.library_id
   and l.surface_type is distinct from h.sf;

-- Guard: after this, no single-surface product may disagree with its holdings.
do $$
declare v_bad int;
begin
  select count(*) into v_bad
  from (
    select d.library_id, min(d.surface_type) as sf
    from designs d group by d.library_id having count(distinct d.surface_type) = 1
  ) h
  join stockist_library l on l.id = h.library_id
  where l.surface_type <> h.sf;

  if v_bad > 0 then
    raise exception 'step 2 failed: % product(s) still disagree with their holdings', v_bad;
  end if;
end $$;
