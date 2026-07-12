-- Product identity migration — STEP 1 of 5: normalise surface_type.
-- (docs/PRODUCT_IDENTITY_MIGRATION_PLAN.md)
--
-- The product key is becoming (stockist, lower(master_design_name), size, surface_type).
-- A NULL/empty column inside a unique key is exactly how "Glossy Ant Bianco" and
-- "Matt Ant Bianco" collapsed into one row in the first place: NULLs do not compare
-- equal, and '' vs NULL vs 'None' were three ways of saying the same thing.
--
-- So before surface can carry identity, it must have exactly ONE way to say "no surface".
-- That value is 'None' — the is_system row already in surface_types.
--
-- Measured on live data 2026-07-12 (trial write, rolled back):
--   735 rows normalised  ->  924 total = 889 'None' + 35 with a real surface.
-- No row is destroyed: every value that was already a real surface is left alone.

-- 1. Collapse NULL and '' into the single canonical 'None'.
update stockist_library
   set surface_type = 'None',
       updated_at   = now()
 where nullif(btrim(coalesce(surface_type, '')), '') is null;

-- 2. Make it impossible to reintroduce the ambiguity. From here on a product ALWAYS
--    has a surface — 'None' is a real, deliberate answer, not a missing one.
--    (library_contribute and admin_library_upsert insert without surface_type today;
--    the default catches them and they stop writing NULLs.)
alter table stockist_library
  alter column surface_type set default 'None';

alter table stockist_library
  alter column surface_type set not null;

-- Guard: 'None' must exist as the system fallback, or the default is a lie.
do $$
begin
  if not exists (select 1 from surface_types where name = 'None') then
    raise exception 'surface_types has no "None" row — step 1 would strand every product';
  end if;
end $$;
