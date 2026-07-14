# PACKING → BOX → HOLD — the plan

**Decided 14 Jul 2026, with Vipul.** His words, and they are the whole plan:

> *"how many box you have is not 'packing' — its hold only. packing is different: how many pieces
> contain and what is weight, its call 'packing'. after that when we put corrugated cover on this
> its call 'box'. if we cover Famous cover than Brand is 'Famous', if we give Anuj cover than its
> 'Anuj' brand."*
>
> *"it will be different number of pieces in packing depend upon stockist, his market and market
> move."*

Scope: **M_Stockist, `attribute` on** (famous ceramic) — Part-1. Nothing here branches on stockist
type; that is just which case we make work first.

---

## 1. THE CHAIN

| | what it is | what it carries |
|---|---|---|
| 🖼️ **ARTWORK** (`print_master`) | the print — **stored ONCE** | name · size · one photo · **image DNA** |
| 🧱 **TILE** (`stockist_library`) | **one piece you can hold** | artwork · surface · body · **thickness** |
| 📦 **PACKING** (`packings`) *new* | how the pieces are packed | **pieces · weight** — **NO BRAND**; a tile may have **several** |
| 🎁 **BOX** (`boxes`) | a packing in a brand's **corrugated cover** | **brand** · the name stamped on that cover |
| 🔢 **HOLD** (`designs`) | **how many boxes you have** | quantity · quality |

**The packing has no brand.** He packs 5 pieces at 10.5 kg — that is the packing. Wrap a FAMOUS
cover round it and it is a FAMOUS box; wrap an ANUJ cover and it is an ANUJ box. **Same packing,
different cover.**

### What this corrects
The old rule said *"one print under two brands packs two ways, independently"*, so pieces + weight
lived on the **box**, per brand. **That is not how a factory works.** It packs once and covers it
differently. Pieces + weight therefore move **off the brand entirely**.

🔑 **This is also why the folder import must not ask for a brand.** The thickness comes from the
PACKING, and the packing is brand-free. The brand enters only at the cover.

---

## 2. ONE TILE — the fields he locked

**Compulsory (identity). Change any one and it is a different tile:**

    artwork (print_id) · surface · body · thickness

**Thickness is DERIVED and never typed** — `weight / (pieces × area × density)`, density from the
**body**. It comes from a PACKING.

**Its own description (optional):**

| | |
|---|---|
| **Punch ▸ Punch Type** | Punch Type becomes **FREE TEXT** |
| **Application** | value list, as today |
| **Series** | **FREE TEXT**, set by the M, **defaults to `Regular`** |

### 🚫 Use Type and Behaviour Type are **DERIVED — never entered, never stored**

**ANSWERED 14 Jul.** His words: *"use type and behaviour type we will not come from anywhere, we
will define condition and we will show this both field by condition — so do not worry about this
both."*

- **Nobody types them.** They are **not** tile fields, **not** DNA to be tagged, and **not** import
  columns. There is **no picker** for them anywhere.
- They are **worked out by CONDITION** from what the tile already knows — surface · body ·
  thickness · size — and **shown by condition**.
- **The rules are not defined yet.** Until he gives them, **build nothing.** Do not invent a
  mapping (a guessed rule in a displayed field is the same disease as a guessed surface).
- 🗑️ Their `dna_attributes` rows are therefore dead weight for tagging. **Leave the rows alone**
  (deactivating them is a separate decision) — just never offer them in an editor or an importer.

---

## 3. TWO CONSEQUENCES THAT DRIVE THE SCHEMA

### 3a. A tile's packings must all agree on the thickness
5 pieces at 10.5 kg and 4 pieces at 8.4 kg are both **2.1 kg a piece** — same tile, two packings,
**one thickness**. So:

> **A new packing whose derived thickness is more than 1 mm from the tile's is NOT a new packing —
> it is a DIFFERENT TILE.**

The packing is where the fork gets caught. (Box weight drifts in the trade — a 600x1200 2-piece box
went 28 kg → 26 kg, which is 0.62 mm. That is the SAME tile. Hence 1 mm, not a band edge.)

### 3b. STOCK MUST BE COUNTED PER BOX
Ten boxes of a 5-piece packing and ten boxes of a 4-piece packing are **not the same amount of
tile**. A HOLD that points at a *tile* cannot tell you the square footage.

> **`designs.box_id` → the BOX.** The box carries its packing; the packing carries the pieces.

This is the biggest change in the plan and it touches every stock, dispatch and catalog reader.

---

## 4. THE SCHEMA

### New: `packings` — brand-free
```
packings
  id            uuid pk
  library_id    uuid not null → stockist_library (the TILE)   on delete cascade
  pieces        int  not null check (pieces > 0)
  weight_kg     numeric not null check (weight_kg > 0)
  created_at    timestamptz not null default now()
  unique (library_id, pieces, weight_kg)
```
The FIRST packing of a tile sets `stockist_library.thickness_mm` (the reference). Every later one
must land within **1 mm** of it or be **REFUSED** — it belongs to a different tile.

### Reshaped: `boxes` — was `stockist_library_brand_names`
```
boxes
  id                 uuid pk
  packing_id         uuid not null → packings         on delete cascade
  brand_id           uuid not null → brands
  brand_design_name  text not null      -- the name stamped on THAT brand's cover
  unique (packing_id, brand_id)
```
🚫 **`pieces_per_box` and `box_weight_kg` LEAVE this table.** They were never the brand's.
⚠️ `brand_design_name` is the **factory's word on the cover** (`1001` on FAMOUS, `601001` on ANUJ).
It is **NOT** the print name and **must never be defaulted from a filename** — that forgery is what
`20260714e` removed from the folder import.

### Changed: `designs` (the HOLD)
```
designs
  box_id     uuid not null → boxes      -- REPLACES library_id + brand_id
  quality    text
  box_quantity int
  unique (stockist_id, box_id, quality)  -- replaces designs_holding_uniq
```
`library_id`, `brand_id`, `surface_type`, `name`, `size` on `designs` become **derivable** (box →
packing → tile → print) and are dropped once their readers move.

### Unchanged
`stockist_library` keeps `print_id · surface_type · tile_type · thickness_mm · thickness_band` and
both identity constraints (`stockist_library_thickness_apart` EXCLUDE, `stockist_library_uniq_no_thickness`).

---

## 5. BUILD ORDER

Nothing here is a data migration — **the DB is EMPTY** (clean slate, 14 Jul). This is a rebuild, and
that is worth a lot: no backfill, no reconciliation, no guessing at old rows.

| # | step | notes |
|---|---|---|
| ~~1~~ | ✅ **DONE** `packings` + `packing_add` | derives thickness; **REFUSES a packing >1 mm off the tile's** |
| ~~2~~ | ✅ **DONE** pieces/weight leave the brand; `boxes` = packing × cover | the NAME stays per (tile, brand) — a brand prints one word on every cover |
| ~~3~~ | ✅ **DONE** `designs.box_id` | `library_id`/`brand_id` are now **trigger-maintained MIRRORS** of it — 40 readers untouched. ⚠️ **NEVER write them by hand.** |
| ~~4~~ | ✅ **DONE** Punch Type + Series free text; Series defaults to `Regular` | Use Type / Behaviour Type **deactivated** — no picker, no import column |
| ~~5~~ | ✅ **DONE** folder import asks **body + pieces + weight**, no brand | artwork + tile + its PACKING; the thickness falls out. Writes NO box. |
| **6** | Library: add a packing · put a brand's cover on a packing (the stamped name) | replaces "Set box packing" |
| **7** | Add Stock picks a **BOX** (tile + packing + cover), not a tile + brand | the picker must show the packing — 10 boxes of 5 ≠ 10 boxes of 4 |

### Readers that must move in step 3 (from `pg_proc`)
`_box_pieces` · `_box_weight` · `_derive_thickness` · `_library_apply_identity` · `my_library` ·
`my_stock` · `my_private_designs` · `import_stock_batch` · `library_for_box` · `library_set_box` ·
`library_set_box_for_size` · `library_upsert_master` · `admin_library_upsert` · `public_catalog`
· `stock_add_holding` · `add_inventory_batch` — plus both public views.

⚠️ **Sweep `pg_proc` again before starting each step.** Dropping a column out from under a reader
has already emptied every Library once (`1b47acd`).

---

## 6. WHAT MUST NOT COME BACK

- 🚫 **No brand in the folder import.** The packing is brand-free; the artwork and the tile are too.
- 🚫 **No thickness field, ever.** It derives from the packing.
- 🚫 **No filename in `brand_design_name`.** That is the factory's word on the cover, not his word
  for the artwork.
- 🚫 **Nothing guesses a surface, a body, or a name.** Blank stays blank and says so.
- 🚫 **No stock path may create a tile** — the law from `20260714b` / `20260714c` still holds.
- 🚫 **No field, picker or import column for Use Type / Behaviour Type.** They are DERIVED by
  condition. Until he gives the rules, they do not exist in the UI at all.

Related: `CLAUDE.md` (vocabulary — **must be rewritten when step 3 lands**) ·
`docs/PRODUCT_IDENTITY_MIGRATION_PLAN.md` · `docs/THICKNESS_AND_BODY_IDENTITY_PLAN.md`
