# BOX + derived thickness

**Status:** PLANNED — not implemented. (DDPI: Discussion + Decision done; this is Planning.)
**Chapter:** 2, part 2 — follows `PRODUCT_IDENTITY_MIGRATION_PLAN.md` (shipped).
**Decided with user:** 2026-07-13

---

## 1. The model (locked)

```
PRODUCT   stockist_library              size · name · image · surface · DNA · THICKNESS
   │ × brand
BOX       stockist_library_brand_names  brand's NAME  +  pieces/box  +  box weight
   │                                    (already keyed UNIQUE (library_id, brand_id))
   │ × quality
HOLDING   designs                       box_quantity
```

**User's rules, verbatim intent:**

- **Brands can pack differently.** The same print under Brand A and Brand B may ship 4/box and
  6/box. So `pieces_per_box` + `box_weight_kg` belong to the **BOX**, not the product.
- **Within one brand, packing does not vary — "if the packing changes, the brand also changes."**
  So the stockist should never type it per product: set it once for a `(brand, size)` and every
  product of that brand at that size **inherits** it.
  ⚠️ **But this is a PREFILL, not a constraint** — the live data already has one counterexample
  (CURA · 800x1600 has two products at 2 and 3 pieces/box). Store per box; default from (brand,
  size).
- **THICKNESS IS DERIVED, not typed:**

      thickness_mm = box_weight_kg / (pieces_per_box × area_m2 × density) × 1000

  The stockist enters **box weight + pieces/box**; thickness falls out of the tile type's density.
  **They can still override it manually per design.**
- **Thickness stays on the PRODUCT** (a Glossy and a Matt of one print each carry their own).

---

## 2. The density is REAL — derived from the live data, and it is exact

`density = box_weight / (pieces × area × thickness)` computed over the 408 products that already
have all four values:

| tile_type | products | implied density (kg/m³) | spread |
|---|---|---|---|
| **Porcelain** | 258 | **2085** | min = avg = max — **zero variance** |
| **PGVT & GVT** | 139 | **2233** | **zero variance** |
| **Ceramic** | 11 | **1677** | 1672–1689 |

Per size, the standard deviation is **0** for 800x1200, 800x1600 and 600x1200; 26 for 600x600.
This is not an approximation — it is the rule the data was built with. **Seed these three densities.**

---

## 3. What does not exist yet

**There is NO `tile_types` table.** `stockist_library.tile_type` is free text, backed by a hardcoded
Dart list (`kTileTypes`). There is a `tile_sizes` table and a `surface_types` table, but nothing for
tile type — and therefore nowhere to put a density.

**446 of 933 products have a BLANK tile_type**, so they have no density and cannot derive a
thickness:

| stockist | products | blank tile_type |
|---|---|---|
| cura (A01) | 212 | **206** |
| famous (1) | 214 | **165** |
| Gracias (A06) | 75 | **75** |
| Sri Balaji (A05) | 258 | 0 |
| saanvi (A03) | 131 | 0 |
| livok (A02) | 43 | 0 |

---

## 4. Scope

**DOES:**
1. New admin table **`tile_types`** (name, `density_kg_m3`, is_active, sort_order) — the twin of
   `surface_types` / `tile_sizes`. Seeded Porcelain 2085 · PGVT & GVT 2233 · Ceramic 1677.
2. **`pieces_per_box` + `box_weight_kg` move onto the BOX** (`stockist_library_brand_names`).
3. **Thickness becomes DERIVED** (generated or computed on write) from density + weight + pieces +
   size, with a **manual override** per product.
4. The 11 readers are re-pointed to resolve the spec through the box.
5. Library card gains an editable **box chip** (`4 pcs · 24 kg`), and a `(brand, size)` prefill.

**DOES NOT (deferred):**
- Faces · joint type · mockup/aligning/closelook/360/video → [[project_tiles_media_portfolio]].
- Renaming `stockist_library_brand_names` to `stockist_boxes`. The name is now misleading (it is
  the BOX, not just names), **but a rename breaks every function that references it by name**
  (Postgres stores function bodies as text and does NOT rewrite them on rename). Not worth the
  churn now — a table COMMENT will say what it really is.

---

## 5. Target schema

```sql
create table tile_types (
  id            uuid primary key default gen_random_uuid(),
  name          text not null unique,
  density_kg_m3 numeric not null,          -- Porcelain 2085 · PGVT & GVT 2233 · Ceramic 1677
  is_active     boolean not null default true,
  sort_order    int     not null default 0
);

alter table stockist_library_brand_names        -- ← THE BOX
  add column pieces_per_box int,
  add column box_weight_kg  numeric;

-- stockist_library keeps: thickness_mm (derived, overridable), tile_type
-- stockist_library LOSES:  pieces_per_box, box_weight_kg   (they were at the wrong level)
```

**Thickness:** keep `thickness_mm` a plain column (NOT generated — a generated column cannot be
overridden, and the user explicitly wants a manual override). Recompute it on write in
`library_set_box` / the importers; leave it alone when the stockist has set it by hand.
⚠️ Needs a `thickness_is_manual boolean` flag, or the next box edit silently overwrites their
override.

---

## 6. Migration steps (each its own file; measure before and after)

### Step 1 — `tile_types` table + seed
Seed the three densities. Then **assign a tile_type to the 446 blanks** — bulk, per stockist. This
is a data question for the user (cura/famous/Gracias), not something to guess.

### Step 2 — add the two columns to the BOX, and backfill
```sql
update stockist_library_brand_names a
   set pieces_per_box = l.pieces_per_box,
       box_weight_kg  = l.box_weight_kg
  from stockist_library l
 where l.id = a.library_id;
```
**Safe:** all 933 products already have at least one box; **0 products have specs with no box.**
A product carried under 2 brands gets the same spec copied to both boxes — correct as a starting
point, and the stockist can then differ them.

### Step 3 — fix the 1 orphan holding
**1 holding** has a `(library_id, brand_id)` with **no matching box row**. It must get one, or it
can never resolve a spec. Create the missing box (name = the product's master name).

### Step 4 — re-point the 11 readers
A holding knows its `library_id` + `brand_id` → that IS the box. Join through it.

| reader | change |
|---|---|
| view `public_designs` | `lib.pieces_per_box` → join box on `(d.library_id, d.brand_id)` |
| view `market_designs` | same |
| `my_library` | return the spec **per box**, not one per product |
| `my_stock`, `my_private_designs`, `public_catalog` | resolve via the holding's box |
| `library_upsert_master`, `admin_library_upsert`, `_library_apply_identity` | write the spec to the box |
| `import_stock_batch` | write the spec to the box (it already knows the brand) |
| `stock_add_holding` | copies the print on a surface-split — must copy the BOX rows too (it already does) |

**Per [[feedback_rpc_param_add_creates_overload]]: if any signature gains a param, DROP the old
signature in the same migration and test the caller that omits it.**

### Step 5 — drop `pieces_per_box` / `box_weight_kg` from `stockist_library`
Only after every reader is re-pointed. **Do this in a separate migration** so it can be reverted
without unwinding step 4.

### Step 6 — new RPC `library_set_box(p_library_id, p_brand_id, p_pieces, p_weight)`
Sets the box spec, **recomputes the product's thickness** from the tile type's density (unless the
stockist has overridden it), and returns the computed thickness so the UI can show it.

---

## 7. App

- **Library card: a BOX chip** — `4 pcs · 24 kg` (per brand when the product has several boxes).
  Tap → sheet: pieces + weight, **prefilled from that brand's other boxes at this size**. Shows the
  derived thickness live as they type. Same pattern as the surface chip (`5719b26`).
- **Library editor:** the pieces/weight fields move out of the product section into the per-brand
  rows (which already exist for the brand alias names). Thickness becomes read-only + an
  "override" toggle.
- **`kTileTypes`** (hardcoded Dart list) is replaced by the `tile_types` table, like sizes/surfaces.
- **Importers** already carry pieces/weight per row — they now write to the box.

---

## 8. Verification

1. Every box that had a spec on its product still has it → `count(*) filter (pieces_per_box > 0)`
   before/after must match **487**.
2. **0 holdings** whose `(library, brand)` has no box.
3. Thickness recomputed matches the stored value for the 408 products that have all four values —
   **within 0.1 mm**. (That is the real test of the density seeds.)
4. Buyer views still expose pieces/weight for every in-stock design.
5. `flutter analyze` clean (2 known infos) · 21 tests green.
6. **Device:** livok Add Stock still lands on the right product; the Library box chip round-trips.

---

## 9. Risks

- **The 446 blank tile_types have no density → no thickness.** They must be assigned before the
  derivation is meaningful. **Ask the user what cura / famous / Gracias actually are.**
- **The manual-override flag is essential.** Without it, editing a box spec silently overwrites a
  thickness the stockist typed by hand. This is the one place this chapter can lose data.
- `pieces_per_box` is NOT strictly constant within `(brand, size)` — CURA 800x1600 already has 2
  and 3. Treat the (brand,size) value as a **default**, never as a constraint.
- Step 5 (dropping the product columns) is the irreversible one. Snapshot
  `stockist_library` first.

---

## 10. Open questions — ANSWER BEFORE CODING

1. **What tile_type are cura's 206, famous's 165 and Gracias's 75 blank products?** Porcelain?
   PGVT? Per stockist, or per size?
2. **Where does `box_weight` come from for a NEW product** with no stock yet — typed by the
   stockist, or defaulted from the brand+size like pieces?
3. Should the buyer see pieces/weight **per brand** (they see a holding, which has a brand → yes,
   naturally), or the product's "default" box?
