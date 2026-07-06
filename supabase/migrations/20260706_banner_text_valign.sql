-- ── Message-banner vertical alignment (Top / Middle / Bottom) ────────────────
-- Adds banner_text_valign so a stockist can push the heading+message to the top
-- (aligns with a top logo), middle (default), or bottom of the banner. Also
-- consolidates set_list_banner_config: earlier size/style work left an 8-arg and
-- a 13-arg overload; drop both and keep ONE canonical function (new params
-- defaulted, so old callers that omit them still resolve here).

alter table stock_catalogs
  add column if not exists banner_text_valign text;

drop function if exists public.set_list_banner_config(uuid,text,text,text,text,text,text,text);
drop function if exists public.set_list_banner_config(uuid,text,text,text,text,text,text,text,text,text,text,text,text);

create or replace function public.set_list_banner_config(
  p_catalog_id uuid, p_source text, p_bg_url text,
  p_company_logo_url text, p_company_pos text, p_td_pos text,
  p_heading text default null::text, p_message text default null::text,
  p_heading_size text default null::text, p_heading_color text default null::text,
  p_msg_size text default null::text, p_msg_color text default null::text,
  p_text_align text default null::text, p_text_valign text default null::text)
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

  if v_src = '' then
    update stock_catalogs set
      banner_source = null, banner_bg_url = null, company_logo_url = null,
      company_pos = null, td_pos = null, banner_url = null,
      banner_heading = null, banner_text = null,
      banner_heading_size = null, banner_heading_color = null,
      banner_msg_size = null, banner_msg_color = null,
      banner_text_align = null, banner_text_valign = null
    where id = p_catalog_id and stockist_id = v_stk;
    if not found then raise exception 'List not found'; end if;
    return;
  end if;

  if v_src = 'none' then
    update stock_catalogs set
      banner_source = 'none', banner_bg_url = null, company_logo_url = null,
      company_pos = null, td_pos = null, banner_url = null,
      banner_heading = null, banner_text = null,
      banner_heading_size = null, banner_heading_color = null,
      banner_msg_size = null, banner_msg_color = null,
      banner_text_align = null, banner_text_valign = null
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
    banner_url       = null,
    banner_heading   = left(nullif(btrim(coalesce(p_heading, '')), ''), 40),
    banner_text      = left(nullif(btrim(coalesce(p_message, '')), ''), 140),
    banner_heading_size  = case when v_src = 'library' then nullif(lower(btrim(coalesce(p_heading_size, ''))), '') else null end,
    banner_heading_color = case when v_src = 'library' then nullif(btrim(coalesce(p_heading_color, '')), '') else null end,
    banner_msg_size      = case when v_src = 'library' then nullif(lower(btrim(coalesce(p_msg_size, ''))), '') else null end,
    banner_msg_color     = case when v_src = 'library' then nullif(btrim(coalesce(p_msg_color, '')), '') else null end,
    banner_text_align    = case when v_src = 'library' then nullif(lower(btrim(coalesce(p_text_align, ''))), '') else null end,
    banner_text_valign   = case when v_src = 'library' then nullif(lower(btrim(coalesce(p_text_valign, ''))), '') else null end
  where id = p_catalog_id and stockist_id = v_stk;
  if not found then raise exception 'List not found'; end if;
end;
$function$;
