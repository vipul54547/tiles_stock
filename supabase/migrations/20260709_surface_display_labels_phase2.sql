-- Phase 2: show the stockist's OWN surface word on buyer cards.
--
-- surface_aliases already maps each stockist's word -> canonical finish, but
-- raw_text is normalised (UPPERCASE, no spaces) for import matching. Add a
-- display_text holding the original, nice-cased word ("Raindrops", "Glossy
-- Finish", "HG") for buyer display. public_surface_labels() resolves ONE display
-- word per (stockist, canonical finish), keyed by sequential_id (which is how
-- buyer designs carry their stockist). (project_per_brand_surface_mode)

alter table public.surface_aliases add column if not exists display_text text;

create or replace function public.public_surface_labels()
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'stockist', t.seq,
    'surface',  t.surface_name,
    'raw',      t.raw_text,
    'display',  t.display_text
  )), '[]'::jsonb)
  from (
    select distinct on (sa.stockist_id, sa.surface_type_id)
      s.sequential_id as seq,
      st.name         as surface_name,
      sa.raw_text,
      coalesce(nullif(btrim(sa.display_text), ''), initcap(lower(sa.raw_text))) as display_text
    from surface_aliases sa
    join stockists s     on s.id = sa.stockist_id
    join surface_types st on st.id = sa.surface_type_id
    order by sa.stockist_id, sa.surface_type_id, sa.created_at, sa.raw_text
  ) t;
$function$;

grant execute on function public.public_surface_labels() to anon, authenticated;
