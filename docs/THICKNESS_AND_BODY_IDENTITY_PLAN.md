# CHAPTER 3 — Thickness and Body join PRODUCT IDENTITY

**Status:** BUILT 2026-07-13 (`8367461` · `b54a854` · `209e804` · the derived-thickness correction).

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
PRODUCT  = stockist + print + size + surface + tile_type + thickness_band  (DERIVED)
   └─ BOX     = product × brand    → brand's box name, pieces_per_box, box_weight_kg
        └─ HOLDING = box × quality → box_quantity
```

## 🔑 Thickness is DERIVED — and there is NO picker

**Corrected 2026-07-13 by the user, after I got it wrong.** I built a thickness picker. That was a
mistake, and the reasoning is worth keeping:

> A stockist reads **PIECES** and **BOX WEIGHT** off the box. They do **not** know "8.5–9.0 mm".
> Asking them to pick a thickness invites a **guess into the identity key** — the exact thing this
> chapter exists to prevent. **The BOX is the source of truth for thickness.**

I had kept the picker because a derived value in the identity key means **editing a box weight
changes which product it is**. But that is the CORRECT behaviour, not a bug: if the weight changes,
either the tile really is different or the weight was wrong — and both must move the product. A
declared value would merely have let a wrong one persist, unchallenged.

So:
- `thickness_mm` — derived by trigger from the BOX. NULL until there is a box spec.
- `thickness_band` — its 0.5 mm band (**4.0–4.5 … 19.5–20.0**, stored as the band's LOW EDGE), a
  **GENERATED** column. **This is the identity component.** Outside 4–20 mm → NULL (a bad box
  weight, not a thin tile).
- `nominal_thickness_mm` and the `thickness_options` table: **deleted.** No second source of truth,
  nothing for a human to get wrong.

### Add-design asks for the three facts that are ON the box
A new design has no box, so it would have no thickness and no complete identity. Add-design
therefore collects **tile type + box weight + pieces**, and the thickness falls out at once (the
form shows it live). Those two box facts are used **on CREATE only** — they seed the product's
first box. On EDIT they are hidden: by then several brands may pack the print differently, and the
per-brand **BOX CHIP** owns them.

### Consequence to accept
A box edit can move a product into another band and thus **change its identity**. If that lands it
on top of an existing product, `library_set_box` raises a plain-English error instead of a raw
23505.

## What was built

1. **Identity key** —
   `(stockist_id, lower(master_design_name), size, surface_type, tile_type, thickness_band)`
   **`NULLS NOT DISTINCT`** (PG 17.6), so two products with no box yet — hence no band — still
   **collide** rather than quietly duplicating.
   ✅ Adding columns to a unique key can only **split**, never collide, so the swap could not fail
   on the existing 930 rows.
2. **`thickness_band`** — GENERATED from `thickness_mm`, itself derived by trigger from the BOX.
   NULL outside 4–20 mm.
3. **`tile_type`** — declared (it supplies the DENSITY the derivation needs, and it *is* a fact the
   stockist knows). Nullable: **declared, or honestly blank.**
   ⚠️ Making it `NOT NULL` broke every import (`library_map_upsert` inserts without one) and bought
   nothing, since `NULLS NOT DISTINCT` already protects blanks. Its `DEFAULT ''` had to go too —
   `''` was the OLD "unknown" and would have defeated the NULL key.
4. **Writers** — `library_upsert_master` (uses pieces/weight on CREATE only, to seed the first box),
   `library_map_upsert` (ADOPTS an undeclared row's `tile_type` rather than duplicating it),
   `import_stock_batch`. No thickness parameter anywhere.
   ⚠️ Changing an RPC's params creates an **OVERLOAD** — the old signature was dropped in the same
   migration ([[feedback_rpc_param_add_creates_overload]]).
5. **No thickness UI anywhere** — not in the editor, not in the Excel template, not in the importer.

## The 930 legacy products

They keep whatever band their box implies; **485 already have one**, 445 have no box spec and so
have no band. Nothing was guessed, and nothing needed to be: the band is derived, so it fills itself
in the moment a box gets its pieces and weight.
