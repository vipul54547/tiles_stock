-- Migration: dna_learn_alias
-- Applied to Supabase project buxjebeeiwyrsakeucyk on 2026-06-22 (LIVE).
--
-- WHY: the importer auto-detects DNA columns and sends raw words per row, which
--   the import RPC resolves with dna_resolve (canonical value name OR a learned
--   alias). A raw word that is neither was silently dropped. The new import-time
--   "Map Design DNA" step lets the stockist align each unresolved word to a
--   canonical value and LEARN it. This is the focused, non-destructive learn used
--   by that step: it adds/repoints ONE (stockist, attribute, raw_text) -> value_id
--   alias without touching the value's other words. (dna_set_value_words replaces
--   ALL of a value's words and would clobber prior aliases, so it's wrong here.)
-- Twin of upsertSurfaceAlias for surfaces. No schema change.

CREATE OR REPLACE FUNCTION public.dna_learn_alias(p_attribute_id uuid, p_raw text, p_value_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_stk uuid;
  v_attr uuid;
  v_raw text := btrim(coalesce(p_raw,''));
begin
  if v_raw = '' then return; end if;
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  -- the value must exist and belong to the named attribute
  select attribute_id into v_attr from dna_values where id = p_value_id;
  if v_attr is null or v_attr <> p_attribute_id then
    raise exception 'Value does not belong to attribute';
  end if;
  insert into dna_aliases(stockist_id, attribute_id, raw_text, value_id)
    values (v_stk, p_attribute_id, v_raw, p_value_id)
    on conflict (stockist_id, attribute_id, lower(raw_text))
    do update set value_id = excluded.value_id;
end;
$function$;
