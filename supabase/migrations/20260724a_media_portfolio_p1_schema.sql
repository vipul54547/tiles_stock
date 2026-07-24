-- 20260724a — 🖼️ MEDIA PORTFOLIO, P1 foundation: tables + admin gating + generic lookups.
--
-- DDPI locked 23 Jul (project_media_portfolio_ddpi, 23 decisions). This migration lays the
-- STRUCTURE only — no RPCs yet (those are the next slice: media CRUD, tag, visibility, matrix,
-- portfolio reads, admin lookup CRUD, gating setters).
--
-- 🔑 THE BINDING: media = the ARTWORK (print_master), EXCEPT CloseLook = the TILE
--   (stockist_library). A mockup/360/video is one shot holding many designs, so it hangs on the
--   print (uploaded once, shared across every surface/body/thickness fork + every brand for free —
--   media is brand-neutral; brand is a LIST scope, never on the asset). CloseLook is a finish-
--   specific detail, so it binds straight to a tile.
--
-- 🔓 VISIBILITY = hand-pick (Option A, locked with the stockist 24 Jul): an asset shows on ALL
--   tiles of its tagged artworks by default; media_asset_tile carries the EXCEPTIONS —
--   `shown=false` drops a tile, and `placement` (Wall / Floor / Wall & Floor) captions the tile's
--   ROLE in the shot (a bathroom mockup = glossy WALL + matt FLOOR, one photo, both designs, each
--   correctly labelled). ⚠️ placement is DISPLAY ONLY — NOT image DNA, not a filter facet, not
--   identity. It never splits a product or keys anything.
--
-- 🗂️ admin_lookups = a GENERIC admin-managed list (list_key + value). Seeds 'space' (mockup/360
--   room tag) and 'placement' (the Wall/Floor roles). Built generic so future tools register their
--   own list_key and reuse the same admin editor — same pattern DNA attribute values use.

-- ── generic admin-managed lookups ────────────────────────────────────────────────────────────────
create table if not exists public.admin_lookups (
  id          uuid primary key default gen_random_uuid(),
  list_key    text not null,                 -- 'space' · 'placement' · (future tools add their own)
  value       text not null,                 -- stable slug, referenced by convention (like DNA free-text)
  label       text not null,                 -- what the human sees
  sort_order  integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
create unique index if not exists admin_lookups_uniq
  on public.admin_lookups (list_key, lower(value));
create index if not exists admin_lookups_list_idx
  on public.admin_lookups (list_key, sort_order);

comment on table public.admin_lookups is
  'Generic admin-managed pick lists (list_key + value + label). Seeds: space (room tag on '
  'mockups/360s) · placement (Wall/Floor role of a tile in a shot). Read by pickers + buyer '
  'filters; edited in the admin Managed-lists panel. Value is the stable slug; label is display.';

-- Seed 'space' — the room tag (#8/#18). "Other" is a built-in fallback, NOT stored/editable.
insert into public.admin_lookups (list_key, value, label, sort_order) values
  ('space', 'living_room', 'Living room',       10),
  ('space', 'bedroom',     'Bedroom',           20),
  ('space', 'kitchen',     'Kitchen',           30),
  ('space', 'bathroom',    'Bathroom',          40),
  ('space', 'staircase',   'Staircase',         50),
  ('space', 'office',      'Office/Commercial', 60),
  ('space', 'balcony',     'Balcony/Lobby',     70),
  ('space', 'terrace',     'Terrace',           80),
  ('space', 'elevation',   'Elevation/Facade',  90),
  ('space', 'parking',     'Parking',          100),
  ('space', 'outdoor',     'Outdoor/Pathway',  110)
on conflict do nothing;

-- Seed 'placement' — the tile's role in a room shot. 'both' (Wall & Floor) is the default.
insert into public.admin_lookups (list_key, value, label, sort_order) values
  ('placement', 'both',  'Wall & Floor', 10),
  ('placement', 'wall',  'Wall',         20),
  ('placement', 'floor', 'Floor',        30)
on conflict do nothing;

-- ── the media asset ───────────────────────────────────────────────────────────────────────────
create table if not exists public.media_asset (
  id          uuid primary key default gen_random_uuid(),
  stockist_id uuid not null references public.stockists(id) on delete cascade,
  type        text not null check (type in ('mockup','aligning','closelook','360','video')),
  url         text not null default '',   -- Cloudinary image · video link · 360 index.html URL
  space       text,                       -- admin_lookups.value where list_key='space'; NULL ok
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists media_asset_stockist_idx
  on public.media_asset (stockist_id, type, sort_order);

comment on table public.media_asset is
  'One uploaded material (mockup/aligning/closelook/360/video). Media hangs on the ARTWORK via '
  'media_asset_artwork (CloseLook on the TILE via media_asset_tile). Stock-blind: carries no '
  'quantity/quality/price. url holds a Cloudinary image, a video link, or a 360 index.html URL.';

-- ── M:N tag: which designs (artworks) are in the shot (#3) ──────────────────────────────────────
create table if not exists public.media_asset_artwork (
  asset_id  uuid not null references public.media_asset(id)  on delete cascade,
  print_id  uuid not null references public.print_master(id) on delete cascade,
  primary key (asset_id, print_id)
);
create index if not exists media_asset_artwork_print_idx
  on public.media_asset_artwork (print_id);

comment on table public.media_asset_artwork is
  'What designs are in a mockup/aligning/360/video — many-to-many (one shot, several artworks). '
  'The tag drives default visibility: the asset shows on every tile of every tagged artwork.';

-- ── hand-pick exceptions + placement role, and CloseLook''s tile home ───────────────────────────
create table if not exists public.media_asset_tile (
  asset_id   uuid not null references public.media_asset(id)      on delete cascade,
  library_id uuid not null references public.stockist_library(id) on delete cascade,
  shown      boolean not null default true,          -- hand-pick: false drops this tile off the shot
  placement  text    not null default 'both',        -- admin_lookups value (list_key='placement')
  primary key (asset_id, library_id)
);
create index if not exists media_asset_tile_library_idx
  on public.media_asset_tile (library_id);

comment on table public.media_asset_tile is
  'Per-tile overrides on a shot. For mockup/aligning/360/video: EXCEPTIONS over the artwork tag — '
  'shown=false hides a tile, placement (wall/floor/both) captions its role. For CloseLook: the row '
  'IS the binding (tile-specific). placement is DISPLAY ONLY — never DNA, never identity.';

-- ── admin gating per stockist: on/off per asset-type + quota on the heavy types (#12) ───────────
alter table public.stockists
  add column if not exists media_mockup_enabled    boolean not null default false,
  add column if not exists media_aligning_enabled  boolean not null default false,
  add column if not exists media_closelook_enabled boolean not null default false,
  add column if not exists media_360_enabled        boolean not null default false,
  add column if not exists media_video_enabled      boolean not null default false,
  add column if not exists media_360_quota          integer not null default 0,   -- count cap (storage)
  add column if not exists media_video_quota        integer not null default 0;   -- count cap (storage)

-- ── RLS: everything through RPCs (like the lot tables) ──────────────────────────────────────────
alter table public.admin_lookups       enable row level security;
alter table public.media_asset         enable row level security;
alter table public.media_asset_artwork enable row level security;
alter table public.media_asset_tile    enable row level security;
revoke all on public.admin_lookups, public.media_asset,
              public.media_asset_artwork, public.media_asset_tile
  from anon, authenticated;
