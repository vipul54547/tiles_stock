-- PER-BRAND STOCK (M): the holding gains a brand dimension so each brand's boxes
-- are counted independently. Identity stays shared on stockist_library (one master
-- + per-brand alias names). T/W: brand_id mirrors the master's brand. See
-- project_per_brand_stock.

ALTER TABLE designs
  ADD COLUMN IF NOT EXISTS brand_id uuid REFERENCES brands(id) ON DELETE SET NULL;

-- WIPE all stock first (user decision) for a clean per-brand restart. Cascades clear
-- dispatches, inquiry_items, my_choices, stock_adjustments, stock_in — all
-- pre-launch test data. Library (photos/DNA/alias names), brands, and stock lists
-- (catalog_designs -> library_id) are preserved.
DELETE FROM designs;

-- Holding identity now includes brand. Replace the old constraint with a unique
-- INDEX using NULLS NOT DISTINCT so a null brand can't create duplicate holdings
-- for the same (stockist, master, quality, surface).
ALTER TABLE designs DROP CONSTRAINT IF EXISTS designs_holding_uniq;
CREATE UNIQUE INDEX designs_holding_uniq
  ON designs (stockist_id, library_id, brand_id, quality, surface_type) NULLS NOT DISTINCT;

CREATE INDEX IF NOT EXISTS idx_designs_brand ON designs(brand_id);
