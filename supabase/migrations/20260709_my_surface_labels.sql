-- The logged-in stockist's OWN word per canonical finish, for the Add Stock
-- picker: { canonicalFinishName : displayWord }. One display word per finish
-- (their primary). The picker shows these words but stores the CANONICAL, so
-- everything downstream (holding, filter, dispatch, buyer resolution) stays on
-- the admin canonical. (project_per_brand_surface_mode)
create or replace function public.my_surface_labels()
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_object_agg(t.surface_name, t.display_text), '{}'::jsonb)
  from (
    select distinct on (sa.surface_type_id)
      st.name as surface_name,
      coalesce(nullif(btrim(sa.display_text), ''), initcap(lower(sa.raw_text))) as display_text
    from surface_aliases sa
    join stockists s      on s.id = sa.stockist_id and s.user_id = auth.uid()
    join surface_types st on st.id = sa.surface_type_id
    order by sa.surface_type_id, sa.created_at, sa.raw_text
  ) t;
$function$;

grant execute on function public.my_surface_labels() to authenticated;
