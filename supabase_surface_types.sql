-- ============================================================
-- MIGRATION: Admin-managed surface types + per-stockist aliases
-- Safe to run multiple times (idempotent).
-- Paste into Supabase SQL Editor (project buxjebeeiwyrsakeucyk) and run.
-- Depends on: stockists table + current_user_role() (from supabase_schema.sql)
-- ============================================================

-- ── 1. TABLES ────────────────────────────────────────────────────────────────

-- surface_types: admin's official master list of finishes.
-- Replaces the hardcoded kFinishes list in lib/utils/finishes.dart.
-- 'None' is the protected fallback (is_system = true) used when a stockist's
-- PDF surface word can't be aligned to any official surface.
create table if not exists surface_types (
  id         uuid primary key default uuid_generate_v4(),
  name       text    not null unique,
  sort_order int     not null default 0,
  is_active  boolean not null default true,
  is_system  boolean not null default false,  -- protects 'None' from deletion
  created_at timestamptz default now()
);

-- surface_aliases: per-stockist learned mapping from a raw PDF surface word
-- (normalised: lowercased, non-letters stripped) to an official surface_type.
-- Built up as a stockist aligns surfaces during PDF upload, so the same word
-- auto-fills on their next upload.
create table if not exists surface_aliases (
  id              uuid primary key default uuid_generate_v4(),
  stockist_id     uuid not null references stockists(id) on delete cascade,
  raw_text        text not null,                 -- normalised PDF word e.g. 'lustra'
  surface_type_id uuid references surface_types(id) on delete set null,
  created_at      timestamptz default now(),
  unique (stockist_id, raw_text)
);

create index if not exists surface_aliases_stockist_idx
  on surface_aliases (stockist_id);


-- ── 2. SEED official surfaces (current kFinishes) ────────────────────────────
-- 'None' created with is_system = true so the admin UI can't delete it.
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


-- ── 3. ROW LEVEL SECURITY ────────────────────────────────────────────────────
alter table surface_types   enable row level security;
alter table surface_aliases enable row level security;

-- surface_types: any authenticated user reads; only admin writes.
drop policy if exists "surface_types_read_authenticated" on surface_types;
create policy "surface_types_read_authenticated" on surface_types for select
  to authenticated using (true);

drop policy if exists "surface_types_admin_all" on surface_types;
create policy "surface_types_admin_all" on surface_types for all
  using (current_user_role() = 'admin');

-- surface_aliases: stockist manages own rows; admin sees/manages all.
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
