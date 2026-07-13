-- CHAPTER 3 — the Library must READ the declared thickness, or the editor cannot show it back.
-- (docs/THICKNESS_AND_BODY_IDENTITY_PLAN.md)
--
-- `thickness_mm` stays in the payload but is now EVIDENCE (derived from the BOX).
-- `nominal_thickness_mm` is the DECLARED value and is part of product identity.

create or replace function public.my_library()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists have a library'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id,
      'brand_id', m.brand_id,
      'brand_name', coalesce((select b.name from brands b where b.id = m.brand_id), ''),
      'size', m.size,
      'master_design_name', m.master_design_name,
      'image_url', m.image_url,
      'surface_type', m.surface_type,
      'surface_label', m.surface_label,
      'stock_type', m.stock_type,
      'tile_type', m.tile_type,
      'pieces_per_box', (select a.pieces_per_box from stockist_library_brand_names a
                          where a.library_id = m.id and coalesce(a.pieces_per_box,0) > 0
                          order by a.created_at limit 1),
      'box_weight_kg',  (select a.box_weight_kg from stockist_library_brand_names a
                          where a.library_id = m.id and coalesce(a.box_weight_kg,0) > 0
                          order by a.created_at limit 1),
      -- DERIVED, evidence only. It validates the declaration; it is not the truth.
      'thickness_mm', m.thickness_mm,
      -- DECLARED. Part of identity. NULL on the rows that predate CHAPTER 3.
      'nominal_thickness_mm', m.nominal_thickness_mm,
      'colour', m.colour,
      'finish_label', m.finish_label,
      -- an alias IS a box: name + how that brand packs it
      'aliases', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'brand_id', a.brand_id,
                 'name', a.brand_design_name,
                 'pieces_per_box', a.pieces_per_box,
                 'box_weight_kg', a.box_weight_kg))
        from stockist_library_brand_names a where a.library_id = m.id), '[]'::jsonb)
    ) order by m.master_design_name, m.size)
    from stockist_library m where m.stockist_id = v_stk
  ), '[]'::jsonb);
end; $function$;
