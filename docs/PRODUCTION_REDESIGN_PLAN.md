# Production planning redesign — plan of record (21 Jul 2026)

Supersedes the single `/stockist/production` screen with a **page-per-decision** flow, and
rebuilds the Runs page around the ORDER so it can host **the JOIN** (produced material → a real
stock order). Direction confirmed with him on 21 Jul; this file is the sequence I build to.

The mockup that started this: artifact *"Production planning — three pages"* (his, generated in an
earlier session). We took the **shape** from it, not every detail — the two corrections below are
his and override the mockup.

## What he decided (locked)

- **Separate pages, not one screen.** Choose orders is its own page; Plan is its own full-width
  page; the Packing plan is its own page.
- **A named + dated DRAFT plan he can save and come back to.** A plan is created (as a draft) when
  he leaves "Choose orders", is finished on the Plan page, and becomes a **run** only when taken
  into production. Drafts persist server-side — he can close the app and return to one.
- **Build the Packing plan sheet** — the printable page the floor packs from: *which cover, how
  many boxes, whose order it is for*.
- **Partial quantity per line** — inside the tick dialog, a customer's line can go into production
  in part (300 of 500 now, 200 later). The server already splits a line
  (`production_take_into_run` takes `planned_boxes` per line); today the Dart tick list sends the
  whole remaining. This is old pending item #2, and it lives inside the Plan page.
- **The Runs page is rebuilt BY ORDER**, and **there is NO add-stock button on it** (correction to
  the mockup):
  - Stock is added from the existing **Stock page** (the normal Add Stock door), never from Runs.
  - After stock is added, the Runs page (by order) shows each order with an **"Order from stock"**
    button. That button IS the JOIN (old pending item #4): produced boxes → hold → an ordinary
    stock order (reuse `create_stockist_order` + `hold_order_items`), and existing dispatch / `/d/`
    takes over from there.

## What already exists (reused, not rebuilt)

- Order picking, the tick dialog (all-or-nothing per line today), the per-cover **Make** box,
  group-by chips, urgent filter, godown free/total, the pending-order warning, and
  `production_take_into_run` (slices an order) — all in `production_screen.dart` today. The redesign
  **re-homes** these across pages and adds the draft + partial-quantity + packing pieces; it does
  not throw them away.
- `my_production_demand`, `my_book_orders`, `my_production_runs`, `my_production_history`.
- The Runs/History screen (`production_runs_screen.dart`) — RUNS tab becomes the by-order rebuild;
  HISTORY tab stays.

## The sequence

### Phase 1 — Production planning as pages (delivers old #2)
1. **Route + navigation** — `/stockist/production` becomes **Choose orders**; **Plan** and
   **Packing plan** are pushed pages (or child routes). Keep the flag gate `currentStockistBookOrders`.
2. **Choose orders page** — the order list on a page of its own (search, box counts, "fully taken"
   drops out). "Next →" opens the **New plan** dialog (name + date) and creates a **draft**.
3. **Draft plan persistence (server)** — a draft holds name, date, the picked orders, the ticks
   (with per-line planned quantity), and the per-cover Make overrides. New table(s) +
   RPCs: `production_plan_create` / `_save` / `_list` / `_load` / `_delete`. A draft becomes a run at
   take-into-production and is then cleared. (Design the table when we start this step — read the
   live `production_runs` / `production_run_*` shapes first.)
4. **Plan page** — the current plan pane, full width: totals, group-by, urgent, the Make box, the
   outcome-per-order, "Take into production". Reads/writes the draft.
5. **Partial-quantity tick** — the tick dialog gets a **quantity box per line** (default = the
   line's whole remaining, clamped). `production_take_into_run` already accepts `planned_boxes`.
6. **Packing plan page** — after take, show the run's pack list: cover → boxes → pieces → *for
   whom*, with Print/share. (`window.print` on web; a plain printable layout elsewhere.)

### Phase 2 — Runs page rebuilt BY ORDER
- The RUNS tab is regrouped from *by run/cover* to *by order*: each booked order that has material
  in production shows its covers, planned/made, and the buyer. Remove the inline **"Made"**
  (declare-output) button from here.
- Decide where declaring output now lives. Under the new flow, **adding stock is the output
  declaration** and happens on the Stock page — so `production_declare_output`'s role shrinks to
  *recording what a run produced*, and allocation moves to the JOIN. Re-read `production_declare_output`
  live before changing it.

### Phase 3 — THE JOIN (old #4)
- Flow: **Add stock (Stock page) → Runs page (by order) → per-order "Order from stock"**.
- Server: an allocation ledger tying a run's produced boxes to orders, and
  `book_order_to_stock_order(run, order)` that puts the boxes on hold for the customer and creates
  an ordinary stock order. Converted qty is DERIVED (no column). Clamp-and-report on short free
  stock. The index on the conversion is **not** unique on `(run, order)` so late output can convert.
- Guard: `customer_delete` must also refuse when a booked order exists (a hole left on 20 Jul —
  today it only checks inquiries/dispatches).
- Two-way traceability: from an order see the run(s) that fed it; from a run see the orders it
  settled.

### Phase 4 — Edit-order facility (old #3)
- `book_order_update`, `book_order_line_set/add/delete` — all refuse unless the order is `open`
  AND `slice is null`. Plan in `docs/BOOK_ORDER_SPLIT_AND_EDIT_PLAN.md` §4. Independent of the
  above; slots in whenever.

### Phase 5 — Rebuild + install the stale APK, then ship (push + web deploy if `/s/` moved).

## Rules that do not change (carry them through every phase)

- A booked order **never touches stock** — enforced by absent columns. Stock is consulted at
  planning as information, never netted.
- **The tick is the decision**, and **the tick slices** — the parent keeps the customer's number,
  slices take a letter.
- **`box_put_cover` is the only writer of `boxes`.** No planning/JOIN path may mint a cover.
- **No quality on demand** — planning is premium; standard is a by-product to free stock.
- The JOIN is where the promise **ends** — the booked order's guarantee stops when the material
  begins (it becomes an ordinary stock order from there).
