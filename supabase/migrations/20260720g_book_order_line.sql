-- 20260720g — BOOK ORDER, step 1: the order line learns to point at a BOX.
--
-- 📕 A BOOK ORDER is an order for a tile that HAS NOT BEEN MADE YET. Today an order line points at
-- `designs` = **a HOLD**, and a hold IS stock — so an order cannot exist before the tile does. That
-- is the single reason the whole app is stock-only.
--
-- 🔑 A **BOX** exists the moment a human ticks that brand's cover in the Design Library
-- (`box_put_cover`) — long before anything is produced. So a line that points at a `box_id` can be
-- booked for material that does not exist, per brand, and the cover is guaranteed to have been
-- DECLARED BY A HUMAN first. That is what will later make "production lands in stock" legal without
-- any stock path minting a box (20260720e).
--
-- ⚠️ **This step is INVISIBLE.** No writer creates a box line yet, so every existing reader still
-- sees exactly what it saw. Stock orders must behave precisely as they do today; that is the test.
-- Teaching the readers about box lines is the NEXT slice, and it must land before step 2 (booking
-- an order) — until then a box line would be silently dropped by the readers' inner join to
-- `designs`. Nothing can create one, so nothing can be dropped.
--
-- Decisions taken with the owner (see docs/BOOK_ORDER_PLAN.md):
--   * quantity is in BOXES; sq ft is DERIVED, never stored (same law as thickness)
--   * quality is OPTIONAL on the line, and means PREMIUM when not given
--   * ⭐ urgency is a FLAG, not a date — set at booking or any time later. Sort = urgent first,
--     then oldest order. A date field would be typed wrong or left blank.
--   * one order may mix STOCK lines and BOOK lines — 500 wanted, 200 on the shelf, 300 to make is
--     ONE promise to ONE customer, not two orders
--   * 🚫 NO price on the line in v1. Pricing is a ledger, not an order.
--   * 🚫 NO buyer-facing anything. Book orders are entered by the STOCKIST only — there is no
--     end-user app for 1–1.5 years, and he does not want the customer seeing production status;
--     he will phone them. (So `public_order` / `create_order_link` stay unwired.)

-- ── the line ────────────────────────────────────────────────────────────────────────────────────

-- A line is now EITHER a hold (stock) or a box (to produce) — never both, never neither.
alter table public.inquiry_items alter column design_id drop not null;

alter table public.inquiry_items
  add column if not exists box_id uuid references public.boxes(id) on delete restrict;

comment on column public.inquiry_items.box_id is
  'BOOK line: the BOX (a brand cover on a packing) ordered for production. Mutually exclusive with '
  'design_id, which is a HOLD (stock). ON DELETE RESTRICT — taking a cover off must not silently '
  'delete a customer''s order line.';

-- 🔑 Exactly one of the two. This is what stops a line being both stock and book, or neither.
alter table public.inquiry_items
  add constraint inquiry_items_hold_xor_box
  check (num_nonnulls(design_id, box_id) = 1);

-- Boxes MADE against this line. Ordered − produced = still to make.
alter table public.inquiry_items
  add column if not exists produced_qty integer not null default 0
  constraint inquiry_items_produced_qty_check check (produced_qty >= 0);

-- ⭐ HIS priority mark, not the customer's. Settable at booking or any time after — a line taken
-- last week can become urgent today. Production sorts on it; the customer never sees it.
alter table public.inquiry_items
  add column if not exists is_urgent boolean not null default false;

-- The grade ordered. NULL means Premium (the default) — readers coalesce. On a STOCK line the
-- grade already comes from the hold, so this is the book line's answer to the same question.
alter table public.inquiry_items
  add column if not exists quality text;

comment on column public.inquiry_items.quality is
  'BOOK line: the grade ordered. NULL = Premium. A STOCK line takes its grade from the hold.';

-- ── uniqueness: one line per (order, thing ordered) ─────────────────────────────────────────────
-- The old UNIQUE (inquiry_id, design_id) cannot see box lines, and would let one order carry the
-- same box twice.
alter table public.inquiry_items drop constraint if exists inquiry_items_inquiry_id_design_id_key;

create unique index if not exists inquiry_items_one_per_thing
  on public.inquiry_items (inquiry_id, coalesce(design_id, box_id));

create index if not exists inquiry_items_box_idx on public.inquiry_items (box_id)
  where box_id is not null;

-- ── the customer remembers its brand ────────────────────────────────────────────────────────────
-- 🏷️ A customer takes material under a particular cover. Asking every single time is friction, and
-- guessing is wrong — so he DECLARES it once and it prefills, exactly like the cover-word toggle
-- (`brands.uses_design_name`). Still changeable per order: a customer may occasionally take another.
alter table public.stockist_customers
  add column if not exists default_brand_id uuid references public.brands(id) on delete set null;

comment on column public.stockist_customers.default_brand_id is
  'The cover this customer usually takes. PREFILLS the brand when booking an order; never forces '
  'it. ON DELETE SET NULL — losing a brand must not delete the customer.';

-- ── the opt-in ──────────────────────────────────────────────────────────────────────────────────
-- Admin-set, same shape as customers_enabled: only a manufacturer/trader who really takes
-- production orders should see any of this.
alter table public.stockists
  add column if not exists book_orders_enabled boolean not null default false;

comment on column public.stockists.book_orders_enabled is
  'Admin opt-in: this stockist books production orders (Book Order + Production planning). '
  'Same pattern as customers_enabled.';

-- ── self-check: the invariant holds, and nothing existing moved ─────────────────────────────────
do $$
declare v_bad int; v_null int;
begin
  select count(*) into v_bad from public.inquiry_items
   where num_nonnulls(design_id, box_id) <> 1;
  if v_bad > 0 then
    raise exception '% line(s) are neither a hold nor a box', v_bad;
  end if;

  -- Every line that exists today is a STOCK line and must have stayed one.
  select count(*) into v_null from public.inquiry_items where design_id is null;
  if v_null > 0 then
    raise exception '% existing line(s) lost their hold', v_null;
  end if;
end $$;
