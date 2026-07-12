-- Drop 8 stale RPC overloads that were left behind by `create or replace function`.
--
-- THE BUG (reported on famousceramic, customers_enabled = OFF):
--   "Could not choose the best candidate function between:
--    public.create_stockist_order(p_hint => text, p_lines => jsonb), ..."
--
-- Adding a parameter does NOT replace a function — it creates a second one. Every migration that
-- grew an RPC by a trailing defaulted param (`create or replace ... p_new x default null`) therefore
-- left the OLD signature in place beside the new one. When a caller then supplies exactly the OLD
-- parameter set, BOTH candidates match (the extra param has a default) and Postgres refuses to
-- choose: 42725 ambiguous_function. Postgres does not prefer the exact-arity candidate.
--
-- Two of these were live-broken:
--   * create_stockist_order — the app omits p_customer_id when the stockist is NOT customers_enabled
--     (`if (customerId != null)`), i.e. for every stockist except livok. Add Order has been dead for
--     them since 534bb09 (customer history Phase A).
--   * stock_add_holding — addDesign() (add_edit_stock_screen, the single "Add Design" save) sends the
--     6-param set and never p_surface_label, so it has been failing since the surface_label work
--     (7116bd9). Its error is swallowed into a generic "Failed to save. Please try again.", which is
--     why this one never got reported. add_inventory_batch (the BATCH path) passes all 7 positionally,
--     which is why bulk Add Stock kept working and hid the breakage.
--
-- The other 6 are dead but load-bearing landmines: they fire the moment any caller omits an optional
-- param. Dropping a short form cannot break a working caller — while both exist, a short-set call
-- ALREADY errors, so nothing can be successfully using it. Verified before dropping:
--   * no other pg_proc body calls a short form (add_inventory_batch → stock_add_holding, 7 args
--     positional; import_stock_batch → library_map_upsert, 4 args positional — both hit the LONG form),
--   * every surviving long form is granted to authenticated (checked pg_proc.proacl),
--   * the long form is a strict superset: its defaults reproduce the old behaviour exactly
--     (p_customer_id null → no customer on the inquiry; p_surface_label null → v_label null → the
--     row is inserted with a null label and no refresh-update, identical to the 6-arg body).

-- Live-broken:
drop function if exists public.create_stockist_order(text, jsonb);
drop function if exists public.stock_add_holding(uuid, text, integer, uuid, text, uuid);

-- Dead, but ambiguous the moment anything calls them:
drop function if exists public.library_map_upsert(text, text, jsonb);
drop function if exists public.library_upsert_master(uuid, text, text, text, jsonb, uuid);
drop function if exists public.stock_list_save(uuid, text, text);
drop function if exists public.import_stock_batch(uuid, uuid, uuid, text, jsonb, text, boolean, uuid[]);
drop function if exists public.admin_dna_add_attribute(text, boolean, boolean);
drop function if exists public.admin_dna_update_attribute(uuid, text, boolean, boolean, boolean, uuid, boolean);
