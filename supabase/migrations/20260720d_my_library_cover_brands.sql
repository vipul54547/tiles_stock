-- 20260720d — `my_library` says WHICH BRANDS ACTUALLY COVER each design.
--
-- 🐞 Add Stock's design picker filtered on `aliases` (the per-brand cover WORD) and on
-- `stockist_library.brand_id` (a stale first-seen hint). Neither is the truth:
--   * a brand may cover a design and print NO word on it — `cover_name_set('')` is explicitly
--     allowed ("this brand has no word for this design. Honest, and allowed"), so alias-filtering
--     misses a real box;
--   * `brand_id` is documented as a default/first-seen hint only, and identity is brand-free.
-- The truth is the BOX: `boxes (packing_id, brand_id)` — a brand's cover round a packing.
--
-- Live proof: ANUJ covered only the Highglossy ALASKA BLACK, yet picking brand ANUJ in Add Stock
-- also offered the Matt one.
--
-- `cover_brand_ids` = the distinct brands holding a box on ANY packing of the design.

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
      'id', m.id, 'brand_id', m.brand_id,
      'brand_name', coalesce((select b.name from brands b where b.id = m.brand_id), ''),
      'size', pm.size, 'master_design_name', pm.print_name, 'image_url', pm.image_url,
      'print_id', m.print_id, 'surface_type', m.surface_type, 'surface_label', m.surface_label,
      'stock_type', m.stock_type, 'tile_type', m.tile_type,
      'pieces_per_box', (select p.pieces from packings p where p.library_id = m.id order by p.created_at limit 1),
      'box_weight_kg',  (select p.weight_kg from packings p where p.library_id = m.id order by p.created_at limit 1),
      'thickness_mm', m.thickness_mm, 'created_at', m.created_at,
      'colour', _dna_colour(m.id), 'finish_label', m.finish_label,
      'body_colour', (select jsonb_build_object('id', bc.id, 'name', bc.name, 'l', bc.l, 'a', bc.a, 'b', bc.b, 'hex', bc.hex)
                      from body_colours bc where bc.id = m.body_colour_id),
      -- 🔒 boxes of stock held on this design — Edit mode locks identity when this is > 0.
      'held', (select coalesce(sum(d.box_quantity), 0) from designs d where d.library_id = m.id),
      'packings', coalesce((select jsonb_agg(jsonb_build_object('id', pk.id, 'pieces', pk.pieces, 'weight_kg', pk.weight_kg)
                         order by pk.created_at) from packings pk where pk.library_id = m.id), '[]'::jsonb),
      -- 🎁 The brands that really WRAP this design. A cover with no word still counts.
      'cover_brand_ids', coalesce((select jsonb_agg(distinct bx.brand_id)
                         from boxes bx join packings pk2 on pk2.id = bx.packing_id
                        where pk2.library_id = m.id), '[]'::jsonb),
      'aliases', coalesce((select jsonb_agg(jsonb_build_object('brand_id', a.brand_id, 'name', a.brand_design_name))
                 from stockist_library_brand_names a where a.library_id = m.id), '[]'::jsonb)
    ) order by pm.print_name, pm.size)
    from stockist_library m join print_master pm on pm.id = m.print_id
    where m.stockist_id = v_stk
  ), '[]'::jsonb);
end; $function$;
