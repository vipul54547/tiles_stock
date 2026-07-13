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

### The layering: PRINT → PRODUCT → (BOX) → HOLDING

- 🖼️ **PRINT** = `print_master` — **the ARTWORK, and it is stored ONCE.** Its key is
  `(stockist_id, lower(print_name), size)`. It owns the **name**, the **size** and the **one image**,
  plus the artwork-side DNA (`print_dna`: Look Type ▸ Natural Name · Print Type · Design Joint ·
  Colour). **A print has no thickness and no weight — you cannot hold it.** It becomes a product only
  once a surface, a body and a box are declared. A print may exist with **no product**.
  🔑 `print_upsert()` is the **only** way one is created; the image is **first-writer-wins**.
- 📁 **THE FOLDER IS THE ONLY HONEST SOURCE OF A PRINT NAME — never a PDF.**
  A supplier PDF prints the name stamped on the **BOX** (`brand_design_name`): the **factory's**
  word, per-brand, free text (`1001`, `CARRARA GOLD`, `DHORO KHIMO`). That is **not** the stockist's
  own word for the artwork, and `print_name` is exactly that. Feeding a PDF label into `print_name`
  **forges a wrong PRINT for every row** — and the print is the top of the identity chain, so the
  damage runs all the way down. **In a folder, HE NAMED THE FILES.** The filename **is** his word.
  - Stockist folder import: `SIZE / [SURFACE] / design.jpg` → `library_image_upsert` (his own).
    No SURFACE level → **`Special`**. **Windows only** (it walks a folder tree with `dart:io`).
  - ⚠️ It must **NOT** call `library_upsert_master` — that **DELETES** every brand alias absent from
    its payload (it backs the Library editor, where the alias list IS the truth). A folder knows one
    brand, so it would **wipe every other brand's BOX**. `library_image_upsert` only **merges**.
  - 🚫 **The PDF importer is HIDDEN from the platform** (no entry point). The route + parser survive
    for re-use elsewhere. **Do not re-add a way in.**
- **PRODUCT** = `stockist_library` — **ONE PIECE of tile.** **This is what "a design" means.**
  It has **no name, no size and no image of its own** — it points at a print (`print_id`, NOT NULL).
  Its identity is:

      print_id + surface_type + tile_type
      + thickness, which separates products ONLY when it differs by MORE THAN 1 mm
      (EXCLUDE stockist_library_thickness_apart · UNIQUE stockist_library_uniq_no_thickness)

  It carries `surface_type` + `surface_label`, `tile_type`, `thickness_mm`, and the piece-side
  **DNA tags** (`library_dna`, via `library_id`).
  ⚠️ `stockist_library.size` still exists as a **trigger-maintained MIRROR** of its print
  (`_trg_library_size_from_print`) — one writer, cannot drift. It is a cache, **not** a second source
  of truth, and it is dropped once the remaining `l.size` readers move. **Never write to it.**
  ⚠️ **`master_design_name`, `image_url` and `colour` are GONE from this table.** The RPCs still
  **return** those keys (sourced from the print / from DNA), so the Dart contract is unchanged —
  but there is no such column to select.
- 🔑 **The test for identity:** a dimension is in the key **iff two of its values are things a buyer
  chooses between, can sit in the godown together, at different rates, and are not substitutes.**
  Tiles sell **BY AREA AT A RATE** (₹/sq ft) — weight is freight, not commerce. So an 8 mm and a
  12 mm of one print cover the same sq ft but sell at **different rates** → **two products**. Same
  for body. **Brand FAILS the test** (same tile, different sticker → BOX). **Quality FAILS it**
  (same tile, graded → HOLDING).
- ⚠️ **`tile_type` is DECLARED, or honestly NULL — never guessed.**
  `NULLS NOT DISTINCT` is what keeps the key safe while it is blank: two *unknown* products of
  one print/surface still **collide** instead of duplicating. (The 444 rows that predate this
  carry NULL. A wrong value in the identity key is worse than a blank.) `tile_type` must not carry
  a `''` default — `''` was the OLD "unknown" and would defeat the NULL key.
- 🎨 **`colour` is DNA now** (multi-value, on the PRINT). `_dna_colour(library_id)` renders it as text
  for the RPCs' `colour` key. The old free-text column is gone.
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
- 📏 **THICKNESS IS DERIVED — NEVER TYPED, AND THERE IS NO PICKER.**
  - `thickness_mm` = `box_weight / (pieces × area × density)`, written **by trigger** from the BOX.
    Unknown is `NULL`, never `0` (a tile is never 0 mm thick).
  - 🔑 **Thickness makes a DIFFERENT PRODUCT only when it differs by MORE THAN 1 mm.** Enforced by
    the `stockist_library_thickness_apart` **EXCLUDE** constraint (btree_gist): two products of one
    print+size+surface+body may not have overlapping `[t−0.5, t+0.5)` ranges.
    ⚠️ **Never key identity on the 0.5 mm band.** **Box weight DRIFTS in the trade** — a 600x1200
    2-piece PGVT & GVT box was **28 kg in 2024 and is 26 kg now**. That is only **0.62 mm**, but it
    crosses a band edge, so a band key would **false-split one product into two**. (It takes
    **3.22 kg** to move that tile a full 1 mm; 800x1600 needs 5.72 kg — so the threshold must be in
    **millimetres, not kilos**.)
  - `thickness_band` = the 0.5 mm band, a GENERATED column — **display + the buyer's filter only.**
    NOT identity. Outside 4–20 mm it is NULL (a bad box weight, not a thin tile).
  - A product with **no box** has no thickness; two such twins still collide
    (`stockist_library_uniq_no_thickness`).
  - 🖼️ When a print really is carried in two thicknesses, the product **forked off** the original
    shows its thickness **in brackets** on the Library card. The original reads plainly.
  - 🚫 **Never add a thickness field to any form.** A stockist reads **PIECES and WEIGHT** off the
    box; they do **not** know "8.5–9.0 mm". A typed thickness is a guess, and it would go straight
    into the identity key. **The BOX is the source of truth for thickness.**
  - 🔑 **Add-design therefore asks for TILE TYPE + BOX WEIGHT + PIECES** — the three facts that are
    actually on the box — and the thickness falls out of them at once. Those two box facts are used
    **on CREATE only** (they seed the product's first box); on EDIT they are hidden, because several
    brands may pack the same print differently and the per-brand **BOX CHIP** owns them from then on.
  - ⚠️ A box edit can move a product into a different band, i.e. **change its identity** — that is
    correct (the weight is the truth), and `library_set_box` raises a plain-English error if it
    lands on top of an existing product.
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
- 🎨 **`'Special'` is what a MACHINE import writes when it has no surface for a row** — and it is
  **not `'None'` in a new hat.** `'Special'` is a **real, active surface**, and a legitimate
  *permanent* answer for a stockist whose surfaces cannot sensibly be enumerated. Stock **inherits**
  a product's surface rather than asking for one, so it cannot spawn a twin, and `library_set_surface`
  cascades a later correction onto every holding.
  - **PDF / Excel / bulk-image import → `Special`.** We never ask mid-parse, so we must not **guess**
    mid-parse either. One chokepoint: **`surfaceForImport()`** in `lib/utils/finishes.dart` — every
    RPC that can CREATE a product goes through it. (`library_map_upsert` **RAISES** on a blank *and*
    on `'None'`, and one bad row throws the WHOLE batch.)
  - **A HUMAN is never defaulted.** In the Library editor the surface is **blank and compulsory** —
    he is standing right there, so ask him.
  - 🚫 **No free text under `Special`.** `surface_label` is not identity, so two `Special` tiles told
    apart only by a label would **collide into one product**.
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
