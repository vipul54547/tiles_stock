-- BOX chapter — STEP 1 of 5: tile_types becomes a real admin table, with a DENSITY.
-- (docs/BOX_AND_DERIVED_THICKNESS_PLAN.md)
--
-- Thickness is DERIVED, never typed (user, 2026-07-13):
--
--     thickness_mm = box_weight_kg / (pieces_per_box × area_m2 × density) × 1000
--
-- The density is a constant per tile body type. It already lives in Dart
-- (lib/utils/tile_types.dart · kTileDensity), calibrated by the user from real per-sq-ft
-- weight data — and those numbers are EXACTLY what falls out of the live data:
--
--     Porcelain   258 products -> 2085 kg/m3   (min = avg = max, ZERO variance)
--     PGVT & GVT  139 products -> 2233 kg/m3   (zero variance)
--     Ceramic      11 products -> 1677 kg/m3   (1672-1689; Dart says 1672)
--
-- But it is stranded in a hardcoded Dart list, while surface_types and tile_sizes are both
-- admin tables. Move it: then the SERVER can compute thickness authoritatively (step 3) and
-- an admin can tune a density without a release.

create table if not exists tile_types (
  id            uuid primary key default gen_random_uuid(),
  name          text    not null unique,
  density_kg_m3 numeric not null check (density_kg_m3 > 0),
  is_active     boolean not null default true,
  sort_order    int     not null default 0,
  created_at    timestamptz not null default now()
);

-- Seeded from Dart's kTileDensity, which the live data independently confirms.
insert into tile_types (name, density_kg_m3, sort_order) values
  ('PGVT & GVT',  2233, 10),
  ('Porcelain',   2085, 20),
  ('Ceramic',     1672, 30),
  ('Full Body',   2350, 40),
  ('DC',          2350, 50),
  ('Colour Body', 2350, 60)
on conflict (name) do update set density_kg_m3 = excluded.density_kg_m3;

alter table tile_types enable row level security;

-- Everyone reads it (buyers filter on tile type); only admins write.
drop policy if exists tile_types_read on tile_types;
create policy tile_types_read on tile_types for select using (true);

grant select on tile_types to anon, authenticated;

-- 446 of 933 products have a BLANK tile_type. They also have NO pieces/weight/thickness —
-- the 487 products WITH specs are exactly the 487 WITH a type — so a blank strands nothing
-- today; it only matters once specs are entered. User: "all data is test data, you can
-- modify or remove — your choice." Give them the commonest real type rather than leaving a
-- blank that would silently derive no thickness.
update stockist_library
   set tile_type = 'Porcelain',
       updated_at = now()
 where nullif(btrim(coalesce(tile_type,'')),'') is null;

-- Guard: every tile_type in use must now exist in the table, or its density is unknowable.
do $$
declare v_bad text;
begin
  select string_agg(distinct l.tile_type, ', ') into v_bad
  from stockist_library l
  where nullif(btrim(coalesce(l.tile_type,'')),'') is not null
    and not exists (select 1 from tile_types t where t.name = l.tile_type);
  if v_bad is not null then
    raise exception 'tile_type(s) with no density row: %', v_bad;
  end if;
end $$;
