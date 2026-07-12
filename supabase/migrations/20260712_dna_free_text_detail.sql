-- DNA: "free-text detail" on a value-list attribute. When on, after the stockist
-- picks a value (e.g. Punch Type = Wave) they can pick/create a free-text word
-- tied to THAT value (e.g. "water punch"). One attribute, no separate child.
-- Rule: free_text_detail ⇒ mapping off. (docs/DNA_CASCADE_AND_MAPPING_PLAN.md)

alter table dna_attributes
  add column if not exists free_text_detail boolean not null default false;

-- admin toggle: +p_free_text_detail; turning it on forces allow_mapping off.
create or replace function public.admin_dna_update_attribute(
  p_id uuid,
  p_name text default null,
  p_is_active boolean default null,
  p_show_in_facets boolean default null,
  p_allow_mapping boolean default null,
  p_parent_attribute_id uuid default null,
  p_clear_parent boolean default false,
  p_free_text_detail boolean default null)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_new_parent uuid; v_old_parent uuid; v_ftd boolean;
begin
  if current_user_role() <> 'admin' then raise exception 'Only admins'; end if;

  select parent_attribute_id into v_old_parent from dna_attributes where id = p_id;
  v_new_parent := case when p_clear_parent then null
                       else coalesce(p_parent_attribute_id, v_old_parent) end;
  if v_new_parent is not null then
    if v_new_parent = p_id then raise exception 'An attribute cannot depend on itself'; end if;
    if exists (select 1 from dna_attributes
               where id = v_new_parent and parent_attribute_id = p_id) then
      raise exception 'That would create a circular dependency';
    end if;
  end if;

  select free_text_detail into v_ftd from dna_attributes where id = p_id;
  v_ftd := coalesce(p_free_text_detail, v_ftd);

  update dna_attributes set
    name = coalesce(nullif(btrim(coalesce(p_name,'')),''), name),
    is_active = coalesce(p_is_active, is_active),
    show_in_facets = coalesce(p_show_in_facets, show_in_facets),
    parent_attribute_id = v_new_parent,
    free_text_detail = v_ftd,
    -- free-text detail forces mapping OFF; otherwise honour p_allow_mapping.
    allow_mapping = case when v_ftd then false
                         else coalesce(p_allow_mapping, allow_mapping) end
  where id = p_id;

  if v_new_parent is distinct from v_old_parent then
    update dna_values set parent_value_id = null where attribute_id = p_id;
  end if;
end; $function$;

-- catalogs carry the new flag.
create or replace function public.dna_catalog()
 returns jsonb language sql stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  with me as (select id from stockists where user_id = auth.uid())
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', a.id, 'name', a.name, 'is_multi', a.is_multi,
      'is_free_text', a.is_free_text, 'sort_order', a.sort_order,
      'show_in_facets', a.show_in_facets,
      'allow_mapping', a.allow_mapping,
      'parent_attribute_id', a.parent_attribute_id,
      'free_text_detail', a.free_text_detail,
      'values', coalesce((
        select jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name,
                           'parent_value_id', v.parent_value_id)
                         order by v.sort_order, lower(v.name))
        from dna_values v
        where v.attribute_id = a.id and v.is_active
          and (v.stockist_id is null
               or v.stockist_id = (select id from me))), '[]'::jsonb)
    ) order by a.sort_order
  ), '[]'::jsonb)
  from dna_attributes a where a.is_active;
$function$;

create or replace function public.public_dna_catalog()
 returns jsonb language sql stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', a.id, 'name', a.name, 'is_multi', a.is_multi,
      'sort_order', a.sort_order,
      'allow_mapping', a.allow_mapping,
      'parent_attribute_id', a.parent_attribute_id,
      'free_text_detail', a.free_text_detail,
      'values', coalesce((
        select jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name,
                           'parent_value_id', v.parent_value_id)
                         order by v.sort_order, lower(v.name))
        from dna_values v
        where v.attribute_id = a.id and v.is_active
          and lower(v.name) <> 'none'), '[]'::jsonb)
    ) order by a.sort_order
  ), '[]'::jsonb)
  from dna_attributes a
  where a.is_active and (not a.is_free_text or a.show_in_facets);
$function$;

-- dna_for_design carries parent_value_id, so the app can tell a primary value
-- (parent points to the PARENT attribute) from a free-text-detail word (parent
-- points to a value of the SAME attribute).
create or replace function public.dna_for_design(p_library_id uuid)
 returns jsonb language sql stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_object_agg(attr_id::text, vals), '{}'::jsonb) from (
    select v.attribute_id as attr_id,
           jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name,
                       'parent_value_id', v.parent_value_id)) as vals
    from library_dna ld join dna_values v on v.id = ld.value_id
    where ld.library_id = p_library_id
    group by v.attribute_id
  ) s;
$function$;

-- Set/clear the free-text detail word under one primary value on a design. The
-- word is the stockist's own value, scoped to that primary value. Appends —
-- does NOT touch the primary value or other primaries.
create or replace function public.dna_set_value_detail(
  p_library_id uuid, p_parent_value_id uuid, p_texts text[])
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_attr uuid; v_t text; v_name text; v_id uuid; v_ids uuid[] := array[]::uuid[];
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if not exists (select 1 from stockist_library where id = p_library_id and stockist_id = v_stk) then
    raise exception 'Not your design'; end if;

  select attribute_id into v_attr from dna_values where id = p_parent_value_id;
  if v_attr is null then raise exception 'Unknown value'; end if;
  if not exists (select 1 from dna_attributes where id = v_attr and free_text_detail) then
    raise exception 'This attribute has no free-text detail'; end if;
  -- the primary value must be tagged on the design first
  if not exists (select 1 from library_dna where library_id = p_library_id and value_id = p_parent_value_id) then
    raise exception 'Pick the value first'; end if;

  foreach v_t in array coalesce(p_texts, array[]::text[]) loop
    v_name := btrim(v_t);
    if v_name = '' then continue; end if;
    select id into v_id from dna_values
      where attribute_id = v_attr and stockist_id = v_stk
        and parent_value_id = p_parent_value_id and lower(name) = lower(v_name)
      limit 1;
    if v_id is null then
      insert into dna_values(attribute_id, name, stockist_id, parent_value_id)
        values (v_attr, v_name, v_stk, p_parent_value_id) returning id into v_id;
    end if;
    if not (v_id = any(v_ids)) then v_ids := array_append(v_ids, v_id); end if;
  end loop;

  -- replace only THIS primary's detail tags (this stockist's, scoped to it)
  delete from library_dna ld using dna_values v
    where ld.value_id = v.id and ld.library_id = p_library_id
      and v.attribute_id = v_attr and v.parent_value_id = p_parent_value_id
      and v.stockist_id = v_stk;
  insert into library_dna(library_id, value_id)
    select p_library_id, x from unnest(v_ids) x;
end; $function$;
