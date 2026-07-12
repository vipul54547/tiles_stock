-- DNA Phase 2: when an attribute has mapping OFF (allow_mapping=false), the
-- stockist may only use the admin canonical values — so the alias writers must
-- refuse. Belt-and-braces behind the UI, which already hides the own-word path.
-- (docs/DNA_CASCADE_AND_MAPPING_PLAN.md)

create or replace function public.dna_learn_alias(p_attribute_id uuid, p_raw text, p_value_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_stk uuid;
  v_attr uuid;
  v_raw text := btrim(coalesce(p_raw,''));
begin
  if v_raw = '' then return; end if;
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  select attribute_id into v_attr from dna_values where id = p_value_id;
  if v_attr is null or v_attr <> p_attribute_id then
    raise exception 'Value does not belong to attribute';
  end if;
  if exists (select 1 from dna_attributes where id = v_attr and not allow_mapping) then
    raise exception 'Mapping is off for this attribute';
  end if;
  insert into dna_aliases(stockist_id, attribute_id, raw_text, value_id)
    values (v_stk, p_attribute_id, v_raw, p_value_id)
    on conflict (stockist_id, attribute_id, lower(raw_text))
    do update set value_id = excluded.value_id;
end;
$function$;

create or replace function public.dna_set_value_words(p_value_id uuid, p_words text[])
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_stk uuid; v_attr uuid; w text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  select attribute_id into v_attr from dna_values where id = p_value_id;
  if v_attr is null then raise exception 'Unknown value'; end if;
  if exists (select 1 from dna_attributes where id = v_attr and not allow_mapping) then
    raise exception 'Mapping is off for this attribute';
  end if;

  delete from dna_aliases a
   where a.stockist_id = v_stk and a.attribute_id = v_attr and a.value_id = p_value_id
     and not exists (
       select 1 from unnest(coalesce(p_words, array[]::text[])) ww
       where lower(btrim(ww)) = lower(a.raw_text));

  foreach w in array coalesce(p_words, array[]::text[]) loop
    if btrim(w) <> '' then
      insert into dna_aliases(stockist_id, attribute_id, raw_text, value_id)
        values (v_stk, v_attr, btrim(w), p_value_id)
        on conflict (stockist_id, attribute_id, lower(raw_text))
        do update set value_id = excluded.value_id;
    end if;
  end loop;
end; $function$;
