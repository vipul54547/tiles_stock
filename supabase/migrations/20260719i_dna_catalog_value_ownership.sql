-- dna_catalog now marks each value's OWNERSHIP (is_own = the stockist's own free-text value, vs an
-- admin canonical). The pickers use it to offer edit/delete only on the stockist's OWN words
-- (Series, Punch Type detail), never on admin values. Identical to the live function otherwise.
create or replace function public.dna_catalog()
 returns jsonb language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  with me as (select id from stockists where user_id = auth.uid())
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', a.id, 'name', a.name, 'is_multi', a.is_multi,
      'is_free_text', a.is_free_text, 'sort_order', a.sort_order,
      'show_in_facets', a.show_in_facets, 'allow_mapping', a.allow_mapping,
      'parent_attribute_id', a.parent_attribute_id, 'free_text_detail', a.free_text_detail,
      'scope', a.scope, 'tile_type_gate', a.tile_type_gate,
      'values', coalesce((
        select jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name,
                           'parent_value_id', v.parent_value_id,
                           'is_own', (v.stockist_id is not null))
                         order by v.sort_order, lower(v.name))
        from dna_values v
        where v.attribute_id = a.id and v.is_active
          and (v.stockist_id is null or v.stockist_id = (select id from me))), '[]'::jsonb)
    ) order by a.sort_order
  ), '[]'::jsonb)
  from dna_attributes a where a.is_active;
$function$;
