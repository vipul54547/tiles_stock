# Buyer order: show real availability before sending

Status: **PLANNED, not built.** Written 2026-07-11.

---

## 1. The problem

A buyer adds designs to My Choice (`my_choices`), leaves the basket for days or weeks,
then hits **Send order**. `send_order_to_stockist` copies the basket straight into the
order:

```sql
insert into inquiry_items (inquiry_id, design_id, quantity)
select v_inq, mc.design_id, mc.quantity from my_choices mc ...
```

**There is no stock check at all.** A stale basket becomes a wrong inquiry.

### The deeper cause — the buyer chose against an inflated number

| Source | Formula | Subtracts control? | Subtracts **held**? |
|---|---|---|---|
| `/s/` link — `public_catalog` | `greatest(0, box_quantity − control_quantity − held_of(id))` | ✅ | ✅ |
| Buyer app — `market_designs` view | `GREATEST(0, box_quantity − control_quantity)` | ✅ | ❌ **NO** |

`market_designs` never subtracts **held** boxes (stock already booked by other buyers'
locked orders). So the wrong inquiry starts at *selection* time, not just at send time.
Putting a gate only at Send would leave the buyer still choosing from a fake number.

**F_Stock model:** free stock `F = max(0, P − C − H)`.
`held_of(design)` = `sum(held_qty − dispatched_qty)` over inquiries in status
`locked` / `dispatching`.

---

## 2. Decisions (locked with the user, 2026-07-11)

1. **Allow send even when the buyer wants more than is available.** An inquiry is a
   *request*, not a reservation — the stockist may restock or dispatch partially. We SHOW
   the truth and make "adjust" the easy path, but we do **not** block.
2. **Fix `market_designs`** so the buyer app shows free stock, like `/s/` already does.

---

## 3. Verified in the live DB (do not re-derive)

- `my_choices(end_user_id, design_id, quantity)` — the basket. Written by a direct table
  upsert from the client (`supabase_data_service.dart` ~2912–2952), not an RPC.
- `send_order_to_stockist(p_stockist_key)` — copies basket → `inquiry_items`, marks sent,
  clears the basket for that stockist. **No stock check.**
- Buyer basket UI: `lib/screens/end_user/my_choice_screen.dart` (Send at ~line 204).
- `TileDesign.boxQuantity` reads `market_designs.box_quantity`. **Changing the view's
  VALUE needs no Dart change** — same column name.

---

## 4. Design

### Fix 1 — `market_designs` shows FREE stock (fix the source)

Change the view to subtract held, matching `public_catalog`:

```sql
GREATEST(0, d.box_quantity - d.control_quantity - held_of(d.id)) AS box_quantity
-- and in the WHERE:
AND (d.box_quantity - d.control_quantity - held_of(d.id)) > 0
```

- Same column name ⇒ **no Flutter change**.
- Brings the app in line with `/s/` and with the F_Stock model.

⚠️ **Consequence to accept:** a design whose stock is fully held by one locked order now
has `F = 0`, so it **disappears from the marketplace** for everyone else. This is correct
(there is nothing free to sell) and `public_catalog` already behaves this way — but it is a
visible behaviour change. Confirmed wanted.

⚠️ **Performance:** `held_of()` is a per-row correlated lookup on `inquiry_items`. In
`public_catalog` it runs for ONE stockist; in `market_designs` it would run across the whole
marketplace. Fine at today's size. If the marketplace grows, precompute held into a column
or a materialized aggregate. Needs an index on `inquiry_items(design_id)` — verify.

### Fix 2 — availability in the basket, and a gate at Send

**New RPC — `choices_availability(p_stockist_key)`.** For the signed-in buyer's basket at
one stockist, return per line:

| field | meaning |
|---|---|
| `design_id`, `name`, `size`, `quality`, `surface_label`, `surface_type`, `brand`, `image` | to render the row |
| `wanted` | `my_choices.quantity` |
| `available` | free stock `= max(0, P − C − H)` |
| `status` | `ok` \| `reduced` \| `out` \| `gone` |

- `ok` — `wanted <= available`
- `reduced` — `0 < available < wanted`
- `out` — `available = 0`
- `gone` — the design no longer exists / is no longer offered publicly

**Buyer UI:**

1. **My Choice screen — show it continuously, not only at Send.**
   Each line shows `You want 50 · Available 20`, with problem lines highlighted. The buyer
   sees reality *before* reaching for the button. A popup only at Send is a nasty surprise.

2. **Send order.**
   - All lines `ok` → **send immediately, no extra screen.** No friction on the happy path.
   - Any problem → show the **review sheet**.

3. **Review sheet** — per problem line:
   - `Use available (20)` · `Remove` · or leave it as it is
   - plus one **"Adjust all to available"** button (the easy, obvious path)
   - **Send order stays enabled** (decision 1 — allow).

4. **On confirm:** write the adjusted quantities back to `my_choices`
   (upsert / delete), then call **`send_order_to_stockist` unchanged.**

### Deliberately NOT doing

- **No hard block** on over-ordering (decided).
- **No change to `send_order_to_stockist`.** It keeps reading the basket; the client fixes
  the basket first. Less risk, less duplication.
- **The race is accepted.** Stock can change in the seconds between review and send. That is
  fine: an inquiry is a *request*, not a reservation. Real reservation happens only when the
  **stockist holds** the order (`hold_order`).

---

## 5. Files touched

- `supabase/migrations/` — (a) `market_designs` view; (b) `choices_availability` RPC.
- `lib/services/supabase_data_service.dart` — `choicesAvailability()`.
- `lib/screens/end_user/my_choice_screen.dart` — per-line availability + review sheet.
- No change to `TileDesign` or to `send_order_to_stockist`.

---

## 6. Must not break

- **`/s/` `public_catalog` is already correct — do not touch it.**
- **Grants:** `market_designs` is read by guests/anon. Recreating the view must keep its
  existing grants (`CREATE OR REPLACE VIEW` keeps them; a `DROP + CREATE` does **not**).
- **`TileDesign.boxQuantity`** keeps its meaning "boxes the buyer can actually ask for".
- Buyer's basket quantity edits must still clamp to a valid range and allow tap-to-type
  ([[feedback_tappable_stepper_qty]]).

---

## 7. Test checklist

Setup: one design, stock 100, control 0. Buyer A puts 50 in the basket.

- [ ] Buyer app shows **100** available.
- [ ] Stockist accepts+holds another order for 80 of that design (`held = 80`).
- [ ] Buyer app now shows **20** available (was 100) — the `market_designs` fix.
- [ ] Buyer's basket line shows `You want 50 · Available 20`, flagged.
- [ ] **Send** → review sheet appears listing that line.
- [ ] `Adjust all to available` → line becomes 20 → send → order has **20**.
- [ ] Send **without** adjusting → allowed → order has **50** (decision 1).
- [ ] A design held to zero free → shows `out of stock`, and disappears from the marketplace.
- [ ] Basket with all lines fine → Send goes straight through, **no review sheet**.
- [ ] `/s/` catalog numbers are unchanged.
