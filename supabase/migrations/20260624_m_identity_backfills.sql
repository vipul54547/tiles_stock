-- M identity redesign — data backfills (branch feat/m-identity-redesign).
-- Idempotent; safe to re-run. DB restore point = bak_20260624_* tables.

-- 1) Junction backfill: ensure every M box's own brand_id is also represented in
--    the brand-names junction, so treating M boxes as brand-agnostic loses no brand.
insert into stockist_library_brand_names (library_id, brand_id, brand_design_name)
select l.id, l.brand_id, l.master_design_name
from stockist_library l
join stockists s on s.id = l.stockist_id and s.business_type = 'M'
where l.brand_id is not null
  and not exists (
    select 1 from stockist_library_brand_names n
    where n.library_id = l.id and n.brand_id = l.brand_id)
on conflict (library_id, brand_id) do nothing;

-- 2) Box-surface backfill: historically imports set surface only on the holding
--    (designs.surface_type); the box (stockist_library.surface_type) was left
--    'None'. Per the locked model surface belongs ON the box (box = master+surface),
--    so copy each M box's single holding-surface up onto the box.
update stockist_library l
set surface_type = hs.surf, updated_at = now()
from (
  select library_id, min(surface_type) surf
  from designs
  where surface_type is not null and surface_type <> '' and surface_type <> 'None'
  group by library_id
  having count(distinct surface_type) = 1
) hs
where l.id = hs.library_id
  and l.stockist_id in (select id from stockists where business_type = 'M')
  and coalesce(l.surface_type,'None') <> hs.surf;

-- NOTE (deferred, with the Design/Stock UI): make library_map_upsert surface-AWARE
-- (match/create box by name+size+surface) so same name+size in two surfaces becomes
-- two boxes. Not done standalone: it needs a signature change + device verification
-- and has 0 current multi-surface cases. See docs/M_IDENTITY_REDESIGN_PLAN.md.
