# tiles_stock

Flutter app (Android / iOS / web / Windows) for tile stockists to publish stock and for
buyers to browse it. Backend is Supabase. ~134 Dart files under `lib/`.

## Commands

```bash
flutter analyze                 # expect 1 pre-existing info in stockist_dashboard_screen.dart
flutter run
flutter build web               # then: netlify deploy --prod   (site curious-druid-1cbbfb → tilesdesign.in)
flutter build apk --release     # package in.tilesdesign.stock
flutter build windows --release # build\windows\x64\runner\Release\ — check data\app.so, the .exe timestamp never changes
```

## Layout

- `lib/app.dart` — all `go_router` routes. Public deep links: `/s/:token` (stockist catalog),
  `/d/:token` (dispatch receipt). Both are login-free and read-only.
- `lib/screens/{admin,stockist,end_user}/` — one directory per role (`UserRole` in
  `services/auth_service.dart`). Loose files in `screens/` are shared/public.
- `lib/services/` — `data_service.dart` is the abstract interface;
  `supabase_data_service.dart` is the only real implementation.
- `lib/models/`, `lib/widgets/`, `lib/utils/` — plain Dart, no Supabase imports.
- `supabase/migrations/` — every schema change is a timestamped `.sql` file here.
- `docs/` — plans and test checklists. Start with `PROJECT_VISION_AND_PLAN.md`.

## Data layer

All reads and writes go through **Postgres RPCs**, not table queries — `supabase_data_service.dart`
has ~160 `.rpc(...)` calls. Adding a feature almost always means: write the SQL function, add a
migration file, then add one method to `SupabaseDataService`.

RPCs are named by audience: `admin_*` (admin only), `my_*` (the signed-in stockist's own data),
`public_*` (anonymous buyers). Match that prefix when you add one.

**Before writing any DB code, read the current function definitions from the live schema.**
Don't infer a function's signature from its call site.

## Vocabulary (these are load-bearing — the DB uses them)

### The layering: PRODUCT → (BOX) → HOLDING

- **PRODUCT** = `stockist_library` — the tile itself, one piece. **This is what "a design" means.**
  Its identity is the `stockist_library_uniq` index:

      (stockist_id, lower(master_design_name), size, surface_type,
       tile_type, nominal_thickness_mm)   NULLS NOT DISTINCT

  It carries `image_url`, `surface_type` + `surface_label`, `colour`, and its **DNA tags**
  (via `library_id`). Faces/closelook/mockup all hang here.
- 🔑 **The test for identity:** a dimension is in the key **iff two of its values are things a buyer
  chooses between, can sit in the godown together, at different rates, and are not substitutes.**
  Tiles sell **BY AREA AT A RATE** (₹/sq ft) — weight is freight, not commerce. So an 8 mm and a
  12 mm of one print cover the same sq ft but sell at **different rates** → **two products**. Same
  for body. **Brand FAILS the test** (same tile, different sticker → BOX). **Quality FAILS it**
  (same tile, graded → HOLDING).
- ⚠️ **`tile_type` and `nominal_thickness_mm` are DECLARED, or honestly NULL — never guessed.**
  `NULLS NOT DISTINCT` is what keeps the key safe while they are blank: two *unknown* products of
  one print/size/surface still **collide** instead of duplicating. (The 930 rows that predate this
  carry NULL. A wrong value in the identity key is worse than a blank.) `tile_type` must not carry
  a `''` default — `''` was the OLD "unknown" and would defeat the NULL key.
- **HOLDING** = `designs` — **quantity on hand, NOT the design.** `designs_holding_uniq` is
  `(stockist, library, brand, quality, surface_type)`. It carries `box_quantity`,
  `control_quantity`, `quality`, `status`. One product → many holdings.
- ⚠️ **The table named `designs` is STOCK.** The word "design" is overloaded in this codebase:
  `TileDesign`, `addDesign()` (really `stock_add_holding`), `deleteDesign()` all operate on the
  **holding**. When it matters, say **product** or **holding**, never bare "design".
- **BOX** = `stockist_library_brand_names` (`product × brand`) — **BUILT.** It carries the name
  stamped on that brand's box (`brand_design_name`) plus **how that brand packs it**
  (`pieces_per_box`, `box_weight_kg`). One print under two brands packs two ways, independently.
  `library_set_box` is the **only** writer of the packing.
- 📏 **THICKNESS — two columns, do not confuse them:**
  - **`nominal_thickness_mm` — DECLARED**, from the fixed `thickness_options` list. **This is
    IDENTITY and this is the truth.** The list is **0.5 mm BANDS** — `4.0–4.5` … `19.5–20.0` (32).
    The stored number is the band's **LOW EDGE**; display it as **`8.5–9.0 mm`**. A band, not a
    round figure, because a real tile is **8.86 mm, not 9 mm**. One number per band keeps it a
    clean key — `8` and `8.0` can never become two products.
  - **`thickness_mm` — DERIVED** from the BOX by trigger (`weight / (pieces × area × density)`).
    **EVIDENCE ONLY** — it validates the declaration and warns on mismatch. **It is NOT identity.**
    Unknown is `NULL`, never `0` (a tile is never 0 mm thick).
  - 🔑 **Why declared, not derived:** the BOX hangs off the PRODUCT, so a derived value in the
    identity key would mean **editing a box weight silently changes which product it is**.
  - 💡 The app **PROPOSES** the band from pieces + box weight + body (`thicknessBandFor`) so the
    stockist confirms rather than enters the same fact twice — but it **never stores it silently**,
    and it proposes **nothing** outside 4–20 mm (that is a bad box weight, not a thin tile).
  - ⚠️ **SUPERSEDED:** ~~"thickness is always derived, never typed"~~ — it is **declared**.
- ⚠️ A product with **no box spec** resolves `pieces_per_box` / `box_weight_kg` to **NULL**
  (`_box_pieces` / `_box_weight`). Dart lands those on **`0`**, which every display site already
  reads as "unknown" and hides. Parse defensively — a bare `json['pieces_per_box']` crashes.

### Surface and brand

- **surface** — never "glaze". Both `surface_label` (the stockist's own word, e.g. "Raindrop") and
  `surface_type` (admin canonical, e.g. "Sugar"). Cards read `Raindrop (Sugar)`. Filters split by
  audience: stockist UI and the `/s/` link filter on the **word**; the buyer app (many stockists)
  filters on the **canonical**. `surface_label` is **display-only, never a key** — keying a lookup
  on it wedges Add Stock against the index.
- 🔑 **Surface IS product identity.** *Glossy Ant Bianco* and *Matt Ant Bianco* are **two products**,
  made from one print. `surface_type` is `NOT NULL`.
- 🚫 **There is no `'None'` surface.** A tile always has a surface; `'None'` was never one — it was
  *"we don't know yet"* wearing a surface's clothes, and since surface is in the product key it
  spawned a phantom product beside the real one. **Surface is mandatory when a product is created**
  (Library editor + import). Never write `'None'`, never offer it in a picker.
- 🔑 **Stock entry asks for a surface ONLY when `surface_mode = 'attribute'`** (rare). Otherwise the
  field is not shown at all: the product already knows its surface and **the stock inherits it**
  (`stock_add_holding` with no surface = "use the product's own"). Asking a surface at Add Stock is
  really asking **which product** — and that is only a question for an `attribute` stockist, whose
  one stamped name covers several surfaces. See `currentStockistAsksSurface`.
- 🔑 **Brand is NOT product identity.** For an M, a different brand is only a different **NAME** for
  the same print. Brand belongs to the **box**; identity is brand-free. `stockist_library.brand_id`
  survives as a *default/first-seen hint only*. A product's brand names live in
  `stockist_library_brand_names (library_id, brand_id, brand_design_name)`, and **stock is still
  per-brand** (`designs.brand_id`). **Identity is brand-free; commerce is per-brand.**
- **surface_mode** (`stockists.surface_mode`) describes **how that factory STAMPS ITS BOXES** — the
  physical box, nothing else. **It has NO influence on identity.**
  - `attribute` — the stamp carries name **and** surface as two fields (`ANT BIANCO | GLOSSY`). One
    stamped name covers several surfaces → **stock entry must ask which surface**. **Rare.**
  - `in_name` — the stamp carries the name only. The name alone identifies one product: they make a
    single surface, or they encode it in the number range (10001-19999 = Glossy, 20001-29999 = Matt).
    **Stock entry must NOT ask.** *(Do not read this as "the surface word is inside the name" — it
    usually isn't. It is simply the default, and it means "don't ask".)*
  - It once gated a surface *stamp* onto `stockist_library`. That was a **workaround for the old
    broken key**, not a design — and it left `famous "1001"` carrying a stale `Sugar` label while its
    stock was Carving/GHR/Matt. Deleted. **Never branch on stockist type to decide identity.**
  - `brands.surface_mode` still exists but nothing reads it.
- **design_name** is verbatim truth — display the name as stored, never concatenate surface,
  size, or quality into it. (An `in_name` factory's name may *contain* a surface word. Leave it.)

See `docs/PRODUCT_IDENTITY_MIGRATION_PLAN.md` for how this got here and what is still deferred
(BOX, faces, joint type, mockup/aligning/closelook).

`docs/` and the memory index carry the full model. When a decision here changes, update this file
in the same change.

## Conventions

- `flutter_lints` via `analysis_options.yaml`; no custom rules enabled.
- Every `+`/`-` quantity stepper must also allow tap-to-type, clamped to valid range.
- Any WhatsApp action needs a Copy fallback — not every user has WhatsApp.
- Secrets: `lib/config/app_config.dart` holds the Supabase publishable key and Cloudinary preset.
  These are client-side public values. Never put a service-role key in `lib/`.
