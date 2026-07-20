-- 20260720c — backfill the BOXES the buggy New Design save never made.
--
-- 🐞 The one-page New Design screen called `cover_name_set` (which only records the WORD a brand
-- prints) but never `box_put_cover` (which CREATES the box). So a design came out with a cover name
-- and `boxes = 0` — and since a HOLD points at `designs.box_id`, stock could never attach. Prod
-- showed it exactly: 2 cover names, 0 boxes. Fixed in new_design_screen.dart (box first, then word).
--
-- This repairs the rows already made. It is NOT a guess: naming a brand's cover already declared
-- that the brand wraps that design. The only thing the name does not say is WHICH packing —
-- so we backfill **only where the design has exactly ONE packing**, where there is nothing to
-- choose. A design with 2+ packings is left alone and reported; he must tick the brand himself.

insert into public.boxes (packing_id, brand_id)
select pk.id, n.brand_id
from public.stockist_library_brand_names n
join public.packings pk on pk.library_id = n.library_id
where (select count(*) from public.packings p2 where p2.library_id = n.library_id) = 1
on conflict (packing_id, brand_id) do nothing;

do $$
declare v_made int; v_skipped int;
begin
  select count(*) into v_made from public.boxes;
  select count(*) into v_skipped
  from public.stockist_library_brand_names n
  where (select count(*) from public.packings p2 where p2.library_id = n.library_id) <> 1;
  raise notice 'boxes now = %; cover names skipped (0 or 2+ packings) = %', v_made, v_skipped;
end $$;
