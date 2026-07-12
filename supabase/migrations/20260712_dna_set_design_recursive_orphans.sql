-- DNA cascade: make dna_set_design's orphan cleanup RECURSIVE, so a 3+ level
-- chain (e.g. Punch → Punch Type → free-text/detail) clears its whole subtree
-- when an ancestor value changes — not just the direct children. Supersedes the
-- one-level cleanup in 20260712_dna_cascade_phase2_integrity.sql.
-- (docs/DNA_CASCADE_AND_MAPPING_PLAN.md). Proven on live data (rollback):
-- tagging TP1→TP2→TP3 then changing TP1 clears both TP2 and TP3.

create or replace function public.dna_set_design(
  p_library_id uuid, p_attribute_id uuid, p_value_ids uuid[])
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_parent_attr uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if not exists (select 1 from stockist_library where id=p_library_id and stockist_id=v_stk) then
    raise exception 'Not your design'; end if;

  select parent_attribute_id into v_parent_attr from dna_attributes where id=p_attribute_id;
  if v_parent_attr is not null then
    if exists (
      select 1 from dna_values v
      where v.id = any(coalesce(p_value_ids, array[]::uuid[]))
        and v.attribute_id = p_attribute_id
        and v.parent_value_id is not null
        and not exists (
          select 1 from library_dna ld
          where ld.library_id = p_library_id and ld.value_id = v.parent_value_id)
    ) then
      raise exception 'Pick the parent value first';
    end if;
  end if;

  delete from library_dna ld using dna_values v
    where ld.value_id = v.id and ld.library_id = p_library_id
      and v.attribute_id = p_attribute_id;
  insert into library_dna(library_id, value_id)
    select p_library_id, v.id from dna_values v
    where v.id = any(coalesce(p_value_ids, array[]::uuid[]))
      and v.attribute_id = p_attribute_id
    on conflict do nothing;

  with recursive orphan as (
    select cv.id
    from library_dna ld
    join dna_values cv on cv.id = ld.value_id
    join dna_attributes ca on ca.id = cv.attribute_id
    where ld.library_id = p_library_id
      and ca.parent_attribute_id = p_attribute_id
      and cv.parent_value_id is not null
      and not exists (
        select 1 from library_dna p
        where p.library_id = p_library_id and p.value_id = cv.parent_value_id)
    union
    select gv.id
    from orphan o
    join dna_values gv on gv.parent_value_id = o.id
    join library_dna ld on ld.library_id = p_library_id and ld.value_id = gv.id
  )
  delete from library_dna
    where library_id = p_library_id and value_id in (select id from orphan);
end; $function$;
