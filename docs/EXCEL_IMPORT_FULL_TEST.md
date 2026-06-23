# Excel Import — Full Consolidated On-Device Test

One pass that exercises the whole Excel import path, including **image reuse from
the Design Library** (Excel carries no photos → the app must fill each row's image
from the stockist's own library by name+size). Supersedes the per-area checklist
for day-to-day runs; the older `EXCEL_IMPORT_TEST_CHECKLIST.md` stays as reference.

Fixtures in `docs/templates/test_fixtures/` (all written with **xlsxwriter** so
they use shared strings — the Dart `excel` v4.0.6 reader does NOT accept openpyxl
inline strings):
- `tw_full.xlsx` — consolidated T/W: image-reuse + new design + map-finishes + invalid.
- `m_combined.xlsx` — M skin (needs a multi-brand account).
- `mock_entry.xlsx` — M_Stockist ENTRY export shape.

---

## 0. Setup — wipe stock, KEEP library
Goal: empty `designs` (P_Stock holdings) for the test stockist but keep all
`stockist_library` rows (identity + `image_url`). Then a re-import must pull the
photo from the library. Run the cleanup SQL (see "Cleanup" at the bottom). After
it: dashboard shows **0 designs / 0 boxes**, but **My Design Library still full**.

⚠️ Destructive — deletes ALL stock (incl. the 56-design / 4693-box batch),
ledger, dispatches, choices, adjustments, inquiry items. Library is untouched.

---

## 1. T/W consolidated — upload `tw_full.xlsx`
6 rows, each a checkpoint:

| Row | Expect on Review |
|---|---|
| **ANT GREY** 800x1600 Premium 100 | NEW holding, **photo shows (from library)**, NO identity fill needed (already in library) |
| **AGATE AZUL** 800x1600 Standard 60 | photo from library, no fill |
| **CALACATTA SYMPHONEY** 800x1600 Premium 30 | photo from library, no fill |
| **ZZ NEW MARBLE** 600x600 Premium 20 | NEW design, **No photo**, set-once already filled (Ceramic/5/20) |
| **ZZ NEW GLOSS** 600x600 Standard 15 | NEW, triggers **Map Finishes** (`high gloss`); set-once filled |
| **ZZ BAD SIZE** 999x999 | **Skipped** (invalid size) |

Checkpoints:
- [ ] On pick: **Map Finishes** lists **only `high gloss`** (the genuine mismatch). Map it → Glossy → Apply.
- [ ] Review: counts = **5 New · 1 Skipped**; the 3 library designs show a **thumbnail**, the 2 ZZ-new show **No photo**.
- [ ] No `needsFill` warning for ANT GREY/AGATE/CALACATTA (in library). Only ZZ-new ones carry identity, already filled → button enabled (**Import 5**).
- [ ] Tap **Import 5** → success toast (5 new, "3 photos from library").

## 1b. Re-import (Update path) — upload `tw_full.xlsx` again
- [ ] Same rows now show **Update** (not New); counts = **5 Update · 1 Skipped**.
- [ ] No identity fill asked (all in library now).
- [ ] Mode **Add only** → boxes add (e.g. ANT GREY 100→200); mode **Update & keep** → boxes set to file number (back to 100).

## 2. M combined — `m_combined.xlsx`  *(needs a multi-brand account)*
Brand columns must equal real brand names (fixture: BOTTEGA/CERA TILES/ENNFACE).
- [ ] CLOUD ONYX → 2 brand aliases written; Premium holding.
- [ ] PLAIN KHAKHI (chosen-brand cell blank) → **map-only** (qty 0).
- [ ] DUNE BEIGE (Premium+Standard) → **2 holdings**.

## 3. ENTRY export — `mock_entry.xlsx`
- [ ] "Which column is the brand?" auto-suggests **BoxPack** (Brand all `--`).
- [ ] Map brand values; **batch sum** (CLOUD ONYX PRE 252/STD 32; DESERT SAND PRE 168/STD 60).
- [ ] **GOLD/ECO dropped**; `800X1600 (2PCS)` → `800X1600`.

## 4. Merge / edge
- [ ] Set a free-text "note" on a design in-app → re-import → note **preserved**.
- [ ] Same name+size+quality, different surface → **separate holding**.
- [ ] Empty sheet → clean error. Cancel a map dialog → nothing saved.

---

## DB verification (Supabase, project `buxjebeeiwyrsakeucyk`)
```sql
-- our imported rows, correct values?
select name,size,quality,surface_type,box_quantity
from designs where stockist_id = '<SID>' order by created_at desc;
-- images pulled? join stock design -> library image
select d.name, d.size, (coalesce(l.image_url,'')<>'') as has_img
from designs d join stockist_library l
  on l.stockist_id=d.stockist_id and l.master_design_name=d.name
 and l.size=d.size
where d.stockist_id='<SID>';
```

## Cleanup (run once, Setup step 0) — wipe stock, keep library
```sql
-- <SID> = the test stockist id
with d as (select id from designs where stockist_id='<SID>')
  delete from stock_in        where design_id in (select id from d);
-- repeat for dispatches, my_choices, stock_adjustments, inquiry_items
delete from designs where stockist_id='<SID>';
```
