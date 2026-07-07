# Order "Remaining" / Dispatch-Close Model — Build Plan

_Locked 2026-07-07 via DDPI. Part of the broader dispatch/order redesign._

## The problem it solves
After a **partial dispatch**, the leftover (`ordered − dispatched`) was left as
"pending" **forever**, with no way to know *why* (still coming? not available?
not needed?) and no way to close it. Orders got stuck in `dispatching` with
phantom pending boxes nobody was backing.

## The locked model
The stockist's **hold choice at dispatch** drives the whole lifecycle:

| Stockist picks | Order | Remaining stock | Buyer sees | Buyer action |
|---|---|---|---|---|
| **Release hold** | **Closed** (`completed`) | back to open stock | "Dispatched D · Remaining R — closed. Re-order R if needed." | Re-order (optional) |
| **Keep hold** | **Open** (`dispatching`, Part-N) | reserved for this buyer | "Dispatch Part-N: D shipped, R still reserved & coming." | None — just wait |

**Invariant:** an order is "open/pending" **only when real stock is held for it**
→ phantom pending is impossible by construction. Multi-lot delivery falls out for
free (keep → Part-1 → keep → Part-2 → … → release → Completed).

### Consequence (accepted)
"Keep hold" reserves actual stock, so it only works if the stockist *has* the
stock. A *restock* backorder (rest not in stock yet) is handled by **close +
buyer re-orders when it's back** — this keeps "open = real stock held" clean.

## Phases

### Phase 1 — Backend: dispatch close/keep + hold release ✅ DONE (2026-07-07)
- `dispatch_inquiry` gains `p_close boolean default true` (two legacy overloads
  collapsed into one 9-arg signature; trailing booleans default so old app builds
  still resolve via named args).
- Logic: `dispatched>0 and (outstanding=0 or p_close)` → `completed` + zero the
  remaining `held_qty` (release). `dispatched>0 and not p_close` → `dispatching`
  (remaining stays held; `held_of()` nets it via `held_qty − dispatched_qty`).
- Notification wording: **Order closed** ("… N not included — re-order if you
  still need them"), **Order completed**, or **Dispatch update** ("… N still
  reserved & coming").
- Dart: `dispatchInquiry(..., bool close = true)` → passes `p_close`.
- Migration `supabase/migrations/20260707_dispatch_close_or_keep_hold.sql`.
- **Round-trip verified:** close → completed / held_qty 0 / held_of 0; keep →
  dispatching / held_of 60 (100 held − 40 shipped).

### Phase 2 — Stockist dispatch UI: the toggle (NEXT)
In `add_dispatch_screen.dart`, when a remaining exists after entering dispatch
quantities, show:
- ◉ **Close order — release the rest to stock** (default, `close=true`)
- ○ **Keep open — hold the rest for this buyer (Part-N)** (`close=false`)
Reconcile with the existing `reduceStock` toggle into one clear "what happens to
the rest" section. Device-verify both paths.

### Phase 3 — Buyer "My Orders" tracker (the main new surface)
New `my_orders_screen.dart`, reusing `my_orders` / `inquiry_detail` /
`my_dispatches` (no new read RPCs):
- Per-order card: stockist, token, **status chip** (Sent / Confirmed / Part-N /
  Closed / Completed), **Ordered · Dispatched · Remaining**.
- **Remaining > 0** → **"Re-order remaining"** button.
- Dispatched/closed → **"View dispatches"**.
- Entry: buyer **⋮ → "My Orders"** + a "Track order →" link on the My Choice strip
  (My Choice stays a pure basket).
- **Re-order remaining:** a small `reorder_remaining(p_inquiry)` RPC that creates a
  **fresh** draft order with the leftover designs+qty.
  - ⚠️ Pre-check: confirm `trg_my_choices_sync_inquiry` never reopens the closed
    order; if risky, the dedicated RPC bypasses the trigger.

### Phase 4 — Buyer agency (optional, later)
- **Cancel order** while still open & un-dispatched (`cancel_my_order`, notify
  stockist, release any hold).
- On a **kept-open** order: **"Don't need the rest"** → releases the stockist's
  held stock.

### Phase 5 — Cleanup
- Retire the old "partial pending with no backing" semantics; make My Choice strip
  point to My Orders; keep status labels consistent buyer + stockist.

## Notes
- No new tables. One param on `dispatch_inquiry` (done), one small
  `reorder_remaining` RPC (Phase 3), one new buyer screen + a stockist toggle.
- Each phase: migrate → round-trip → build APK → device-verify → commit/push/deploy.
