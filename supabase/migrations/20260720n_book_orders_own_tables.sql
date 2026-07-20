-- 20260720n — 📕 BOOKED DEMAND GETS ITS OWN TABLES.
--
-- 🔑 **A BOOKED ORDER NEVER TOUCHES STOCK.** His words: *"if pratap ceramic booked order of 500 box
-- and 200 box same design is available in godown … if they want to take pratap order after 10 days,
-- why should stockist block his same design box from today? BOOKED ORDER IS NOTHING TO DO WITH
-- CURRENT STOCK POSITION."* Stock is looked at **only at production-planning time**, as information
-- on the day — never subtracted, never reserved.
--
-- ⚠️ **The enforcement is ABSENCE, not a guard.** These tables have **no `held_qty`, no
-- `dispatched_qty`, no `control_quantity`, no `design_id`.** A rule kept by "remember to exclude
-- book lines" is a rule that gets broken — 17 functions read `inquiry_items` without knowing
-- `box_id` existed, and THREE were already wrong. `hold_order` ran
-- `update inquiry_items set held_qty = quantity where inquiry_id = p_id` with no box guard, so
-- holding an order reserved stock against booked demand — exactly what he forbids, live in prod.
-- A rule kept by "there is no such column" cannot be broken.
--
-- 🚫 **NO QUALITY on a line.** *"Every time production planning is done for only premium quality;
-- standard is a by-product."* So demand is always premium, and the grade is a fact about OUTPUT,
-- not about the order. Standard falls out of the run and goes to free stock, allocated to nobody.
--
-- 🎁 The line still points at a **BOX** — the customer books a COVER ("500 FAMOUS boxes"). The
-- factory then makes a TILE and the cover goes on at packing; that asymmetry is the whole model.
-- `box_id NOT NULL` also keeps the old law: a box exists only because a human ticked that cover
-- (`box_put_cover`), so an order cannot be booked for a cover nobody declared.

create sequence if not exists public.book_order_token_seq start 1;

create table if not exists public.book_orders (
  id            uuid primary key default gen_random_uuid(),
  stockist_id   uuid not null references public.stockists(id) on delete cascade,
  customer_id   uuid references public.stockist_customers(id) on delete set null,
  customer_hint text,
  token         text not null unique
                default ('BO-' || lpad(nextval('public.book_order_token_seq')::text, 6, '0')),
  status        text not null default 'open'
                check (status in ('open','closed','cancelled')),
  note          text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  closed_at     timestamptz
);

create table if not exists public.book_order_lines (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references public.book_orders(id) on delete cascade,
  -- ON DELETE RESTRICT: taking a cover off must not silently delete a customer's booked line.
  box_id       uuid not null references public.boxes(id) on delete restrict,
  quantity     integer not null check (quantity > 0),          -- 📏 BOXES. sq ft is DERIVED.
  is_urgent    boolean not null default false,                 -- ⭐ HIS mark, never the customer's
  produced_qty integer not null default 0 check (produced_qty >= 0),
  created_at   timestamptz not null default now(),
  unique (order_id, box_id)
);

create index if not exists book_orders_stockist_idx on public.book_orders (stockist_id, status);
create index if not exists book_order_lines_box_idx on public.book_order_lines (box_id);

alter table public.book_orders      enable row level security;
alter table public.book_order_lines enable row level security;
revoke all on public.book_orders, public.book_order_lines from anon, authenticated;

comment on table public.book_orders is
  'Standing demand for tiles not yet made. NEVER touches stock: no hold, no reservation, no '
  'F_Stock effect. Consumed by production planning.';
comment on table public.book_order_lines is
  'One booked line: a BOX (brand cover) and how many. No quality — planning is always premium, '
  'standard is a by-product. No held_qty/dispatched_qty by design.';
