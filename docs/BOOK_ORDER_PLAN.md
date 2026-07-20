# BOOK ORDER — an order for a tile that has not been made yet

**Status: STEP 1 BUILT (`20260720g`). Steps 2–6 planned, not built.** (20 Jul 2026)

## 🚫 Scope, locked by the owner

- **The STOCKIST enters every book order.** There is **no buyer/end-user application for 1–1.5
  years**, so nothing here may depend on one.
- **The customer is shown NOTHING.** No public order page, no production status link. *"Stockist
  never wants to give this information — if they want to, they will call manually by phone."*
  So `public_order` / `create_order_link` stay unwired, and the old "buyer sees it" step is
  **DELETED from this plan.** Do not rebuild it.
- Keep it simple. This is a planning tool for one man at his desk, not a marketplace.

## Why

Everything we have starts **at stock**: the tile exists → boxes are in the godown → the buyer sees
what is there → he buys it. `/s/`, the hold, F_Stock, dispatch — all of it assumes **the material
already exists**.

A large part of the ceramic trade runs the other way:

> the buyer sees the **DESIGN** (a picture, no stock) → he **books an order** → the company collects
> orders from many customers → plans its **production programme** → produces → the material comes
> off the line **into stock** → and from there the system we already have takes over.

We are missing everything that happens **before stock exists**.

## 🔑 The insight that makes this cheap

`packings (library_id, pieces, weight_kg)` has **no brand**. `boxes (packing_id, brand_id)` is the
cover. So:

> **The factory produces a TILE. The brand is only the corrugated cover, put on at the very end.**

Therefore **production is planned on the TILE; the customer's order is on the BOX.** One run of
*ALASKA BLACK Matt* feeds FAMOUS, ANUJ and KHAKHI orders at once — you plan one production and split
it at the cover. The roll-up chain is **BOX → packing → TILE**.

This is the PACKING/BOX split of 14 Jul paying off. It was not designed for this, and it fits exactly.

## 🔁 Book Order is NOT a new thing — it is the existing order, pointed at a BOX

Today: `inquiries` + `inquiry_items`, and `inquiry_items.design_id` → `designs` = **a HOLD**.
A hold is stock, so **an order cannot exist before the tile does.** That is the whole limitation.

A **BOX** exists the moment a human ticks that brand's cover in the Design Library
(`box_put_cover`) — long before any tile is made. Point the line at a `box_id` and the order works
for material that does not exist yet.

Extend, don't invent:

1. **One deal is often both.** 500 wanted, 200 on the shelf, 300 to make. A separate table would
   force two orders for one commercial promise.
2. `inquiries` already carries `customer_id`, `customer_hint`, `token`, `connection_code`, the
   status lifecycle, `create_order_link`, `public_order`, `my_orders`, `dispatch_inquiry`.
3. The partial machinery exists: `quantity` / `dispatched_qty` / `held_qty`, and `remaining_boxes`.
4. 🔑 **Keying the line on the BOX is the enforcement, not a compromise.** A box only exists because
   he declared the cover. So an order cannot be booked for a cover nobody declared — which is
   exactly what makes "production lands in stock" legal without any stock path minting a box
   (`20260720e`).

**The one real cost:** `inquiry_items.design_id` is `NOT NULL` (verified) and every reader
inner-joins `designs`. Nine readers must learn about box lines.

## Data model

```
inquiry_items
  design_id     uuid  NULL          -- HOLD (stock line, as today)
  box_id        uuid  NULL          -- BOX  (book line)                    NEW
  check (num_nonnulls(design_id, box_id) = 1)
  produced_qty  int not null default 0    -- boxes made against this line   NEW
  wanted_by     date NULL                                                   NEW
  -- unique(inquiry_id, design_id) becomes unique on (inquiry_id, coalesce(design_id, box_id))

stockists.book_orders_enabled  bool not null default false   -- admin opt-in, like customers_enabled

production_views                    -- "remember those groupings"
  id, stockist_id, name, filters jsonb, group_by text[], sort text, is_default bool, created_at
  unique (stockist_id, lower(name))

production_runs        id, stockist_id, name, status, planned_for, created_at
production_run_lines   id, run_id, library_id, target_pieces, note      -- keyed on the TILE
production_run_output  id, run_id, box_id, quality, boxes, produced_at, stock_in_id  -- on the BOX
```

⚠️ **The asymmetry between `production_run_lines` (TILE, pieces) and `production_run_output`
(BOX, boxes) IS the model.** It is where the brand enters, and it mirrors the factory.

📏 **Quantity is in BOXES. Sq ft is DERIVED and never stored** — the same law as thickness.
`boxes × packings.pieces × _tile_area_m2(size) × 10.7639`. `_tile_area_m2` exists server-side;
`sqftPerBox()` exists in `lib/utils/tile_types.dart`.

## Production planning — the screen

**`my_production_demand(p_filters jsonb)`** — open book lines (`box_id not null`,
`quantity > produced_qty`), joined box → packing → tile → print. Returns per
(library_id, packing_id, box_id): ordered / produced / remaining in boxes, pieces and sq ft, plus
every grouping dimension — print name, size, `surface_type` / `surface_label`, `tile_type`, body
colour, thickness, brand, customer, order token, `wanted_by`, and DNA via **`_dna_of_library()`**
(never `library_dna` directly — that misses the print's).

All five dimensions he asked for already exist: **design** = tile/print · **surface** =
`surface_type` · **order** = the inquiry · **punch** = DNA `Punch` ▸ `Punch Type` · **series** = DNA
`Series`. Nothing new to model.

**`/stockist/production`:**
- **Filters** — Design · Surface · Order · Punch · Series · Size · Brand · Customer · Wanted-by.
- **Ordered group-by chips** — e.g. `Series ▸ Size ▸ Surface`; each group totals remaining
  boxes / pieces / sq ft.
- **Rows at the TILE by default**, expandable → packing → box → the orders behind the number.
- **"Remember" = saved views** (`production_views`), one settable as default.

## Production → stock, without breaking the law

**`production_declare_output(p_run_id, p_box_id, p_quality, p_boxes)`:**
1. Verify the box is his (box → packing → tile → `stockist_id`).
2. 🚫 **Resolve only — never `box_put_cover`.** An undeclared cover raises the existing `_box_for`
   sentence.
3. Create/find the HOLD for `(box_id, quality)` and `add_stock`. **A HOLD is not a box**, so
   creating one is legal. `stock_in` logs it as today.
4. Allocate against open book lines for that box, earliest `wanted_by` first, raising
   `produced_qty`. Surplus falls into free stock.

## Partial production

No new concept — three numbers on the line, the shape `my_orders` already publishes:
`quantity` (ordered) · `produced_qty` (made) · `dispatched_qty` (shipped).
⚠️ **The line is never rewritten from box to hold.** It keeps its `box_id` for life; dispatch
resolves box → hold. One line, one promise, from booking to delivery.

## Buyer visibility — 🚫 NONE. Deleted from this plan.

The owner is explicit: the customer sees nothing, and he will phone them. `public_order(p_token)`
and `create_order_link(p_inquiry, p_days)` exist in the DB with **zero Dart callers and no route**
(verified) — leave them that way. **Do not build a `/o/:token` page.**

## Staged delivery

| # | step | verified by |
|---|---|---|
| **1 ✅** | **The book line exists** (`20260720g`). `design_id` nullable · `box_id` · XOR check · `produced_qty` · `is_urgent` · `quality`; customer `default_brand_id`; `book_orders_enabled` | ✅ done — both/neither refused, stock line intact, `inquiry_detail` + `my_inquiries` unchanged |
| **1b** | **Teach the readers.** `inquiry_detail`, `my_inquiries`, `my_orders`, `update_order_items`, `hold_order_items`, `dispatch_inquiry`, `create_stockist_order` all **inner-join `designs`** and so silently DROP a box line. **`held_of` must keep ignoring them — a book line holds nothing.** MUST land before step 2 | a book line survives a round trip through every reader |
| 2 | **Book an order.** `create_book_order`; Add Order gains a second door "From Library (to produce)" → tile → packing → brand cover; brand prefills from the customer | an order for a tile with **zero stock** saves, lists with 0 produced |
| 3 | **See the demand.** `my_production_demand` + the Production screen, filters + group-by, no saving | two customers, one tile, two brands → one tile row with right pieces + sq ft |
| 4 | **Remember it.** `production_views` + save / load / default | a named view reopens with the same filters and grouping |
| 5 | **Declare output.** `production_declare_output` + "Production done" sheet | uncovered brand **raises**; covered brand creates the HOLD, logs `stock_in`, raises `produced_qty`; the `20260720e` self-check still passes |
| 6 | **Named programmes.** `production_runs` / `_lines` / `_output`, promote-selection-to-run, run sheet to print or WhatsApp (**Copy fallback required**) | a run planned from a saved view, output declared, order lines updated |

## 🚫 What must not come back

- No production path may call `box_put_cover`. **Resolve, or raise.**
- No stored sq ft column. Derived, like thickness.
- No thickness, surface or brand asked at the production counter — all three come from the box.
- Never write `designs.library_id` / `brand_id` by hand — trigger-maintained mirrors of `box_id`.

## Decisions — SETTLED with the owner (20 Jul 2026)

| # | question | ANSWER |
|---|---|---|
| 1 | Does a book line carry a quality? | **Yes, OPTIONAL — NULL means Premium.** *(his change; he often knows the grade at booking)* |
| 2 | Quantity in boxes, sq ft derived? | **Yes.** Never stored — same law as thickness. |
| 3 | Rate (₹/sq ft) on the line in v1? | **No.** Pricing is a ledger, not an order. |
| 4 | May one order mix stock and book lines? | **Yes.** 500 wanted / 200 on the shelf / 300 to make is ONE promise. |
| 5 | Urgency: a date, or a flag? | **⭐ A FLAG (`is_urgent`), settable at booking or ANY TIME after.** Sort = urgent first, then oldest order. **NO `wanted_by` date** — *(his change; a compulsory date gets left blank or typed wrong)* |
| 6 | Does surplus production go to free stock? | **Yes**, silently. It is real stock. |
| 7 | Gated behind an opt-in? | **Yes** — `stockists.book_orders_enabled`, like `customers_enabled`. |
| 8 | Brand on the order? | **Yes — asked per order, and REMEMBERED on the customer** (`stockist_customers.default_brand_id`). Prefills, never forces. *(his addition)* |
