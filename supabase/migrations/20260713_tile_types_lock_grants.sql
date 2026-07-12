-- tile_types: take away the write grants Supabase hands out by default.
--
-- Creating a table in the public schema gives `anon` and `authenticated` INSERT / UPDATE /
-- DELETE / TRUNCATE through the schema's default privileges. RLS is enabled with only a
-- SELECT policy, so writes ARE already denied — but that leaves ONE layer between an
-- anonymous visitor and the densities that every derived thickness depends on.
--
-- This is the exact shape of the privilege-escalation hole we fixed on `profiles` (962a7f6):
-- the RPCs were fine, the GRANTs + RLS were the hole. [[project_admin_rpc_audit]] — follow a
-- permission to its data source and check that table's GRANTs, not just its policies.
--
-- Reads stay open: buyers need the density for the thickness-band filter, and the anon fetch
-- is exactly how the app loads it.

revoke all on table tile_types from anon, authenticated;
grant select on table tile_types to anon, authenticated;

-- Writes go through an admin path only. No INSERT/UPDATE/DELETE policy exists, so even a
-- future GRANT would still be stopped by RLS.
comment on table tile_types is
  'Admin-managed tile BODY types + their density_kg_m3. Density is the whole point: thickness '
  'is never typed, it is derived — weight / (pieces x area x density). Read-only to anon and '
  'authenticated; seeded in 20260713_box_step1_tile_types.sql.';
