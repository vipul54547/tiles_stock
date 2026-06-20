# Tiles Stock — Project Vision, Architecture & Plan

> **Master document. Written 2026-06-20.** Consolidates the locked vision, the data model,
> the strategy, every decision taken, and all open questions + pending work, so the next
> session can start the pending build and take decisions. **Status: VISION + DESIGN locked;
> very little of the "unify import / SD_Library" work is coded yet.**

---

## 0. One-paragraph summary

We are building **three products that share one Supabase brain**: **TSA** (the Flutter mobile+web
app for the *trade*), **TSS** (a future *desktop* back-office for producers), and a **separate
Next.js/Astro SEO website** (the *end customer's* Google front door). The whole system's real key
is **Design DNA** — a visual-character index of "how a tile looks" — because in this market a
design's **name lies** (the same name means different tiles across companies) and its **image is the
truth**. Build DNA well now and all three products converge. Priority = make data-entry effortless
for the stockists who already have data (M/T), because the *dealer* (90–95% of users) only gets
value once the supply data exists.

---

## 1. The three products (one server, three front doors)

| Product | Built with | Audience | What they do | Owns |
|---|---|---|---|---|
| **TSS** — Tiles_Stock Software | Desktop | M/T **producers** (back-office) | Deep production entry | **batch, shade, location, machine no.** |
| **TSA** — Tiles_Stock Application | Flutter (mobile + web) | The **trade**: M/T/W/R, logged-in | Manage stock / source / inquire | catalog, SD_Library, stock, DNA tagging, inquiry |
| **SEO Website** | **Separate Next.js/Astro** (NOT Flutter web) | The **END CUSTOMER** (homeowner / architect / builder) | Searches Google for a design | indexable design pages, master design library |

```
                         SUPABASE  (single source of truth / brain)
              ▲ feeds                  ▲▼ transacts                 ▲ reads/indexes
   ┌──────────┴──────────┐   ┌─────────┴───────────┐   ┌────────────┴─────────────┐
   │ TSS (desktop)       │   │ TSA (Flutter app)   │   │ SEO Website (Next/Astro) │
   │ producer back-office│   │ the trade chain     │   │ end-customer Google door │
   └─────────────────────┘   └─────────────────────┘   └──────────────────────────┘
```

- **TSA is built FIRST.** TSS and the SEO site come later.
- The PDF/Excel import in TSA **is the TSS→TSA bridge** until TSS has live sync. The factory-software
  report format we analysed (see §8) is exactly what TSS will emit, so the importer is already
  forward-compatible.
- **TSA serves the trade; the website serves the end user. Two front doors, one brain.**

---

## 2. The supply chain & relative roles

```
M_Stockist  →  T_Stockist  →  W (city wholesaler)  →  R_Dealer  →  END CUSTOMER
(Morbi, makes)  (Morbi, trades)  (in cities, stocks)   (retail shop)  (installs & uses)
```

- **M_Stockist** — manufacturer, at **Morbi**. Makes tiles. Runs multiple **brands = packing boxes**.
- **T_Stockist** — trader, at **Morbi**.
- **W_Stockist** — wholesaler in **other cities across India** (NOT Morbi). **His location/proximity to
  dealers is his value.** Provides stock to R_Dealers. **~70% of stockists.**
- **R_Dealer** — retail shop.
- **END CUSTOMER** — homeowner / architect / builder / contractor. The only one who actually
  **installs and uses** the tile.

**Roles are RELATIVE, not person-types.** The same W is a **W_Stockist** when selling to R and a
**W_Dealer** (buyer/user) when buying from M/T. Every level is a *stockist* to the layer below and a
*dealer/user* to the layer above.
➡️ **App implication:** "stockist" vs "user" is a **hat worn per transaction, not a fixed account
type.** A W account needs **both** a stockist screen (manage stock) and a buyer screen (source from
Morbi). Likely true for R too.

**Who is the "user of tiles"?** Relative answer: at every step the buyer is the user of his supplier.
**Ultimate answer: the END CUSTOMER** — the only one who doesn't resell. The end customer's product is
the **SEO website**, not TSA.

---

## 3. User-base split & the EGG-FIRST strategy

- **Dealer/buyer side (R, + W wearing the buyer hat) ≈ 90–95% of users — the TARGET.**
- **Stockist/supply side ≈ 5–10%.**
- The app is **NOT a godown manager — it's a demand-side discovery engine fed by godown data.** We
  capture only the slice a dealer needs (name, size, finish, image, qty, quality, brand). Deep
  production fields → TSS, never shown to dealers.
- **Design rule:** *every field a stockist enters must answer a question a dealer would otherwise phone
  to ask — if it doesn't, it belongs in TSS, not TSA.*

**Stockist composition (of 100% of stockists):**

| Type | Share | Has factory software + images? | Data entry | Role in strategy |
|---|---|---|---|---|
| **M** | ~10% | ✅ ~80% do (images + PDF + good Excel) | Harder (brand→master-design mapping) but fast | **Image source / seed** |
| **T** | ~20% | ✅ do | **Easy** — no brand mapping; upload PDF → library ready → then Excel/PDF | **Image source / seed** |
| **W** | ~70% | ❌ mostly not | Light resellers | **Consumer of the library** |

> **All three types are EQUALLY important — just different ways of working.** Tailor delivery to each.

**🥚 Egg-first decision (answer to "egg or chicken?"):** the **egg = stockist data, image-first** comes
first (dealer value is impossible without filled design data). **But pick the right egg: the 30% (M+T)
who already have software/images** — easiest to onboard and the source of every image. Seed the data
with them; the dealer side then fills itself.

**The 8 dealer problems TSA solves** (6 of 8 are pure demand-side):
1. Availability (who has it + how much) · 2. Discovery/match (by attributes/DNA + size + finish) ·
3. Visual (image to show the customer) · 4. Identity/naming (same tile across brand names) ·
5. Reach (one catalog across all "My Suppliers") · 6. Transaction (in-app inquiry→order, kills
WhatsApp chaos) · 7. Awareness (restock / new-arrival alerts) · 8. Representation (branded share links
+ stockist anonymity).

---

## 4. Core principles (locked)

### 4.1 Design identity is VISUAL, not name
*"A design IS its image and character. The name is just a label we hang on it — and labels lie."*
- "Vipul" the name is shared by thousands; **Vipul's face + character** is the real identity.
- "Calcutta Gold" is shared by many companies; each is a **different** tile. **Image + character (DNA)**
  is the real identity.
- Same name → different designs. Different names → can be the same design.
- Importance order: **imagination/look + image FIRST, character (DNA) second, name LAST.**
- The customer never asks for a name — he asks for *"white marble look, glossy, big slab"* (imagination).

### 4.2 Name doesn't matter; duplicate images are tolerable
- Don't chase name-matching or perfect image-dedup. If the same Morbi design appears under 5 stockists
  with 5 slightly-different photos, that's fine — each keeps his own image; **DNA groups them.**

### 4.3 The "no cross-stockist image" rule = anti-MIXUP, not secrecy
- **Designs are NOT secret** — all India's tiles come from **Morbi**; designs are openly Google-
  searchable. You can't hide a design and still sell it.
- **But same name ≠ same design across companies** → **no auto-merge / auto-inherit of images by name.**
- The rule exists so you **never show *famous*'s photo under *lonix*'s inventory** (mixup destroys
  trust). Each stockist's inventory carries **its own** confirmed image.
- The image = a **clean, neutral design shot** like Google results — *"no hands, legs, eyes, ears"* =
  no watermark, no branding, no identifying marks.
- Cross-stockist "same design" = **visual match + human confirm, never name-match.**

### 4.4 Design DNA is the SPINE that unifies all three systems
- DNA (colour, look-type, finish, pattern, application, print-type, …) encodes **how a design looks** —
  the only identity that is name-/brand-/stockist-agnostic and Morbi-wide.
- **TSS** emits design+image+attrs → **TSA** stockist tags DNA + dealer searches by DNA → **SEO site**
  master library clusters by DNA + end customer searches by "look."
- **Build DNA once → serves trade search + end-user search + master-library clustering.**
- **DNA narrows, image + human confirms** — DNA alone can't fully decide "same design" (two different
  white-marble-glossy tiles share DNA). DNA does ~90%, not 100%.
- *(Future)* a **vision model could auto-extract DNA from the image** → cut tagging effort, maybe solve
  the W-onboarding gap. Horizon idea.

---

## 5. SD_Library (Stockist Design Library) — the data model

**SD_Library = each stockist's own master library of designs**, auto-populated as a **side effect** of
two entry points (no one edits a "library screen" directly):
1. **PDF** — fast initial entry; one step creates library masters + godown stock.
2. **Excel** — used afterward to maintain the godown (qty, new designs, corrections).
Both flows + the master-data tables are **identical for M/T/W**.

**🔒 Identity (master key) = `name + size`.**
- **Finish is NOT identity** (an attribute on the master).
- **Body type is NOT identity** either — it's a plain **optional DNA attribute** (only ~2% of stockists
  will use it; let them handle it manually). *(Note: this reverses an earlier mid-session call that put
  body_type in the key.)*

**Attribute / stock stack:**
- IDENTITY (one SD_Library master): `name + size`
- ATTRIBUTES on master: finish, image, DNA (body type, colour, punch, look, application, print…),
  company_design_name
- STOCK rows (`designs`): quality × quantity, brand, stock_type
- CROSS-BRAND LINK (M only): brandN design-name → same master via company_design_name

**M vs T/W — what "brand" means:**
- **M:** brand = a **packing box / cover** decided at packing time. The true anchor is the
  **Company Design Name** (the factory's internal name, e.g. a tile laid as "Peatra Dhoru" can be packed
  in Brand1 as "Peatra Dhoru" and Brand2 as "PD Stone"). M can **link brandN name → one master**
  (brand names become aliases). He may type his own internal name or reuse the default brand's name.
- **T/W:** brand = the **supplier company they buy from.** Brand1 = Company A, Brand2 = Company B =
  physically different tiles → brands are **fully isolated, NEVER cross-linked.**

**Cross-brand linking lives in Excel only — and there is NO auto-match.** Manufacturers deliberately
give the same tile unrelated names across brands, so fuzzy matching is impossible. Therefore: **PDF
silently creates a new master** (never guesses a link); **Excel is the single source of truth** for
cross-brand identity; **manual in-app linking = fallback.** (Shared-sheet file naming convention:
*company name with id in brackets*, e.g. `Famous Ceramic (FC001).xlsx`.)

**Quality as parallel quantity columns:** `GOLD = Premium, STD = Standard, ECO = Economy`. One design
can hold stock in several grades at once. **ECO is manufacturer-entry-only** (internal godown count) —
never a buyer-facing grade, never in PDF. Buyer side stays Premium/Standard.

**Re-upload is idempotent:** find-or-create the master (no dup) + UPDATE box_quantity, via the single
atomic `import_stock_batch` RPC.

---

## 5A. Stockist_Master_Design — LOCKED construction model (2026-06-20)

`Stockist_Master_Design` = each stockist's own canonical set of master designs (= the SD_Library
master records). Built NOW. Two-tier: it later rolls up (via DNA + visual confirm) into
**`Admin_Master_Design`** (the global cross-stockist library that feeds the SEO site) — **Admin_Master_
Design is deferred until the DNA framework exists.** W's data has no special app behaviour; its special
value is **geographic coverage for SEO** (end customers search by city → a W near them).

**Structure (same two tables for ALL M/T/W):**
- **Master** (brand-agnostic): identity `name + size`; holds **image (4a)** + **DNA (4b)**.
- **Brand-name alias** rows: `(brand_id, brand_design_name) → master`.

**Collision rule — Option A (LOCKED):** when an import brings `name+size` that already exists under a
*different brand*, **auto-create a SEPARATE master per brand.** Cross-brand merge happens **only by
explicit human link**, never auto by name (honours *accuracy > image-dup; never auto-merge by name*).
- The **auto-separate default serves T/W (~90% of stockists)** — different supplier brands = different
  tiles, kept correctly separate with zero effort.
- The **explicit-link path serves M (~10%)** — same tile in different boxes, merged on purpose.

**Per-type entry rules (LOCKED):**

| Type | Brand-1 | Brand-2+ | Mechanism |
|---|---|---|---|
| **M** | PDF (images) + Excel (data) | **mapping ONLY — no PDF** | brand-1 PDF + brand-2 Excel **create-or-link** |
| **T / W** | PDF | **PDF per brand** | Option A auto-separate per brand |

- **M_Stockist may upload PDF ONLY for the default brand (brand 1).** Brand-2+ PDF is **blocked** —
  re-importing the same physical tile would only duplicate images. Brand-2+ is a **mapping** operation
  (brand-2 names → existing brand-1 masters). The mapping is **create-or-link**: if no matching master
  exists (a brand-2-only design), it CREATES a new master (image added later/manually, since no PDF).
- **T/W** upload a PDF per brand (each brand = a different supplier = different tiles/images), so
  Option A's auto-separate applies to them.
- The PDF *flow itself* (parse → preview → create masters+stock) is identical for all; only **which
  brands a PDF may target** differs (M = brand-1 only; T/W = any brand).

**Image (4a, LOCKED):** the design image is **per-stockist** — first-writer-wins within his own brands,
**never** auto-pulled/copied from another stockist (anti-mixup rule).

**DNA (4b, LOCKED):** DNA attributes (colour, look-type, finish, body type, punch, application, print…)
live **on the master design** (not the brand alias, not the stock row) — written once, flow forward into
Admin_Master_Design + SEO later.

**Their factory Excel = a DATA SOURCE only, NOT our schema.** Build our **own lean TSA template/schema**
with just the TSA-required fields; map their columns into it; ignore their layout/headers; add the DNA
fields they don't have ourselves.

---

## 5B. Import flow — Step 1 + Step 2 spec (PDF + Excel) — LOCKED 2026-06-20

### Upload modes (chosen in Step 1, applied by the atomic engine)
Three modes. **"Unmatched" is always scoped to the Brand + Stock list being uploaded into — never
other lists/brands.**

| Mode | Matched design | New design | Unmatched existing (in this list) |
|---|---|---|---|
| **1. Add only** | qty **+=** uploaded (top-up) | create | **keep** (untouched) |
| **2. Fully new** | qty **=** uploaded (replace) | create | **zeroed** — box_quantity 0 / out-of-stock |
| **3. Update & keep** | qty **=** uploaded (replace) | create | **keep** |

- **"Zeroed" = box_quantity 0 / out-of-stock, NEVER deleted** — the Library record, **image and DNA are
  preserved** (image is precious).
- Modes 2 & 3 both **replace** matched quantities; they differ only on unmatched (2 zeroes, 3 keeps).

### Step 1 — destination + mode + guarded confirm (+ library build)
1. Stockist picks **Brand + Stock list**, taps **Upload**.
2. The **3 modes show clearly** (one-line description each).
3. On tapping a mode → a **confirmation dialog**: a consequence message **tailored to the mode**, which
   **names the exact Brand and Stock list**, with a **5-second countdown** before Yes/Confirm enables
   (Cancel always available). The destructive **Fully new** is the reason for the countdown.
4. **(PDF)** the PDF is parsed and **builds the Library — name + size + image for every design** (this is
   Step 1's whole job). **(Excel)** the file is parsed — **data only, no images.**

### Step 2 (PDF) — the selection chain (each item gates the next)
**At Step 2 entry, show a match summary: "X designs already in your Library · Y new designs"** — so the
stockist sees how much the PDF matched vs what's new before selecting.

**MOTTO — no relaxation of required fields (data quality is non-negotiable).** We never loosen a required
selection to make the stockist's upload easier, because **the W/R dealer's experience is worth more than
the stockist's convenience** and depends entirely on complete, accurate data (quality, tile type,
surface, thickness). Stockists adapt step by step — they ask their M_supplier for a proper-format PDF, or
switch to **Excel**. The **Excel fallback means strictness never blocks anyone**, so enforcing quality
"will not create any problem." Strict gates stay strict.

1. **Quality** — ask *"Is quality in the PDF?"*
   - **YES** → **scrape per row** (a PDF may be **mixed** — some rows Premium, some Standard); fuzzy-map
     (`prm/primium → Premium`, `second/std → Standard`). A row whose quality **can't be read is flagged
     in review** — never silently defaulted.
   - **NO** → **compulsory single pick** Premium **or** Standard, applied to **all** rows.
2. **Stock Type** — **quality-gated** (`stockTypesForQuality`): options depend on the quality above;
   **defaults to Uncertain**; optional (disabled until Quality is set).
3. **Surface** — ask *"Is surface in the PDF?"*
   - **YES** → scrape per design; **not found → None + 🔴 red flag** in the final review.
   - **NO** → ask *"Does the whole stock list have only ONE surface?"*
     - **YES** → pick that one surface from the **admin surface list** → applied to all.
     - **NO** → ask *"Proceed with None for all?"* → **YES** → all surfaces = None.
4. **Tile Type (GATE)** — not scraped. A **multi-select window** of the 6 `kTileTypes`
   (PGVT & GVT / Porcelain / Ceramic / Full Body / DC / Colour Body).
   - **Exactly 1 → proceed** (stamped on the whole batch).
   - **More than 1** → message *"not built for multiple tile types — proceed?"* → **re-show the window**;
     if **still >1 → REJECT the PDF** (stockist splits the report by tile type and re-uploads).
   - Compulsory, **no None**; enforced at the window, so **no Save-time block is needed.**
5. **Pieces per box (GATE)** — selection **1–8 plus "Custom" → number box** (so any pieces/box is
   possible). Same multi-guard as Tile Type (>1 → warn → retry → reject). One value for the whole batch.
   **Without pieces/box the flow does not proceed.**
6. **Box weight** — numeric **text box (kg), compulsory.**
7. **Thickness** — **AUTO-DERIVED** from size + pieces + weight + tile type (`approxThicknessMm` → 0.5 mm
   band). **Never asked.**

**DNA is NOT in the PDF flow** — PDF = identity + image + compulsory stock fields only. DNA is optional,
added later via the in-app mapper / Excel, with a **gentle post-Save nudge** ("Add DNA tags to make these
searchable ›"). Never blocks.

Reaching the review **proves** Quality, Tile Type, Pieces and Weight all resolved (the gates). A rejected
PDF **stops here — nothing is written** (atomic). Images come **only** from a PDF (Excel has none).
**No "use Excel / add images" hint in the PDF flow** — Step 1 already gave every design its image.

### Multi-size PDF handling (the library always wins)
A PDF is **never fully rejected** — Step 1 always builds the Library (name + size + image) for every
design. In Step 2:
- **Single-size PDF** → the bulk flow above runs (Tile Type / Pieces / Weight are single-for-batch, and
  they're size-dependent, so they only make sense for one size).
- **Multi-size PDF** → Tile Type / Pieces / Weight **can't be applied in bulk**. The system then:
  1. keeps the **new designs registered in the Library** (from Step 1),
  2. shows a **genuine reason** (*"multiple sizes — tile type, pieces and weight can't be set in bulk"*),
  3. gives a **path to the Library + the list of those designs** to finish,
  4. **manual add in the Library still enforces every compulsory field** (no relaxation).
So images are never lost; only the bulk shortcut is unavailable for multi-size, and detail is completed
manually (still strict).

### Step 2 (Excel) — read from the columns
- **Quality** — from the **Premium Boxes / Standard Boxes** columns (structured, compulsory). No ask.
- **Tile Type** — from the **compulsory Tile Type** column (dropdown of the 6 values).
- **Surface** — from the Surface column (optional; blank → None).
- **Stock Type** — from the column; blank → **Uncertain**.
- **Images** — Excel carries **none** → after import, show the helper *"add tile images from your phone
  manually"* (camera/gallery, design by design). **This image-add hint is Excel-only.**
- **Pieces / Box weight / thickness** — **Excel is PER-DESIGN** (unlike PDF's single-for-batch): pieces/box
  becomes a **column** (each design can differ), box weight likely a column too; thickness still
  auto-derived per row. ⏳ **Template change pending** (plus more template edits the user has flagged) —
  **deferred until the PDF flow is finished.**

### Review + atomic Save (both paths)
- Review shows **ALL selections** — Brand, Stock list, quality, surface, tile type, pieces, weight,
  derived thickness — **AND the chosen upload mode**, plus **🔴 flags** (None surfaces / unreadable
  quality).
- **Save → ONE atomic `import_stock_batch` transaction** (all-or-nothing, idempotent by batch_id):
  builds masters, find-or-creates designs, **applies the mode** (add / replace / zero), logs the stock
  ledger. **Nothing is written before Save; Cancel/back = nothing.**

---

## 6. Output shape (one PDF → one atomic batch → 3 tables)

- **`stockist_library`** — master identity (find-or-create by `name + size`; image here; master name).
- **`stockist_library_brand_names`** — alias row (library_id, brand_id, brand_design_name).
- **`designs`** — the stock row (name/size/surface/quality/stock_type/box_quantity/brand/catalog…).

T/W (lean) and M (richer) produce the **same structure** — only some `designs` columns blank vs filled.

---

## 7. Batch / shade / location = TSS's domain (PARKED for TSA)

The factory ENTRY format (see §8) carries **Batch/Shade, BoxPack (= packing brand), Location, Item
Status (Domestic/Export), PRE/STD/GOLD/ECO, Entry Date**. These deep production fields belong to **TSS**,
**not TSA**. The whole batch/shade design discussion is **parked as a TSS spec.**
- *(Architecture note, accepted but DO NOT BUILD yet — understand TSS first):* later reserve nullable
  `batch`/`shade`/`location` pass-through columns + keep ONE ingestion RPC (`import_stock_batch`) that
  both TSA-import and future TSS-sync write through.

---

## 8. Reference: the factory-software reports analysed (2026-06-20)

These files (in `Downloads/`) are **one good software's reports for ONE client** — shown for ideas, not
ours. They validated our column model.

**Consolidated/Summary/120X180 set** — brand **VERITAAS**, size **1200X1800 9 MM**, ~308 designs:

| Their column | Meaning | Maps to |
|---|---|---|
| DesignName | raw name (trailing spaces) | design name — **must trim** |
| Base DesignName | trimmed name | proves name-normalization needed |
| Brand | VERITAAS (one/file) | our **Brand**, one per upload |
| Size | `1200X1800 9 MM` | Size **+ thickness baked in (9MM)** |
| **Category** | GVT/WHITE/FULL/S&P/GREY/DARK F.B BODY | our **Body Type** (now a DNA attribute) |
| **Finish** | GLOSSY/MATT/CARVING/PAPER MATT/PORSCH/SUGAR/SATIN/HIGH GLOSSY/PORSH MATT/ITALIAN | our **Surface/Finish** |
| **Punch** | `-` | our **Punch** DNA attribute |
| **STD/GOLD/ECO** | quantity split by quality grade | quality columns (ECO internal) |
| Total | SUMIF of design across rows | our auto-sum |
| Product / Design Type / Status / Use Cont. / Mark / MchNo | placeholders / machine | **ignore** |
| `Consolidated Summary` sheet | name+size+finish → summed qty | a hand-built **Godown view** (our RPC does it) |

**`ENTRY (1).xlsx`** — the software's **godown ENTRY screen** (richer): each design appears as multiple
rows split by **Batch/Shade** (`260619/-` = production date YYMMDD + shade code) + **BoxPack** (BOTTEGA
/ PLAIN KHAKHI / CERA TILES / ENNFACE / LONIX = the **packing brand** = literal proof of "brand = empty
box cover") + **quality (PRE/STD/GOLD/ECO)** + **Location** (A02, D-36…). This is the TSS-level detail.

---

## 8A. BUILD PROGRESS

- **2026-06-20 — UNIFIED PDF screen + APK on device.** Decided ONE PDF screen for ALL stockists
  (M and T/W): `stockist_dashboard_screen.dart` main-brand PDF now always routes to
  `/stockist/stock/import-supplier-pdf` (both upload spots); `upload_stock_screen.dart` retired from
  routing (left dormant). flutter-analyze clean; debug APK built + installed via adb on device
  VOVS4TGYMFSSN7AQ. **Device-verify in progress** (user testing the mode flow + gates + Fully-new
  replace).

- **2026-06-20 — PDF Step 1+2 flow (§5B) BUILT on the T/W importer (`import_supplier_pdf_screen.dart`),
  flutter-analyze clean.** DB: migration `import_stock_batch_add_p_mode_add_replace_zero` adds `p_mode`
  (add / replace_all = fully-new with zero-untouched-in-list / replace_keep) to the atomic RPC — single
  6-arg function, old 5-arg calls bind via default (no overload ambiguity); replace logs delta to
  stock_in, fully-new zeroes untouched designs in the list (box_quantity 0, never deleted). Dart
  `importStockBatch` gained a `mode` param. New reusable `lib/widgets/upload_mode.dart` = the 3 modes +
  a **5-second guarded confirm dialog** naming brand+list (shared by PDF & Excel later). Screen: new
  `mode` phase (pick mode → guarded dialog) → pick → edit → **expanded `ask`** (Quality keep · **Tile
  Type gate** FilterChips, 1 required, >1 warned-then-rejected via `_goToStock` · **Pieces 1–8 +
  Custom** · **Box weight** + live thickness preview · **Surface nested tree** in-pdf?/one-for-all?/none)
  → stock → review (now shows Mode/Tile type/Pieces/Weight) → done (+ gentle DNA nudge). `_save` carries
  tile_type/pieces/box_weight/thickness + mode; **multi-size PDF → genuine-reason dialog → library-only
  save (qty 0, forced add-mode)**. ⏳ Device-verify pending. ⏳ OPEN: precise "X in Library · Y new"
  match count (needs a library-keys fetch — stubbed as total for now).

- **2026-06-20 — M path (brand-1-PDF-only + brand-2 create-or-link) DONE at DB.** Two parts:
  (1) **UI gating already existed** — the dashboard upload sheet shows the PDF option only for the
  default/main brand (`isMainBrand`), and routes brand-2+ to **"Set up designs — Mapping (Excel)"**
  (`/stockist/library/import-mapping`) for manufacturers (`!isImporter`). So M already can't PDF a
  non-default brand. (2) **The gap was that the mapping didn't actually LINK** — brand-1's PDF master
  has an auto **brand-prefixed** `master_design_name` (*"Brand1 Peatra Dhoru"*), but the mapping screen
  finds masters only by that name while the stockist types the *company* name (*"Peatra Dhoru"*) →
  created a duplicate master instead of linking. **Fix: migration
  `library_map_upsert_link_by_alias_create_or_link`** makes `library_map_upsert` **find-by-alias first**
  (`brand_id + brand_design_name + size`) → links brand-2 onto the existing brand-1 master; else
  find-by-master-name; else **create** (brand-2-only edge case = the create-or-link contract). Safe for
  the import path (single-brand alias only matches its own master → T/W auto-separate and re-upload
  idempotency unchanged; idempotency now also anchored on the brand's own alias). **No Flutter change
  needed** — mapping screen (`import_mapping_excel_screen.dart`) + dashboard gating pre-existed.
  ⏳ **Device-verify pending** (M: brand-1 PDF → masters; brand-2 mapping Excel linking "PD Stone"→
  "Peatra Dhoru" → one master with both brand aliases, no duplicate; a brand-2-only row → new master).

- **2026-06-20 — T/W auto-separate path (stock level) DONE at DB.** Migration
  `import_stock_batch_scope_design_lookup_to_catalog` added `and catalog_id is not distinct from
  p_catalog_id` to the `designs` find-or-create inside `import_stock_batch`. Now the same
  `name+size+quality` in a **different brand/stock-list creates a SEPARATE stock row** instead of
  updating the wrong brand's quantity. Same-list re-upload still updates (idempotent; batch_id guard
  unchanged). Library-master auto-separate already worked via the brand-prefixed `master_design_name`
  (`"<brand> <design>"`) in `library_map_upsert`. Image stays per-stockist first-writer-wins
  (`library_contribute` coalesce); DNA on master unchanged. **The T/W importer screen pre-existed
  (`import_supplier_pdf_screen.dart`, built v1).** ⏳ **Device-verify pending** (two brands, same design
  name → confirm two separate stock rows + two masters; re-upload one → no double-add).

---

## 9. Build order / plan

**Strategic order (from egg-first + DNA-spine):**
1. **Nail the M/T data-entry experience** (PDF = images + names in one shot, zero typing; Excel = ongoing
   stock). Seeds the image+design library.
2. **Build Design DNA tagging** (per-stockist) + dealer **search-by-imagination**.
3. **W onboarding** rides on the library (qty-light; image still per-stockist, visual confirm — the
   open gap, see §10).
4. **Master design library + SEO website** later (cluster by DNA).

**Tactical (the original "unify import" 5 phases — still valid, refreshed for identity = name+size,
all M/T/W in V1, batch parked):** see `.claude/plans/distributed-twirling-lightning.md`.
- P1 Route every stockist to the unified importer screen (drop the M-vs-T/W branch).
- P2 Add optional manufacturer fields to the extraction `ask` step.
- P3 Fold in value-adds (surface-alias learning, library image fill-if-blank, finish_label).
- P4 Retire the old `upload_stock_screen.dart` + route; leave `business_type` column dormant.
- P5 analyze-clean → APK → device-verify (M-style fill, bare PDF skip, re-upload no double-add).

---

## 10. OPEN decisions (take these next)

**RESOLVED 2026-06-20 (now in §5A):** Stockist_Master_Design construction — Option A collision rule;
M = PDF brand-1-only + brand-2 mapping (create-or-link); T/W = PDF per brand; image per-stockist (4a);
DNA on master (4b); their Excel = data source not schema.

**RESOLVED 2026-06-20 (batch 2):**
- **"W-onboarding cheap path" = a non-problem.** W's app flow = T's exactly: pick Brand+List → supplier
  PDF (library build = name+size+image) → step 2 rest → stock. No special path. Term dropped.
- **PDF = library build-up ONLY.** Step 1 (pre-upload): Brand + Stock list chosen → PDF brings size,
  design name, image. Step 2: everything else (quality, surface, qty, optional DNA).
- **Dual role (W = W_Stockist + W_Dealer): admin links BOTH at account creation.** Post-login UX =
  ONE login + a Selling/Buying role switch (single account, no second login). Final UX = builder's call.
- **Two Excel formats generated** in `docs/templates/`: `TW_stock_template.xlsx` (single brand, no
  mapping) + `M_mapping_stock_template.xlsx` (multi-brand: Company Design Name anchor + one column per
  brand = the cross-brand mapping). **Tile Type (`kTileTypes`: PGVT & GVT / Porcelain / Ceramic / Full
  Body / DC / Colour Body) is COMPULSORY in BOTH** (locked Stock Upload Validation; drives thickness +
  buyer filter) — initially omitted, fixed 2026-06-20. Removed the confusing optional "Body Type" column
  (factory Category = finer optional DNA, can return later). Required now: T/W = Design Name + Size +
  Tile Type; M = Size + Company Design Name + Brand-1 + Tile Type. Tile Type & Stock Type have dropdowns;
  Stock Type defaults Uncertain. ⏳ **Awaiting user's call on (a) any further compulsory fields, (b)
  whether the M sheet gets an Economy/ECO column.**

Still open:
1. **W_Stockist location** — the user has more to explain about how location reshapes W's flow.
2. **One account, two hats** — final post-login Selling/Buying switch UX (admin-linking decided).
3. **Excel compulsory fields + M Economy column** — user to decide after reviewing the two templates.
4. **Excel scope for TSA import** — PDF-only vs PDF+Excel-stock share one atomic path vs unify all 4
   entry points (deferred; revisit after the SD_Library work).
5. **Body type & other DNA attributes** — confirm they stay optional/progressive (never block upload).

---

## 11. Pending engineering work (don't lose)

- **Push 3 unpushed commits:** `7b035df`, `c05e1b7`, `b466ef7` (origin/master = `833600a`).
- **Verify remaining 4 of 7 supplier PDFs** (2 more bare "Design Stock Report" + 2 more labelled);
  3 already verified. Bare-DSR parser fix is in `b466ef7` (local, unpushed).
- **Device-verify backlog** (built, unverified): DNA chain, atomic import chain (no double-add),
  merge-duplicates UI, anonymity masking. Fill `Application` DNA values + tag more designs.
- Refresh the (now stale) "TO BUILD" status in the locked library-identity-model memory.

---

## 12. Critical files (TSA)

- `lib/screens/stockist/import_supplier_pdf_screen.dart` — the better importer shell → becomes the
  unified import screen.
- `lib/screens/stockist/upload_stock_screen.dart` — source of the manufacturer extras; retired later.
- `lib/screens/stockist/stockist_dashboard_screen.dart` — upload routing.
- `lib/app.dart` — router.
- `lib/utils/tile_types.dart` — `kTileTypes`, `approxThicknessMm`, `thicknessRangeLabel`,
  `stockTypesForQuality`.
- `supabase_data_service.dart` — `importStockBatch` / `import_stock_batch` RPC (the single ingestion
  point), `upsertSurfaceAlias`, `designImageKey`.
- DNA engine (DB): `dna_attributes` / `dna_values` / `dna_aliases` / `library_dna` tables + RPCs.

---

### Related memory files
`project_vipul_vision_unify_import` · `project_user_base_and_egg_first` ·
`project_design_identity_is_visual` · `project_supply_chain_roles` · `project_dna_is_the_spine` ·
`project_website_seo_strategy` · `project_design_dna_engine` · `project_library_identity_model` ·
`project_stockist_library` · `reference_master_data_tables` · `project_atomic_import`.
Full tactical plan: `.claude/plans/distributed-twirling-lightning.md`.
