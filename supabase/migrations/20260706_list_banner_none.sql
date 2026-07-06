-- ── "No banner" option for a stock list ──────────────────────────────────────
-- Stockists can now REMOVE the banner from any list (source = 'none'), distinct
-- from 'pool' (which still shows the shared rotating background). The share page
-- (/s/) then starts straight at the tiles — no header image, logo, or message.
--
-- Only set_list_banner_config needs changing. This body is the LIVE definition
-- (pg_get_functiondef, 2026-07-06 — the message_banner version with ungated
-- heading/text and NULL-default params) with ONE addition: a 'none' branch that
-- stores the marker and clears every visual field. public_catalog needs no
-- change — its first banner branch passes a non-'pool' banner_source straight
-- through as `source`, so 'none' round-trips to the client (which hides the
-- banner area); the OG share card falls through to logo/name-card on empty bg.

create or replace function public.set_list_banner_config(
  p_catalog_id uuid, p_source text, p_bg_url text,
  p_company_logo_url text, p_company_pos text, p_td_pos text,
  p_heading text default null::text, p_message text default null::text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_stk uuid;
  v_src text := lower(coalesce(p_source, ''));
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can set a list banner'; end if;

  -- Empty source → clear the per-list banner (revert to the shared pool).
  if v_src = '' then
    update stock_catalogs set
      banner_source = null, banner_bg_url = null, company_logo_url = null,
      company_pos = null, td_pos = null, banner_url = null,
      banner_heading = null, banner_text = null
    where id = p_catalog_id and stockist_id = v_stk;
    if not found then raise exception 'List not found'; end if;
    return;
  end if;

  -- 'none' → an explicit NO-banner list (distinct from 'pool'). Stored as a
  -- marker with every visual field cleared; the share page renders no header.
  if v_src = 'none' then
    update stock_catalogs set
      banner_source = 'none', banner_bg_url = null, company_logo_url = null,
      company_pos = null, td_pos = null, banner_url = null,
      banner_heading = null, banner_text = null
    where id = p_catalog_id and stockist_id = v_stk;
    if not found then raise exception 'List not found'; end if;
    return;
  end if;

  if v_src not in ('pool', 'library', 'upload') then
    raise exception 'Invalid banner source';
  end if;

  update stock_catalogs set
    banner_source    = v_src,
    banner_bg_url    = nullif(btrim(coalesce(p_bg_url, '')), ''),
    company_logo_url = nullif(btrim(coalesce(p_company_logo_url, '')), ''),
    company_pos      = coalesce(nullif(btrim(p_company_pos), ''), 'none'),
    td_pos           = coalesce(nullif(btrim(p_td_pos), ''), 'top-right'),
    banner_url       = null,   -- the rich config supersedes the legacy single image
    banner_heading   = left(nullif(btrim(coalesce(p_heading, '')), ''), 40),
    banner_text      = left(nullif(btrim(coalesce(p_message, '')), ''), 140)
  where id = p_catalog_id and stockist_id = v_stk;
  if not found then raise exception 'List not found'; end if;
end;
$function$;
