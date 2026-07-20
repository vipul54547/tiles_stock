# SPLITTING A BOOKED ORDER, AND EDITING ONE

**Status: PLANNED, not built.** (20 Jul 2026) Follows `20260720n`…`u`.
Completes `docs/PRODUCTION_PLANNING_PLAN.md`.

His idea, and he was right where I was wrong:

> *"When stockist select order from 'choose order' and going to 'plan what to run', at that time in
> second row in quantity we have option of tick_mark to consider or not — from here you can split
> order or not. BO-00012 to BO-00012/A and BO-00012/B, so which design is not running it will keep
> in BO-00012/B automatic and keep in 'Booked Order', and which is in tick_mark will go ahead as
> BO-00012/A."*

## 1. 🔑 Why the split is right (I argued against it; I was wrong)

I said "the run is the truck, you don't need a second name". That missed the real benefit:

> **A booked order in the open list should contain ONLY work that has not been planned yet.**

Tick 4 of 7 designs and the 4 leave as a **slice**; the 3 that stay are a clean, ordinary booked
order. Nothing half-planned ever sits in the list, so no screen has to explain a mixed state.

🔑 **The tick was already the split.** The mechanism exists — `production_run_demand` records exactly
which lines and how many boxes. Slicing simply makes that visible as a document.

**What it removes:**
- no `planned` tracking per line, and no "show only the unplanned part" filter in planning
- no "partly planned" chip to design, explain or get wrong
- ⚡ **editing becomes trivial** (§4): the editable order only ever holds un-planned work, so almost
  every edit guard disappears

**What it does NOT remove — say so plainly:** a slice of 500 that yields 300 off the line still needs
`ordered · made · moved`. Splitting at PLANNING time does not remove counting at PRODUCTION time.
That was the honest half of my objection and it still stands.

## 2. Numbering — the remainder keeps the customer's number

⚠️ **One refinement on his sketch.** He wrote `BO-00012` → `/A` + `/B`. I recommend instead:

```
BO-000012              the customer's order. KEEPS ITS NUMBER for life.
   ↓ tick, take into production
BO-000012/A            slice 1 → RUN-00007 → … → INQ-000456   (truck 1)
BO-000012              still here, holding the remainder — clean and normal
   ↓ tick again
BO-000012/B            slice 2 → RUN-00011 → … → INQ-000478   (truck 2)
```

**Why:** the number the customer was told never changes, and each truck still gets its letter. If
the parent were renamed `/B` on the first split, the reference he gave the customer would vanish and
would keep changing on every split.

🚫 **No split when there is no remainder.** Tick everything at full quantity and the order itself
goes into production — no `/A`, no orphan parent.

## 3. Schema

```
book_orders
  + parent_id  uuid null references book_orders(id) on delete restrict
  + slice      text null                      -- 'A','B','C' … null on the customer's own order
  status: open | in_production | closed | cancelled      -- 'in_production' is NEW
  token: parent's token || '/' || slice   for a slice
```

- 🔑 A **slice is never edited and never re-planned.** It exists to be produced.
- The **parent** is what he edits, and what Production planning offers.
- `production_run_demand` points at the **slice's** lines, so the run's history is unchanged.
- Booked Orders tabs: **Open** (parents with work left) · **In production** (slices) · **Closed**.
  📌 A slice *moves tab*; nothing ever vanishes.

## 4. ⚡ Editing — nearly free, because of the split

Since the parent only ever holds **un-planned** work, the guards almost all disappear:

| action | rule |
|---|---|
| change a quantity | ✅ always — nothing is planned |
| add a design | ✅ always |
| remove a design | ✅ always |
| edit the customer / note | ✅ always |
| edit a **slice** | 🚫 refused — *"BO-000012/A is in production. Edit BO-000012 for what is still to plan."* |
| edit a **closed / cancelled** order | 🚫 refused |

Compare with what editing would have cost **without** the split: every change would have to check
"is this line planned into an open run", "is produced_qty above the new quantity", "is part of it
already converted". All of that goes away.

RPCs:
```
book_order_update(p_id, p_hint, p_customer_id)
book_order_line_set(p_line_id, p_quantity, p_is_urgent)     -- quantity > 0
book_order_line_add(p_order_id, p_library_id, p_brand_id, p_quantity, p_is_urgent, p_packing_id)
book_order_line_delete(p_line_id)                            -- last line? then delete the order
```
All four refuse unless the order is `open` **and** `slice is null`. Line add reuses the same
`_box_resolve`-or-raise as `create_book_order` — 🚫 booking still may not invent a cover.

## 5. `production_take_into_run` changes

1. Work out, per picked order, the ticked lines and their planned quantities.
2. **Whole order ticked at full quantity** → no slice; set the order `in_production`.
3. **Otherwise** → create the slice (`parent_id`, next free letter, token `<parent>/<letter>`,
   status `in_production`), move the ticked quantities onto it, and **reduce the parent's lines by
   the same amount**. A parent line reduced to 0 is deleted. A parent left with no lines is closed.
4. `production_run_demand` references the **slice's** line ids.

⚠️ **The arithmetic must balance**: parent + all slices = the original order, always. The migration
carries a self-check, and so does the RPC.

## 6. What this replaces

`docs/PRODUCTION_PLANNING_PLAN.md` step 4 said Production planning shows "only the unplanned part",
computed from `planned`. With slicing, **everything a parent holds is unplanned by construction**, so
`my_production_demand` no longer needs the `planned` figure at all. Simpler, and one fewer number to
get wrong.

## 7. Staged delivery

| # | step | verified by |
|---|---|---|
| 1 | `parent_id` · `slice` · `in_production` status; `my_book_orders` returns them; Booked Orders tabs | an existing order still lists exactly as today |
| 2 | `production_take_into_run` slices; balance self-check | tick 4 of 7 → `/A` has 4 lines and is `in_production`, parent has 3 and stays `open`, totals balance |
| 3 | partial-quantity split: tick 300 of 500 → 300 to the slice, 200 stays on the parent | the two add to 500 |
| 4 | the four edit RPCs + the edit UI on Booked Orders | a slice refuses editing in plain English; a parent edits freely |
| 5 | drop `planned` from `my_production_demand` and the screen | planning shows the parent whole |

## 8. 🚫 What must not happen

- 🚫 **Never edit a slice.** It is in production; the material may already be part-made.
- 🚫 **Never let parent + slices drift from the original total.** Self-check it.
- 🚫 A slice is never re-planned or re-sliced — it goes forward only.
- 🚫 Booking still may not invent a cover: line-add resolves the box or raises.
- 🚫 **Verify through the RPCs, never with raw SQL** — `20260720g` shipped a 42P10 to prod that way.
