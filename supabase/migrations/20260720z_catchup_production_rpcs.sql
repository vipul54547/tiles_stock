-- 20260720z — CATCH-UP part 3: the PRODUCTION RPCs (was `20260720q`, `s`, `t`, `u`, `w`).
-- See `20260720x` for why these files did not exist.

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- 🏭 WHAT THE LINE HAS TO MAKE
-- ⚠️ `p_stock` / `f_stock` are INFORMATION read at `as_of` — never netted against the demand.
-- ════════════════════════════════════════════════════════════════════════════════════════════
create or replace function public.my_production_demand()
 returns jsonb
 language plpgsql stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
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
      -- 🧬 what is RUNNING — read through _dna_of_library so the PRINT's tags come too
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
      'remaining_boxes', sum(greatest(l.quantity - l.produced_qty, 0)),
      'remaining_pieces', sum(greatest(l.quantity - l.produced_qty, 0)) * pk.pieces,
      'remaining_sqft', round(sum(greatest(l.quantity - l.produced_qty, 0)) * pk.pieces
                              * coalesce(_tile_area_m2(pm.size), 0) * 10.7639, 1),
      'urgent', bool_or(l.is_urgent),
      'oldest_order_at', min(o.created_at),
      'p_stock', coalesce((select sum(d.box_quantity) from designs d where d.box_id = bx.id), 0),
      'f_stock', coalesce((select sum(greatest(d.box_quantity - d.control_quantity - held_of(d.id), 0))
                             from designs d where d.box_id = bx.id), 0),
      'lines', jsonb_agg(jsonb_build_object(
          'line_id', l.id, 'order_id', o.id, 'token', o.token,
          'customer', coalesce(c.name, nullif(btrim(coalesce(o.customer_hint,'')),''), 'Walk-in'),
          'note', coalesce(o.customer_hint,''),
          'ordered', l.quantity, 'produced', l.produced_qty,
          'remaining', greatest(l.quantity - l.produced_qty, 0),
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
      and l.quantity > l.produced_qty
    group by bx.id, lib.id, pk.id, pm.print_name, pm.image_url, pm.size,
             lib.surface_type, lib.tile_type, lib.body_colour_id, lib.thickness_mm,
             b.name, b.id, bn.brand_design_name, pk.pieces
  ) t;

  return jsonb_build_object('as_of', now(), 'rows', v_rows);
end $function$;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- 🔪 TAKE INTO PRODUCTION — the tick is the decision, and it SLICES the order.
-- 🚫 Writes NOTHING to stock and does NOT raise produced_qty.
-- ════════════════════════════════════════════════════════════════════════════════════════════
create or replace function public.production_take_into_run(
  p_name text, p_boxes jsonb, p_demand jsonb, p_note text default null)
 returns jsonb
 language plpgsql security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_stk uuid; v_run uuid; v_run_name text; e jsonb;
  v_box uuid; v_qty int; v_line uuid; v_left int;
  v_boxes int := 0; v_lines int := 0; v_orders int; v_slices int := 0;
  r record; tk record; v_slice uuid; v_letter text; v_target uuid;
  v_full boolean; v_urg boolean;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if not coalesce((select book_orders_enabled from stockists where id = v_stk), false) then
    raise exception 'Book Order is not switched on for you.';
  end if;
  if coalesce(jsonb_array_length(p_boxes), 0) = 0 then
    raise exception 'Nothing to run — set a quantity on at least one design.';
  end if;
  if coalesce(jsonb_array_length(p_demand), 0) = 0 then
    raise exception 'Tick at least one customer''s line, so the run knows who it is for.';
  end if;

  create temp table _tick(line_id uuid primary key, order_id uuid, box_id uuid,
                          qty int, is_urgent boolean) on commit drop;
  for e in select * from jsonb_array_elements(p_demand) loop
    v_line := nullif(e->>'book_order_line_id','')::uuid;
    v_qty  := greatest(coalesce((e->>'planned_boxes')::int, 0), 0);
    if v_qty = 0 then continue; end if;
    select greatest(l.quantity - l.produced_qty, 0), l.order_id, l.box_id, l.is_urgent
      into v_left, v_target, v_box, v_urg
      from book_order_lines l join book_orders o on o.id = l.order_id
     where l.id = v_line and o.stockist_id = v_stk and o.status = 'open' and o.slice is null;
    if v_left is null then
      raise exception 'That booked line is not yours, or its order is not open for planning.';
    end if;
    v_qty := least(v_qty, v_left);
    if v_qty > 0 then insert into _tick values (v_line, v_target, v_box, v_qty, v_urg); end if;
  end loop;
  if not exists (select 1 from _tick) then
    raise exception 'Nothing left to take — those lines are already produced.';
  end if;

  insert into production_runs (stockist_id, name, note)
  values (v_stk, coalesce(nullif(btrim(coalesce(p_name,'')),''),
                          'RUN-' || lpad(nextval('production_run_seq')::text, 5, '0')),
          nullif(btrim(coalesce(p_note,'')),''))
  returning id, name into v_run, v_run_name;

  for e in select * from jsonb_array_elements(p_boxes) loop
    v_box := nullif(e->>'box_id','')::uuid;
    v_qty := greatest(coalesce((e->>'target_boxes')::int, 0), 0);
    if v_qty = 0 then continue; end if;
    if not exists (
      select 1 from boxes bx join packings pk on pk.id = bx.packing_id
      join stockist_library l on l.id = pk.library_id
      where bx.id = v_box and l.stockist_id = v_stk) then
      raise exception 'That box is not yours';
    end if;
    insert into production_run_boxes (run_id, box_id, target_boxes)
    values (v_run, v_box, v_qty)
    on conflict (run_id, box_id) do update set target_boxes = excluded.target_boxes;
    v_boxes := v_boxes + v_qty;
  end loop;

  -- 🔪 one slice per order, unless the WHOLE order is going (then no slice — two documents for
  -- one thing would be worse than none).
  for r in select distinct order_id as oid from _tick loop
    select not exists (
      select 1 from book_order_lines l
       where l.order_id = r.oid
         and coalesce((select t.qty from _tick t where t.line_id = l.id), 0)
             < greatest(l.quantity - l.produced_qty, 0)
    ) into v_full;

    if v_full then
      update book_orders set status = 'in_production', updated_at = now() where id = r.oid;
      insert into production_run_demand (run_id, book_order_line_id, planned_boxes)
      select v_run, t.line_id, t.qty from _tick t where t.order_id = r.oid
      on conflict (run_id, book_order_line_id) do update set planned_boxes = excluded.planned_boxes;
    else
      v_letter := _next_slice_letter(r.oid);
      insert into book_orders (stockist_id, customer_id, customer_hint, parent_id, slice, token, status)
      select o.stockist_id, o.customer_id, o.customer_hint, o.id, v_letter,
             o.token || '/' || v_letter, 'in_production'
        from book_orders o where o.id = r.oid
      returning id into v_slice;
      v_slices := v_slices + 1;

      for tk in select * from _tick t where t.order_id = r.oid loop
        insert into book_order_lines (order_id, box_id, quantity, is_urgent)
        values (v_slice, tk.box_id, tk.qty, tk.is_urgent)
        returning id into v_target;
        perform _move_book_line(tk.line_id, tk.qty);
        insert into production_run_demand (run_id, book_order_line_id, planned_boxes)
        values (v_run, v_target, tk.qty)
        on conflict (run_id, book_order_line_id) do update set planned_boxes = excluded.planned_boxes;
      end loop;

      update book_orders set status = 'closed', closed_at = now()
       where id = r.oid
         and not exists (select 1 from book_order_lines l where l.order_id = r.oid);
    end if;
  end loop;

  select count(*) into v_lines from production_run_demand where run_id = v_run;
  if v_lines = 0 then raise exception 'Nothing was taken into the run.'; end if;

  select count(distinct o.id) into v_orders
    from production_run_demand d
    join book_order_lines l on l.id = d.book_order_line_id
    join book_orders o on o.id = l.order_id
   where d.run_id = v_run;

  return jsonb_build_object('id', v_run, 'name', v_run_name,
    'boxes', v_boxes, 'lines', v_lines, 'orders', v_orders, 'slices', v_slices);
end $function$;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- 🏭 DECLARE OUTPUT — the moment material becomes STOCK.
-- 🔑 OUTPUT HONOURS THE TICK: this run's own lines settle first.
-- 🚫 Standard is never allocated. 🚫 Never across a brand. 🚫 Never creates a box.
-- ════════════════════════════════════════════════════════════════════════════════════════════
create or replace function public.production_declare_output(
  p_run_id uuid, p_box_id uuid, p_boxes integer, p_quality text default 'Premium')
 returns jsonb
 language plpgsql security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_stk uuid; v_lib uuid; v_brand uuid; v_pack uuid; v_q text;
  v_design uuid; v_left int; v_take int;
  v_run_alloc int := 0; v_other_alloc int := 0; v_closed int := 0;
  r record;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if coalesce(p_boxes,0) <= 0 then raise exception 'How many boxes came off the line?'; end if;
  v_q := coalesce(nullif(btrim(coalesce(p_quality,'')),''), 'Premium');

  if not exists (select 1 from production_runs where id = p_run_id and stockist_id = v_stk) then
    raise exception 'That run is not yours';
  end if;

  select pk.library_id, bx.brand_id, pk.id into v_lib, v_brand, v_pack
    from boxes bx
    join packings pk on pk.id = bx.packing_id
    join stockist_library l on l.id = pk.library_id
   where bx.id = p_box_id and l.stockist_id = v_stk;
  if v_lib is null then raise exception 'That box is not yours'; end if;

  v_design := stock_add_holding(v_lib, v_q, p_boxes, null, null, v_brand, null, v_pack);

  insert into production_run_output (run_id, box_id, quality, boxes, design_id)
  values (p_run_id, p_box_id, v_q, p_boxes, v_design);

  if lower(v_q) = 'premium' then
    v_left := p_boxes;

    for r in
      select l.id, least(l.quantity - l.produced_qty, d.planned_boxes) as owed
        from production_run_demand d
        join book_order_lines l on l.id = d.book_order_line_id
        join book_orders o on o.id = l.order_id
       where d.run_id = p_run_id and l.box_id = p_box_id
         and o.status in ('open','in_production') and l.quantity > l.produced_qty
       order by l.is_urgent desc, o.created_at
    loop
      exit when v_left <= 0;
      v_take := least(v_left, r.owed);
      if v_take > 0 then
        update book_order_lines set produced_qty = produced_qty + v_take where id = r.id;
        v_left := v_left - v_take;
        v_run_alloc := v_run_alloc + v_take;
      end if;
    end loop;

    for r in
      select l.id, l.quantity - l.produced_qty as owed
        from book_order_lines l
        join book_orders o on o.id = l.order_id
       where l.box_id = p_box_id and o.stockist_id = v_stk
         and o.status in ('open','in_production') and l.quantity > l.produced_qty
         and not exists (select 1 from production_run_demand d
                          where d.run_id = p_run_id and d.book_order_line_id = l.id)
       order by l.is_urgent desc, o.created_at
    loop
      exit when v_left <= 0;
      v_take := least(v_left, r.owed);
      update book_order_lines set produced_qty = produced_qty + v_take where id = r.id;
      v_left := v_left - v_take;
      v_other_alloc := v_other_alloc + v_take;
    end loop;

    with done as (
      update book_orders o set status = 'closed', closed_at = now(), updated_at = now()
       where o.stockist_id = v_stk and o.status in ('open','in_production')
         and exists (select 1 from book_order_lines l where l.order_id = o.id)
         and not exists (select 1 from book_order_lines l
                          where l.order_id = o.id and l.produced_qty < l.quantity)
      returning 1)
    select count(*) into v_closed from done;
  end if;

  return jsonb_build_object(
    'design_id', v_design, 'boxes', p_boxes, 'quality', v_q,
    'to_this_run', v_run_alloc, 'to_other_orders', v_other_alloc,
    'to_free_stock', p_boxes - v_run_alloc - v_other_alloc,
    'orders_closed', v_closed);
end $function$;

create or replace function public.my_production_runs()
 returns jsonb language sql stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(row order by row->>'created_at' desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', r.id, 'name', r.name, 'status', r.status, 'note', coalesce(r.note,''),
      'created_at', r.created_at, 'closed_at', r.closed_at,
      'target_boxes', (select coalesce(sum(b.target_boxes),0)
                         from production_run_boxes b where b.run_id = r.id),
      'made_boxes', (select coalesce(sum(o.boxes),0)
                       from production_run_output o where o.run_id = r.id),
      'customers', coalesce((select jsonb_agg(distinct coalesce(c.name,
                                nullif(btrim(coalesce(bo.customer_hint,'')),''),'Walk-in'))
                       from production_run_demand d
                       join book_order_lines bl on bl.id = d.book_order_line_id
                       join book_orders bo on bo.id = bl.order_id
                       left join stockist_customers c on c.id = bo.customer_id
                      where d.run_id = r.id), '[]'::jsonb),
      'boxes', coalesce((select jsonb_agg(jsonb_build_object(
                    'box_id', b.box_id,
                    'cover_word', coalesce(nullif(btrim(coalesce(bn.brand_design_name,'')),''), pm.print_name),
                    'brand', br.name, 'surface', lib.surface_type, 'size', pm.size,
                    'pieces', pk.pieces, 'target', b.target_boxes,
                    'made', (select coalesce(sum(o.boxes),0) from production_run_output o
                              where o.run_id = r.id and o.box_id = b.box_id))
                    order by pm.print_name)
                  from production_run_boxes b
                  join boxes bx on bx.id = b.box_id
                  join packings pk on pk.id = bx.packing_id
                  join stockist_library lib on lib.id = pk.library_id
                  join print_master pm on pm.id = lib.print_id
                  join brands br on br.id = bx.brand_id
                  left join stockist_library_brand_names bn
                         on bn.library_id = lib.id and bn.brand_id = bx.brand_id
                 where b.run_id = r.id), '[]'::jsonb)
    ) as row
    from production_runs r
    where r.stockist_id in (select id from stockists where user_id = auth.uid())
  ) t;
$function$;

-- 📜 WHICH DESIGN WENT INTO PRODUCTION FOR WHICH BUYER, AND WHEN
create or replace function public.my_production_history()
 returns jsonb language sql stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(row order by row->>'taken_at' desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'run_id', r.id, 'run_name', r.name, 'run_status', r.status,
      'taken_at', d.created_at,
      'customer', coalesce(c.name, nullif(btrim(coalesce(o.customer_hint,'')),''), 'Walk-in'),
      'customer_id', o.customer_id,
      'order_token', o.token, 'order_note', coalesce(o.customer_hint,''),
      'design_name', coalesce(nullif(btrim(coalesce(bn.brand_design_name,'')),''), pm.print_name),
      'print_name', pm.print_name, 'size', pm.size,
      'surface', lib.surface_type, 'tile_type', coalesce(lib.tile_type,''),
      'brand', br.name, 'library_id', lib.id, 'box_id', bl.box_id,
      'planned_boxes', d.planned_boxes,
      'ordered_boxes', bl.quantity,
      'produced_boxes', bl.produced_qty,
      'urgent', bl.is_urgent
    ) as row
    from production_run_demand d
    join production_runs r on r.id = d.run_id
    join book_order_lines bl on bl.id = d.book_order_line_id
    join book_orders o on o.id = bl.order_id
    left join stockist_customers c on c.id = o.customer_id
    join boxes bx on bx.id = bl.box_id
    join packings pk on pk.id = bx.packing_id
    join stockist_library lib on lib.id = pk.library_id
    join print_master pm on pm.id = lib.print_id
    join brands br on br.id = bx.brand_id
    left join stockist_library_brand_names bn
           on bn.library_id = lib.id and bn.brand_id = bx.brand_id
    where r.stockist_id in (select id from stockists where user_id = auth.uid())
  ) t;
$function$;

revoke all on function public.my_production_demand() from public, anon;
revoke all on function public.production_take_into_run(text, jsonb, jsonb, text) from public, anon;
revoke all on function public.production_declare_output(uuid, uuid, integer, text) from public, anon;
revoke all on function public.my_production_runs() from public, anon;
revoke all on function public.my_production_history() from public, anon;
grant execute on function public.my_production_demand() to authenticated;
grant execute on function public.production_take_into_run(text, jsonb, jsonb, text) to authenticated;
grant execute on function public.production_declare_output(uuid, uuid, integer, text) to authenticated;
grant execute on function public.my_production_runs() to authenticated;
grant execute on function public.my_production_history() to authenticated;
