-- DNA cascade + mapping — Phase 1: schema + admin RPCs + catalog reads.
-- (docs/DNA_CASCADE_AND_MAPPING_PLAN.md). Defaults reproduce today's behaviour:
-- allow_mapping=true, no parents. Stockist cascade + integrity = Phase 2.

-- 1. Columns.
alter table dna_attributes
  add column if not exists allow_mapping boolean not null default true,
  add column if not exists parent_attribute_id uuid references dna_attributes(id);
alter table dna_values
  add column if not exists parent_value_id uuid references dna_values(id);

-- 2. admin_dna_update_attribute — one canonical signature carrying the two new
--    controls. Drop the older overloads so there is no ambiguity.
drop function if exists admin_dna_update_attribute(uuid, text, boolean);
drop function if exists admin_dna_update_attribute(uuid, text, boolean, boolean);

create or replace function public.admin_dna_update_attribute(
  p_id uuid,
  p_name text default null,
  p_is_active boolean default null,
  p_show_in_facets boolean default null,
  p_allow_mapping boolean default null,
  p_parent_attribute_id uuid default null,
  p_clear_parent boolean default false)   -- true = detach (set parent to NULL)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_new_parent uuid; v_old_parent uuid;
begin
  if current_user_role() <> 'admin' then raise exception 'Only admins'; end if;

  select parent_attribute_id into v_old_parent from dna_attributes where id = p_id;

  -- Resolve the parent we are moving to (null when clearing or unchanged-null).
  v_new_parent := case when p_clear_parent then null
                       else coalesce(p_parent_attribute_id, v_old_parent) end;

  if v_new_parent is not null then
    if v_new_parent = p_id then raise exception 'An attribute cannot depend on itself'; end if;
    -- one-level cycle guard: the chosen parent must not already depend on us.
    if exists (select 1 from dna_attributes
               where id = v_new_parent and parent_attribute_id = p_id) then
      raise exception 'That would create a circular dependency';
    end if;
  end if;

  update dna_attributes set
    name = coalesce(nullif(btrim(coalesce(p_name,'')),''), name),
    is_active = coalesce(p_is_active, is_active),
    show_in_facets = coalesce(p_show_in_facets, show_in_facets),
    allow_mapping = coalesce(p_allow_mapping, allow_mapping),
    parent_attribute_id = v_new_parent
  where id = p_id;

  -- If the parent changed, this attribute's values' parent_value_id no longer
  -- makes sense — clear them so the admin re-assigns under the new parent.
  if v_new_parent is distinct from v_old_parent then
    update dna_values set parent_value_id = null where attribute_id = p_id;
  end if;
end; $function$;

-- 3. admin_dna_add_value — optional parent value; required + validated when the
--    attribute is dependent.
create or replace function public.admin_dna_add_value(
  p_attribute_id uuid, p_name text, p_parent_value_id uuid default null)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_id uuid; v_ord int; v_parent_attr uuid;
begin
  if current_user_role() <> 'admin' then raise exception 'Only admins'; end if;
  if btrim(coalesce(p_name,'')) = '' then raise exception 'Name required'; end if;

  select parent_attribute_id into v_parent_attr from dna_attributes where id = p_attribute_id;
  if v_parent_attr is not null then
    if p_parent_value_id is null then
      raise exception 'This attribute depends on a parent — pick a parent value';
    end if;
    if not exists (select 1 from dna_values
                   where id = p_parent_value_id and attribute_id = v_parent_attr) then
      raise exception 'Parent value does not belong to the parent attribute';
    end if;
  end if;

  select coalesce(max(sort_order),0)+1 into v_ord from dna_values where attribute_id=p_attribute_id;
  insert into dna_values(attribute_id, name, sort_order, parent_value_id)
    values (p_attribute_id, btrim(p_name), v_ord,
            case when v_parent_attr is null then null else p_parent_value_id end)
    on conflict (attribute_id, lower(name)) where stockist_id is null do nothing
    returning id into v_id;
  return v_id;
end; $function$;

-- 4. admin_dna_update_value — can also re-assign the parent value.
create or replace function public.admin_dna_update_value(
  p_id uuid, p_name text default null, p_is_active boolean default null,
  p_parent_value_id uuid default null, p_set_parent boolean default false)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_attr uuid; v_parent_attr uuid;
begin
  if current_user_role() <> 'admin' then raise exception 'Only admins'; end if;

  if p_set_parent and p_parent_value_id is not null then
    select attribute_id into v_attr from dna_values where id = p_id;
    select parent_attribute_id into v_parent_attr from dna_attributes where id = v_attr;
    if v_parent_attr is null then
      raise exception 'This attribute has no parent';
    end if;
    if not exists (select 1 from dna_values
                   where id = p_parent_value_id and attribute_id = v_parent_attr) then
      raise exception 'Parent value does not belong to the parent attribute';
    end if;
  end if;

  update dna_values set
    name = coalesce(nullif(btrim(coalesce(p_name,'')),''), name),
    is_active = coalesce(p_is_active, is_active),
    parent_value_id = case when p_set_parent then p_parent_value_id else parent_value_id end
  where id = p_id;
end; $function$;

-- 5. dna_catalog — expose allow_mapping + parent_attribute_id + each value's parent.
create or replace function public.dna_catalog()
 returns jsonb
 language sql
 stable security definer
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

-- 6. public_dna_catalog — carry the same fields (buyer UI ignores them; buyer
--    filters stay flat — decision 5). Kept in sync so nothing drifts.
create or replace function public.public_dna_catalog()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', a.id, 'name', a.name, 'is_multi', a.is_multi,
      'sort_order', a.sort_order,
      'allow_mapping', a.allow_mapping,
      'parent_attribute_id', a.parent_attribute_id,
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
