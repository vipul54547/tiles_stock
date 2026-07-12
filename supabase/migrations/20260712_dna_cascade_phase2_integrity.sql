-- DNA cascade — Phase 2 (server integrity). dna_set_design now:
--   1. rejects a child value whose parent value is not set on the design, and
--   2. when a PARENT attribute is set, clears any child tags left orphaned.
-- (docs/DNA_CASCADE_AND_MAPPING_PLAN.md). Free-text children are gated in the UI
-- only (their words carry no parent link), so they don't pass through here.

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

  -- 1. If this attribute depends on a parent, every incoming child value's parent
  --    value must already be tagged on this design.
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

  -- replace this attribute's tags
  delete from library_dna ld using dna_values v
    where ld.value_id = v.id and ld.library_id = p_library_id
      and v.attribute_id = p_attribute_id;
  insert into library_dna(library_id, value_id)
    select p_library_id, v.id from dna_values v
    where v.id = any(coalesce(p_value_ids, array[]::uuid[]))
      and v.attribute_id = p_attribute_id
    on conflict do nothing;

  -- 2. Setting a parent may orphan children — drop child tags whose parent value
  --    is no longer on the design.
  delete from library_dna ld
    using dna_values cv join dna_attributes ca on ca.id = cv.attribute_id
    where ld.library_id = p_library_id and ld.value_id = cv.id
      and ca.parent_attribute_id = p_attribute_id
      and cv.parent_value_id is not null
      and not exists (
        select 1 from library_dna p
        where p.library_id = p_library_id and p.value_id = cv.parent_value_id);
end; $function$;
