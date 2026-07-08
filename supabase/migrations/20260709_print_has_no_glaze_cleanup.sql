-- Data cleanup, authorised by the user 2026-07-09 ("all test data, go ahead").
-- Brings existing rows in line with the corrected model:
--   stockist_library = the PRINT (name + size + image). No glaze, no brand.
--   designs          = the TILE  (print + brand + quality + glaze + boxes).
-- See project_per_brand_surface_mode.
--
-- NOTE: stock (designs / inquiries / dispatch_notes) is deliberately NOT touched.
-- famous ceramic holds 78 holdings / 4161 boxes / 6 orders / 11 dispatch notes —
-- the only fixtures we have for the order + dispatch flows, which are still
-- unverified. Nothing here needs them gone.

-- 1) M boxes are brand-agnostic: the brand lives ONLY in the alias table.
--    library_upsert_master already nulls brand_id for M on every save; these 35
--    rows (all famous ceramic) predate that fix. Verified beforehand: all 35 have
--    an alias row for their own brand, so nulling orphans nothing from the
--    Add-Stock brand filter (add_stock_batch_screen.dart falls back to aliases).
update public.stockist_library l
   set brand_id = null
  from public.stockists s
 where l.stockist_id = s.id
   and s.business_type = 'M'
   and l.brand_id is not null;

-- 2) A print carries no glaze. The glaze is chosen when stock is made, and lives
--    on designs.surface_type (stock_add_holding keys the holding on it).
--    Safe now: the only reader of this column on a live path was
--    add_edit_stock_screen.dart's add-branch, which is unreachable — the sole
--    route into that screen (/stockist/stock/edit/:id) always supplies designId.
--
--    ⚠️ import_stock_batch and library_map_upsert still WRITE this column, so an
--    import will re-dirty it until the importers are reworked to put the glaze on
--    the holding instead. Harmless: nothing reads it.
update public.stockist_library
   set surface_type = ''
 where coalesce(surface_type, '') <> '';
