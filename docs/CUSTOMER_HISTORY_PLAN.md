# Customer history: "this customer came back — what did he take last time?"

Status: **PLANNED, not built.** Written 2026-07-12.
Supersedes **Phase 3** of `DISPATCH_ORDER_BACKED_PLAN.md` (order-backed dispatch).

---

## 1. What the user actually asked for

> *"when we enter walk-in dispatch — is it about history, how to save, where to save, or in
> future if the same customer is coming, how to find? … or is walk-in dispatch creating any
> problem to maintain stock?"*

Two questions. The code answers them differently:

**"Is walk-in breaking stock?" — No.** `dispatch_walkin` and `dispatch_inquiry` reduce stock with
byte-identical SQL:

```sql
box_quantity = greatest(0, box_quantity - v_disp),
status = case when greatest(0, box_quantity - v_disp) = 0 then 'out_of_stock' else 'active' end
```

There is no stock problem on the walk-in path. There never was.

**"Can I find a returning customer's history?" — No, and that is the real gap.**

---

## 2. Verified against the live DB, 2026-07-12 (do not re-derive)

Only **four** functions in the whole schema touch customers:

| Function | Role |
|---|---|
| `upsert_customer` | creates / reuses a customer |
| `list_customers` | returns name, phone, address — **no history** |
| `dispatch_walkin` | **writes** `dispatch_notes.customer_id` |
| `admin_set_stockist_customers` | the `customers_enabled` toggle |

⇒ **`dispatch_notes.customer_id` is a write-only column.** Nothing reads it back. There is no
customer history screen; it was never built. `list_customers` is used only as an autocomplete on
the Dispatch screen.

⇒ **`dispatch_inquiry` cannot record a customer at all.** Its `insert into dispatch_notes (…)`
omits `customer_id`. The UI already works around this — `manual_dispatch_screen.dart:1425` hides
the Customer field whenever an order is attached, with the comment
*"ignores customer_id — so a Customer field here would lie."*
So **an order-backed dispatch loses the customer link**, which is the opposite of what
`DISPATCH_ORDER_BACKED_PLAN.md` assumed.

⇒ **`inquiries` has `customer_hint` (free text) but no `customer_id`.** An order cannot point at a
saved customer.

Live data — the feature is dormant, so **there is no migration risk and no back-fill to do**:

```
dispatch_notes:                    13   (9 walk-in, 4 order-backed)
notes with customer_id set:         0
saved customers:                    0
stockists with customers_enabled:   0
```

---

## 3. Decisions

1. **Keep walk-in dispatch.** It maintains stock correctly and it already saves the customer.
   Phase 3 of the dispatch plan is **superseded** — see §7.
2. **Customer history is a READ feature, not a rewrite.** The rows already exist
   (`dispatch_notes` + `dispatches`). What is missing is a column on `inquiries`, one read RPC,
   and one screen.
3. **History must cover BOTH paths** — a walk-in and an order dispatch to the same customer belong
   in one timeline. This is the only reason we touch `dispatch_inquiry`.
4. **Customers stays opt-in** (`customers_enabled`). Off for every stockist today; turning it on is
   a per-stockist admin choice, not part of this build.

---

## 4. Design

### A. Close the write gap (so order dispatches also link)

The order should know who it is for; the dispatch note then inherits it. That keeps a single
source of truth and means an *attached-order* dispatch does not have to re-ask.

1. **Migration:** `alter table inquiries add column customer_id uuid references stockist_customers(id)`.
   (This is the one genuinely good idea inside old Phase 3 — keep it, drop the rest.)
2. **`create_stockist_order`** takes an optional `p_customer_id` alongside the existing
   `customer_hint`.
3. **`dispatch_inquiry`** copies `inquiries.customer_id` onto the `dispatch_notes` row it writes.
   One line in the existing `insert`. No signature change, no new dispatch path.
4. **`manual_dispatch_screen`**: the Customer field may now be **shown** on the attached-order
   branch (read-only, naming the order's customer) instead of hidden — the comment at :1425 stops
   being true and must be updated in the same commit.

`dispatch_walkin` is **not touched.** It already writes `customer_id` correctly.

### B. The read (the actual feature)

New RPC — `my_customer_history(p_customer_id uuid)`. Returns the customer's dispatch notes, newest
first, each with its lines:

```
[{ dispatch_no, dispatched_on, invoice_no, vehicle_no, transporter, note,
   inquiry_token,            -- null for a walk-in
   total_boxes,
   lines: [{ design_name, size, brand, quality, surface_label, surface_type, boxes }] }]
```

Rules:
- `my_*` prefix — it is the signed-in stockist's own data (CLAUDE.md convention).
- Scope it: `stockist_customers.stockist_id = (the caller's stockist)`. A stockist must never read
  another stockist's customer.
- Read `dispatches` joined to `dispatch_notes` on `dispatch_note_id`; **do not** read
  `inquiry_items` — a walk-in has none, and dispatch is the truth (CLAUDE.md / dispatch plan §7).
- Card label per line = `Word (Canonical)` — `surface_label` + `surface_type`, never concatenated
  into `design_name`.

### C. The screen

**Customers** list (`list_customers`) → tap a customer → **Customer History**.

- Header: name, phone, city. A **Call** and a **WhatsApp** action, each with a **Copy** fallback
  ([[feedback_copy_when_no_whatsapp]]).
- Summary: total boxes ever taken · number of dispatches · last visit date.
- Timeline: one card per dispatch note — date, `dispatch_no`, invoice, total boxes; expand to see
  the design lines. A walk-in and an order dispatch look the same here, except the order one shows
  its token.
- Empty state: "No dispatches yet."

Entry point: the dashboard's **Customers** pill is a disabled placeholder today
([[project_dashboard_ia]]) — this is what fills it.

---

## 5. Phases

**Phase A — the write gap.** `inquiries.customer_id`; `create_stockist_order` takes it;
`dispatch_inquiry` copies it to the note; un-hide the Customer field on the attached-order branch.
Ship alone: no screen yet, but from this point every new dispatch records its customer.

**Phase B — the read.** `my_customer_history` RPC + `SupabaseDataService.myCustomerHistory()`.

**Phase C — the screen.** Customers list → history timeline. Fill the dashboard placeholder.

A and B are independent. C needs B.

---

## 6. Must not break

- **Stock.** Nothing in this plan touches a `box_quantity` write. If a diff does, it is wrong.
- **Walk-in dispatch.** Untouched. `dispatch_walkin` keeps working and keeps writing `customer_id`.
- **Old dispatch history.** 9 walk-in notes have `inquiry_id = null` and 13 notes have
  `customer_id = null`. Every reader must tolerate both nulls. The history screen simply will not
  list pre-existing dispatches under any customer — correct, because none were recorded against one.
- **`customers_enabled = false` is the default.** With the flag off, the Customer field stays plain
  text, nothing is saved, and the history screen must not be reachable.
- **Over-dispatch stays allowed** — dispatch is the final truth, system stock can be stale.
- **The buyer's identity.** An order from an app buyer has `end_user_id`, not a
  `stockist_customer`. Do not conflate them: `customer_id` stays null there, and that is correct.

---

## 7. Why Phase 3 of DISPATCH_ORDER_BACKED_PLAN.md is superseded

Old Phase 3 = "every dispatch is backed by an order; `dispatch_walkin` is deprecated for new
writes; a new `dispatch_counter` RPC creates order + hold + dispatch in one transaction."

It was justified on three grounds. Checked against the code on 2026-07-12:

| Claim | Reality |
|---|---|
| Walk-in leaves no proper record | False. It writes `dispatch_notes` + `dispatches` + `customer_id`. |
| Walk-in risks stock drift | False. Identical stock SQL to the order path. |
| Order-backing restores the customer link | **Backwards.** The *order* path is the one that drops the customer. |

What it really bought was **one code path instead of two**, and a counter sale showing up in My
Orders. Neither is a bug; both are tidiness, and the open question in its §8.2 ("is the auto-created
order visible in My Orders?") only exists *because* of the rewrite — dissolving the rewrite dissolves
the question.

**Kept from it:** the `inquiries.customer_id` column (§4A).
**Dropped:** `dispatch_counter`, deprecating `dispatch_walkin`, the auto-created counter-sale order.

If a future need genuinely requires one order behind every dispatch (e.g. GST invoicing off orders),
re-open it then — with that need as the justification, not architectural symmetry.

---

## 8. Test checklist

Phase A:
- [ ] Stockist order with a saved customer → dispatch it → `dispatch_notes.customer_id` is set.
- [ ] Order from an **app buyer** → dispatch → `customer_id` stays null, `end_user_id` set, buyer
      still notified.
- [ ] Walk-in dispatch → still records `customer_id`, stock still reduces.
- [ ] `customers_enabled = false` → no customer is written on either path.

Phase B/C:
- [ ] A customer with one walk-in and one order dispatch shows **both**, newest first.
- [ ] Box totals match the `dispatches` rows exactly.
- [ ] Lines render `design_name` verbatim + `Word (Canonical)` surface.
- [ ] Stockist A cannot read stockist B's customer (RPC scoping).
- [ ] Customer with no dispatches → clean empty state.
- [ ] Over-dispatched line (more boxes than stock) still appears — history is not filtered by stock.
