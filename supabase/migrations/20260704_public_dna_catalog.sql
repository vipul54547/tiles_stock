-- Buyer-wide DNA catalog: every active attribute + value (id + name), across ALL
-- stockists (global + per-stockist values), so any tagged value resolves to a
-- name on any buyer surface. Anonymous-callable (web /s/ + app). Pairs with the
-- public designs_dna_values(ids). (project_design_dna_engine)
create or replace function public.public_dna_catalog()
returns jsonb language sql stable security definer
set search_path to 'public','pg_temp' as $$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', a.id, 'name', a.name, 'is_multi', a.is_multi,
      'sort_order', a.sort_order,
      'values', coalesce((
        select jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name)
                         order by v.sort_order, lower(v.name))
        from dna_values v
        where v.attribute_id = a.id and v.is_active
          and lower(v.name) <> 'none'), '[]'::jsonb)
    ) order by a.sort_order
  ), '[]'::jsonb)
  from dna_attributes a
  where a.is_active and (not a.is_free_text or a.show_in_facets);
$$;

grant execute on function public.public_dna_catalog() to anon, authenticated;
