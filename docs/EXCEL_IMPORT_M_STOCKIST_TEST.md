# Excel Import — M_Stockist Full Test (multi-brand → DB)

Focused, full-coverage pass for a **manufacturer (M) stockist** uploading Excel
that carries **all of its brand names in one sheet**, verifying every row lands
in the database correctly. Companion to `EXCEL_IMPORT_FULL_TEST.md` (which covers
the T/W path, already verified). Code: `lib/screens/stockist/import_excel_stock_screen.dart`.

Two M shapes are tested:
- **Combined multi-brand sheet** — one column per brand (BOTTEGA / CERA TILES /
  ENNFACE …) + a Master Design column + wide Premium/Standard qty.
  Fixture: `docs/templates/test_fixtures/m_combined.xlsx`.
- **ENTRY export** — the M's current software shape: brand in BoxPack, wide
  PRE/STD/GOLD/ECO, same design repeating per batch.
  Fixture: `docs/templates/test_fixtures/mock_entry.xlsx`.

---

## 0. Pre-conditions
- [ ] Account is **business_type = M** with ≥2 brands (1 main + non-main). Test
      account: `cura ceramic` (`c8efecc1-…`), brands BOTTEGA / CERA TILES / ENNFACE.
- [ ] **New-brand GATE:** a brand with **no library designs** only offers
      "Set up designs — Mapping (Excel)" — no stock import until it has designs.
      So **map-first, then stock**. (Confirm the gate still shows for an empty brand.)
- [ ] Decide clean vs re-import. For a clean read, wipe stock but keep library
      (Cleanup SQL at bottom). Note: the prior session left **duplicate CLOUD ONYX
      masters** (stock-before-map order) — start from a clean library to avoid it.

## 1. Format detection
- [ ] `m_combined.xlsx` → parsed as **combined sheet** (brand columns recognised),
      NOT the ENTRY path.
- [ ] `mock_entry.xlsx` → detected as **ENTRY** (`_isEntryFormat`): triggers the
      **"Which column is the brand?"** confirm, auto-suggesting **BoxPack**
      (because `Brand` is all `--`).

## 2. Combined sheet — ALL brand names → DB  (the core case)
Upload `m_combined.xlsx` with the **main brand chosen** as upload brand.
- [ ] Every header equal to a stockist brand name is picked up as that brand's
      **alias column** (`brandCols`). A column whose header is **not** a brand of
      this account is **ignored** (add a junk "FOO" column → no alias written).
- [ ] **Master naming** (`#5` fix): master named from the **Master Design** column,
      NOT brand-1's alias. CLOUD ONYX stays "CLOUD ONYX".
- [ ] **CLOUD ONYX** → master + **all** brand aliases written; Premium holding.
- [ ] **PLAIN KHAKHI** (chosen-brand cell blank, other brands named) →
      **map-only**: alias rows written, **qty 0**, **no stock holding**.
- [ ] **DUNE BEIGE** (Premium **and** Standard) → **2 holdings**.
- [ ] A **Standard = 0** line is **NOT** persisted (only real quantities).
- [ ] **DNA** columns (Colour / Look Type) auto-tagged on the master.

### DB checks after step 2
```sql
-- holdings
select name,size,quality,surface_type,box_quantity
from designs where stockist_id='<SID>' order by created_at desc;
-- every brand alias present for each master?
select l.master_design_name, b.name as brand, n.brand_design_name
from stockist_library l
join stockist_library_brand_names n on n.library_id=l.id
join stockist_brands b on b.id=n.brand_id
where l.stockist_id='<SID>' order by l.master_design_name, b.name;
```
- [ ] Each master shows one alias row **per brand column that had a value**.
- [ ] map-only designs appear in library/aliases but **not** in `designs`.

## 3. ENTRY export — `mock_entry.xlsx`
- [ ] Brand-column confirm → **BoxPack**; map the BoxPack brand values to brands.
- [ ] **Batch-sum**: CLOUD ONYX **PRE 252 / STD 32**; DESERT SAND **PRE 168 / STD 60**
      (summed across the design's repeated batch rows).
- [ ] **GOLD / ECO** columns **read but dropped** (no holdings created for them).
- [ ] Size suffix stripped: **`800X1600 (2PCS)` → `800X1600`**.
- [ ] PRE→**Premium**, STD→**Standard**.

## 4. Quantity modes
- [ ] **Add only**: re-upload → boxes **add** (e.g. CLOUD ONYX Premium 252 → 504).
- [ ] **Update & keep**: re-upload → boxes **set** to the file number (back to 252).

## 5. New-design friction (#3, known/open)
- [ ] A genuinely **new** design (not in library, no identity) flags **needsFill** —
      Save blocked until tile type / pieces / weight filled or the row excluded.
      (Open product decision; for the test, fill manually.)

## 6. Atomicity & failure-recovery  ← the "API error stopped the session" case
The save is one atomic, idempotent RPC (`importStockBatch`, reused `_batchId`).
- [ ] **Mid-upload failure writes nothing.** If the call errors (kill network /
      force an API error), the toast says "Nothing was saved" and **`designs`,
      `stockist_library`, aliases are all unchanged** — no half-write.
- [ ] **Retry doesn't double-count.** Re-tap Import after a failure (same screen,
      same `_batchId`) → quantities are correct **once**, not doubled.
- [ ] **Cancel a brand/map dialog** → nothing saved.

## 7. Edge cases
- [ ] **Empty sheet** → clean, actionable error (no crash).
- [ ] **Inline-string xlsx** (openpyxl export, no shared strings, `#4` open) →
      actionable "Save As .xlsx and re-upload" message (NOT a cryptic failure).
- [ ] **Same name+size+quality, different surface** → **separate holding**.
- [ ] **Unknown brand column** (header not a brand of this account) → ignored.

---

## DB verification helpers
```sql
-- SID for the M test account
-- select id,name,business_type from stockists where name ilike 'cura%';

-- 1) holdings correct (name/size/quality/surface/qty)
select name,size,quality,surface_type,box_quantity,created_at
from designs where stockist_id='<SID>' order by created_at desc;

-- 2) library masters + image presence
select master_design_name,size,(coalesce(image_url,'')<>'') as has_img
from stockist_library where stockist_id='<SID>' order by master_design_name;

-- 3) per-brand aliases (the "all brand names" check)
select l.master_design_name, b.name brand, n.brand_design_name
from stockist_library l
join stockist_library_brand_names n on n.library_id=l.id
join stockist_brands b on b.id=n.brand_id
where l.stockist_id='<SID>' order by 1,2;

-- 4) no duplicate masters (same name+size twice = artifact, should be 1)
select master_design_name,size,count(*)
from stockist_library where stockist_id='<SID>'
group by 1,2 having count(*)>1;
```

## Cleanup (wipe stock, KEEP library)
```sql
-- <SID> = the test stockist id
with d as (select id from designs where stockist_id='<SID>')
  delete from stock_in where design_id in (select id from d);
-- repeat for dispatches, my_choices, stock_adjustments, inquiry_items
delete from designs where stockist_id='<SID>';
-- to also reset library + aliases (full clean):
-- delete from stockist_library_brand_names where library_id in
--   (select id from stockist_library where stockist_id='<SID>');
-- delete from stockist_library where stockist_id='<SID>';
```

## Known open items to keep in mind
- **#3 M-bulk needs-fill** — every brand-new design needs identity; heavy for a
  big M export. Product decision pending.
- **#4 inline-string xlsx** — Dart `excel` v4.0.6 can't read openpyxl inline
  strings; only the error message is improved, parsing not added.
- **Duplicate masters** can exist from a stock-before-mapping test order — verify
  with DB check #4 and start clean.
