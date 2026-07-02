-- Series DNA chip: repurpose the unused "Range" free-text attribute into a
-- stockist-private "Series" chip (own naming, no admin mapping), expose
-- free-text attributes as buyer-facing facets via an opt-in flag, and add
-- rename/delete for a stockist's own values.

-- 1. Opt-in facet visibility for free-text attributes (Range/Series-like).
--    Non-free-text attributes are unaffected (always shown, as today).
alter table dna_attributes add column if not exists show_in_facets boolean not null default false;

-- 2. Pre-existing bug fix: dna_values_attr_name_uq enforced global uniqueness
--    of (attribute_id, lower(name)) across ALL rows, including private
--    (stockist_id not null) ones. That means two different stockists could
--    never both name a private value the same thing (e.g. two stockists
--    both wanting a series called "Premium") without a constraint violation.
--    Canonical/admin values (stockist_id is null) still need global
--    uniqueness; private values only need to be unique within their own
--    stockist, which dna_values_stockist_uq already enforces correctly.
--    Narrow the first index to canonical rows only.
drop index if exists dna_values_attr_name_uq;
create unique index dna_values_attr_name_uq on dna_values (attribute_id, lower(name))
  where stockist_id is null;

create or replace function public.admin_dna_add_value(p_attribute_id uuid, p_name text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_id uuid; v_ord int;
begin
  if current_user_role() <> 'admin' then raise exception 'Only admins'; end if;
  if btrim(coalesce(p_name,'')) = '' then raise exception 'Name required'; end if;
  select coalesce(max(sort_order),0)+1 into v_ord from dna_values where attribute_id=p_attribute_id;
  insert into dna_values(attribute_id, name, sort_order)
    values (p_attribute_id, btrim(p_name), v_ord)
    on conflict (attribute_id, lower(name)) where stockist_id is null do nothing
    returning id into v_id;
  return v_id;
end; $function$;

-- 3. Admin attribute create/update: thread the new flag through.
create or replace function public.admin_dna_add_attribute(p_name text, p_is_multi boolean DEFAULT false, p_is_free_text boolean DEFAULT false, p_show_in_facets boolean DEFAULT false)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_id uuid; v_ord int;
begin
  if current_user_role() <> 'admin' then raise exception 'Only admins'; end if;
  if btrim(coalesce(p_name,'')) = '' then raise exception 'Name required'; end if;
  select coalesce(max(sort_order),0)+1 into v_ord from dna_attributes;
  insert into dna_attributes(name, is_multi, is_free_text, sort_order, show_in_facets)
    values (btrim(p_name), coalesce(p_is_multi,false), coalesce(p_is_free_text,false), v_ord, coalesce(p_show_in_facets,false))
    returning id into v_id;
  if not coalesce(p_is_free_text,false) then
    insert into dna_values(attribute_id, name, sort_order) values (v_id, 'None', 0);
  end if;
  return v_id;
end; $function$;

create or replace function public.admin_dna_update_attribute(p_id uuid, p_name text DEFAULT NULL::text, p_is_active boolean DEFAULT NULL::boolean, p_show_in_facets boolean DEFAULT NULL::boolean)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
begin
  if current_user_role() <> 'admin' then raise exception 'Only admins'; end if;
  update dna_attributes set
    name = coalesce(nullif(btrim(coalesce(p_name,'')),''), name),
    is_active = coalesce(p_is_active, is_active),
    show_in_facets = coalesce(p_show_in_facets, show_in_facets)
  where id = p_id;
end; $function$;

-- 4. dna_catalog(): expose the new flag so the app can decide whether a
--    free-text attribute participates in facet filters.
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
      'values', coalesce((
        select jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name)
                         order by v.sort_order, lower(v.name))
        from dna_values v
        where v.attribute_id = a.id and v.is_active
          and (v.stockist_id is null
               or v.stockist_id = (select id from me))), '[]'::jsonb)
    ) order by a.sort_order
  ), '[]'::jsonb)
  from dna_attributes a where a.is_active;
$function$;

-- 5. public_dna_facets(): let opted-in free-text attributes through.
create or replace function public.public_dna_facets(p_stockist uuid)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', a.id, 'name', a.name, 'is_multi', a.is_multi,
      'is_free_text', a.is_free_text, 'sort_order', a.sort_order,
      'values', coalesce((
        select jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name)
                         order by v.sort_order, lower(v.name))
        from dna_values v
        where v.attribute_id = a.id and v.is_active
          and lower(v.name) <> 'none'
          and (v.stockist_id is null or v.stockist_id = p_stockist)), '[]'::jsonb)
    ) order by a.sort_order
  ), '[]'::jsonb)
  from dna_attributes a
  where a.is_active and (not a.is_free_text or a.show_in_facets);
$function$;

-- 6. Rename / delete a stockist's own private value (Series entries).
create or replace function public.dna_rename_my_value(p_value_id uuid, p_new_name text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_stk uuid; v_attr uuid; v_name text := btrim(coalesce(p_new_name,''));
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if v_name = '' then raise exception 'Name required'; end if;
  select attribute_id into v_attr from dna_values where id = p_value_id and stockist_id = v_stk;
  if v_attr is null then raise exception 'Not your value'; end if;
  if exists (
    select 1 from dna_values
    where attribute_id = v_attr and stockist_id = v_stk
      and lower(name) = lower(v_name) and id <> p_value_id
  ) then
    raise exception 'You already have a value named "%"', v_name;
  end if;
  update dna_values set name = v_name where id = p_value_id;
end; $function$;

create or replace function public.dna_delete_my_value(p_value_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  delete from dna_values where id = p_value_id and stockist_id = v_stk;
end; $function$;

create or replace function public.dna_my_values_with_usage(p_attribute_id uuid)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  with me as (select id from stockists where user_id = auth.uid())
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', v.id, 'name', v.name,
      'design_count', (select count(*) from library_dna ld where ld.value_id = v.id)
    ) order by lower(v.name)
  ), '[]'::jsonb)
  from dna_values v
  where v.attribute_id = p_attribute_id and v.stockist_id = (select id from me);
$function$;

grant execute on function public.dna_rename_my_value(uuid, text) to authenticated;
grant execute on function public.dna_delete_my_value(uuid) to authenticated;
grant execute on function public.dna_my_values_with_usage(uuid) to authenticated;

-- 7. Repurpose "Range" -> "Series" in place (zero real usage: 2 leftover
--    test values, 0 tagged designs). Already is_multi=false, is_free_text=true.
do $$
declare v_attr uuid;
begin
  select id into v_attr from dna_attributes where name = 'Range';
  if v_attr is not null then
    update dna_attributes set name = 'Series', show_in_facets = true where id = v_attr;
    delete from dna_values where attribute_id = v_attr and name in ('Postcard', 'Diamond Gliter');
  end if;
end $$;
