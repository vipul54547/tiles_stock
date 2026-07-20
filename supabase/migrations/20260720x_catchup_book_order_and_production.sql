-- 20260720x — 🔴 CATCH-UP: everything from BOOK ORDER and PRODUCTION that was applied to prod
--             but never written to the repo.
--
-- ⚠️ WHAT WENT WRONG. Migrations `20260720o` … `20260720w` were applied to the live database during
-- a long design conversation, and the SQL files were never written to disk. Three later fixes
-- (`_next_slice_letter`, `_move_book_line`, and the final `production_take_into_run`) were applied
-- with a plain SQL call and are not even recorded in `schema_migrations`. So the database was
-- correct and the repo could not rebuild it — if this project were ever recreated from source,
-- Book Order and Production would simply not exist, and the Dart would call RPCs that were not
-- there.
--
-- 🔑 THE LESSON, worth more than the fix: **an applied migration that is not on disk is not a
-- migration.** Write the file first, apply from the file, and check the folder against
-- `schema_migrations` before moving on. This is the second time in one day (see `20260720f`).
--
-- This file reproduces the FINAL state of every object those nine migrations introduced. It is
-- idempotent (`create or replace` / `if not exists`), so applying it to the live database changes
-- nothing, and applying it to a fresh database builds the whole feature.
--
-- Covered here: o (book order RPCs) · p (inquiry_items revert) · q+s (production demand) ·
-- r (run tables) · t (output + runs/history reads) · u (output honours the tick) ·
-- v (order slices) · w (take-into-run slices).

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- TABLES
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- 📕 booked demand. NO held_qty, NO dispatched_qty, NO design_id, NO quality — the rule
-- "a booked order never touches stock" is enforced by the ABSENCE of the columns.
create sequence if not exists public.book_order_token_seq start 1;

create table if not exists public.book_orders (
  id            uuid primary key default gen_random_uuid(),
  stockist_id   uuid not null references public.stockists(id) on delete cascade,
  customer_id   uuid references public.stockist_customers(id) on delete set null,
  customer_hint text,
  token         text not null unique
                default ('BO-' || lpad(nextval('public.book_order_token_seq')::text, 6, '0')),
  status        text not null default 'open',
  note          text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  closed_at     timestamptz,
  -- 🔪 slices (20260720v). The PARENT keeps the customer's number for life; only slices take a
  -- letter, and a slice's token is <parent token>/<letter>.
  parent_id     uuid references public.book_orders(id) on delete restrict,
  slice         text
);

alter table public.book_orders drop constraint if exists book_orders_status_check;
alter table public.book_orders add constraint book_orders_status_check
  check (status in ('open','in_production','closed','cancelled'));

create table if not exists public.book_order_lines (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references public.book_orders(id) on delete cascade,
  box_id       uuid not null references public.boxes(id) on delete restrict,
  quantity     integer not null check (quantity > 0),
  is_urgent    boolean not null default false,
  produced_qty integer not null default 0 check (produced_qty >= 0),
  created_at   timestamptz not null default now(),
  unique (order_id, box_id)
);

create sequence if not exists public.production_run_seq start 1;

create table if not exists public.production_runs (
  id          uuid primary key default gen_random_uuid(),
  stockist_id uuid not null references public.stockists(id) on delete cascade,
  name        text not null
              default ('RUN-' || lpad(nextval('public.production_run_seq')::text, 5, '0')),
  status      text not null default 'planned'
              check (status in ('planned','running','done','cancelled')),
  note        text,
  created_at  timestamptz not null default now(),
  closed_at   timestamptz
);

-- 🎁 WHAT TO PACK — per BOX (a brand's cover). The tile-level total is DERIVED from these.
create table if not exists public.production_run_boxes (
  id           uuid primary key default gen_random_uuid(),
  run_id       uuid not null references public.production_runs(id) on delete cascade,
  box_id       uuid not null references public.boxes(id) on delete restrict,
  target_boxes integer not null check (target_boxes > 0),
  unique (run_id, box_id)
);

-- 🔑 WHY THE RUN EXISTS — the booked lines he ticked. This is the history: which design went into
-- production for which buyer.
create table if not exists public.production_run_demand (
  id                 uuid primary key default gen_random_uuid(),
  run_id             uuid not null references public.production_runs(id) on delete cascade,
  book_order_line_id uuid not null references public.book_order_lines(id) on delete restrict,
  planned_boxes      integer not null check (planned_boxes > 0),
  created_at         timestamptz not null default now(),
  unique (run_id, book_order_line_id)
);

create table if not exists public.production_run_output (
  id          uuid primary key default gen_random_uuid(),
  run_id      uuid not null references public.production_runs(id) on delete cascade,
  box_id      uuid not null references public.boxes(id) on delete restrict,
  quality     text not null default 'Premium',
  boxes       integer not null check (boxes > 0),
  design_id   uuid references public.designs(id) on delete set null,
  produced_at timestamptz not null default now()
);

create index if not exists book_orders_stockist_idx on public.book_orders (stockist_id, status);
create index if not exists book_orders_parent_idx   on public.book_orders (parent_id);
create index if not exists book_order_lines_box_idx on public.book_order_lines (box_id);
create index if not exists production_runs_stk_idx  on public.production_runs (stockist_id, status);
create index if not exists prd_line_idx             on public.production_run_demand (book_order_line_id);
create index if not exists pro_run_idx              on public.production_run_output (run_id);

alter table public.book_orders            enable row level security;
alter table public.book_order_lines       enable row level security;
alter table public.production_runs        enable row level security;
alter table public.production_run_boxes   enable row level security;
alter table public.production_run_demand  enable row level security;
alter table public.production_run_output  enable row level security;
revoke all on public.book_orders, public.book_order_lines, public.production_runs,
              public.production_run_boxes, public.production_run_demand,
              public.production_run_output
  from anon, authenticated;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- p — inquiry_items reverted to STOCK-ONLY (book lines left it in 20260720n/o)
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- The XOR experiment is gone: a stock order line points at a HOLD and nothing else. Three latent
-- bugs died with it, the worst being `hold_order` setting held_qty on a booked line.
alter table public.inquiry_items drop constraint if exists inquiry_items_hold_xor_box;
drop index if exists public.inquiry_items_one_box_per_order;
alter table public.inquiry_items drop column if exists box_id;
alter table public.inquiry_items drop column if exists produced_qty;
alter table public.inquiry_items drop column if exists is_urgent;
alter table public.inquiry_items drop column if exists quality;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ════════════════════════════════════════════════════════════════════════════════════════════
create or replace function public._next_slice_letter(p_parent uuid)
 returns text language sql stable
 set search_path to 'public', 'pg_temp'
as $$ select chr((65 + count(*))::int) from book_orders where parent_id = p_parent $$;

-- 🔪 The whole line moved to the slice: REMOVE it rather than update it to zero — the
-- `quantity > 0` check would fire before a following delete could run.
create or replace function public._move_book_line(p_line uuid, p_qty int)
 returns void language plpgsql
 set search_path to 'public', 'pg_temp'
as $$
declare v_have int;
begin
  select quantity into v_have from book_order_lines where id = p_line;
  if p_qty >= v_have then
    delete from book_order_lines where id = p_line;
  else
    update book_order_lines set quantity = v_have - p_qty where id = p_line;
  end if;
end $$;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- SELF-CHECK — every object this feature needs must now exist
-- ════════════════════════════════════════════════════════════════════════════════════════════
do $$
declare miss text;
begin
  select string_agg(t, ', ') into miss from (
    select t from unnest(array['book_orders','book_order_lines','production_runs',
                               'production_run_boxes','production_run_demand',
                               'production_run_output']) t
    where not exists (select 1 from information_schema.tables
                       where table_schema='public' and table_name=t)) x;
  if miss is not null then raise exception 'missing table(s): %', miss; end if;

  select string_agg(f, ', ') into miss from (
    select f from unnest(array['create_book_order','my_book_orders','book_order_detail',
                               'book_line_set_urgent','book_order_set_status','book_order_delete',
                               'my_production_demand','production_take_into_run',
                               'production_declare_output','my_production_runs',
                               'my_production_history','_next_slice_letter','_move_book_line',
                               '_box_resolve','_box_for']) f
    where not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                       where n.nspname='public' and p.proname=f)) y;
  if miss is not null then raise exception 'missing function(s): %', miss; end if;

  -- the law that must survive every one of these changes
  select string_agg(p.proname, ', ') into miss
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prosrc ilike '%insert into boxes%'
    and p.proname <> 'box_put_cover';
  if miss is not null then
    raise exception 'box_put_cover must be the only writer of boxes; also: %', miss;
  end if;

  -- and the rule kept by absence
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='book_order_lines'
                and column_name in ('held_qty','dispatched_qty','design_id','quality')) then
    raise exception 'book_order_lines must NOT carry a reservation or a design or a quality';
  end if;
end $$;
