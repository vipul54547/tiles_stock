-- DNA display: return parent_value_id (+ ids/sorts) so the app can render
-- parent › child › detail breadcrumb chains grouped by the ROOT attribute,
-- instead of flat per-value chips. (project_dna_cascade_mapping)

-- Stockist "My Design Library" card tags → raw tags per library.
create or replace function public.dna_my_library_tags()
 returns jsonb language sql stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  with me as (select id from stockists where user_id = auth.uid())
  select coalesce(jsonb_object_agg(lib_id::text, tags), '{}'::jsonb)
  from (
    select ld.library_id as lib_id,
           jsonb_agg(jsonb_build_object(
             'value_id', dv.id,
             'parent_value_id', dv.parent_value_id,
             'attribute', da.name,
             'attr_sort', da.sort_order,
             'val_sort', dv.sort_order,
             'label', coalesce(
               (select al.raw_text from dna_aliases al
                where al.stockist_id = (select id from me) and al.value_id = dv.id
                order by lower(al.raw_text) limit 1),
               dv.name))
             order by da.sort_order, dv.sort_order) as tags
    from library_dna ld
    join stockist_library lib on lib.id = ld.library_id
    join dna_values dv on dv.id = ld.value_id and dv.is_active
    join dna_attributes da on da.id = dv.attribute_id and da.is_active
    where lib.stockist_id = (select id from me) and lower(dv.name) <> 'none'
    group by ld.library_id
  ) s;
$function$;

-- Buyer design-detail tags (in the design's own stockist's word) → raw tags.
create or replace function public.design_dna_tags(p_design_id uuid)
 returns jsonb language sql stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(
           jsonb_build_object('attribute', attribute, 'label', label,
             'value_id', vid, 'parent_value_id', pvid,
             'attr_sort', attr_sort, 'val_sort', val_sort)
           order by attr_sort, val_sort), '[]'::jsonb)
  from (
    select distinct
           da.name as attribute, da.sort_order as attr_sort,
           dv.sort_order as val_sort, dv.id as vid, dv.parent_value_id as pvid,
           coalesce(
             (select al.raw_text from dna_aliases al
              where al.stockist_id = d.stockist_id and al.value_id = dv.id
              order by lower(al.raw_text) limit 1),
             dv.name) as label
    from designs d
    join library_dna ld on ld.library_id = d.library_id
    join dna_values dv on dv.id = ld.value_id and dv.is_active
    join dna_attributes da on da.id = dv.attribute_id and da.is_active
    where d.id = p_design_id and lower(dv.name) <> 'none'
  ) s;
$function$;

-- Buyer /s/ catalog facets → carry parent_value_id per value.
create or replace function public.public_dna_facets(p_stockist uuid)
 returns jsonb language sql stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', a.id, 'name', a.name, 'is_multi', a.is_multi,
      'is_free_text', a.is_free_text, 'sort_order', a.sort_order,
      'values', coalesce((
        select jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name,
                           'parent_value_id', v.parent_value_id)
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
