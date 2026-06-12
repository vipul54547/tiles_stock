-- ============================================================
-- TILES STOCK APP — COMPLETE SUPABASE SCHEMA
-- Run this once in the Supabase SQL Editor (supabase.com → SQL Editor → New query)
-- ============================================================

-- ── 0. Extensions ────────────────────────────────────────────────────────────
create extension if not exists "uuid-ossp";


-- ══════════════════════════════════════════════════════════════
-- 1. TABLES
-- ══════════════════════════════════════════════════════════════

-- profiles: maps every auth.users row to a role
create table if not exists profiles (
  id         uuid primary key references auth.users on delete cascade,
  role       text not null check (role in ('admin', 'stockist', 'end_user')),
  created_at timestamptz default now()
);

-- stockists
create table if not exists stockists (
  id            uuid primary key default uuid_generate_v4(),
  user_id       uuid references auth.users on delete set null,
  sequential_id text not null unique,   -- display ID e.g. '001', '002'
  name          text not null,
  phone         text not null default '',
  city          text not null default '',
  state         text not null default '',
  address       text not null default '',
  is_active     boolean not null default true,
  created_at    timestamptz default now()
);

-- end_users (self-registered buyers)
create table if not exists end_users (
  id                uuid primary key default uuid_generate_v4(),
  user_id           uuid references auth.users on delete set null,
  company_name      text not null,
  contact_person    text not null,
  phone             text not null default '',
  city              text not null default '',
  gst_number        text,
  inquiries_today   int  not null default 0,
  last_inquiry_date date,
  created_at        timestamptz default now()
);

-- designs (tile listings owned by a stockist)
create table if not exists designs (
  id             uuid primary key default uuid_generate_v4(),
  stockist_id    uuid not null references stockists(id) on delete cascade,
  name           text not null,
  size           text not null,
  surface_type   text not null default '',
  finish_label   text,                       -- raw PDF finish when not a standard one (e.g. "Punch Ghr")
  quality        text not null default 'Standard',
  colour         text not null default '',
  stock_type     text not null default 'Regular',
  box_quantity   int  not null default 0,
  pieces_per_box int  not null default 0,
  box_weight_kg  numeric(8,2)  not null default 0,
  thickness_mm   numeric(6,2)  not null default 0,
  box_price      numeric(10,2) not null default 0,
  face_image_urls text[] not null default '{}',
  status         text not null default 'active' check (status in ('active', 'out_of_stock')),
  created_at     timestamptz default now(),
  updated_at     timestamptz default now()
);

-- stock_in: log of every stock addition
create table if not exists stock_in (
  id             uuid primary key default uuid_generate_v4(),
  design_id      uuid not null references designs(id) on delete cascade,
  stockist_id    uuid not null references stockists(id) on delete cascade,
  quantity_added int  not null check (quantity_added > 0),
  pdf_filename   text,
  size           text not null default '',
  quality        text not null default '',
  created_at     timestamptz default now()
);

-- dispatches: log of every stock dispatch (sale / outgoing)
create table if not exists dispatches (
  id                  uuid primary key default uuid_generate_v4(),
  design_id           uuid not null references designs(id) on delete cascade,
  stockist_id         uuid not null references stockists(id) on delete cascade,
  quantity_dispatched int  not null check (quantity_dispatched > 0),
  buyer_name          text not null default '',
  notes               text not null default '',
  created_at          timestamptz default now()
);

-- inquiries: end-user → stockist contact requests
create table if not exists inquiries (
  id          uuid primary key default uuid_generate_v4(),
  end_user_id uuid not null references end_users(id) on delete cascade,
  stockist_id uuid not null references stockists(id) on delete cascade,
  design_id   uuid references designs(id) on delete set null,
  message     text,
  status      text not null default 'pending' check (status in ('pending', 'read', 'replied')),
  created_at  timestamptz default now()
);


-- ══════════════════════════════════════════════════════════════
-- 2. TRIGGERS
-- ══════════════════════════════════════════════════════════════

create or replace function update_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists designs_updated_at on designs;
create trigger designs_updated_at
  before update on designs
  for each row execute function update_updated_at();


-- ══════════════════════════════════════════════════════════════
-- 3. HELPER FUNCTION (used by RLS policies)
-- ══════════════════════════════════════════════════════════════

-- security definer = bypasses RLS so it can always read profiles
create or replace function current_user_role()
returns text language sql security definer stable as $$
  select role from profiles where id = auth.uid()
$$;


-- ══════════════════════════════════════════════════════════════
-- 4. ATOMIC RPC FUNCTIONS
-- ══════════════════════════════════════════════════════════════

-- add_stock: insert stock_in record AND increment designs.box_quantity atomically
create or replace function add_stock(
  p_design_id    uuid,
  p_stockist_id  uuid,
  p_quantity     int,
  p_pdf_filename text,
  p_size         text,
  p_quality      text
) returns void language plpgsql security definer as $$
begin
  insert into stock_in (design_id, stockist_id, quantity_added, pdf_filename, size, quality)
  values (p_design_id, p_stockist_id, p_quantity, p_pdf_filename, p_size, p_quality);

  update designs
  set box_quantity = box_quantity + p_quantity,
      status       = 'active',
      updated_at   = now()
  where id = p_design_id;
end;
$$;

-- dispatch_stock: check stock, insert dispatches record, decrement designs.box_quantity atomically
-- returns TRUE on success, FALSE if insufficient stock
create or replace function dispatch_stock(
  p_design_id    uuid,
  p_stockist_id  uuid,
  p_quantity     int,
  p_buyer_name   text,
  p_notes        text
) returns boolean language plpgsql security definer as $$
declare
  v_current int;
begin
  -- Lock the row to prevent race conditions
  select box_quantity into v_current
  from designs
  where id = p_design_id
  for update;

  if v_current is null or v_current < p_quantity then
    return false;
  end if;

  insert into dispatches (design_id, stockist_id, quantity_dispatched, buyer_name, notes)
  values (p_design_id, p_stockist_id, p_quantity, p_buyer_name, p_notes);

  update designs
  set box_quantity = box_quantity - p_quantity,
      status       = case when (box_quantity - p_quantity) = 0
                          then 'out_of_stock'
                          else 'active' end,
      updated_at   = now()
  where id = p_design_id;

  return true;
end;
$$;


-- ══════════════════════════════════════════════════════════════
-- 5. ROW LEVEL SECURITY
-- ══════════════════════════════════════════════════════════════

alter table profiles   enable row level security;
alter table stockists  enable row level security;
alter table end_users  enable row level security;
alter table designs    enable row level security;
alter table stock_in   enable row level security;
alter table dispatches enable row level security;
alter table inquiries  enable row level security;

-- ── profiles ─────────────────────────────────────────────────
-- Users can read/write their own row; admin can see all
create policy "profiles_select_own" on profiles for select
  using (id = auth.uid());

create policy "profiles_insert_own" on profiles for insert
  with check (id = auth.uid());

create policy "profiles_update_own" on profiles for update
  using (id = auth.uid());

create policy "profiles_admin_all" on profiles for all
  using (current_user_role() = 'admin');

-- ── stockists ────────────────────────────────────────────────
-- Any authenticated user can read; only admin can create/update/delete
create policy "stockists_read_authenticated" on stockists for select
  to authenticated using (true);

create policy "stockists_admin_all" on stockists for all
  using (current_user_role() = 'admin');

-- ── end_users ────────────────────────────────────────────────
-- End users manage their own row; admin sees all
create policy "end_users_select_own" on end_users for select
  using (user_id = auth.uid() or current_user_role() = 'admin');

create policy "end_users_insert_own" on end_users for insert
  with check (user_id = auth.uid());

create policy "end_users_update_own" on end_users for update
  using (user_id = auth.uid() or current_user_role() = 'admin');

create policy "end_users_admin_delete" on end_users for delete
  using (current_user_role() = 'admin');

-- ── designs ──────────────────────────────────────────────────
-- Any authenticated user can read; stockist manages own designs; admin manages all
create policy "designs_read_authenticated" on designs for select
  to authenticated using (true);

create policy "designs_insert_own_stockist" on designs for insert
  with check (
    stockist_id in (select id from stockists where user_id = auth.uid())
  );

create policy "designs_update_own_stockist" on designs for update
  using (
    stockist_id in (select id from stockists where user_id = auth.uid())
    or current_user_role() = 'admin'
  );

create policy "designs_delete_own_stockist" on designs for delete
  using (
    stockist_id in (select id from stockists where user_id = auth.uid())
    or current_user_role() = 'admin'
  );

-- ── stock_in ─────────────────────────────────────────────────
-- INSERTs are done by the security-definer add_stock() RPC (bypasses RLS)
-- SELECT: stockist sees own records; admin sees all
create policy "stock_in_read" on stock_in for select
  using (
    stockist_id in (select id from stockists where user_id = auth.uid())
    or current_user_role() = 'admin'
  );

-- ── dispatches ───────────────────────────────────────────────
-- INSERTs are done by the security-definer dispatch_stock() RPC (bypasses RLS)
-- SELECT: stockist sees own records; admin sees all
create policy "dispatches_read" on dispatches for select
  using (
    stockist_id in (select id from stockists where user_id = auth.uid())
    or current_user_role() = 'admin'
  );

-- ── inquiries ────────────────────────────────────────────────
-- End user can insert their own inquiries and read them
-- Stockist can read inquiries directed to them and update status
-- Admin sees all
create policy "inquiries_insert_end_user" on inquiries for insert
  with check (
    end_user_id in (select id from end_users where user_id = auth.uid())
  );

create policy "inquiries_select" on inquiries for select
  using (
    end_user_id in (select id from end_users where user_id = auth.uid())
    or stockist_id in (select id from stockists where user_id = auth.uid())
    or current_user_role() = 'admin'
  );

create policy "inquiries_update_stockist" on inquiries for update
  using (
    stockist_id in (select id from stockists where user_id = auth.uid())
    or current_user_role() = 'admin'
  );


-- ══════════════════════════════════════════════════════════════
-- 6. CREATE ADMIN USER
-- Run AFTER creating the auth user in the Supabase dashboard
-- (Authentication → Users → Add user → Create new user)
-- Then paste that user's UUID below:
-- ══════════════════════════════════════════════════════════════

-- insert into profiles (id, role)
-- values ('<paste-admin-uuid-here>', 'admin');


-- ══════════════════════════════════════════════════════════════
-- 7. CREATE A STOCKIST (example)
-- Run after creating a stockist auth user in the dashboard
-- ══════════════════════════════════════════════════════════════

-- Step 1: create auth user in dashboard, copy UUID
-- Step 2: insert profile
-- insert into profiles (id, role)
-- values ('<stockist-auth-uuid>', 'stockist');
--
-- Step 3: insert stockist row
-- insert into stockists (user_id, sequential_id, name, phone, city, state, address)
-- values (
--   '<stockist-auth-uuid>',
--   '001',
--   'Stockist Name',
--   '9876543210',
--   'Morbi',
--   'Gujarat',
--   'Full address here'
-- );


-- ══════════════════════════════════════════════════════════════
-- 8. SURFACE TYPES (admin master list) + PER-STOCKIST ALIASES
-- Also available as a standalone idempotent migration in
-- supabase_surface_types.sql
-- ══════════════════════════════════════════════════════════════

-- surface_types: admin's official master list of finishes; replaces the
-- hardcoded kFinishes list. 'None' (is_system) is the protected fallback used
-- when a stockist's PDF surface word can't be aligned to an official surface.
create table if not exists surface_types (
  id         uuid primary key default uuid_generate_v4(),
  name       text    not null unique,
  sort_order int     not null default 0,
  is_active  boolean not null default true,
  is_system  boolean not null default false,
  created_at timestamptz default now()
);

-- surface_aliases: per-stockist learned mapping from a raw PDF surface word
-- (normalised) to an official surface_type, built up during PDF upload.
create table if not exists surface_aliases (
  id              uuid primary key default uuid_generate_v4(),
  stockist_id     uuid not null references stockists(id) on delete cascade,
  raw_text        text not null,
  surface_type_id uuid references surface_types(id) on delete set null,
  created_at      timestamptz default now(),
  unique (stockist_id, raw_text)
);

create index if not exists surface_aliases_stockist_idx
  on surface_aliases (stockist_id);

insert into surface_types (name, sort_order, is_system) values
  ('Glossy',   10,  false),
  ('Matt',     20,  false),
  ('Satin',    30,  false),
  ('Polished', 40,  false),
  ('Rustic',   50,  false),
  ('Carving',  60,  false),
  ('Lappato',  70,  false),
  ('Sugar',    80,  false),
  ('None',     999, true)
on conflict (name) do nothing;

alter table surface_types   enable row level security;
alter table surface_aliases enable row level security;

drop policy if exists "surface_types_read_authenticated" on surface_types;
create policy "surface_types_read_authenticated" on surface_types for select
  to authenticated using (true);

drop policy if exists "surface_types_admin_all" on surface_types;
create policy "surface_types_admin_all" on surface_types for all
  using (current_user_role() = 'admin');

drop policy if exists "surface_aliases_select" on surface_aliases;
create policy "surface_aliases_select" on surface_aliases for select
  using (
    stockist_id in (select id from stockists where user_id = auth.uid())
    or current_user_role() = 'admin'
  );

drop policy if exists "surface_aliases_insert_own" on surface_aliases;
create policy "surface_aliases_insert_own" on surface_aliases for insert
  with check (
    stockist_id in (select id from stockists where user_id = auth.uid())
  );

drop policy if exists "surface_aliases_update_own" on surface_aliases;
create policy "surface_aliases_update_own" on surface_aliases for update
  using (
    stockist_id in (select id from stockists where user_id = auth.uid())
    or current_user_role() = 'admin'
  );

drop policy if exists "surface_aliases_delete_own" on surface_aliases;
create policy "surface_aliases_delete_own" on surface_aliases for delete
  using (
    stockist_id in (select id from stockists where user_id = auth.uid())
    or current_user_role() = 'admin'
  );


-- ══════════════════════════════════════════════════════════════════════════
-- CHANGES APPLIED VIA MCP MIGRATIONS — 2026-06 session
-- Mirrored here for reference; these are also in Supabase's migration history.
-- All SECURITY DEFINER functions below set search_path = public, extensions,
-- pg_temp (hardening). Existing functions earlier in this file were also
-- ALTERed to the same fixed search_path.
-- ══════════════════════════════════════════════════════════════════════════

-- ── Column additions ────────────────────────────────────────────────────────
alter table stockists             add column if not exists country_code text not null default '+91';
alter table end_users             add column if not exists country_code text not null default '+91';
alter table registration_requests add column if not exists country_code text not null default '+91';
alter table stock_in add column if not exists status text not null default 'approved'
  check (status in ('approved', 'pending', 'rejected'));

-- ── New tables ────────────────────────────────────────────────────────────────

-- stock_adjustments: recount ledger (correct stock to physical reality).
create table if not exists stock_adjustments (
  id           uuid primary key default uuid_generate_v4(),
  design_id    uuid not null references designs(id)   on delete cascade,
  stockist_id  uuid not null references stockists(id) on delete cascade,
  old_quantity int  not null,
  new_quantity int  not null check (new_quantity >= 0),
  delta        int  not null,
  reason       text not null default '',
  note         text not null default '',
  created_at   timestamptz default now()
);
alter table stock_adjustments enable row level security;
drop policy if exists stock_adjustments_read on stock_adjustments;
create policy stock_adjustments_read on stock_adjustments for select using (
  stockist_id in (select id from stockists where user_id = auth.uid())
  or current_user_role() = 'admin');

-- notifications: in-app inbox (buyer/stockist/admin). Insert via _notify only.
create table if not exists notifications (
  id           uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references auth.users(id) on delete cascade,
  type         text not null default 'info',
  title        text not null,
  body         text not null default '',
  data         jsonb not null default '{}',
  is_read      boolean not null default false,
  created_at   timestamptz default now()
);
create index if not exists notifications_recipient_idx
  on notifications(recipient_id, created_at desc);
alter table notifications enable row level security;
drop policy if exists notif_read on notifications;
create policy notif_read on notifications for select using (recipient_id = auth.uid());
drop policy if exists notif_update on notifications;
create policy notif_update on notifications for update
  using (recipient_id = auth.uid()) with check (recipient_id = auth.uid());
drop policy if exists notif_delete on notifications;
create policy notif_delete on notifications for delete using (recipient_id = auth.uid());

-- tile_sizes: admin-managed size master (replaces the hardcoded kAllowedSizes).
create table if not exists tile_sizes (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  sort_order int  not null default 0,
  is_active  boolean not null default true,
  created_at timestamptz default now()
);
alter table tile_sizes enable row level security;
drop policy if exists tile_sizes_read on tile_sizes;
create policy tile_sizes_read on tile_sizes for select using (true);
drop policy if exists tile_sizes_admin_all on tile_sizes;
create policy tile_sizes_admin_all on tile_sizes for all using (current_user_role() = 'admin');

-- ── Functions (final versions) ───────────────────────────────────────────────
-- NOTE: full bodies live in Supabase migration history. Signatures + purpose:
--   add_stock(uuid,uuid,int,text,text,text)           -- now holds >=10k/day as 'pending'
--   adjust_stock(uuid,int,text,text) -> bool           -- recount, logs stock_adjustments
--   set_pending_stock(uuid,bool) -> int                -- admin approve/reject pending stock
--   admin_pending_stock() -> jsonb                     -- admin: pending stock per stockist
--   my_pending_stock_boxes() -> int                    -- stockist: own pending boxes
--   fulfill_choice(uuid,uuid,int)                      -- dispatch reduces buyer's my_choice
--   reject_inquiry(uuid,uuid)                          -- delete a buyer's my_choice + notify
--   reject_design_inquiries(uuid)                      -- delete all my_choices for a design
--   my_design_buyers(text) -> jsonb                    -- now includes end_user_id
--   _notify(uuid,text,text,text,jsonb)                 -- internal insert (revoked from clients)
--   notify_stockist(text)                              -- buyer->stockist "New inquiry" (name/phone/city)
--   notify_dispatch(uuid,uuid,int)                     -- stockist->buyer dispatch alert
--   admin_send_notification(text,text,text[],text[],bool,bool) -> int
--   daily_admin_join_summary()                         -- pg_cron 03:30 UTC (09:00 IST)
--   daily_group_restock_alert()                        -- pg_cron 04:00 UTC (09:30 IST)
--   create_user_from_excel(...,p_country_code)         -- +country_code (old 15-arg dropped)
--   submit_registration_request(...,p_country_code)    -- +country_code, notifies admins
--   approve_registration_request(text,numeric,text)    -- +country_code carry, notifies new user
--   admin_set_stockist_listing(text,numeric,text)      -- set tier + priority (by seq)
--   admin_update_stockist(text,text,text,text,text,text,text,text,text,numeric)
--   admin_delete_stockist(text)                        -- hard delete (only when inactive); also clears user_devices
--   admin_update_end_user(uuid,text,text,text,text,text,text,text,numeric)
--   admin_delete_end_user(uuid)                        -- hard delete (only when inactive); also clears user_devices
--   admin_inquiry_report() -> jsonb                    -- all inquiries across stockists
--   reorder_tile_sizes(uuid[])                         -- admin reorder sizes

-- ── Scheduled jobs (pg_cron) ──────────────────────────────────────────────────
-- create extension if not exists pg_cron;
-- cron.schedule('daily-admin-join-summary',  '30 3 * * *', 'select public.daily_admin_join_summary();');
-- cron.schedule('daily-group-restock-alert', '0 4 * * *',  'select public.daily_group_restock_alert();');
