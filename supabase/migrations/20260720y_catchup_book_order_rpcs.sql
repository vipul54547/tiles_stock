-- 20260720y — CATCH-UP part 2: the BOOK ORDER read/write RPCs (was `20260720o`, `p`, `v`).
-- See `20260720x` for why these files did not exist.

drop function if exists public.create_book_order(text, uuid, jsonb, uuid);

-- 📕 Book an order for tiles that have NOT been made.
-- p_lines = [{library_id, brand_id, quantity, is_urgent?, packing_id?}]
-- 🔑 The brand is PER LINE — a BOX is (packing, brand) and a line points at one.
-- 🚫 RESOLVE ONLY: booking may not invent a cover (20260720e).
-- 🚫 NO QUALITY: planning is premium; standard is a by-product of the run.
create or replace function public.create_book_order(
  p_hint text, p_lines jsonb, p_customer_id uuid default null)
 returns jsonb
 language plpgsql security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_stk uuid; v_id uuid; v_token text; v_cust uuid;
  ln jsonb; v_lib uuid; v_brand uuid; v_pk uuid; v_box uuid; v_qty int;
  v_brand_name text; v_design text; v_lines int := 0; v_first_brand uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can book an order'; end if;
  if not coalesce((select book_orders_enabled from stockists where id = v_stk), false) then
    raise exception 'Book Order is not switched on for you. Ask the admin to enable it.';
  end if;

  if p_customer_id is not null then
    select id into v_cust from stockist_customers where id = p_customer_id and stockist_id = v_stk;
    if v_cust is null then raise exception 'That customer is not yours'; end if;
  end if;
  if coalesce(jsonb_array_length(p_lines), 0) = 0 then
    raise exception 'Add at least one design to the order.';
  end if;

  insert into book_orders (stockist_id, customer_id, customer_hint)
  values (v_stk, v_cust, nullif(btrim(coalesce(p_hint,'')),''))
  returning id, token into v_id, v_token;

  for ln in select * from jsonb_array_elements(p_lines) loop
    v_lib   := nullif(ln->>'library_id','')::uuid;
    v_brand := nullif(ln->>'brand_id','')::uuid;
    v_pk    := nullif(ln->>'packing_id','')::uuid;
    v_qty   := greatest(coalesce((ln->>'quantity')::int, 0), 0);
    if v_qty <= 0 then continue; end if;

    if not exists (select 1 from stockist_library where id = v_lib and stockist_id = v_stk) then
      raise exception 'That design is not yours';
    end if;
    select name into v_brand_name from brands where id = v_brand and stockist_id = v_stk;
    if v_brand_name is null then
      raise exception 'Every line needs one of your brands — a box is its cover.';
    end if;

    v_box := _box_resolve(v_lib, v_brand, v_pk);
    if v_box is null then
      select pm.print_name into v_design
        from stockist_library l join print_master pm on pm.id = l.print_id where l.id = v_lib;
      raise exception
        '% has no cover for "%" — open the design in your Design Library and tick % on it first.',
        v_brand_name, coalesce(v_design,'this design'), v_brand_name;
    end if;

    insert into book_order_lines (order_id, box_id, quantity, is_urgent)
    values (v_id, v_box, v_qty, coalesce((ln->>'is_urgent')::boolean, false))
    on conflict (order_id, box_id) do update
      set quantity = excluded.quantity, is_urgent = excluded.is_urgent;
    v_lines := v_lines + 1;
    v_first_brand := coalesce(v_first_brand, v_brand);
  end loop;

  if v_lines = 0 then raise exception 'Every line had a quantity of 0.'; end if;

  -- 🏷️ remember the cover this customer takes — only into a blank
  if v_cust is not null and v_first_brand is not null then
    update stockist_customers set default_brand_id = v_first_brand, updated_at = now()
     where id = v_cust and default_brand_id is null;
  end if;

  return jsonb_build_object('id', v_id, 'token', v_token, 'lines', v_lines);
end $function$;

create or replace function public.my_book_orders()
 returns jsonb language sql stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(row order by row->>'created_at' desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', o.id, 'token', o.token, 'status', o.status,
      'parent_id', o.parent_id, 'slice', coalesce(o.slice,''),
      'parent_token', (select p.token from book_orders p where p.id = o.parent_id),
      'customer_hint', coalesce(o.customer_hint,''),
      'customer_id', o.customer_id, 'customer_name', coalesce(c.name,''),
      'created_at', o.created_at, 'updated_at', o.updated_at, 'closed_at', o.closed_at,
      'line_count', (select count(*) from book_order_lines l where l.order_id = o.id),
      'ordered_boxes', (select coalesce(sum(l.quantity),0) from book_order_lines l where l.order_id=o.id),
      'produced_boxes', (select coalesce(sum(l.produced_qty),0) from book_order_lines l where l.order_id=o.id),
      'remaining_boxes', (select coalesce(sum(greatest(l.quantity - l.produced_qty,0)),0)
                            from book_order_lines l where l.order_id=o.id),
      'urgent', (select coalesce(bool_or(l.is_urgent),false) from book_order_lines l where l.order_id=o.id),
      'slices', coalesce((select jsonb_agg(jsonb_build_object(
                     'id', s.id, 'token', s.token, 'status', s.status,
                     'boxes', (select coalesce(sum(l2.quantity),0) from book_order_lines l2 where l2.order_id=s.id))
                     order by s.slice)
                   from book_orders s where s.parent_id = o.id), '[]'::jsonb),
      'brands', coalesce((select jsonb_agg(distinct b.name)
                            from book_order_lines l join boxes bx on bx.id=l.box_id
                            join brands b on b.id=bx.brand_id where l.order_id=o.id), '[]'::jsonb)
    ) as row
    from book_orders o
    left join stockist_customers c on c.id = o.customer_id
    where o.stockist_id in (select id from stockists where user_id = auth.uid())
  ) t;
$function$;

create or replace function public.book_order_detail(p_id uuid)
 returns jsonb language plpgsql stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_stk uuid; v_lines jsonb;
begin
  select stockist_id into v_stk from book_orders where id = p_id;
  if v_stk is null then raise exception 'Order not found'; end if;
  if v_stk not in (select id from stockists where user_id = auth.uid()) then
    raise exception 'Not allowed';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', l.id, 'box_id', l.box_id, 'library_id', lib.id,
    'design_name', coalesce(nullif(btrim(coalesce(bn.brand_design_name,'')),''), pm.print_name),
    'print_name', pm.print_name, 'size', pm.size,
    'image', nullif(btrim(coalesce(pm.image_url,'')),''),
    'surface', lib.surface_type, 'tile_type', lib.tile_type,
    'brand', b.name, 'brand_id', b.id, 'pieces', pk.pieces,
    'quantity', l.quantity, 'produced_qty', l.produced_qty,
    'remaining', greatest(l.quantity - l.produced_qty, 0),
    'is_urgent', l.is_urgent)
    order by l.is_urgent desc, pm.print_name), '[]'::jsonb)
  into v_lines
  from book_order_lines l
  join boxes bx on bx.id = l.box_id
  join packings pk on pk.id = bx.packing_id
  join stockist_library lib on lib.id = pk.library_id
  join print_master pm on pm.id = lib.print_id
  join brands b on b.id = bx.brand_id
  left join stockist_library_brand_names bn on bn.library_id = lib.id and bn.brand_id = bx.brand_id
  where l.order_id = p_id;

  return (select jsonb_build_object(
    'id', o.id, 'token', o.token, 'status', o.status,
    'parent_id', o.parent_id, 'slice', coalesce(o.slice,''),
    'customer_hint', coalesce(o.customer_hint,''),
    'customer_id', o.customer_id, 'customer_name', coalesce(c.name,''),
    'created_at', o.created_at, 'closed_at', o.closed_at, 'lines', v_lines)
    from book_orders o left join stockist_customers c on c.id = o.customer_id
    where o.id = p_id);
end $function$;

-- ⭐ his mark, flippable at booking or long after
create or replace function public.book_line_set_urgent(p_line_id uuid, p_urgent boolean)
 returns void language plpgsql security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_stk uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  update book_order_lines l set is_urgent = coalesce(p_urgent,false)
    from book_orders o
   where l.id = p_line_id and o.id = l.order_id and o.stockist_id = v_stk;
end $function$;

create or replace function public.book_order_set_status(p_id uuid, p_status text)
 returns void language plpgsql security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_stk uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if p_status not in ('open','in_production','closed','cancelled') then
    raise exception 'A booked order is open, in production, closed or cancelled.';
  end if;
  update book_orders set status = p_status, updated_at = now(),
         closed_at = case when p_status in ('open','in_production') then null else now() end
   where id = p_id and stockist_id = v_stk;
end $function$;

-- 🗑️ refused once anything has been produced against it — that is history
create or replace function public.book_order_delete(p_id uuid)
 returns void language plpgsql security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_stk uuid; v_made int;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  select coalesce(sum(produced_qty),0) into v_made
    from book_order_lines l join book_orders o on o.id = l.order_id
   where o.id = p_id and o.stockist_id = v_stk;
  if v_made > 0 then
    raise exception
      'This order cannot be deleted — % box(es) have already been produced against it. Cancel it instead.',
      v_made;
  end if;
  delete from book_orders where id = p_id and stockist_id = v_stk;
end $function$;

revoke all on function public.create_book_order(text, jsonb, uuid) from public, anon;
revoke all on function public.my_book_orders() from public, anon;
revoke all on function public.book_order_detail(uuid) from public, anon;
revoke all on function public.book_line_set_urgent(uuid, boolean) from public, anon;
revoke all on function public.book_order_set_status(uuid, text) from public, anon;
revoke all on function public.book_order_delete(uuid) from public, anon;
grant execute on function public.create_book_order(text, jsonb, uuid) to authenticated;
grant execute on function public.my_book_orders() to authenticated;
grant execute on function public.book_order_detail(uuid) to authenticated;
grant execute on function public.book_line_set_urgent(uuid, boolean) to authenticated;
grant execute on function public.book_order_set_status(uuid, text) to authenticated;
grant execute on function public.book_order_delete(uuid) to authenticated;
