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

      (stockist_id, lower(master_design_name), size, surface_type)

  It carries `image_url`, `surface_type` + `surface_label`, **`thickness_mm`**, `colour`,
  `tile_type`, and its **DNA tags** (via `library_id`). Faces/closelook/mockup all hang here.
- **HOLDING** = `designs` — **quantity on hand, NOT the design.** `designs_holding_uniq` is
  `(stockist, library, brand, quality, surface_type)`. It carries `box_quantity`,
  `control_quantity`, `quality`, `status`. One product → many holdings.
- ⚠️ **The table named `designs` is STOCK.** The word "design" is overloaded in this codebase:
  `TileDesign`, `addDesign()` (really `stock_add_holding`), `deleteDesign()` all operate on the
  **holding**. When it matters, say **product** or **holding**, never bare "design".
- **BOX** (`product × brand` → `pieces_per_box`, `box_weight_kg`) is the missing entity. Those two
  columns currently sit on `stockist_library`, which is the **wrong level** — a box holds N pieces
  and its weight follows from the piece count. Planned, not built.

### Surface and brand

- **surface** — never "glaze". Both `surface_label` (the stockist's own word, e.g. "Raindrop") and
  `surface_type` (admin canonical, e.g. "Sugar"). Cards read `Raindrop (Sugar)`. Filters split by
  audience: stockist UI and the `/s/` link filter on the **word**; the buyer app (many stockists)
  filters on the **canonical**. `surface_label` is **display-only, never a key** — keying a lookup
  on it wedges Add Stock against the index.
- 🔑 **Surface IS product identity.** *Glossy Ant Bianco* and *Matt Ant Bianco* are **two products**,
  made from one print. `surface_type` is `NOT NULL DEFAULT 'None'` — `'None'` is a deliberate
  answer, not a missing one.
- 🔑 **Brand is NOT product identity.** For an M, a different brand is only a different **NAME** for
  the same print. Brand belongs to the **box**; identity is brand-free. `stockist_library.brand_id`
  survives as a *default/first-seen hint only*. A product's brand names live in
  `stockist_library_brand_names (library_id, brand_id, brand_design_name)`, and **stock is still
  per-brand** (`designs.brand_id`). **Identity is brand-free; commerce is per-brand.**
- **surface_mode** (`stockists.surface_mode`) is a **parser/import hint ONLY** — *where do I read
  the surface from on this factory's dispatch note*: its own column (`attribute`) or inside the
  design name (`in_name`). **It has NO influence on identity.** It used to gate a surface *stamp*
  onto `stockist_library`, which was a workaround for the old broken key and is now deleted.
  `brands.surface_mode` still exists but nothing reads it.
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
