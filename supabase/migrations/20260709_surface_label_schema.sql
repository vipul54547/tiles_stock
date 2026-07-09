-- Surface = two-part per holding: the stockist's OWN word (surface_label) +
-- the admin canonical (surface_type). Stockist screens read surface_label; buyer
-- cards show "surface_label (surface_type)"; stockist filter = surface_label,
-- buyer filter = surface_type. The stockist PICKS the word at Add Stock (one of
-- their aliases), so different words (Golden Series vs DC Series, both Glossy)
-- stay as separate stock rows. (project_per_brand_surface_mode)

alter table public.designs         add column if not exists surface_label text;
alter table public.stockist_library add column if not exists surface_label text;

-- The stockist's pickable surface options for the Add Stock picker:
-- [{label, canonical}] = each of their alias words (nice-cased) with its admin
-- finish, PLUS any active admin finish they have no alias for (shown as the
-- admin name). None is added client-side for in_name.
create or replace function public.my_surface_options()
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  with stk as (select id from stockists where user_id = auth.uid()),
  aliases as (
    select coalesce(nullif(btrim(sa.display_text), ''), initcap(lower(sa.raw_text))) as label,
           st.name as canonical
    from surface_aliases sa
    join surface_types st on st.id = sa.surface_type_id
    where sa.stockist_id = (select id from stk)
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

grant execute on function public.my_surface_options() to authenticated;
