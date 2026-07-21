# The LOT layer — batch + location below the holding (plan of record, 21 Jul 2026)

Locked 13 Jul (`project_print_master_model`), never built. Being built **now, before the production
"Made"/JOIN work**, because that is the natural home for batch + location — and because **stock is
empty (0 rows)**, so there is nothing to migrate and nothing to break. Building it later, with live
holdings + dispatch history, would be far riskier.

## The model

```
HOLDING (designs)   product × brand × quality     · control_quantity + status STAY here
                    box_quantity  →  trigger-maintained SUM of its lots (never written directly)
   ↓
stock_lots          holding_id · batch (text, null) · location_id (null) · box_quantity
                    merge key (holding_id, batch, location) — same batch+spot ADD together
                    transient: box_quantity → 0 deletes the row; the HOLDING survives at 0
stock_locations     (stockist_id, code) — his own flat pick-list, add on the fly, free text
```

- **Batch = shade**, one free-text field off the carton. **Location** = a code from his pick-list.
- Both **OPTIONAL, in no key** — they DECOMPOSE a holding, they never split a product/holding.
  A stockist who tracks neither gets **one lot, batch+location NULL**, invisible to him.

## His decisions (21 Jul)

- **TWO separate admin flags**, default OFF: `stockists.track_batches` and `stockists.track_locations`
  — a stockist may use one without the other. They only decide whether he **SEES** the fields; there
  is **no second data path** (the surface_mode trap). Same pattern as `book_orders_enabled`.
- **Dispatch: he PICKS the lot.** When a holding has more than one lot, dispatch asks which
  batch/location to ship from.
- **Location is a managed pick-list** (`stock_locations`); at stock-add he picks an existing code or
  types a new one (auto-added to the list).

## The invariant that drives the build

> **`designs.box_quantity` is the SUM of its lots — nothing writes it directly, ever.**

A trigger on `stock_lots` recomputes it. So **every quantity mutation goes through a lot.** The 9
functions that write `box_quantity` today all move onto lots:

`stock_add_holding` · `add_stock` · `adjust_stock` · `import_stock_batch` · `set_pending_stock` ·
`library_merge_masters` · `dispatch_stock` · `dispatch_inquiry` · `dispatch_walkin`.

Read each one's live body before converting it.

## Sequence

### L1 — foundation, lot-backed but INVISIBLE (flags off ⇒ behaves exactly like today)
- Tables `stock_lots`, `stock_locations`; columns `stockists.track_batches`, `track_locations`.
- Trigger: `stock_lots` change → `designs.box_quantity = sum(lots)`.
- Convert all 9 writers to operate on lots. Add-side writers upsert a lot (NULL batch/location for
  now); dispatch decrements a lot **oldest-first** (interim — the picker is L3), so the total stays
  consistent everywhere. `stock_locations` CRUD RPCs. Admin toggles in Manage Stockists.
- ✅ Testable: add stock → one NULL lot, `box_quantity` correct; dispatch → lot decrements; a lot at
  0 disappears, the holding stays. Nothing looks different to the stockist yet.

### L2 — Add Stock UI
- Batch text field (iff `track_batches`) + location picker with add-on-the-fly (iff `track_locations`)
  on the Add-Stock form(s). `stock_add_holding` gains `p_batch` / `p_location_id`.
- ✅ Testable: flags on → add stock with batch+location → the holding shows separate lots.

### L3 — Dispatch picks the lot
- Replace L1's oldest-first with the picker: when >1 lot, dispatch asks which batch/location to ship.
- ✅ Testable: two lots → dispatch → choose one → only that lot drops.

### L4 — Holding card shows its lots
- The stock/holding card lists its lots (batch · location · boxes) when the stockist tracks either.

### Then — production "Made" writes a lot
- The production output ("Made") becomes a lot-aware stock-add: it pre-fills design/cover/packing
  from the run, and (if tracked) asks batch + location. This is where the LOT layer meets the
  Runs/JOIN work we paused.

## Rules carried through
- Lots are **transient** (deleted at 0); the **holding survives at 0** (`out_of_stock`) — "available 0"
  ≠ "I don't stock it".
- **No stockist-type branching, no second data path** — the flags gate DISPLAY only.
- `control_quantity` (the HOLD) stays on the **holding**, not the lot. `F_stock = box_quantity − control
  − hold` is unchanged (box_quantity is now the lot sum).
- Batch/location are **never identity, never required, never block a save.**
