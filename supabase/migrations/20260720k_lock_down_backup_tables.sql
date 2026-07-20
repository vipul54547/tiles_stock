-- 20260720k — 🔐 the BACKUP tables were readable with the public app key.
--
-- 18 snapshot tables had RLS OFF and `anon` holding SELECT: the whole 14 Jul wipe backup
-- (`_wipe_backup_20260714_*` — designs, library, print_master, stock_catalogs, stock_in, the DNA
-- tables …), `_thickness_before`, `designs_pre_split` and `stockist_library_pre_split`.
--
-- ⚠️ The publishable key is NOT a secret — it ships inside every APK and the web bundle by design
-- (lib/config/app_config.dart). Anything `anon` may SELECT is effectively public. So the live
-- tables are guarded by RLS and every read goes through a `public_*` RPC — but these snapshots sat
-- beside them wide open, holding the same commercial data: his stock, his library, his artworks.
--
-- 🚫 **DO NOT DROP THEM.** PITR is off, and they are the only way back from the 13/14 Jul wipes.
-- The fix is to take the grants away and turn RLS on, keeping every row.
--
-- No policies are created, deliberately: RLS on with no policy = nothing is visible to anon or
-- authenticated at all. The service role and the table owner still see everything, which is what a
-- restore actually uses. Verified first: 0 functions reference any of these tables.

do $$
declare r record; v_locked int := 0;
begin
  for r in
    select c.oid, c.relname
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and (c.relname like '\_wipe\_backup\_%'
        or c.relname like '\_merge\_backup\_%'
        or c.relname = '_thickness_before'
        or c.relname like '%\_pre\_split')
  loop
    execute format('revoke all on public.%I from anon, authenticated', r.relname);
    execute format('alter table public.%I enable row level security', r.relname);
    v_locked := v_locked + 1;
  end loop;
  raise notice 'locked % backup table(s)', v_locked;
end $$;

-- Self-check: no snapshot table may still be readable by the public key.
do $$
declare v_open text;
begin
  select string_agg(c.relname, ', ') into v_open
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'
    and (c.relname like '\_wipe\_backup\_%'
      or c.relname like '\_merge\_backup\_%'
      or c.relname = '_thickness_before'
      or c.relname like '%\_pre\_split')
    and (has_table_privilege('anon', c.oid, 'SELECT') or not c.relrowsecurity);
  if v_open is not null then
    raise exception 'still exposed: %', v_open;
  end if;
end $$;
