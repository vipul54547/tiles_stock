-- Anonymity removed from the platform (user decision 2026-07-07: real names
-- everywhere, machinery no longer wanted). Applied to buxjebeeiwyrsakeucyk as
-- two Supabase migrations: `remove_anonymity_completely` + a follow-up
-- `public_catalog_remove_anonymity`. This file documents the schema change; the
-- rewritten function/view bodies are the authoritative ones now live in the DB.
--
-- Schema drops:
--   stockists.is_anonymous, stockists.public_display_name, stockists.public_code
--   stock_catalogs.is_anonymous
-- Dropped provisioning RPCs:
--   admin_set_anonymous, admin_regenerate_public_code, admin_resolve_public_code,
--   gen_public_code (+ any public-code history table)
-- Rewritten to use the real name / sequential_id unconditionally (no more
--   `case when is_anonymous then masked`): public_catalog, claim_catalog,
--   my_claimed_catalogs, market_designs, my_orders, my_inquiries, my_dispatches,
--   reject_order, daily_group_restock_alert, notify_stockist, resolve_stockist_key,
--   create_stock_list, _stockist_default_catalog, stock_list_save, delete_my_account.
-- View buyer_stockists now exposes `false AS is_anonymous` (kept as a constant
--   for backward-compat with any client still selecting the column).
-- public_market_enabled() is retained (it gates the public market, not anonymity).

alter table public.stockists      drop column if exists is_anonymous;
alter table public.stockists      drop column if exists public_display_name;
alter table public.stockists      drop column if exists public_code;
alter table public.stock_catalogs drop column if exists is_anonymous;

drop function if exists public.admin_set_anonymous(text, boolean, text);
drop function if exists public.admin_regenerate_public_code(text);
drop function if exists public.admin_resolve_public_code(text);
drop function if exists public.gen_public_code();
