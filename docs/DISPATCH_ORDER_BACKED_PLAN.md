# Dispatch: one order-backed path + a safe design picker

Status: **Phases 1–2 SHIPPED. Phase 3 SUPERSEDED 2026-07-12 — do NOT build it.**
Written 2026-07-11.

> ## ⛔ Phase 3 is dead. Walk-in dispatch STAYS.
>
> Phase 3 ("every dispatch is backed by an order", `dispatch_counter`, deprecate
> `dispatch_walkin`) was justified on three claims. All three failed when checked against the
> live code on 2026-07-12:
>
> - *"Walk-in leaves no proper record"* — **false.** It writes `dispatch_notes` +
>   `dispatches` + `customer_id`.
> - *"Walk-in risks stock drift"* — **false.** Its stock SQL is byte-identical to the order path.
> - *"Order-backing restores the customer link"* — **backwards.** `dispatch_inquiry` omits
>   `customer_id` from its note insert, so the **order** path is the one that drops the customer.
>   `manual_dispatch_screen.dart:1425` already hides the Customer field for exactly this reason.
>
> What the user actually needs — *"if the same customer comes again, how do I find them?"* — is a
> **customer history read**, which Phase 3 would not have delivered. That is now
> **`docs/CUSTOMER_HISTORY_PLAN.md`**.
>
> **Kept from Phase 3:** the `inquiries.customer_id` column.
> **Dropped:** `dispatch_counter`, deprecating `dispatch_walkin`, the auto-created counter-sale
> order — and with it the §8.2 open question, which only existed because of the rewrite.
>
> Re-open only if a real need appears (e.g. GST invoicing off orders) — justified by that need,
> not by architectural symmetry. Sections 3–7 below are left intact as the record of what was
> verified; read §4B and §5-Phase-3 as **history, not a spec**.

---

## 1. The problem

Two problems, and they are not the same problem.

**Problem A — the wrong variant gets picked.**
One print can be held in several variants: brand × quality × surface.
`DELTON_8_A` alone is 6 holdings (3 surfaces × Premium/Standard).
Today the dispatch picker (`manual_dispatch_screen._pickDesign`) is **one flat list of
holdings** — 6 near-identical `DELTON_8_A` rows. It is easy to tap Premium when you
meant Standard, or Matt when you meant Glossy. Same risk in the stockist's Add-Order
picker (`stockist_add_order_screen._pickDesigns` — a flat filtered grid).

**Problem B — two different dispatch paths.**
- `dispatch_inquiry` — an order exists (from the platform, or the stockist made it).
- `dispatch_walkin` — no order. A counter sale.

Two paths = two code paths, two shapes of record, and a walk-in dispatch leaves no order
behind it.

**The trap to avoid:** making every dispatch order-backed does NOT fix Problem A. When the
*stockist* creates the order, they still hand-pick brand/quality/surface. It only *moves*
the risky pick from the Dispatch screen to the Order screen. Problem A must be fixed on its
own, wherever a human hand-picks a holding.

---

## 2. Decisions (locked with the user, 2026-07-11)

1. **Every dispatch is backed by an order.** The walk-in *data path* goes away.
2. **But NOT the walk-in speed.** The stockist must not be forced through
   Add Order → Save → Hold → Dispatch as three screens. A counter sale stays **one screen**;
   the app creates the order + hold + dispatch **in the background, in one transaction**.
3. **Over-dispatch stays allowed.** Dispatch is the final truth; system stock can be stale.
4. **Customer stays optional.** A counter sale often has no name (`'Walk-in'` fallback).
5. Picker style = **grouped-variant** (not a full brand→design→size→quality→surface cascade):
   keep search on the design list; make the *small* dimensions explicit and constrained.

---

## 3. Verified against the live DB (do not re-derive)

| Question | Answer |
|---|---|
| Does `create_stockist_order` cap quantity at stock? | **No.** Only `quantity >= 0`. |
| Does `hold_order` cap the hold at stock? | **No.** Sets `held_qty = quantity`; never reads `box_quantity`. |
| Does `hold_order_items` cap at stock? | **No.** Caps only at the *ordered* quantity. |
| So can we hold/order more than we have? | **Yes.** Nothing compares a hold to stock. |
| Does an order carry a saved customer? | **No.** `inquiries` has `customer_hint` (text) only — **no `customer_id`**. |
| Does a dispatch note carry one? | **Yes.** `dispatch_notes.customer_id` exists. |

⇒ **Decision 3 (over-dispatch) is safe.** Routing every dispatch through an order will not
block it.
⇒ **Gap found:** `inquiries.customer_id` does not exist. Without it, an auto-created order
loses the "My Customers" link that `dispatch_walkin` has today.

Holding identity (from `designs_holding_uniq`) is
`(stockist_id, library_id, brand_id, quality, surface_type)`.
`surface_label` is display-only. A library row = one print (name + size), so **size is
implied by the print** — it needs no picker step of its own.

---

## 4. Design

### A. The shared grouped-variant picker (fixes Problem A)

A new widget. **One picker, used everywhere a human hand-picks a holding.**

**Step 1 — pick the PRINT** (searchable, like today).
List is grouped by `library_id` = one row per print (name + size + image), NOT one row per
holding. Each row shows: image · name · size · total boxes · a hint of its variants
(`3 surfaces · 2 qualities`). This alone kills the "6 identical DELTON_8_A rows" problem.

**Step 2 — pick the VARIANT** (constrained + auto-skipped).
Show only the dimensions that are actually ambiguous for this print:

- **Brand** — only if this print has holdings under >1 brand. Else auto-select.
- **Surface** — only if >1 surface in stock. Else auto-select.
- **Quality** — only if >1 quality in stock. Else auto-select.

Rules that make it safe:
- **Only offer what is IN STOCK for this print.** Never the full surface/quality list.
  (Otherwise you re-introduce "picked Glossy when I only hold Matt".)
- **Each option shows its box count** — `Premium 121` · `Standard 5`,
  `Matt 121` · `Raindrop (Sugar) 101`. Seeing the number is what stops the wrong tap.
- **Auto-skip any dimension with exactly one option.** A single-variant print = pick print,
  type qty. The fast path stays fast.

**Step 3 — quantity.** Tap-to-type, per [[feedback_tappable_stepper_qty]].

**Output:** exactly one `TileDesign` (one holding) + qty. This is the same `_sel` the flat
list produces today, so **nothing downstream changes**.

### B. Counter sale = an order created in the background (fixes Problem B)

Keep **one** dispatch screen. When no order is attached, the server does the whole thing in
one transaction instead of the stockist doing it in three screens.

New RPC — `dispatch_counter(p_lines, p_customer_id, p_customer_name, p_invoice, p_vehicle,
p_transporter, p_note, p_date, p_reduce_stock)`:

1. `insert into inquiries` — `source='stockist'`, `customer_hint`, **`customer_id`** (new col).
2. `insert into inquiry_items` — `quantity = dispatched qty`, `held_qty = quantity`.
3. `perform dispatch_inquiry(v_inq, p_lines, …, p_close => true, p_prune => true)`
   — **reuse the existing, tested dispatch logic.** Do not duplicate it.
4. `update dispatch_notes set customer_id = …` for the note it just wrote
   (`dispatch_inquiry` does not set `customer_id`).

Result: a counter sale leaves a real order (created → held → dispatched → completed, nothing
outstanding), a dispatch note, and a customer link. One tap for the stockist.

Notes:
- `dispatch_inquiry` only notifies a buyer when `end_user_id` is not null. A counter-sale
  order has none, so **no spurious notification** — correct by construction.
- `p_reduce_stock` stays a parameter (some stockists keep their real count elsewhere).

---

## 5. Phases

**Phase 1 — the picker (highest value, lowest risk).**
Build the grouped-variant picker widget. Wire it into
`manual_dispatch_screen` (add-a-line / add-extra-design). Nothing else changes; the two
dispatch RPCs are untouched. Ship and test this on its own.

**Phase 2 — ✅ DONE (`c240ad3`).** Not the one-at-a-time picker in the end: a **keyboard
entry bar** (`lib/widgets/holding_entry_bar.dart`), on **both** Add-Order and Dispatch.

    delt ↓ Tab   m ↓ Tab   p ↓ Tab   40 Enter

Same two questions the touch picker asks — the PRINT first, then only the variants that are
genuinely ambiguous, each carrying its box count — but typed, because the stockists work at
a counter, at a keyboard. Brand/Surface/Quality are auto-filled and Tab-skipped when the
print has only one; the bar **refuses to add while more than one holding is still standing**.
The count is the caller's: dispatch counts the shelf (`boxQuantity`), an order counts what is
free to promise (`fStock`).

Add-Order keeps BOTH doors — the multi-select grid stays as **Browse all** (faster for ticking
many at once), it just is not the only way in. Grouping moved to `lib/utils/holding_group.dart`
so the touch picker and the bar cannot drift. Pinned by `test/holding_entry_bar_test.dart`.

**Phase 3 — ⛔ SUPERSEDED 2026-07-12, do NOT build. See the banner at the top and
`docs/CUSTOMER_HISTORY_PLAN.md`. Step 1 below (the `inquiries.customer_id` column) survives, and
moved to that plan's Phase A; steps 2–4 are dropped. Kept here as the record only.**
1. Migration: `alter table inquiries add column customer_id uuid references stockist_customers(id)`.
2. Migration: new `dispatch_counter` RPC (§4B).
3. `manual_dispatch_screen`: when no order is attached, call `dispatch_counter` instead of
   `dispatch_walkin`. The screen barely changes — the "walk-in" branch just calls a different RPC.
4. Deprecate `dispatch_walkin` for **new writes**. **Keep the function and its rows readable** —
   existing walk-in dispatch history must still render (`all_dispatches_screen`, `/d/<token>`).

Phases 1 and 3 are independent. Either can ship first.

---

## 6. Files touched

- `lib/widgets/` — **new** grouped-variant picker widget (shared).
- `lib/screens/stockist/manual_dispatch_screen.dart` — `_pickDesign` → new widget; walk-in
  branch → `dispatch_counter`.
- `lib/screens/stockist/stockist_add_order_screen.dart` — `_pickDesigns` → new widget (Phase 2).
- `lib/services/supabase_data_service.dart` — `dispatchCounter()`.
- `supabase/migrations/` — `inquiries.customer_id`; `dispatch_counter`.
- `CLAUDE.md` — if the "dispatch has two paths" model changes, update it in the same commit.

---

## 7. Must not break

- ✅ **Over-dispatch** — verified unblocked at every step (§3). Keep it that way.
- ✅ **Optional customer** — `'Walk-in'` fallback must survive.
- **Existing walk-in history** — `dispatch_walkin` rows have `inquiry_id = null`. Every reader
  must still handle a null order. Do not delete the function or the rows.
- **The order-attached flow** — its lines are pre-filled from `design_id` and are already safe.
  **Do not touch it.** Only the hand-pick path changes.
- **`_reduceStock` / Close-Keep** — currently gated on "an order is attached". Once *every*
  dispatch has an order, re-check that gate or a counter sale will start demanding those
  choices. A counter sale should default to reduce-stock + close, not ask.

---

## 8. Open questions

1. ~~**Add-Order is multi-select today.**~~ **SETTLED 2026-07-11 → offer both.** Neither (a) nor
   (b): the stockists work at a **keyboard**, so the answer was a typed entry bar, with the
   multi-select grid kept as **Browse all**. See Phase 2 above. The premise in §1 was also stale
   — Add-Order's picker was already a searchable list carrying brand/surface/quality; what it
   lacked was the **box count** and any grouping, so six near-identical `DELTON_8_A` rows sat
   adjacent with no number to tell them apart.
2. ~~Should the auto-created counter-sale order be **visible in My Orders**, or hidden?~~
   **DISSOLVED 2026-07-12.** There is no auto-created counter-sale order — Phase 3 is superseded,
   so the question it depended on no longer exists.

---

## 9. Test checklist

Picker (livok, T, `DELTON_8_A` = 3 surfaces × 2 qualities):
- [ ] Print list shows **one** `DELTON_8_A` row (not 6), with `3 surfaces · 2 qualities`.
- [ ] Tapping it offers 3 surfaces, each with its box count; then 2 qualities with counts.
- [ ] A print with ONE surface and ONE quality skips both steps → straight to qty.
- [ ] Offered surfaces/qualities are only ones **with stock**.
- [ ] The chosen holding matches what the old flat list would have selected.

Order-backed dispatch:
- [ ] Counter sale with no customer name → records, buyer shows `Walk-in`.
- [ ] Counter sale with a saved customer → `dispatch_notes.customer_id` is set.
- [ ] An order appears behind it (`source='stockist'`, status `completed`, outstanding 0).
- [ ] **Over-dispatch**: dispatch more boxes than in stock → allowed, stock floors at 0.
- [ ] Old walk-in dispatches (`inquiry_id = null`) still render in All Dispatches and `/d/<token>`.
- [ ] Attached-order dispatch is unchanged.
