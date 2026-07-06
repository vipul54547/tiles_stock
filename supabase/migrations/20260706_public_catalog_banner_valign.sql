-- ── public_catalog returns banner_text_valign ────────────────────────────────
-- Patch public_catalog in place (avoid re-transcribing the large function):
-- inject banner_text_valign into the rich banner branch, right after
-- banner_text_align. Idempotent — no-op if the key is already present.
do $mig$
declare
  v_def text;
begin
  select pg_get_functiondef('public.public_catalog(text)'::regprocedure) into v_def;
  if position('banner_text_valign' in v_def) > 0 then
    return;
  end if;
  v_def := replace(
    v_def,
    '''banner_text_align'', c.banner_text_align,',
    '''banner_text_align'', c.banner_text_align, ''banner_text_valign'', c.banner_text_valign,'
  );
  execute v_def;
end $mig$;
