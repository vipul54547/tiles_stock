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

### Phase 2–3 — MADE → POSITION → ORDER FROM STOCK (redesigned 21 Jul with him; supersedes the old
###                "Runs by order, no Made button" sketch). Depends on the LOT layer (docs/LOT_LAYER_PLAN).
The flow he locked: **booked → planned → taken into production → MADE → *Order from stock* (held by
default) → dispatch (whenever the truck comes).** "Made" is NOT dispatch — the ship date is unknown,
so the material is HELD for the customer and waits.

**A. The Made dialog stays ON the Runs page (keep the button).** Two rows for the SAME design:
- **Row 1 — Premium:** brand *(fixed = the run's brand)* · design *(fixed)* · quantity · batch · location.
  → stock under that brand's cover, **earmarked to the run's booked orders** (`produced_qty`).
- **Row 2 — Standard:** grade *(fixed)* · **brand ▾** *(auto = the default brand if the brand's toggle
  is on, else the produced brand — always overridable)* · design *(auto = Row 1)* · quantity · batch ·
  location. → **free stock** under the chosen brand's cover.
- One **transactional** submit (both or neither). The Row-2 brand ▾ lists only brands that **cover**
  the design. Batch/location columns show only if the stockist tracks them (LOT flags).
- 🔒 **#2 Standard → free stock, NEVER auto-allocated.** 🔒 **#3 run progress = PREMIUM only** (standard
  is extra, never completes a target). This solves his (D): the default brand need not appear on the
  Runs page — its standard is entered from the produced brand's Made action and routed automatically.

**B. Per-brand toggle** `brands.standard_in_default` — *"this brand's standard is packed in the default
brand."* Set at brand create + editable. Drives the Row-2 default only; nothing is ever compulsory (his
rule C: an all-standard run may be sold under the real brand).

**C. NEW page after Runs — the PRODUCTION POSITION, by design.** Per design: **Program** (ticked into
production) · **Premium made** · **Standard made**. Gives him the true position of the run. We do NOT
track/enforce the remaining gap — the stockist handles any shortfall manually. From here he **sends
ready orders → Order from stock**, and a **PARTIAL send is allowed** (hold what's ready, leave the rest).

**D. Order from stock (the JOIN, as a HELD staging area).** Sent orders land here with the produced
material **HELD** for the customer by default (reserved — out of free stock — so it can't be sold away
while it waits). **Standard is NEVER held** (stays free). Dispatch runs from here whenever the vehicle
arrives → the existing `/d/` receipt. Reuse the hold + dispatch mechanism; the booked order becomes an
ordinary held stock order at this point (the promise ends where the material begins).
- Guard: `customer_delete` must also refuse when a booked order exists (hole left 20 Jul).
- Two-way traceability + HISTORY: per run·design·buyer — Ordered → Planned → Premium made → Dispatched,
  with **batch·location** (real audit trail); standard shown separately as free stock.

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
