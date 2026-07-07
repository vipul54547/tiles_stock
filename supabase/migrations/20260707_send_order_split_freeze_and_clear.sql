-- The My Choice ↔ order split. A DRAFT order = the buyer's live basket
-- (my_choices). On Send it is FROZEN into inquiry_items, marked 'sent', and its
-- basket rows are cleared — so sent+ orders live in My Orders (from inquiry_items)
-- and My Choice only ever holds un-sent drafts.

-- 1) Trigger: only drafts are basket-coupled (create/update/cleanup a DRAFT).
create or replace function public.trg_my_choices_sync_inquiry()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
declare v_design uuid; v_eu uuid; v_stockist uuid; v_inq uuid; v_remaining int;
begin
  if (tg_op = 'DELETE') then v_design := old.design_id; v_eu := old.end_user_id;
  else v_design := new.design_id; v_eu := new.end_user_id; end if;
  select stockist_id into v_stockist from designs where id = v_design;
  if v_stockist is null then return coalesce(new, old); end if;

  select id into v_inq from inquiries
   where end_user_id = v_eu and stockist_id = v_stockist and status = 'draft'
   limit 1;

  if (tg_op in ('INSERT','UPDATE')) then
    if v_inq is null then
      insert into inquiries(end_user_id, stockist_id, status) values (v_eu, v_stockist, 'draft');
    else
      update inquiries set updated_at = now() where id = v_inq;
    end if;
  elsif (tg_op = 'DELETE') then
    if v_inq is not null then
      select count(*) into v_remaining
        from my_choices mc join designs d on d.id = mc.design_id
       where mc.end_user_id = v_eu and d.stockist_id = v_stockist;
      if v_remaining = 0 then delete from inquiries where id = v_inq;
      else update inquiries set updated_at = now() where id = v_inq; end if;
    end if;
  end if;
  return coalesce(new, old);
end; $function$;

-- 2) Send: freeze basket → order, mark sent (notifies stockist), clear basket.
create or replace function public.send_order_to_stockist(p_stockist_key text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
declare v_eu uuid; v_st uuid; v_inq uuid; v_token text;
begin
  select id into v_eu from end_users where user_id = auth.uid();
  if v_eu is null then raise exception 'Not a buyer'; end if;
  select id into v_st from stockists
   where sequential_id = p_stockist_key or public_code = p_stockist_key;
  if v_st is null then raise exception 'Supplier not found'; end if;

  select id, token into v_inq, v_token from inquiries
   where end_user_id = v_eu and stockist_id = v_st and status = 'draft' limit 1;
  if v_inq is null then
    if exists (select 1 from my_choices mc join designs d on d.id = mc.design_id
               where mc.end_user_id = v_eu and d.stockist_id = v_st) then
      insert into inquiries(end_user_id, stockist_id, status)
        values (v_eu, v_st, 'draft') returning id, token into v_inq, v_token;
    else
      raise exception 'Nothing to send for this supplier';
    end if;
  end if;

  insert into inquiry_items (inquiry_id, design_id, quantity)
  select v_inq, mc.design_id, mc.quantity
  from my_choices mc join designs d on d.id = mc.design_id
  where mc.end_user_id = v_eu and d.stockist_id = v_st
  on conflict (inquiry_id, design_id) do update set quantity = excluded.quantity;

  perform public.mark_inquiry_sent(v_inq);

  delete from my_choices mc using designs d
  where mc.design_id = d.id and mc.end_user_id = v_eu and d.stockist_id = v_st;

  return jsonb_build_object('id', v_inq, 'token', v_token);
end; $function$;
revoke execute on function public.send_order_to_stockist(text) from public;
grant  execute on function public.send_order_to_stockist(text) to authenticated;

-- 3) my_orders (authoritative): only a draft reads from the basket; sent+ frozen.
create or replace function public.my_orders()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
  select coalesce(jsonb_agg(row order by row->>'updated_at' desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', i.id, 'token', i.token, 'status', i.status,
      'created_at', i.created_at, 'updated_at', i.updated_at,
      'confirmed_at', i.confirmed_at, 'locked_at', i.locked_at,
      'guarantee_until', i.guarantee_until, 'accepted_at', i.accepted_at,
      'guarantee_days', i.guarantee_days,
      'stockist_id', i.stockist_id,
      'stockist_key',  case when s.is_anonymous then s.public_code         else s.sequential_id end,
      'stockist_name', case when s.is_anonymous then s.public_display_name else s.name          end,
      'line_count', case when i.status = 'draft'
        then (select count(*) from my_choices mc join designs d on d.id=mc.design_id
               where mc.end_user_id=i.end_user_id and d.stockist_id=i.stockist_id)
        else (select count(*) from inquiry_items it where it.inquiry_id=i.id) end,
      'total_boxes', case when i.status = 'draft'
        then (select coalesce(sum(mc.quantity),0) from my_choices mc join designs d on d.id=mc.design_id
               where mc.end_user_id=i.end_user_id and d.stockist_id=i.stockist_id)
        else (select coalesce(sum(it.quantity),0) from inquiry_items it where it.inquiry_id=i.id) end,
      'dispatched_boxes', case when i.status = 'draft' then 0
        else (select coalesce(sum(it.dispatched_qty),0) from inquiry_items it where it.inquiry_id=i.id) end,
      'remaining_boxes', case when i.status = 'draft'
        then (select coalesce(sum(mc.quantity),0) from my_choices mc join designs d on d.id=mc.design_id
               where mc.end_user_id=i.end_user_id and d.stockist_id=i.stockist_id)
        else (select coalesce(sum(greatest(it.quantity - it.dispatched_qty,0)),0) from inquiry_items it where it.inquiry_id=i.id) end
    ) as row
    from inquiries i join stockists s on s.id = i.stockist_id
    where i.end_user_id in (select id from end_users where user_id = auth.uid())
  ) t;
$function$;

-- 4) inquiry_detail: only a draft reads lines from the basket; sent+ from items.
create or replace function public.inquiry_detail(p_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
declare v_eu uuid; v_st uuid; v_status text; v_lines jsonb;
begin
  select end_user_id, stockist_id, status into v_eu, v_st, v_status
  from inquiries where id = p_id;
  if v_st is null then raise exception 'Order not found'; end if;
  if not (
    v_eu in (select id from end_users where user_id = auth.uid())
    or v_st in (select id from stockists where user_id = auth.uid())
    or current_user_role() = 'admin') then
    raise exception 'Not allowed';
  end if;

  if v_eu is not null and v_status = 'draft' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'design_id', d.id, 'design_name', d.name, 'size', d.size,
      'surface', d.surface_type, 'quality', d.quality,
      'image', nullif(btrim(coalesce(lib.image_url,'')),''),
      'quantity', mc.quantity, 'dispatched_qty', 0, 'available', d.box_quantity,
      'held', held_of(d.id), 'line_held', 0)
      order by d.name), '[]'::jsonb)
    into v_lines
    from my_choices mc join designs d on d.id = mc.design_id
    left join stockist_library lib on lib.id = d.library_id
    where mc.end_user_id = v_eu and d.stockist_id = v_st;
  else
    select coalesce(jsonb_agg(jsonb_build_object(
      'design_id', d.id, 'design_name', d.name, 'size', d.size,
      'surface', d.surface_type, 'quality', d.quality,
      'image', nullif(btrim(coalesce(lib.image_url,'')),''),
      'quantity', it.quantity, 'dispatched_qty', it.dispatched_qty, 'available', d.box_quantity,
      'held', held_of(d.id), 'line_held', it.held_qty)
      order by d.name), '[]'::jsonb)
    into v_lines
    from inquiry_items it join designs d on d.id = it.design_id
    left join stockist_library lib on lib.id = d.library_id
    where it.inquiry_id = p_id;
  end if;

  return (select jsonb_build_object(
    'id', i.id, 'token', i.token, 'status', i.status,
    'connection_code', i.connection_code, 'customer_hint', i.customer_hint,
    'source', i.source,
    'created_at', i.created_at, 'updated_at', i.updated_at,
    'confirmed_at', i.confirmed_at, 'locked_at', i.locked_at,
    'guarantee_until', i.guarantee_until, 'accepted_at', i.accepted_at,
    'guarantee_days', i.guarantee_days,
    'lines', v_lines)
    from inquiries i where i.id = p_id);
end;
$function$;
