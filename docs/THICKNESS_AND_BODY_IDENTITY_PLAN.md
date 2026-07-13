# CHAPTER 3 — Thickness and Body join PRODUCT IDENTITY

**Status:** planned, not built. Decided 2026-07-13.

## Why

A 7 mm and a 12 mm tile of the same print, size and surface are **two products**. Same area
(600x1200 × 2 pcs = 15.5 sq ft either way), but a 12 mm tile carries ~70% more body — more clay,
more firing, more freight — so it sells at a **different rate**. Tiles sell **by AREA at a rate**;
weight is freight, not commerce. The rate is set by print + size + surface + **thickness** + **body**.

Today's key collapses those two tiles into one row and the thickness ends up being whatever the
first-created BOX happened to imply. **That is a silent merge of two separately-priced products** —
and it is the thing the market's software gets wrong.

Same argument for **body** (Ceramic vs Porcelain vs PGVT & GVT): a different body at the same
print/size/surface/thickness is a different tile at a different rate.

## The test (use this for any future dimension)

> A dimension belongs in **product identity** iff two of its values are things a buyer chooses
> between, can sit in the godown at the same time, at different rates, and are **not substitutes**.

| Dimension | Coexist & priced differently? | Lives on |
|---|---|---|
| print (`master_design_name`) | yes | **PRODUCT (identity)** |
| size | yes | **PRODUCT (identity)** |
| surface | yes — Glossy vs Matt | **PRODUCT (identity)** |
| **thickness** | **yes — 8 mm vs 12 mm** | **PRODUCT (identity)** ← new |
| **body / `tile_type`** | **yes — Ceramic vs Porcelain** | **PRODUCT (identity)** ← new |
| brand | no — *same tile, different sticker* | BOX |
| quality (Premium/Standard) | no — *same tile, graded* | HOLDING |

## The shape

```
PRODUCT  = stockist + print + size + surface + tile_type + nominal_thickness_mm
   └─ BOX     = product × brand    → brand's box name, pieces_per_box, box_weight_kg
        └─ HOLDING = box × quality → box_quantity
```

## 🔑 Thickness must be DECLARED, not derived

Derived thickness comes from the BOX (`weight ÷ (pieces × area × density)`), and the BOX **hangs off
the product**. A derived value in the identity key means **editing a box weight silently changes
which product it is** — colliding with another product or orphaning its holdings. Identity cannot be
recomputed by a later edit.

The live data proves the derivation is not fit to be truth:
- all **258** Porcelain 600x600 derive to *exactly* **7.99 mm** — a density artifact, not a measurement
- a **4.1 mm** 800x1600 and a **5.0 mm** 600x600 — neither tile exists
- Ceramic 300x450 derives **8.9–9.8 mm**; the trade calls that tile **8 mm**

So:
- **`nominal_thickness_mm`** — DECLARED from a fixed list, **in the identity key**, mandatory at
  creation (Library editor · import · Excel template), exactly as surface became in CHAPTER 2a.
- **`thickness_mm`** (derived) — **demoted to EVIDENCE.** The trigger stays and keeps computing it,
  but it now only *validates*: "this box's weight implies ~11 mm but the product is declared 8 mm —
  wrong weight, or a different product?"

### This supersedes two rules shipped 2026-07-13
1. ~~"thickness is ALWAYS derived by trigger, never typed"~~ → **declared**; derivation is evidence.
2. ~~"always show the 0.5 mm BAND, never a bare figure"~~ (`20b4a34`) → the band existed *only*
   because the number was derived and fuzzy. **A declared nominal is exact: show `8 mm`**, and let
   buyers filter on it exactly.

### It also dissolves the box-weight guard argument
A box whose `kg ÷ pieces` disagrees with its siblings is no longer "bad data" by definition. It is
**either a typo or a signal that this is a different product** — and the app can finally ask which,
instead of rejecting (which deadlocks: each brand's correction is blocked by the others).

## Steps

1. **`thickness_options`** admin table (like `tile_types`, so it extends without a deploy).
   **The list is 0.5 mm BANDS: `4.0–4.5` … `19.5–20.0` (32 bands).** The stored number is the band's
   **LOW EDGE**; it displays as `8.5–9.0 mm`.
   > My first seed was round "nominal" figures (`5, 6, 7, 8, …`). **The user corrected it to bands**,
   > and he is right: a real tile is **8.86 mm, not 9 mm**, so a band is what can honestly be
   > declared. It also makes the suggestion *exact* — the bands tile the range, so a derived figure
   > falls in exactly ONE band. That is not a rounding; it is the band the figure is already in.

   → new public table = revoke `anon` write ([[feedback_new_public_table_anon_grants]]).
2. `stockist_library.nominal_thickness_mm` (nullable at first — see backfill).
   `tile_type` → **NOT NULL** (already 100% populated: Porcelain 702 / PGVT & GVT 141 / Ceramic 87).
3. **Swap `stockist_library_uniq`** to
   `(stockist_id, lower(master_design_name), size, surface_type, tile_type, nominal_thickness_mm)`
   **`NULLS NOT DISTINCT`** (PG is 17.6 ✅) so two *unknown-thickness* products of the same
   print/size/surface still **collide** rather than duplicating.
   ✅ Adding columns to a unique key can only **split**, never collide — this cannot fail on the
   existing 930 rows.
4. Writers ask for thickness + body: `library_upsert_master`, `library_map_upsert`,
   `import_stock_batch`, the Library editor, the Excel template.
   → enumerate every writer from `pg_proc` first ([[feedback_find_every_writer_before_fixing]]).
   ⚠️ adding a param to an existing RPC creates an **OVERLOAD** — drop the old signature in the same
   migration ([[feedback_rpc_param_add_creates_overload]]).
5. Display + filters move to the **declared nominal**, exact (`8 mm`). Retire the band from the UI.
6. **Holding key simplifies** to `(stockist, library, brand, quality)` — `surface_type` in it is
   already redundant and thickness/body would be too, since the product implies all three.

## Backfill — DECIDED: leave blank, prompt the stockist

The 930 existing products get **`nominal_thickness_mm = NULL`**. We do **not** guess.

> A wrong value in the **identity key** is worse than a blank — it would stamp `9 mm` on the Ceramic
> 300x450 that the trade calls `8 mm`, and give all 258 Porcelain the same artifact value.

`NULLS NOT DISTINCT` keeps the key safe while they are blank. **New products must declare.** The
Library gets a **"needs thickness"** badge + filter so stockists fill their own — they are the only
source of truth.
