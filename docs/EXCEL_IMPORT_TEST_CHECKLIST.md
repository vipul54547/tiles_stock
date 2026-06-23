# Excel Import — On-Device Test Checklist

Manual checklist for the Excel stock-import path. The headless parts (template
generation: columns, colours, dropdowns, legend, free-text exclusion) are already
covered by `test/excel_template_smoke_test.dart`. Everything below needs the real
app (file picker + Supabase) and is verified by hand.

**Fixtures:** `docs/templates/test_fixtures/` — `tw_filled.xlsx`,
`m_combined.xlsx`, `mock_entry.xlsx` (regenerate with
`python tool/make_test_fixtures.py`).

**Open the screen:** Stockist Dashboard → Upload → the Excel/spreadsheet option
→ route `/stockist/stock/import-excel`.

**Pre-reqs for fixtures:**
- T/W tests: a single-brand stockist whose admin config has sizes `800x1600 /
  600x1200 / 600x600`, finishes incl. `Matt / Glossy`, colours `White / Blue /
  Beige`, Look `Marble / Wood`.
- M tests: a multi-brand stockist with brands named exactly **BOTTEGA**,
  **CERA TILES**, **ENNFACE** (else rename the brand columns in the fixture).
- "Existing vs new" depends on what's already in that stockist's library.

---

## 1. Template generation (download)
- [ ] **T/W**: tap **Download blank template** → opens in Excel/Sheets.
  - [ ] Columns in order: `Design Name · Size · Quality · Box Qty` (navy) then
        `Surface · Tile Type · Pieces/Box · Weight (kg) · <DNA…>` (grey).
  - [ ] **No** brand column.
  - [ ] Dropdowns on Size / Quality / Surface / Tile Type / DNA chips.
  - [ ] Header row frozen; colour legend on the `Lists` sheet.
  - [ ] Free-text DNA (e.g. Range) is **not** a column.
- [ ] **M** (multi-brand): download → `Master Design` (navy) · one **purple**
      column per brand · `Size · Premium · Standard` (navy) · grey set-once block.
  - [ ] Dropdown values reflect **this** stockist's real sizes/finishes/DNA.

## 2. T/W round-trip — upload `tw_filled.xlsx`
- [ ] **Statuario Gold** (set-once block blank): if the design exists → only
      **Box Qty updates**, photo reused, no map dialogs. If new → see row 4 below.
- [ ] **Carrara Blue** (new, exact dropdown values): imports as **new** with
      **no** Map Finishes / Map DNA dialog.
- [ ] **Onyx Storm** (`glossy finish`): **Map Finishes** dialog appears → map to
      an admin finish → applies; re-import same wording → **no** dialog (alias
      learned).
- [ ] **Wood Teak** (colour `Walnut`): **Map DNA** dialog appears → align to a
      colour → learns alias; re-import → not re-asked.
- [ ] **Bad Size** (`999x999`): row flagged invalid, **excluded** from import;
      per-cell edit to a valid size re-resolves the tag live.
- [ ] **Weight regression**: a row with `Weight (kg)` filled → box weight is
      actually stored and thickness estimated (NOT silently dropped).

## 3. M round-trip — upload `m_combined.xlsx`
- [ ] **CLOUD ONYX**: imports under the chosen brand; both brand names
      (Bottega Cloud / Cera Onyx) written to the Library; one **Premium** holding.
- [ ] **PLAIN KHAKHI** uploaded under **BOTTEGA** (its BOTTEGA cell is blank):
      becomes **map-only** — Library mapping, **qty 0**, no stock line.
- [ ] **DUNE BEIGE** (Premium 100 + Standard 50): fans into **two holdings**, one
      per quality.
- [ ] Summary toast shows updated / new / mapped counts that match the above.

## 4. ENTRY export — upload `mock_entry.xlsx`
- [ ] **"Which column is the brand?"** prompt appears and auto-suggests
      **BoxPack** (because `Brand` is all `--`); accept it.
- [ ] Brand-value map step lists BOTTEGA / PLAIN KHAKHI / CERA TILES / ENNFACE →
      map each to a brand.
- [ ] **Batch sum**: CLOUD ONYX → Premium **252**, Standard **32** (one holding,
      not two rows); DESERT SAND → Premium **168**, Standard **60**.
- [ ] **GOLD / ECO** columns are **ignored** (no extra qualities created).
- [ ] Size `800X1600 (2PCS)` imported as **`800X1600`** (note stripped).
- [ ] `Category` (GLOSSY / MATT) flows into Surface (via Map Finishes if needed).

## 5. Re-import / merge semantics
- [ ] Re-upload the same file in **add** mode → quantities add; in
      **replace_keep** mode → behaves per the mode (no double-count on retry).
- [ ] DNA **not clobbered**: set a free-text "note" in the app, then re-import the
      same design via Excel → the note is **preserved**.
- [ ] Same Name+Size+Quality but a **different Surface** → a **separate** holding,
      not flagged as a conflict.

## 6. Edge / negative
- [ ] Empty sheet (header only) → clean "no data rows" message, no crash.
- [ ] New design missing Tile Type / Pieces / Weight → **Save blocked**
      (`needsFill`) until filled or the row is excluded.
- [ ] Cancelling a Map Finishes / Map DNA dialog aborts the import (nothing saved).

---

### Found a problem?
Note the **fixture + row + what you saw vs expected** and report it — the
single-file, atomic importer rolls the whole batch back on any failure, so a
partial save shouldn't happen; if it does, that's a bug to flag.
