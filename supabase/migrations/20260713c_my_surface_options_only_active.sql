-- my_surface_options() is now THE source for every surface picker a stockist sees:
-- Add Stock, the Library editor + its surface chip, and the Excel template.
--
-- Its alias branch never filtered on is_active, so a word pointing at a surface the
-- admin later deactivates would still be OFFERED — and then REFUSED on save, because
-- both library_set_surface and library_upsert_master require an active, non-'None'
-- surface. An option you cannot pick is worse than a missing one. Filtered here, at the
-- single source, rather than in each of the four callers.
--
-- Nothing points at a dead surface today; this is the guard, not a repair.
create or replace function public.my_surface_options()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  with stk as (select id from stockists where user_id = auth.uid()),
  aliases as (
    select coalesce(nullif(btrim(sa.display_text), ''), initcap(lower(sa.raw_text))) as label,
           st.name as canonical
    from surface_aliases sa
    join surface_types st on st.id = sa.surface_type_id
    where sa.stockist_id = (select id from stk)
      and st.is_active                      -- a dead surface is not pickable
      and lower(st.name) <> 'none'          -- 'None' is not a surface
  ),
  no_alias as (
    select st.name as label, st.name as canonical
    from surface_types st
    where st.is_active and lower(st.name) <> 'none'
      and not exists (select 1 from aliases a where a.canonical = st.name)
  )
  select coalesce(jsonb_agg(jsonb_build_object('label', t.label, 'canonical', t.canonical)
                            order by t.canonical, t.label), '[]'::jsonb)
  from (select label, canonical from aliases
        union all
        select label, canonical from no_alias) t;
$function$;
