-- 20260722g — 🏭 Plan demand: outstanding = ordered − SENT (not − produced).
--
-- With the MADE flow, "fulfilled" is what's been SENT to a Ready order (sent_qty), not what's been
-- produced (produced_qty is just made stock, which lives in F_Stock). If the plan kept counting
-- ordered − produced, a line sent FROM THE GODOWN (sent up, produced unchanged) would still show as
-- "to make" → double-production. Outstanding now = ordered − sent; the already-made material shows as
-- GODOWN (f_stock) so the stockist nets it off manually. produced stays as an info figure.
-- (docs/PRODUCTION_REDESIGN_PLAN.md — close the loop)

create or replace function public.my_production_demand()
 returns jsonb
 language plpgsql stable security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_stk uuid; v_rows jsonb;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;

  select coalesce(jsonb_agg(r order by r->>'print_name', r->>'brand'), '[]'::jsonb)
  into v_rows
  from (
    select jsonb_build_object(
      'box_id', bx.id, 'library_id', lib.id, 'packing_id', pk.id,
      'print_name', pm.print_name,
      'image', nullif(btrim(coalesce(pm.image_url,'')),''),
      'size', pm.size,
      'cover_word', coalesce(nullif(btrim(coalesce(bn.brand_design_name,'')),''), pm.print_name),
      'surface', lib.surface_type, 'tile_type', coalesce(lib.tile_type,''),
      'body_colour', coalesce((select name from body_colours where id = lib.body_colour_id), ''),
      'thickness_mm', lib.thickness_mm,
      'brand', b.name, 'brand_id', b.id, 'pieces', pk.pieces,
      'punch', coalesce((select string_agg(v.name, ', ') from _dna_of_library(lib.id) dl
                          join dna_values v on v.id = dl.value_id
                         where v.attribute_id = 'b8286979-2785-4da0-b142-517f963e3a69'), ''),
      'punch_type', coalesce((select string_agg(v.name, ', ') from _dna_of_library(lib.id) dl
                          join dna_values v on v.id = dl.value_id
                         where v.attribute_id = 'af8a2dcf-dc94-4f9b-bfac-7f98642f29d1'), ''),
      'series', coalesce((select string_agg(v.name, ', ') from _dna_of_library(lib.id) dl
                          join dna_values v on v.id = dl.value_id
                         where v.attribute_id = '094c0c92-b4ea-465e-9748-5753883dd79b'), ''),
      'ordered_boxes', sum(l.quantity),
      'produced_boxes', sum(l.produced_qty),
      'remaining_boxes', sum(greatest(l.quantity - l.sent_qty, 0)),
      'remaining_pieces', sum(greatest(l.quantity - l.sent_qty, 0)) * pk.pieces,
      'remaining_sqft', round(sum(greatest(l.quantity - l.sent_qty, 0)) * pk.pieces
                              * coalesce(_tile_area_m2(pm.size), 0) * 10.7639, 1),
      'urgent', bool_or(l.is_urgent),
      'oldest_order_at', min(o.created_at),
      -- ⚠️ INFORMATION at this instant. NEVER netted against the demand above.
      'p_stock', coalesce((select sum(d.box_quantity) from designs d where d.box_id = bx.id), 0),
      'f_stock', coalesce((select sum(greatest(d.box_quantity - d.control_quantity - held_of(d.id), 0))
                             from designs d where d.box_id = bx.id), 0),
      'lines', jsonb_agg(jsonb_build_object(
          'line_id', l.id, 'order_id', o.id, 'token', o.token,
          'customer', coalesce(c.name, nullif(btrim(coalesce(o.customer_hint,'')),''), 'Walk-in'),
          'note', coalesce(o.customer_hint,''),
          'ordered', l.quantity,
          'produced', l.produced_qty,
          'remaining', greatest(l.quantity - l.sent_qty, 0),
          -- already committed to an open run, so he never plans the same boxes twice
          'planned', coalesce((select sum(d2.planned_boxes)
                                 from production_run_demand d2
                                 join production_runs r2 on r2.id = d2.run_id
                                where d2.book_order_line_id = l.id
                                  and r2.status in ('planned','running')), 0),
          'urgent', l.is_urgent) order by l.is_urgent desc, o.created_at)
    ) as r
    from book_order_lines l
    join book_orders o on o.id = l.order_id
    join boxes bx on bx.id = l.box_id
    join packings pk on pk.id = bx.packing_id
    join stockist_library lib on lib.id = pk.library_id
    join print_master pm on pm.id = lib.print_id
    join brands b on b.id = bx.brand_id
    left join stockist_library_brand_names bn
           on bn.library_id = lib.id and bn.brand_id = bx.brand_id
    left join stockist_customers c on c.id = o.customer_id
    where o.stockist_id = v_stk and o.status = 'open'
      and l.quantity > l.sent_qty
    group by bx.id, lib.id, pk.id, pm.print_name, pm.image_url, pm.size,
             lib.surface_type, lib.tile_type, lib.body_colour_id, lib.thickness_mm,
             b.name, b.id, bn.brand_design_name, pk.pieces
  ) t;

  return jsonb_build_object('as_of', now(), 'rows', v_rows);
end $function$;
