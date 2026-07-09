-- Surface as a Design DNA attribute.
--
-- in_name stockists keep the surface INSIDE the verbatim design_name
-- (project_design_name_is_verbatim_truth); the holding carries no surface. To
-- let buyers still FILTER those designs by surface, surface becomes a faceted
-- Design DNA attribute on the library print (DNA "generalises Surface").
-- Attribute-mode surface stays on the holding (designs.surface_type) as before.
--
-- The DNA value names MIRROR surface_types so a single buyer Surface filter can
-- match attribute-mode surface_type strings AND in_name DNA values by NAME.
-- (project_per_brand_surface_mode)
do $$
declare v_attr uuid;
begin
  -- Idempotent: do nothing if a Surface attribute already exists.
  if exists (select 1 from dna_attributes where lower(name) = 'surface') then
    return;
  end if;

  insert into dna_attributes(name, is_multi, is_free_text, show_in_facets, sort_order)
    values ('Surface', false, false, true,
            (select coalesce(max(sort_order), 0) + 1 from dna_attributes))
    returning id into v_attr;

  -- 'None' = no surface (matches the add-attribute convention).
  insert into dna_values(attribute_id, name, sort_order)
    values (v_attr, 'None', 0);

  -- Mirror the active surface_types (except None) as canonical facet values.
  insert into dna_values(attribute_id, name, sort_order)
    select v_attr, st.name,
           row_number() over (order by st.sort_order)
    from surface_types st
    where st.is_active and lower(st.name) <> 'none';
end $$;
