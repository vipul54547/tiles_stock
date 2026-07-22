-- 20260722f — 🔖 MADE flow M4 (server): Order from stock = a HELD "Ready order".
--
-- Sending a booked order's ready material reserves it from F_Stock (godown + made, F = P − C − H)
-- into a HELD inquiry for the customer — the existing hold+dispatch machinery. Ready = current
-- F_Stock, ceiling = the ticked qty (book_order_lines.quantity); Standard never held; partial ok.
-- (docs/PRODUCTION_REDESIGN_PLAN.md §Phase 3–D · order_from_stock artifact)

alter table public.book_order_lines
  add column if not exists sent_qty integer not null default 0;         -- premium moved to a Ready order
alter table public.inquiries
  add column if not exists book_order_id uuid references public.book_orders(id) on delete set null;

-- ── the run's booked orders, by order, for the Position "by order" section ───────────────────────
-- Per line: ticked (order qty) · made (produced) · sent · F_Stock (godown + made) · ready.
create or replace function public.production_position_orders(p_run_id uuid)
 returns jsonb language sql stable security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(row order by row->>'token'), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'order_id', bo.id, 'token', bo.token,
      'customer', coalesce(c.name, nullif(btrim(coalesce(bo.customer_hint,'')),''), 'Walk-in'),
      'lines', jsonb_agg(jsonb_build_object(
          'line_id', bl.id, 'design_id', dh.id, 'design', pm.print_name,
          'cover_word', coalesce(nullif(btrim(coalesce(bn.brand_design_name,'')),''), pm.print_name),
          'brand', br.name, 'surface', libx.surface_type, 'size', pm.size,
          'ticked', bl.quantity, 'make', d.planned_boxes,
          'made', bl.produced_qty, 'sent', bl.sent_qty,
          'f_stock', coalesce(greatest(dh.box_quantity - dh.control_quantity - held_of(dh.id), 0), 0),
          'ready', greatest(least(bl.quantity - bl.sent_qty,
                     coalesce(greatest(dh.box_quantity - dh.control_quantity - held_of(dh.id), 0), 0)), 0)
        ) order by pm.print_name)
    ) as row
    from production_run_demand d
    join book_order_lines bl on bl.id = d.book_order_line_id
    join book_orders bo on bo.id = bl.order_id
    join boxes bx on bx.id = bl.box_id
    join packings pk on pk.id = bx.packing_id
    join stockist_library libx on libx.id = pk.library_id
    join print_master pm on pm.id = libx.print_id
    join brands br on br.id = bx.brand_id
    left join stockist_library_brand_names bn on bn.library_id = libx.id and bn.brand_id = bx.brand_id
    left join stockist_customers c on c.id = bo.customer_id
    left join designs dh on dh.box_id = bl.box_id and dh.quality = 'Premium'
                        and dh.stockist_id = bo.stockist_id
    where d.run_id = p_run_id
      and bo.stockist_id = (select id from stockists where user_id = auth.uid())
    group by bo.id, bo.token, c.name, bo.customer_hint
  ) t;
$function$;

-- ── send ready material → held Ready order ───────────────────────────────────────────────────────
-- p_lines: `[{line_id, boxes}]`. Each take = least(boxes, ticked − sent, F_Stock). Creates/append a
-- HELD inquiry (book_order_id link) for the order; bumps sent_qty; closes the order when fully sent.
create or replace function public.book_order_send_to_stock(p_lines jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_st uuid; ln jsonb; v_line uuid; v_want int;
  v_box uuid; v_qty int; v_sent int; v_order uuid; v_cust uuid; v_hint text;
  v_design uuid; v_bq int; v_cq int; v_fstock int; v_take int;
  v_inq uuid; v_token text; v_total int := 0; v_orders uuid[] := array[]::uuid[];
begin
  select id into v_st from stockists where user_id = auth.uid();
  if v_st is null then raise exception 'Only stockists'; end if;

  for ln in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    v_line := (ln->>'line_id')::uuid;
    v_want := greatest(coalesce((ln->>'boxes')::int, 0), 0);
    if v_want <= 0 then continue; end if;

    select bl.box_id, bl.quantity, bl.sent_qty, bo.id, bo.customer_id, bo.customer_hint
      into v_box, v_qty, v_sent, v_order, v_cust, v_hint
      from book_order_lines bl join book_orders bo on bo.id = bl.order_id
     where bl.id = v_line and bo.stockist_id = v_st;
    if v_box is null then raise exception 'That order line is not yours'; end if;

    -- the Premium holding for this box (godown + made live in the same holding)
    select id, box_quantity, control_quantity into v_design, v_bq, v_cq
      from designs where box_id = v_box and quality = 'Premium' and stockist_id = v_st;
    if v_design is null then continue; end if;              -- nothing to reserve yet

    v_fstock := greatest(v_bq - v_cq - held_of(v_design), 0);
    v_take := least(v_want, greatest(v_qty - v_sent, 0), v_fstock);   -- ceiling = ticked; cap = F_Stock
    if v_take <= 0 then continue; end if;

    -- one held Ready order per booked order; append on later sends
    select id, token into v_inq, v_token from inquiries
     where book_order_id = v_order and stockist_id = v_st and status in ('locked','dispatching')
     limit 1;
    if v_inq is null then
      insert into inquiries (stockist_id, end_user_id, source, status, customer_hint,
                             customer_id, book_order_id, locked_at)
      values (v_st, null, 'stockist', 'locked', nullif(btrim(coalesce(v_hint,'')),''),
              v_cust, v_order, now())
      returning id, token into v_inq, v_token;
    end if;

    insert into inquiry_items (inquiry_id, design_id, quantity, held_qty, dispatched_qty)
    values (v_inq, v_design, v_take, v_take, 0)
    on conflict (inquiry_id, design_id) do update
      set quantity = inquiry_items.quantity + v_take,
          held_qty = inquiry_items.held_qty + v_take;

    update book_order_lines set sent_qty = sent_qty + v_take where id = v_line;
    v_total := v_total + v_take;
    v_orders := array_append(v_orders, v_order);
  end loop;

  -- close any booked order now fully sent
  update book_orders o set status = 'closed', closed_at = now(), updated_at = now()
   where o.id = any(v_orders) and o.status = 'open'
     and not exists (select 1 from book_order_lines l
                      where l.order_id = o.id and l.sent_qty < l.quantity);

  return jsonb_build_object('sent', v_total, 'inquiry_id', v_inq, 'token', v_token);
end $function$;

-- ── customer_delete: also refuse when a BOOKED order exists (20 Jul hole) ─────────────────────────
create or replace function public.customer_delete(p_id uuid)
 returns void language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_stk uuid; v_orders int; v_dispatches int; v_books int; v_name text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  select name into v_name from stockist_customers where id = p_id and stockist_id = v_stk;
  if v_name is null then raise exception 'That customer is not yours'; end if;

  select count(*) into v_orders     from inquiries      where customer_id = p_id;
  select count(*) into v_dispatches from dispatch_notes where customer_id = p_id;
  select count(*) into v_books      from book_orders    where customer_id = p_id;

  if v_orders > 0 or v_dispatches > 0 or v_books > 0 then
    raise exception
      '% cannot be removed — % order(s), % dispatch(es) and % booked order(s) are recorded '
      'against them. That history is the point of saving a customer.',
      v_name, v_orders, v_dispatches, v_books;
  end if;

  delete from stockist_customers where id = p_id;
end $function$;

revoke all on function public.production_position_orders(uuid) from public, anon;
revoke all on function public.book_order_send_to_stock(jsonb) from public, anon;
grant execute on function public.production_position_orders(uuid) to authenticated;
grant execute on function public.book_order_send_to_stock(jsonb) to authenticated;
