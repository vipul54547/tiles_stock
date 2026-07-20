# PRODUCTION PLANNING — booked demand, and what the line runs

**Supersedes the production sections of `docs/BOOK_ORDER_PLAN.md`.** Steps 1–2 BUILT (20 Jul 2026,
`20260720n`–`p`); steps 3–8 planned.

His correction, which is the whole plan:

> *"If pratap ceramic booked order of 500 box and 200 box same design is available in stockist
> godown — at this place we are confusing. But real scenario: when stockist wants to take this order
> in production, today stockist decides 'I want to take pratap order', then easily they can see what
> is available in stock, according to that stockist can make production planning. If they want to
> take pratap order after 10 days, why should stockist block his same design box from today? So our
> flow will be: **BOOKED ORDER IS NOTHING TO DO WITH CURRENT STOCK POSITION.**"*

> *"When stockist starts production planning, at that time they look at booked orders, select
> individual design OR buyer order, as per which punch is running, which surface is running, which
> body is running. After taking into production, stockist needs history: which design taken into
> production for which buyer."*

## 1. The model

A **BOOKED ORDER is pure standing demand.** A customer, a BOX (a brand's cover on a packing), and a
quantity in boxes. It does **not** hold, reserve, allocate or decrement anything: no `held_qty`, no
`dispatched_qty`, no `control_quantity`, no F_Stock effect, no row in `designs`. Stock is read
**only at production-planning time, as information on that day** — never subtracted from demand.

🔑 **The enforcement is ABSENCE, not a guard.** `book_order_lines` has no reservation column, so the
rule cannot be broken by forgetting. This replaced 7 "ignore book lines" guards, **three of which
were already wrong in prod** — `hold_order` ran `update inquiry_items set held_qty = quantity` with
no box guard, reserving stock against booked demand: exactly what he forbids.

🎁 **The customer books a COVER; the factory makes a TILE; the cover goes on at PACKING.** *"When
stockist makes production planning they have idea about which brand have which design, so they are
combining all this and make production planning. When material is packed, at that time only cover
will come."* So the booked line is per BOX, the run line is per TILE, and output is declared per BOX.

🚫 **NO QUALITY on a booked line.** *"Every time production planning is done for only premium
quality; standard is a by-product."* Demand is always premium. Standard falls out of the run and
goes to **free stock**, allocated to nobody. Grade is a fact about OUTPUT, not about demand.

## 2. Decisions (settled with him, 20 Jul)

| # | question | answer |
|---|---|---|
| 1 | Own tables, out of `inquiries`? | **YES** |
| 2 | One order mixing stock + booked lines? | **NO** — stock orders already have Hold; keep them separate documents |
| 3 | Own `BO-000001` numbering? | **YES** |
| 4 | Does "take into production" count as made? | **NO** — only declaring output does |
| 5 | Partly-planned order (2 of 5 designs)? | each line shows **ordered / planned / made**; unplanned lines keep appearing on the Production screen |
| 6 | Stock shown per tile or per box? | **PER BOX** |
| 7 | One line into two runs? | **YES** — 90% one run, 10% partial |
| 8 | Grouping | by **Punch ▸ Surface ▸ Body** — what is running on the line |
| 9 | Quality | **removed from demand**; premium planned, standard is by-product → free stock |
| 10 | Run targets | entered in **BOXES**, pieces derived |

## 3. Schema (BUILT)

```
book_orders       id, stockist_id, customer_id, customer_hint, token 'BO-000001',
                  status open|closed|cancelled, note, created_at, updated_at, closed_at
book_order_lines  id, order_id, box_id NOT NULL, quantity>0, is_urgent, produced_qty
                  unique (order_id, box_id)
```

🚫 **No `held_qty`, no `dispatched_qty`, no `design_id`, no `quality`, no `wanted_by`.** Each absence
is a rule. `box_id NOT NULL` keeps the old law: a box exists only because a human ticked that cover
(`box_put_cover`), so an order cannot be booked for a cover nobody declared.

RPCs: `create_book_order(p_hint, p_lines, p_customer_id)` where a line is
`{library_id, brand_id, quantity, is_urgent?, packing_id?}` · `my_book_orders` · `book_order_detail`
· `book_line_set_urgent` · `book_order_set_status` · `book_order_delete` (refuses once anything is
produced).

## 4. Still to build

| # | step | verified by |
|---|---|---|
| 3 | Book Orders get their **own screen** `/stockist/book-orders`, out of Inquiries | Inquiries shows only stock orders |
| 4 | **`my_production_demand` + `/stockist/production`** — filters (punch · surface · body · series · size · design · brand · customer · ⭐), ordered group-by, stock per box as **information with an `as_of` time** | booking changes demand and NOT stock; adding stock changes stock and NOT demand |
| 5 | `production_views` — saved groupings | a named view reopens identically |
| 6 | `production_runs` / `_lines` (TILE, pieces) / `_demand` (**the history join**) / `production_take_into_run` | ⚠️ **every stock number identical before and after** |
| 7 | `production_declare_output` — resolve-or-raise, creates the HOLD + `stock_in`, raises `produced_qty` ⭐urgent-first; standard → free stock | uncovered brand raises; `20260720e` self-check still passes |
| 8 | `my_production_history` + Customer History section | "which design, for which buyer, when" |

## 5. 🚫 What must not happen

- 🚫 **A booked order never holds, reserves or blocks stock.** No such column — do not add one.
- 🚫 **Never net demand against stock.** No `to_make = remaining − in_stock`, no pre-ticked
  shortfall. He sees 500 ordered and 200 in godown and **he** decides, on the day.
- 🚫 **No production path may call `box_put_cover`. RESOLVE, or RAISE.** (`20260720e`)
- 🚫 **Book orders never appear in Inquiries**, and stock orders never in Book Orders.
- 🚫 No stored sq ft. No thickness/surface/body/brand asked at the production counter.
- 🚫 **Never verify a schema change with raw SQL — call the RPCs.** `20260720g` shipped a 42P10 to
  prod because its self-test inserted rows directly.
