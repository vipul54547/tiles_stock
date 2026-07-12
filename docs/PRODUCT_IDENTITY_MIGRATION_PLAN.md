# Product identity migration — surface IN, brand OUT

**Status:** PLANNED (DDPI: Discussion + Decision done, Planning here, not implemented)
**Chapter:** 2 — the foundation for the media chapter (mockup / aligning / closelook / faces / 360 / video)
**Decided with user:** 2026-07-12

---

## 1. The model (locked)

```
PRINT      the artwork                     "Ant Bianco"
  |        one print -> many products (one per surface)
PRODUCT    print x surface x size          Glossy Ant Bianco 600x600
  |                                        Matt   Ant Bianco 600x600   <- TWO products
BOX        product x brand                 pieces_per_box -> box_weight
  |
HOLDING    box x quality                   box_quantity, control_quantity
```

**Locked truths from the user:**

- **A PRODUCT is one tile piece.** It carries `size`, `master_design_name`, `image_url`,
  `surface_type` (+ `surface_label`, `finish_label`), **`thickness`**, and **DNA**.
- **Surface IS product identity.** *Glossy Ant Bianco* and *Matt Ant Bianco* are **two different
  products**, made from the same print.
- **Brand is NOT product identity.** For an M, a different brand is only a different **name** for the
  same print. Brand belongs to the **box**.
- **`pieces_per_box` and `box_weight` are NOT product properties.** A box holds N pieces; box weight
  follows from the piece count. They belong to the **box** (`product x brand`).
- **`thickness` IS a product property.** It stays.

**Why the model got muddled:** market software, and each M's own operating theory. One factory's
supervisor writes `Glossy Ant Bianco` as the name; another keeps the name `Ant Bianco` and puts
`Glossy` in a separate column. **That is data-entry variance, not truth about the tile.** We let
their paperwork shape our schema.

---

## 2. What is broken today (evidence from the live DB, 2026-07-12)

**Today's product key has surface OUT and brand IN — both backwards:**

```sql
stockist_library_uniq (stockist_id, brand_id, lower(master_design_name), size)
```

### 2a. `attribute` mode is a broken key, and `surface_mode` is the scar

```sql
-- add_inventory_batch
if v_biz = 'M' and v_mode <> 'attribute' and lower(v_surf) <> 'none' then
  update stockist_library set surface_type = v_surf, surface_label = v_label
    where id = v_lib and stockist_id = v_stk;   -- stamp surface onto the PRODUCT
end if;
```

- **`in_name` mode accidentally works.** Surface is inside the name, so `Glossy Ant Bianco` and
  `Matt Ant Bianco` are different strings -> two rows -> two products. Correct **by luck**.
- **`attribute` mode is genuinely broken.** Name is just `Ant Bianco` for both, surface sits in a
  column -> **same key -> ONE row.** Glossy and Matt collapse, and `surface_type` is overwritten by
  whichever was written last.

The `<> 'attribute'` guard is **not a design decision — it is a workaround for the broken key.**
Stamping in `attribute` mode would make the surface flip-flop, so someone disabled the stamp
instead of fixing the identity.

**`surface_mode` is not a model concept. It is a parser setting** — *where do I find the surface in
this row* — and must have no influence on where the surface lands.

### 2b. The flip-flop already happened in production

`famous` product **`1001`** (300x450) has `surface_type = 'Sugar'` on the product, but its holdings
are **Carving, GHR, Matt** — there is no Sugar holding at all. **A stale, wrong stamp, live.**

### 2c. The 6 collapsed masters — one library row that is really 2+ products

| stockist | library_id | name | size | product surface | holding surfaces | holdings |
|---|---|---|---|---|---|---|
| 1 (famous, M/attribute) | `5a5c5220…` | 1004 | 300x450 mm | *(empty)* | Carving, Sugar | 2 |
| 1 (famous, M/attribute) | `e718fb01…` | 1001 | 300x450 mm | **Sugar (stale)** | Carving, GHR, Matt | 4 |
| 1 (famous, M/attribute) | `4a2d83e3…` | 1006 | 300x450 mm | *(empty)* | Carving, Glossy | 2 |
| A01 (cura, M/in_name) | `9e8e0bb3…` | BIANCO SYDNEY | 800x1200 | Glossy | Glossy, P.Glossy, Sugar | 6 |
| A02 (livok, T) | `7678e1a4…` | DELTON_8_A | 300x450 mm | None | Carving, Matt, Sugar | 6 |
| A02 (livok, T) | `552caf15…` | 3209 | 300x450 mm | None | Carving, P.Glossy | 4 |

These are the **only real instances of the bug that exist**. They are the migration's test fixture —
**do not delete them** (user offered; declined for this reason).

### 2d. Brand on the product defeats the alias table

`stockist_library_brand_names (library_id, brand_id, brand_design_name)` already exists — *one
master, many brand names*, exactly the intended model. But `brand_id` is in the product key, which
re-splits the master by brand.

- 924 masters: **495 brand-free** (all M — `library_map_upsert` already sets `brand_id = null` for
  `business_type = 'M'`), **429 brand-stamped** (all T/W).
- 1001 alias rows exist, but **every one has `brand_design_name` = `master_design_name`** — the
  aliasing is populated but **degenerate**. Nobody has entered a genuinely different per-brand name
  yet, which is the only reason this has not bitten.

---

## 3. Scope

**This chapter DOES:**
1. Backfill `surface_type` onto the product from its holdings.
2. Split the 6 collapsed masters into one product per surface.
3. Swap the product key: **brand OUT, surface IN**.
4. Delete the `surface_mode <> 'attribute'` guard — **always** stamp surface onto the product.
5. Make brand **alias-only** on the product (`stockist_library_brand_names`) + the holding's brand.

**This chapter does NOT (deferred, in order):**
- **BOX entity** (`product x brand` -> `pieces_per_box`, `box_weight`). Next chapter.
- **Faces** — small, additive, comes straight after. See §9.
- **Joint type** (random / endless / bookmatch). User will explain separately.
- **Media** (mockup, aligning, closelook, 360, video).
- Removing `surface_type` from `designs_holding_uniq` (it becomes redundant once `library_id`
  implies the surface — but leave it; harmless and it keeps `stock_add_holding` untouched).

**CANCELLED — do NOT build:**
- **The PRINT layer as a table.** User decided **2026-07-12: DNA is tagged per PRODUCT, not per
  print.** Tagging "Ant Bianco" does **not** propagate to both Glossy and Matt — each product is
  tagged on its own. So *print* stays what it already is: a **name we group by** (`family_key`),
  never a table. Step 3 therefore **copies** DNA to each split product, which is correct and final.
- Consequence: a stockist tags Glossy and Matt separately. **This is the status quo, not new work** —
  under `in_name` naming they are already two library rows today. Only `attribute`-mode M (famous)
  newly splits, and that stockist is currently *broken* anyway (see §2b).

**Buyer-visible change: NONE.** Buyers read holdings; holdings keep brand and surface.

---

## 4. Target schema

```sql
-- PRODUCT: brand-free, surface-bearing
stockist_library_uniq (stockist_id, lower(master_design_name), size, surface_type)

-- HOLDING: unchanged
designs_holding_uniq  (stockist_id, library_id, brand_id, quality, surface_type)
```

`stockist_library.brand_id` — **keep the column, drop it from the key.** It degrades to a
"first-seen / default brand" hint. Dropping the column outright is more churn for no gain now, and
the Box chapter will decide its fate properly.

**`surface_type` must be NOT NULL, default `'None'`** — a nullable column in a unique key is exactly
how Glossy and Matt collapsed. (`NULLS NOT DISTINCT` is already used on `designs_holding_uniq`;
match that or normalise nulls to `'None'`. Prefer normalising — explicit beats clever.)

---

## 5. Migration steps

Every step is one migration file in `supabase/migrations/`. **Measure before and after each.**

### Step 1 — normalise
```sql
update stockist_library set surface_type = 'None'
 where nullif(btrim(coalesce(surface_type,'')),'') is null;
```
Affects **735 empty + already-'None'** rows -> all become `'None'`.

### Step 2 — backfill surface from the single-surface holdings
```sql
update stockist_library l
   set surface_type  = h.sf,
       surface_label = coalesce(h.lbl, l.surface_label),
       updated_at    = now()
  from (
    select d.library_id, min(d.surface_type) as sf, min(d.surface_label) as lbl
    from designs d
    group by d.library_id
    having count(distinct d.surface_type) = 1
  ) h
 where l.id = h.library_id;
```
**44 products** get their true surface. (874 have **no holdings at all** — surface stays `'None'`
until stock or an edit supplies it. That is honest: we do not know it.)

### Step 3 — split the 6 collapsed masters
For each `library_id` whose holdings span >1 surface:
1. Pick the **keeper surface** = the surface with the most holdings (ties -> lowest
   `surface_types.sort_order`). Set the existing row's `surface_type` to it. **Discard any stale
   stamp** (e.g. `1001`'s bogus `Sugar`).
2. For every **other** surface, `insert` a new `stockist_library` row copying **all** product
   attributes: `master_design_name`, `size`, `image_url`, `thickness_mm`, `thickness_band`,
   `pieces_per_box`, `box_weight_kg`, `colour`, `tile_type`, `stock_type`, `finish_label`,
   `brand_id`, `is_sample` — with that surface.
3. **Carry the child rows to each new product** (same artwork -> same character):
   - `library_dna`      (DNA tags)  -> **copy**
   - `stockist_library_brand_names` (aliases) -> **copy**
   - `library_family_overrides`     (family_key) -> **copy**
4. **Re-point holdings:** `update designs set library_id = <product for that surface>` matching on
   `designs.surface_type`.
5. Assert: every holding's `surface_type` == its product's `surface_type`.

Expected: **6 masters -> 6 + 9 = 15 products** (2+4+2+... see the table; count exactly at run time).

### Step 4 — swap the key
```sql
drop index stockist_library_uniq;
create unique index stockist_library_uniq
  on stockist_library (stockist_id, lower(master_design_name), size, surface_type);
```
**Verified: 0 collisions, 0 rows lost** against the current 924 rows (measured 2026-07-12, before
the split — re-measure after Steps 1-3).

### Step 5 — the 8 writer functions
Every function that writes `stockist_library` must look the product up on the **new key** and stop
keying on brand:

| function | change |
|---|---|
| `add_inventory_batch` | **delete the `v_mode <> 'attribute'` guard** — always stamp surface. |
| `library_map_upsert` | drop the M / non-M brand branching; look up by `(stockist, lower(name), size, surface)`. Keep writing aliases. |
| `library_contribute` | stop keying on `brand_id`; take a surface. |
| `admin_library_upsert` | drop `brand_id is not distinct from p_brand_id` from the lookup; key on surface. |
| `library_upsert_master` | key on surface, not brand. |
| `import_stock_batch` | match on `(name, size, surface)`; brand column -> alias name + holding brand. |
| `_library_apply_identity` | no key change (updates by `p_library_id`) — **verify only**. |
| `library_merge_masters` | must refuse to merge across **different surfaces** (they are different products now). |
| `library_image_for` | brand-keyed lookup -> fall back to brand-free. |

**Per [[feedback_rpc_param_add_creates_overload]]: if any signature gains a param, DROP the old
signature in the same migration, and test the caller that omits it.**

### Step 6 — app
- **Importers** (Excel + PDF) are the heaviest users: they match on `brand + name + size` -> must
  match on `name + size + surface`, with the brand column feeding the **alias name** and the
  **holding's** brand.
- **Library screen**: a print now appears once **per surface**, not once per brand. Brand names show
  as aliases.
- **Add Stock / Add Design**: pick product (which now carries the surface), then brand -> brand
  chooses the *holding*, not a new library row.
- `surface_mode` UI: relabel as a **parser/import setting**, not an identity switch.

---

## 6. Verification

Run against live data (read-only; use the `DO $$ ... RAISE EXCEPTION 'RESULT >> %'` rollback trick
from [[reference_live_db_access]] to measure a trial write without committing).

1. `select count(*) from stockist_library` -> **924 + 9 = 933** (re-count at run time).
2. **0 rows** where a holding's `surface_type` <> its product's `surface_type`.
3. **0 groups** violating the new key.
4. The **6 named masters** each come out as one product per surface, holdings pointed correctly.
   Spot-check `DELTON_8_A` (livok) — it is also the `holding_entry_bar` test fixture.
5. `famous 1001` no longer carries the stale `Sugar`.
6. **DNA survived the split**: each new product has the same `library_dna` tags as its parent.
7. `flutter analyze` clean (2 known pre-existing infos).
8. `flutter test` — 21 green, incl. `holding_entry_bar` (which pins `DELTON_8_A`).
9. **Device**: Add Stock on livok (T, multi-surface) and famous (M, attribute) — the case that was
   broken.

---

## 7. Risks

- **`holding_entry_bar_test` pins `DELTON_8_A`**, one of the 6 split targets. The split changes how
  many library rows that print has. **Expect this test to need updating — that is the point**, and
  it is the cheapest possible early warning that the split worked.
- **`family_key` is derived from `master_design_name`.** Splitting by surface does NOT change names,
  so families are unaffected. Confirm `_family_members` still groups on `(stockist, size,
  family_key)` — it does not look at surface, so a Glossy and a Matt of one print will now appear as
  two family members of the same family. **Flag to user: is that wanted?** (Probably yes — they are
  genuinely two products.)
- **874 products have no holdings**, so their surface stays `'None'`. They are not wrong, just
  unknown. Sri Balaji (258), saanvi (131), Gracias (75) are entirely in this bucket.
- Rollback: each step is a separate migration. Steps 1-3 are data; Step 4 is the index. Keep a
  `create table stockist_library_pre_split as select * from stockist_library;` snapshot before
  Step 3.

---

## 8. Decisions taken (2026-07-12)

1. **DNA is per PRODUCT.** Tagging "Ant Bianco" does NOT propagate to Glossy + Matt. -> **No PRINT
   table, ever.** See §3 CANCELLED.
2. **Faces** — see §9. Deliberately minimal; the user does not yet know what stockists will supply.

**Still open (does not block this chapter):**
- Should a Glossy and a Matt of one print show as two **family** members? (see §7 Risks.) They *are*
  two products, so probably yes — but it is a visible change in the family strip.
- **Joint type** (random / endless / bookmatch) — user will explain. Likely a DNA attribute (admin
  canonical values + stockist words), which needs no new machinery.

---

## 9. Faces — the NEXT chapter (small, additive, do it right after this one)

**The user's model, verbatim intent:** a stockist may hand us **one image containing 2/3/4 prints**
of "Ant Bianco" side by side, **or** separate images per face. **We cannot split a combined image,
and we should not try.** We do not yet know which stockists will do which. So: **store what we are
given, and record how many faces there are.** Nothing clever.

```sql
alter table stockist_library
  add column face_count      int    not null default 0,   -- 2, 3, 4...  0 = unknown / single
  add column face_image_urls text[] not null default '{}'; -- 1..N images
```

- `face_count = 4`, **1** image  -> that one image shows all 4 faces. Show it whole.
- `face_count = 4`, **4** images -> one per face. Show them individually.
- Anything else -> just show what exists. **The face count is a fact about the design; the images are
  whatever the stockist gave us.** Do not infer one from the other.

**The pipe is already laid.** `public_designs.face_image_urls` **already exists as `text[]`** — but
it is a **stub**:

```sql
CASE WHEN lib.image_url IS NOT NULL
     THEN ARRAY[lib.image_url]     -- one element: the design's OWN swatch
     ELSE '{}' END AS face_image_urls
```

So the buyer-facing column is named for faces and carries a single swatch. Making it real is a
**one-line view change**: return `lib.face_image_urls`, falling back to `ARRAY[lib.image_url]` when
empty. Same for `market_designs`.

**Faces are per PRODUCT** (consistent with the DNA decision) — Glossy and Matt each carry their own
face images, which is also physically right: a glossy face and a matt face photograph differently.

**Honest disclosure to the buyer:** the box's face distribution is **not guaranteed** — you do not
know which faces you get until you open it. The UI should say "4 faces" and never imply a promise
about what is in a given box.
