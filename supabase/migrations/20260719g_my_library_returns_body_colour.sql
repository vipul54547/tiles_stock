-- my_library now returns each design's BODY COLOUR (name + L·a·b / hex), so the Library card can
-- show it — one print+surface is now several products when the body colour differs, and the card
-- must make that visible. NULL for glazed tiles (they have no body colour). Everything else is
-- byte-for-byte the live function.
create or replace function public.my_library()
 returns jsonb
 language plpgsql security definer set search_path to 'public', 'pg_temp'
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
      'size', pm.size,
      'master_design_name', pm.print_name,
      'image_url', pm.image_url,
      'print_id', m.print_id,
      'surface_type', m.surface_type,
      'surface_label', m.surface_label,
      'stock_type', m.stock_type,
      'tile_type', m.tile_type,
      'pieces_per_box', (select p.pieces from packings p
                          where p.library_id = m.id order by p.created_at limit 1),
      'box_weight_kg',  (select p.weight_kg from packings p
                          where p.library_id = m.id order by p.created_at limit 1),
      'thickness_mm', m.thickness_mm,
      'created_at', m.created_at,
      'colour', _dna_colour(m.id),
      'finish_label', m.finish_label,
      -- 🎨 the body colour that identifies a Full/Colour Body design (NULL for glazed tiles)
      'body_colour', (select jsonb_build_object(
                        'id', bc.id, 'name', bc.name, 'l', bc.l, 'a', bc.a, 'b', bc.b, 'hex', bc.hex)
                      from body_colours bc where bc.id = m.body_colour_id),
      'packings', coalesce((
        select jsonb_agg(jsonb_build_object('id', pk.id, 'pieces', pk.pieces, 'weight_kg', pk.weight_kg)
                         order by pk.created_at)
        from packings pk where pk.library_id = m.id), '[]'::jsonb),
      'aliases', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'brand_id', a.brand_id,
                 'name', a.brand_design_name))
        from stockist_library_brand_names a where a.library_id = m.id), '[]'::jsonb)
    ) order by pm.print_name, pm.size)
    from stockist_library m
    join print_master pm on pm.id = m.print_id
    where m.stockist_id = v_stk
  ), '[]'::jsonb);
end; $function$;
