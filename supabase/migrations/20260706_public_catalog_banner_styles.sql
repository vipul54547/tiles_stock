-- ── public_catalog returns the banner text styles ───────────────────────────
-- The message (library) banner branch must return banner_heading_size/color,
-- banner_msg_size/color and banner_text_align so the /s/ page + OG card render
-- the same styles the stockist picked. public_catalog is a large function; to
-- avoid re-transcribing it (and risking drift), patch its own definition in
-- place: inject the 5 keys into the rich banner branch, right before its 'name'.
-- Idempotent-ish: re-running is a no-op if the keys are already present, because
-- the anchor (…banner_text, <ws> 'name', case when (s.is_anonymous…) only exists
-- in the rich branch and only until the keys are inserted.
do $mig$
declare
  v_def text;
begin
  select pg_get_functiondef('public.public_catalog(text)'::regprocedure) into v_def;
  if position('banner_heading_size' in v_def) > 0 then
    return; -- already patched
  end if;
  v_def := regexp_replace(
    v_def,
    '''banner_text'', c\.banner_text,(\s*)''name'', case when \(s\.is_anonymous and c\.is_anonymous and c\.show_in_marketplace and public_market_enabled\(\)\)',
    '''banner_text'', c.banner_text, ''banner_heading_size'', c.banner_heading_size, ''banner_heading_color'', c.banner_heading_color, ''banner_msg_size'', c.banner_msg_size, ''banner_msg_color'', c.banner_msg_color, ''banner_text_align'', c.banner_text_align,\1''name'', case when (s.is_anonymous and c.is_anonymous and c.show_in_marketplace and public_market_enabled())'
  );
  execute v_def;
end $mig$;
