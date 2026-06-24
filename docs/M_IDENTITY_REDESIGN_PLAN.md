# M Identity Redesign — Plan (DDPI: Planning)

Make the **M** design identity **brand-agnostic + surface-complete** so one physical tile is **one box** across all its brands — dissolving the duplicate-master bug (#7) and enabling clean Design/Stock flows. **Scope: input → P_Stock only** (buyer-facing display out of scope, but must not break).

Decision this implements: `memory/project_addflow_redesign_ddpi.md` (M LOCKED). No code until this plan is approved.

---

## Target model (locked)
```
BOX (identity)         box_id → master_design_name + surface + size + image (+ physical attrs)
                       • box = master + surface  (master_design_name groups its surface-boxes)
                       • M: brand-agnostic (brand_id NULL)   T/W: brand-bound (brand_id = the silo brand)
BRAND-NAMES (N:M)      (box_id, brand_id, brand_design_name)   — M only; the per-brand name on the link
P_Stock                box_id + quality + quantity            — one shared holding; brand has no role inside
```

## Current schema (audited 2026-06-24)
- `stockist_library` (BOX): `master_design_name, size, image_url, surface_type ✅(already here), brand_id, ` + physical attrs (`tile_type, pieces_per_box, box_weight_kg, thickness_mm, colour, finish_label, stock_type`).
- `stockist_library_brand_names` (JUNCTION): `library_id, brand_id, brand_design_name` ✅ already the N:M.
- `designs` (P_Stock): `library_id, quality, box_quantity` + **denormalized** `name, size, surface_type`.
- `catalog_designs` (brand-list membership): `catalog_id, library_id`.

## Gap analysis (current → target)
| # | Gap | Action |
|---|-----|--------|
| 1 | `surface_type` exists on the box but is **NOT part of the identity key** (matcher keys on name+size only) | Make box identity = **(stockist_id, master_design_name, size, surface_type)** |
| 2 | `brand_id` on the box binds M identity to a brand (#7 root) | **NULL it for M** (brand→junction); **keep for T/W** (silo) |
| 3 | Holding (`designs`) carries denormalized `name/size/surface_type` | Surface (and identity) come from the **box**; holding = `box_id+quality+quantity` |
| 4 | `library_map_upsert` matches **brand-scoped, no surface** | Replace with **type-aware, surface-aware, human-confirm** matcher |
| 5 | Existing data has duplicate masters (#7) + one-surface-per-master | Migrate: split by surface, merge dups (guided) |

> **Type-aware key (the crux):** `box.brand_id` is **NULL for M** (brand-agnostic; brands via junction) and **= the silo brand for T/W** (brand IS part of identity). The matcher branches on `stockists.business_type`.

---

## Phases

### Phase 0 — Audit & worklist (read-only, no change)
- Count M masters whose `designs` holdings span **>1 surface** → these boxes must be **split**.
- Count duplicate masters (same `master_design_name+size(+surface)`, different `brand_id`, same stockist) → **merge** worklist.
- Full DB snapshot/backup before any write.

### Phase 1 — Schema (additive, non-breaking)
- No column drops yet. Add helper columns/indexes only as needed for migration.
- Defer the unique index `(stockist_id, master_design_name, size, surface_type) WHERE brand_id IS NULL` (M) until **after** dedup (Phase 2) — existing dups would violate it.

### Phase 2 — Data migration (THE HARD PART)
1. **Surface-split (M):** for each M box whose holdings span multiple surfaces, create one box per distinct `surface_type` (source of truth = `designs.surface_type`), copy box attrs + image, **re-point each holding** to its surface-box, set the box `surface_type`.
2. **Brand-agnostic merge (M):** collapse masters that are the **same box across `brand_id`** into ONE box (brand_id→NULL); move their brand rows into the junction; re-point holdings + catalog_designs.
   - ⚠️ **Cannot auto-merge by name** (same name ≠ same tile). Auto only the *provably* safe (identical image / single obvious dup); everything ambiguous goes through a **guided visual confirm** (reuse the shipped "Merge a duplicate" tool / a migration-time review screen).
3. **T/W untouched:** keep `brand_id` on T/W boxes; their trivial junction rows can be ignored/cleaned later.

### Phase 3 — Matcher RPC (replace `library_map_upsert`)
- `box_find_candidates(stockist_id, name, size, surface)` → boxes matching **name+size+surface**, **brand-agnostic for M / brand-scoped for T/W**, returns candidates **with images** for the human.
- `box_link_brand(box_id, brand_id, brand_design_name)` (M) and `box_create(...)`.
- Human-confirm in UI decides link-vs-create; RPC just executes on the chosen `box_id`.

### Phase 4 — Add-flow UI (Design vs Stock)
- "+ Add" → **Design** | **Stock** (intent split).
- **Design (M):** brand-first context → enter name + surface (+ size) → `box_find_candidates` across brands → show candidates+images → **confirm same/new** → link brand-name / create box.
- **Stock:** find the box (name search → pick surface/size) → set **quality + quantity**; brand context = which list publishes it.
- Reuse the inline search-or-create already shipped (`6fea120`) as the box-search component.

### Phase 5 — Cleanup (destructive — only after all verified on device)
- Add the M unique index (Phase 1 deferred).
- `designs`: stop writing denormalized `surface_type/name/size` (read from box); drop later.
- Keep `box.brand_id` (now NULL-for-M / set-for-T/W).

### Phase 6 — Imports (bulk reconcile) — later
- Excel/PDF importers call the new matcher with a **bulk human-confirm/reconcile screen** (per-row confirm is too heavy — this is where #7 actually bit). Design separately.

---

## Risks & safeguards
- **Identity migration is high-risk** (touches every design + every holding + the importers + buyer display reads). → snapshot first; migrate on a branch/copy; verify on device before Phase 5 drops.
- **Don't break T/W** (shares the tables) — every step gated on `business_type`; T/W path = no behavioural change.
- **Buyer-facing display reads these tables** — keep reads working throughout (additive-first, drop last).
- **Merge can't be auto** — guided visual confirm for ambiguous dups.

## Open questions to resolve before Implementation
1. T/W's trivial junction rows — drop them, or leave as harmless?
2. Imports bulk-reconcile UX — per-file review screen shape (Phase 6).
3. Do we migrate all existing M data, or apply new model **going forward** + clean historic dups gradually with the merge tool?
4. Surface vocabulary — is `surface_type` a free list, or a controlled set (affects the surface part of the identity key / dedup)?
