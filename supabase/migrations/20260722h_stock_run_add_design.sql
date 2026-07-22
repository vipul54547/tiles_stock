-- 20260722h — 🏭 Add design → STOCK production: a run may carry boxes with NO order behind them.
--
-- "Add design" on Plan lets the stockist run a design for stock (or the remaining), chosen manually
-- by what surface/tile/punch is on the line. Such a box has a target but no booked demand. Today the
-- take RPC refuses a demand-less run; relax it so boxes without demand become STOCK production (their
-- Made output lands in free stock, since production_made bumps only the run's ticked lines).
-- The order-driven path is unchanged when demand IS present. (docs/PRODUCTION_REDESIGN_PLAN.md — loop)
--
-- Also my_addable_boxes(): every cover the stockist can run, shaped like a demand row (0 ordered,
-- empty lines) so the Plan can drop one straight in.

create or replace function public.production_take_into_run(p_name text, p_boxes jsonb, p_demand jsonb, p_note text DEFAULT NULL::text)
 returns jsonb
 language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_stk uuid; v_run uuid; v_run_name text; e jsonb;
  v_box uuid; v_qty int; v_line uuid; v_left int;
  v_boxes int := 0; v_lines int := 0; v_orders int; v_slices int := 0;
  r record; tk record; v_slice uuid; v_letter text; v_target uuid;
  v_full boolean; v_urg boolean; v_has_demand boolean;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if not coalesce((select book_orders_enabled from stockists where id = v_stk), false) then
    raise exception 'Book Order is not switched on for you.';
  end if;
  if coalesce(jsonb_array_length(p_boxes), 0) = 0 then
    raise exception 'Nothing to run — set a quantity on at least one design.';
  end if;
  v_has_demand := coalesce(jsonb_array_length(p_demand), 0) > 0;

  create temp table _tick(line_id uuid primary key, order_id uuid, box_id uuid,
                          qty int, is_urgent boolean) on commit drop;
  if v_has_demand then
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
  -- A run must produce SOMETHING: an order line, or a stock box.
  if v_lines = 0 and v_boxes = 0 then
    raise exception 'Nothing was taken into the run.';
  end if;

  select count(distinct o.id) into v_orders
    from production_run_demand d
    join book_order_lines l on l.id = d.book_order_line_id
    join book_orders o on o.id = l.order_id
   where d.run_id = v_run;

  return jsonb_build_object('id', v_run, 'name', v_run_name,
    'boxes', v_boxes, 'lines', v_lines, 'orders', coalesce(v_orders, 0), 'slices', v_slices);
end $function$;

-- Every cover the stockist can run, demand-row-shaped (0 ordered, empty lines) for Plan's Add design.
create or replace function public.my_addable_boxes()
 returns jsonb language sql stable security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
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
      'ordered_boxes', 0, 'produced_boxes', 0, 'remaining_boxes', 0,
      'remaining_pieces', 0, 'remaining_sqft', 0,
      'urgent', false, 'oldest_order_at', null,
      'p_stock', coalesce((select sum(d.box_quantity) from designs d where d.box_id = bx.id), 0),
      'f_stock', coalesce((select sum(greatest(d.box_quantity - d.control_quantity - held_of(d.id), 0))
                             from designs d where d.box_id = bx.id), 0),
      'lines', '[]'::jsonb
    ) order by pm.print_name, b.name), '[]'::jsonb)
  from boxes bx
  join packings pk on pk.id = bx.packing_id
  join stockist_library lib on lib.id = pk.library_id
  join print_master pm on pm.id = lib.print_id
  join brands b on b.id = bx.brand_id
  left join stockist_library_brand_names bn on bn.library_id = lib.id and bn.brand_id = bx.brand_id
  where lib.stockist_id = (select id from stockists where user_id = auth.uid());
$function$;

revoke all on function public.my_addable_boxes() from public, anon;
grant execute on function public.my_addable_boxes() to authenticated;
