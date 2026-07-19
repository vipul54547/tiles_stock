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
  `(stockist_id, lower(print_name), size)`. It owns the **name**, the **size** and the **image**.
  **A print has no thickness and no weight — you cannot hold it.** It becomes a product only once a
  surface, a body and a box are declared. A print may exist with **no product**.
  🔑 `print_upsert()` is the **only** way one is created; the image is **first-writer-wins**.
  - 🖼️ **FACES** — a design ships with 2/3/4 different prints, its **faces**. `print_master.image_url`
    is **Faces-1** (the card/primary image); the **extra faces (2, 3, 4 …)** live in `print_faces`
    `(print_id, position≥2, image_url)`. Faces belong to the **artwork** — every tile cut from it
    carries all of them — and are **portfolio media, NOT identity** (nothing keys on a face). The
    name is composed **"<print_name> faces-N"**, never stored. Writers: `print_face_add` (appends the
    next position) · `print_face_delete` (removes one, then re-sequences to stay contiguous). Read
    via the `faces` array on `my_artworks()`. Managed from the **My Artworks** card only.
  - 🧬 **THE IMAGE DNA IS THE PRINT'S** (`print_dna`) — **Look Type ▸ Natural Name · Design Joint ·
    Print Type · Colour**. It describes the **artwork**, so it belongs to the artwork and **not** to
    a piece cut from it. Tag `1001` once and **all three of its pieces (Matt · Carving · GHR) carry
    it**; the Matt cannot be *"white marble, bookmatch"* while the Carving is something else. A
    thickness **fork inherits it for free** — it shares the print.
  - 🔑 **An attribute declares its own home: `dna_attributes.scope` = `'print' | 'product'`.** Every
    writer routes on that one column (`dna_set_design`, `_dna_tag_import`), so a caller **cannot**
    put it in the wrong table. Every reader goes through **`_dna_of_library(library_id)`** = the
    piece's own tags **∪** its print's. Never read `library_dna` directly — you will miss the print's.
  - Everything else (**Punch ▸ Punch Type · Application · Use Type · Behaviour Type**) describes the
    **PIECE** and stays on it (`library_dna`).
  - 🖼️ On the Library card the image DNA renders **once, in the print header**, with its own editor
    (`showDnaEditor(scope: 'print')`). The piece rows show only the piece's own.
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
- 🚪🚪 **TWO DOORS. An import either BUILDS PRODUCTS or ADDS STOCK — never both.** (14 Jul 2026)
  - **PRODUCT door** — 📁 the folder (`/stockist/library/import-images`, Windows) **or** an Excel
    sheet (`/stockist/library/import-products`). Creates print + product + BOX. **Imports NO stock.**
    Server: `import_stock_batch(p_library_only => true)`. Every identity column is **compulsory** on
    every row (surface · tile type · pieces/box · box weight) — this sheet is what MAKES the product,
    so a blank one would make an incomplete one. It has **no quantity column at all**.
  - **STOCK door** — `/stockist/stock/import-excel`. Adds quantities to products that **already
    exist**. **Creates NO product.** Server: `import_stock_batch(p_match_only => true)` →
    `library_map_resolve()`, the **read-only twin** of `library_map_upsert`: it returns NULL rather
    than creating, and NULL again when the row is **ambiguous** (one print in two surfaces, no
    surface on the row — a stock row must never guess which product it means). An unresolved row
    comes back in `unmatched_rows` and is **reported, never minted**. The sheet has **no identity
    block**; Surface survives on it only to pick *which* product, and **stock inherits the product's
    surface** once resolved. The two flags are **mutually exclusive** — the server raises on both.
  - ⚠️ **This is where the 444 came from.** `import_stock_batch` used to call `library_map_upsert` on
    **every** row, so the stock importer was a product FACTORY: an unrecognised name silently minted
    a product with surface `'Special'`, a **NULL body** and **no box**. Enforcing NOT NULL was
    impossible while any stock path could create a product. **Never let a stock import create one.**
  - 🗑️ **The Library ▸ 🌳 mapping importer is DELETED** (`import_mapping_excel_screen.dart`,
    `buildMappingTemplate`, `libraryMapUpsert`, `/stockist/library/import-mapping`). It was a third,
    **broken** product door: it could not express surface / body / box, so every product it made was
    incomplete by construction. **Do not rebuild it** — the product Excel door is a strict superset.
- **PRODUCT** = `stockist_library` — **ONE PIECE of tile.** **This is what "a design" means.**
  It has **no name, no size and no image of its own** — it points at a print (`print_id`, NOT NULL).
  Its identity is:

      print_id + surface_type + tile_type + body_colour_id
      + thickness, which separates products ONLY when it differs by MORE THAN 1 mm
      (EXCLUDE stockist_library_thickness_apart · UNIQUE stockist_library_uniq_no_thickness)

  🎨 **BODY COLOUR is IDENTITY, and compulsory, for a Full Body / Colour Body tile** (only those
  two bodies). Same print+surface in body colour "Earth" vs "Milky Body" = **two products**. It is
  the stockist's own WORD (a `body_colours` palette row: name + optional L·a·b / hex), keyed by
  `stockist_library.body_colour_id` (NULL for glazed tiles). It is **NOT a DNA tag** — the old
  "Body Colour" DNA attribute is retired. `tile_add` takes `p_body_colour_id` and enforces the rule;
  `library_set_body` changes it (refused while the design holds stock). `bodyHasColour()` gates the
  UI. 🔑 A DESIGN is made on ONE full-page form (`new_design_screen.dart`, create AND edit) —
  surface · body · body colour · packing · per-design DNA · brand covers.

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
  - **`Special` is the LAST RESORT of a machine that cannot ask** — the folder import (no SURFACE
    level) and the hidden PDF parser. We never ask mid-parse, so we must not **guess** mid-parse
    either. One chokepoint: **`surfaceForImport()`** in `lib/utils/finishes.dart` — every RPC that
    can CREATE a product goes through it. (`library_map_upsert` **RAISES** on a blank *and* on
    `'None'`, and one bad row throws the WHOLE batch.)
  - **A HUMAN is never defaulted.** In the Library editor the surface is **blank and compulsory** —
    he is standing right there, so ask him. ⚠️ **The product Excel door is a human too**: he is at
    his desk filling a sheet, and there is a **review step** before anything is written. So a blank
    surface there is **not** silently `Special` — it is a `needsFill` row that **blocks Import**
    until he fills it or drops the row. Only a machine with no human in the loop gets `Special`.
  - **The STOCK door never writes a surface at all** — it *resolves* one. The word on a stock row
    only picks WHICH product; the holding then **inherits the product's** `surface_type`. Sending
    `Special` for a blank there would filter the match against a surface the product hasn't got and
    leave every row unmatched.
  - 🚫 **No free text under `Special`.** `surface_label` is not identity, so two `Special` tiles told
    apart only by a label would **collide into one product**.
- 🚫 **ADD STOCK NEVER ASKS FOR A SURFACE — from anyone. There is no surface field.** (14 Jul 2026)
  The stock **inherits the piece's own** (`stock_add_holding` with no surface = "use the product's").
  - It used to ask, for an `attribute` stockist. That was a **WORKAROUND**: the design picker showed
    only the **PRINT's** name (`1001`) and could not tell that print's three pieces apart, so the
    surface dropdown was really asking **which product**. 🔑 **The picker now names the PIECE**
    (`1001 — MATTE`, see `utils/piece_label.dart`), so the question is answered when he chooses.
  - ⚠️ **Asking it twice let the two answers DISAGREE.** Choose `1001 — MATTE`, pick surface `CARV`,
    and `stock_add_holding` **threw the chosen product away** and put the boxes on the **Carving**
    product — and if no such product existed it **INSERTED ONE**. **Adding stock could MINT a
    design** (famous's surface list even offers `Golden Series`, which is not a surface).
  - Now `p_surface` may only **CONFIRM** the piece's surface; a contradiction **RAISES**, and there
    is **no path from stock to a new product** — the same law as the stock import door.
  - **Surface is still product identity.** What changed is only **WHERE it is asked**: in the
    **Library**, where a product is made — never at the stock counter.
- 🔑 **Brand is NOT product identity.** For an M, a different brand is only a different **NAME** for
  the same print. Brand belongs to the **box**; identity is brand-free. `stockist_library.brand_id`
  survives as a *default/first-seen hint only*. A product's brand names live in
  `stockist_library_brand_names (library_id, brand_id, brand_design_name)`, and **stock is still
  per-brand** (`designs.brand_id`). **Identity is brand-free; commerce is per-brand.**
- ⚰️ **surface_mode is DEAD. NOTHING reads it. Do not branch on it, ever.** (`stockists.surface_mode`,
  `brands.surface_mode`, `currentStockistAsksSurface` — all inert. The columns survive; ignore them.)
  It described **how a factory STAMPS ITS BOXES** — the physical box, nothing else — and it **never
  had any influence on identity**. Both of the jobs it was given turned out to be workarounds, and
  both are gone:
  1. It gated a surface *stamp* onto `stockist_library` — a workaround for the old broken key. It
     left `famous "1001"` carrying a stale `Sugar` label while its stock was Carving/GHR/Matt.
  2. It gated the **surface question at Add Stock** — a workaround for a picker that showed only
     the print's name. Deleted 14 Jul; the picker names the piece now.
  - 🔑 **What tells two pieces of one print apart is NOT predictable from the mode.** Live proof:
    **famous** is `attribute` and forks by **SURFACE** (`1001` = Matt/Carving/GHR); **cura** is
    `in_name` and forks by **THICKNESS** (`6003 (SV)` = 8.4 mm vs 11.8 mm, same surface). Any code
    that branches on the mode gets one of them wrong.
  - **NEVER branch on stockist type to decide identity — or to decide how to DISPLAY identity.**
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
