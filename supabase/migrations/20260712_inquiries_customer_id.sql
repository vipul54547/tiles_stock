-- Customer history, Phase A — close the write gap.
--
-- Walk-in dispatch already stamps dispatch_notes.customer_id. The ORDER path does not:
-- dispatch_inquiry omitted customer_id from its note insert, and inquiries had no customer_id
-- at all. So an order dispatched to a saved customer forgot whom it went to, and the Customer
-- field on the attached-order dispatch branch was hidden because it had nowhere to write.
--
-- This migration gives the ORDER a durable home for the link, and makes the dispatch note
-- inherit it. Nothing here touches stock. (docs/CUSTOMER_HISTORY_PLAN.md)

-- 1. The order can now point at a saved customer (optional; app-buyer orders leave it null).
alter table inquiries
  add column if not exists customer_id uuid references stockist_customers(id);

-- 2. create_stockist_order accepts which customer the order is for. Optional + validated:
--    the customer must be one of the caller's own. Default null keeps every existing caller
--    working unchanged.
create or replace function public.create_stockist_order(
  p_hint text,
  p_lines jsonb,
  p_customer_id uuid default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_st uuid; v_id uuid; v_token text; v_code text; v_cust uuid;
  ln jsonb; v_design uuid; v_qty int;
begin
  select id into v_st from stockists where user_id = auth.uid();
  if v_st is null then raise exception 'Only stockists can create an order'; end if;

  -- Every line's design must belong to the caller.
  if exists (
    select 1 from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) e
    left join designs d on d.id = (e->>'design_id')::uuid
    where d.id is null or d.stockist_id <> v_st) then
    raise exception 'A design does not belong to you';
  end if;

  -- The customer, if given, must be one of the caller's own.
  if p_customer_id is not null then
    select id into v_cust from stockist_customers
    where id = p_customer_id and stockist_id = v_st;
    if v_cust is null then raise exception 'That customer is not yours'; end if;
  end if;

  insert into inquiries (stockist_id, end_user_id, source, status, customer_hint, customer_id)
  values (v_st, null, 'stockist', 'sent', nullif(btrim(coalesce(p_hint,'')),''), v_cust)
  returning id, token, connection_code into v_id, v_token, v_code;

  for ln in select * from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) loop
    v_design := (ln->>'design_id')::uuid;
    v_qty := greatest(coalesce((ln->>'quantity')::int, 0), 0);
    if v_qty > 0 then
      insert into inquiry_items (inquiry_id, design_id, quantity, dispatched_qty)
      values (v_id, v_design, v_qty, 0)
      on conflict (inquiry_id, design_id) do update set quantity = excluded.quantity;
    end if;
  end loop;

  return jsonb_build_object('id', v_id, 'token', v_token, 'connection_code', v_code);
end;
$function$;

-- 3. dispatch_inquiry copies the order's customer onto the dispatch note it writes.
--    Only the two marked lines change vs. the live definition: select i.customer_id, and add
--    customer_id to the dispatch_notes insert. Everything else is preserved verbatim.
create or replace function public.dispatch_inquiry(
  p_inquiry uuid, p_lines jsonb,
  p_invoice text default ''::text, p_vehicle text default ''::text,
  p_transporter text default ''::text, p_note text default ''::text,
  p_date date default current_date, p_reduce_stock boolean default true,
  p_close boolean default true, p_prune boolean default true)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_eu uuid; v_st uuid; v_status text; v_token text; v_company text; v_hint text;
  v_cust uuid;                          -- CHANGED: carry the order's customer
  v_buyer_label text;
  v_keep uuid[]; ln jsonb; v_design uuid; v_disp int;
  v_total int; v_note_id uuid; v_dispatch_no text;
  v_outstanding int; v_dispatched int; v_new_status text; v_buyer uuid;
  v_title text; v_msg text;
begin
  select i.end_user_id, i.stockist_id, i.status, i.token, e.company_name, i.customer_hint,
         i.customer_id                  -- CHANGED
  into v_eu, v_st, v_status, v_token, v_company, v_hint,
       v_cust                           -- CHANGED
  from inquiries i
  join stockists s on s.id = i.stockist_id
  left join end_users e on e.id = i.end_user_id
  where i.id = p_inquiry and s.user_id = auth.uid();
  if v_st is null then raise exception 'Not allowed'; end if;
  if v_status in ('completed','rejected') then
    raise exception 'This order is already closed';
  end if;
  v_buyer_label := coalesce(nullif(btrim(v_company), ''), nullif(btrim(v_hint), ''), 'Walk-in');

  insert into inquiry_items (inquiry_id, design_id, quantity)
  select p_inquiry, mc.design_id, mc.quantity
  from my_choices mc join designs d on d.id = mc.design_id
  where mc.end_user_id = v_eu and d.stockist_id = v_st
  on conflict (inquiry_id, design_id) do nothing;

  select array_agg((e->>'design_id')::uuid) into v_keep
  from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) e;
  v_keep := coalesce(v_keep, array[]::uuid[]);
  if exists (
    select 1 from unnest(v_keep) did
    left join designs d on d.id = did
    where d.id is null or d.stockist_id <> v_st) then
    raise exception 'A design does not belong to you';
  end if;

  -- p_prune=false: the caller sent only the truck's lines, not the whole order.
  if p_prune then
    delete from inquiry_items
    where inquiry_id = p_inquiry and not (design_id = any(v_keep));
  end if;

  select coalesce(sum(greatest((e->>'dispatch')::int,0)),0) into v_total
  from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) e;
  if v_total > 0 then
    insert into dispatch_notes (inquiry_id, stockist_id, end_user_id, customer_id,
      invoice_no, vehicle_no, transporter, note, dispatched_on)   -- CHANGED: customer_id
    values (p_inquiry, v_st, v_eu, v_cust,                        -- CHANGED: v_cust
      coalesce(p_invoice,''), coalesce(p_vehicle,''), coalesce(p_transporter,''),
      coalesce(p_note,''), coalesce(p_date, current_date))
    returning id, dispatch_no into v_note_id, v_dispatch_no;
  end if;

  for ln in select * from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) loop
    v_design := (ln->>'design_id')::uuid;
    v_disp   := coalesce((ln->>'dispatch')::int, 0);

    insert into inquiry_items (inquiry_id, design_id, quantity, dispatched_qty)
    values (p_inquiry, v_design, greatest(v_disp,0), 0)
    on conflict (inquiry_id, design_id) do nothing;

    if v_disp > 0 then
      insert into dispatches (design_id, stockist_id, quantity_dispatched, buyer_name, notes, dispatch_note_id)
      values (v_design, v_st, v_disp, v_buyer_label, 'Order ' || v_token, v_note_id);

      if p_reduce_stock then
        update designs
        set box_quantity = greatest(0, box_quantity - v_disp),
            status = case when greatest(0, box_quantity - v_disp) = 0
                          then 'out_of_stock' else 'active' end,
            updated_at = now()
        where id = v_design;
      end if;

      update inquiry_items set dispatched_qty = dispatched_qty + v_disp
      where inquiry_id = p_inquiry and design_id = v_design;
    end if;
  end loop;

  select coalesce(sum(greatest(quantity - dispatched_qty, 0)),0),
         coalesce(sum(dispatched_qty),0)
  into v_outstanding, v_dispatched
  from inquiry_items where inquiry_id = p_inquiry;

  if v_dispatched > 0 and (v_outstanding = 0 or p_close) then
    v_new_status := 'completed';
    update inquiry_items set held_qty = 0 where inquiry_id = p_inquiry;
    update inquiries set status='completed', completed_at=now(), updated_at=now() where id = p_inquiry;
  elsif v_dispatched > 0 then
    v_new_status := 'dispatching';
    update inquiries set status='dispatching', updated_at=now() where id = p_inquiry;
  else
    v_new_status := v_status;
    update inquiries set updated_at=now() where id = p_inquiry;
  end if;

  if v_total > 0 then
    select user_id into v_buyer from end_users where id = v_eu;
    if v_buyer is not null then
      if v_new_status = 'completed' and v_outstanding > 0 then
        v_title := 'Order closed';
        v_msg := v_token || ': ' || v_total || ' boxes dispatched, ' || v_outstanding ||
                 ' not included — re-order if you still need them.';
      elsif v_new_status = 'completed' then
        v_title := 'Order completed';
        v_msg := v_token || ': ' || v_total || ' boxes dispatched.';
      else
        v_title := 'Dispatch update';
        v_msg := v_token || ': ' || v_total || ' boxes dispatched, ' || v_outstanding ||
                 ' still reserved & coming.';
      end if;
      perform _notify(v_buyer, 'dispatch', v_title, v_msg,
        jsonb_build_object('token', v_token, 'dispatch_no', v_dispatch_no));
    end if;
  end if;

  return jsonb_build_object('status', v_new_status,
                            'outstanding', v_outstanding,
                            'dispatched', v_dispatched,
                            'dispatch_no', v_dispatch_no);
end;
$function$;
