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

- **surface** — never "glaze". Every stock row carries both `surface_label` (the stockist's own
  word, e.g. "Raindrop") and `surface_type` (admin canonical, e.g. "Sugar"). Cards everywhere read
  `Raindrop (Sugar)`. Filters split by audience: stockist UI and the `/s/` link (one stockist)
  filter on the **word**; the buyer app (many stockists) filters on the **canonical**.
- **surface_mode** — only an **M** has one (`stockists.surface_mode`), because an M *is* the factory
  and its brands are alternate names for one print. **T/W has none**: it carries other factories'
  brands and records whatever the dispatch note said, so Add Stock always offers the picker with a
  `None` choice. `brands.surface_mode` still exists but nothing reads it. A brand's convention is
  read off that factory's dispatch note — surface in its own column vs. inside the name.
  In `in_name` mode `add_inventory_batch` stamps the surface onto `stockist_library` (identity);
  **that stamp is M-only** — for a T/W one print may sit on the shelf in several surfaces.
- **Stockist_Library** = identity (a design exists). **P_Stock** / `holding` = quantity on hand.
  These are separate; changing one must not silently change the other.
- **design_name** is verbatim truth — display the name as stored, never concatenate surface,
  size, or quality into it.
- Stock is **per-brand** (`designs.brand_id`); identity is shared across brands via a master +
  per-brand alias names.

`docs/` and the memory index carry the full model. When a decision here changes, update this file
in the same change.

## Conventions

- `flutter_lints` via `analysis_options.yaml`; no custom rules enabled.
- Every `+`/`-` quantity stepper must also allow tap-to-type, clamped to valid range.
- Any WhatsApp action needs a Copy fallback — not every user has WhatsApp.
- Secrets: `lib/config/app_config.dart` holds the Supabase publishable key and Cloudinary preset.
  These are client-side public values. Never put a service-role key in `lib/`.
