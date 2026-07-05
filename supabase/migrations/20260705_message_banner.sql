-- Message banner: per-list heading + message text over a text-friendly Library
-- background. Applied live in two parts (columns+RPC, then public_catalog).
-- See migrations message_banner_columns_rpc + message_banner_public_catalog in
-- the Supabase migration history for the exact applied SQL. Summary:
--   • stock_catalogs.banner_heading, banner_text (text)
--   • set_list_banner_config gains p_heading/p_message (defaulted → old 6-arg
--     callers still resolve to this one function); td_pos default → 'top-right';
--     server caps heading 40 / message 140 chars.
--   • public_catalog returns banner_heading + banner_text on every banner branch.
--   • banners.kind gains a 'text' value (used by Library message mode) — no
--     schema change, just a new value written by admin_add_generic_banner(kind).
alter table public.stock_catalogs
  add column if not exists banner_heading text,
  add column if not exists banner_text    text;

-- Fix (banners_kind_allow_text): the banners.kind CHECK originally allowed only
-- 'generic'/'brand', rejecting the new 'text' backgrounds. Widen it.
alter table public.banners drop constraint if exists banners_kind_check;
alter table public.banners
  add constraint banners_kind_check
  check (kind = any (array['generic'::text, 'brand'::text, 'text'::text]));
