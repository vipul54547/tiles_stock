-- Phase D — dispatch mode (reduce stock vs release holding only) + null-buyer
-- safety. (project_dispatch_order_redesign)
--
-- p_reduce_stock = true  → boxes leave: decrement designs.box_quantity (today's
--                          behaviour). H falls via dispatched_qty too.
-- p_reduce_stock = false → "Release Holding only": stockist manages stock in
--                          their own software, so we DON'T touch box_quantity;
--                          we still bump dispatched_qty (H falls + order
--                          advances), log the dispatch + note, and notify.
create or replace function public.dispatch_inquiry(
  p_inquiry uuid, p_lines jsonb,
  p_invoice text default '', p_vehicle text default '',
  p_transporter text default '', p_note text default '',
  p_date date default current_date,
  p_reduce_stock boolean default true)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_eu uuid; v_st uuid; v_status text; v_token text; v_company text; v_hint text;
  v_buyer_label text;
  v_keep uuid[]; ln jsonb; v_design uuid; v_disp int;
  v_total int; v_note_id uuid; v_dispatch_no text;
  v_outstanding int; v_dispatched int; v_new_status text; v_buyer uuid;
begin
  select i.end_user_id, i.stockist_id, i.status, i.token, e.company_name, i.customer_hint
  into v_eu, v_st, v_status, v_token, v_company, v_hint
  from inquiries i
  join stockists s on s.id = i.stockist_id
  left join end_users e on e.id = i.end_user_id
  where i.id = p_inquiry and s.user_id = auth.uid();
  if v_st is null then raise exception 'Not allowed'; end if;
  if v_status not in ('locked','dispatching') then
    raise exception 'Confirm the order before dispatching';
  end if;
  v_buyer_label := coalesce(nullif(btrim(v_company), ''), nullif(btrim(v_hint), ''), 'Walk-in');

  select array_agg((e->>'design_id')::uuid) into v_keep
  from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) e;
  v_keep := coalesce(v_keep, array[]::uuid[]);
  if exists (
    select 1 from unnest(v_keep) did
    left join designs d on d.id = did
    where d.id is null or d.stockist_id <> v_st) then
    raise exception 'A design does not belong to you';
  end if;

  delete from inquiry_items
  where inquiry_id = p_inquiry and not (design_id = any(v_keep));

  select coalesce(sum(greatest((e->>'dispatch')::int,0)),0) into v_total
  from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) e;
  if v_total > 0 then
    insert into dispatch_notes (inquiry_id, stockist_id, end_user_id,
      invoice_no, vehicle_no, transporter, note, dispatched_on)
    values (p_inquiry, v_st, v_eu,
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

      -- Only touch physical stock when the stockist chose "reduce from stock".
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

  if v_dispatched > 0 and v_outstanding = 0 then
    v_new_status := 'completed';
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
      perform _notify(v_buyer, 'dispatch',
        case when v_new_status='completed' then 'Order completed' else 'Dispatch update' end,
        v_token || ': ' || v_total || ' boxes dispatched' ||
          case when v_outstanding > 0 then ', ' || v_outstanding || ' pending' else '' end,
        jsonb_build_object('token', v_token, 'dispatch_no', v_dispatch_no));
    end if;
  end if;

  return jsonb_build_object('status', v_new_status,
                            'outstanding', v_outstanding,
                            'dispatched', v_dispatched,
                            'dispatch_no', v_dispatch_no);
end;
$function$;

-- reject_order: null-buyer safe (guard off stockist_id, not end_user_id).
create or replace function public.reject_order(p_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_eu uuid; v_st uuid; v_token text; v_stname text; v_buyer uuid;
begin
  select i.end_user_id, i.stockist_id, i.token,
         case when s.is_anonymous then s.public_display_name else s.name end
  into v_eu, v_st, v_token, v_stname
  from inquiries i join stockists s on s.id = i.stockist_id
  where i.id = p_id and s.user_id = auth.uid() and i.status <> 'completed';
  if v_st is null then raise exception 'Not allowed'; end if;
  update inquiries set status='rejected', updated_at=now() where id = p_id;
  delete from my_choices mc using designs d
   where mc.design_id = d.id and mc.end_user_id = v_eu and d.stockist_id = v_st;

  select user_id into v_buyer from end_users where id = v_eu;
  if v_buyer is not null then
    perform _notify(v_buyer, 'order', 'Order declined',
      coalesce(nullif(trim(v_stname),''),'The supplier') || ' declined your order ' || v_token || '.',
      jsonb_build_object('token', v_token));
  end if;
end;
$function$;
