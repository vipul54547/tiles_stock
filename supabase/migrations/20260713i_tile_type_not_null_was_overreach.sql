-- CHAPTER 3, fix — tile_type goes back to NULLABLE, and its '' default is dropped.
--
-- ❌ Making tile_type NOT NULL (in 20260713f) was an OVERREACH and it BROKE THE IMPORT:
--    library_map_upsert inserts a product without a tile_type, so every import failed instantly.
--
-- The NOT NULL bought nothing. The identity key is
--     (stockist_id, lower(master_design_name), size, surface_type, tile_type, nominal_thickness_mm)
--     NULLS NOT DISTINCT
-- and NULLS NOT DISTINCT already makes two BLANK rows COLLIDE rather than duplicate. A blank
-- tile_type is therefore protected by the key exactly like a blank thickness.
--
-- ⚠️ The second half matters as much as the first: tile_type carried `DEFAULT ''`. The OLD model
-- used the empty string as "unknown"; the new one uses NULL (that is what NULLS NOT DISTINCT keys
-- on). Leaving the default in place would keep manufacturing the old sentinel, and an import row
-- would land as '' — which is neither declared nor honestly blank.
--
-- tile_type and nominal_thickness_mm now behave identically, which is the backfill decision:
-- DECLARED, or honestly BLANK. Never guessed — a wrong value in the identity key is worse than a
-- blank. The Library editor requires both on a NEW product; legacy rows and imports fill in later.

alter table stockist_library alter column tile_type drop not null;
alter table stockist_library alter column tile_type drop default;

-- Keep '' out (it would be a second flavour of "unknown"), but allow a real NULL.
alter table stockist_library drop constraint if exists stockist_library_tile_type_not_blank;
alter table stockist_library add constraint stockist_library_tile_type_not_blank
  check (tile_type is null or btrim(tile_type) <> '');

update stockist_library set tile_type = null where btrim(coalesce(tile_type,'')) = '';

comment on column stockist_library.tile_type is
  'Body type (Ceramic / Porcelain / PGVT & GVT ...). Part of PRODUCT IDENTITY. NULL = not yet '
  'declared. Also supplies the density that DERIVES thickness_mm (evidence only).';

-- Verified against live data (in a rolled-back probe, so nothing was written):
--   import-style insert with no tile_type ....... works
--   a second identical blank-identity row ....... BLOCKED by the key
--   same print/size/surface, declared 12 mm ..... allowed as a SEPARATE product
--
-- ⚠️ Do NOT put that probe in a DO block that ends in RAISE EXCEPTION inside this migration: the
-- raise would roll back the ALTERs above along with it. (It did, on the first attempt.)
