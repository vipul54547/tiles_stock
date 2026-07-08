-- Command Center hardening #1: NO over-dispatch, NO negatives anywhere.
-- A stockist may ship less than ordered, and (deliberately) more than their
-- SYSTEM stock (physical truth differs) — but never MORE boxes than the buyer
-- actually ordered on a line. Over-ordering was the one way dispatched_qty could
-- exceed quantity, making the buyer's Ordered/Dispatched/Remaining totals fail to
-- reconcile (looked like a negative remaining). The app now blocks it in the UI;
-- this caps it in the RPC too so no client (web/stockist/legacy build) can slip a
-- line past. Designs ADDED to the dispatch (not on the order) get quantity=v_disp
-- on insert, so their cap == what's sent → they pass through unchanged.
--
-- Based on the live definition in 20260707_order_flow_simplify_gates_hold_dispatch
-- (relaxed gate + basket materialize) — the ONLY change is the per-line HARD CAP
-- and reporting the actually-dispatched total (v_dispatched) instead of requested.
create or replace function public.dispatch_inquiry(
  p_inquiry uuid, p_lines jsonb,
  p_invoice text default ''::text, p_vehicle text default ''::text,
  p_transporter text default ''::text, p_note text default ''::text,
  p_date date default current_date, p_reduce_stock boolean default true,
  p_close boolean default true
) returns jsonb
 language plpgsql
 security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
declare
  v_eu uuid; v_st uuid; v_status text; v_token text; v_company text; v_hint text;
  v_buyer_label text;
  v_keep uuid[]; ln jsonb; v_design uuid; v_disp int; v_rem int;
  v_total int; v_note_id uuid; v_dispatch_no text;
  v_outstanding int; v_dispatched int; v_new_status text; v_buyer uuid;
  v_title text; v_msg text;
begin
  select i.end_user_id, i.stockist_id, i.status, i.token, e.company_name, i.customer_hint
  into v_eu, v_st, v_status, v_token, v_company, v_hint
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

    -- Materialise the ordered qty (added designs → quantity = dispatched).
    insert into inquiry_items (inquiry_id, design_id, quantity, dispatched_qty)
    values (p_inquiry, v_design, greatest(v_disp,0), 0)
    on conflict (inquiry_id, design_id) do nothing;

    if v_disp > 0 then
      -- HARD CAP: never dispatch more than remains on the order. The app already
      -- blocks this; this is the last-line guarantee that dispatched_qty can't
      -- exceed quantity (→ remaining floors at 0, never negative).
      select greatest(quantity - dispatched_qty, 0) into v_rem
      from inquiry_items where inquiry_id = p_inquiry and design_id = v_design;
      v_disp := least(v_disp, v_rem);
    end if;

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
      -- Report the boxes that ACTUALLY shipped this round (post-cap): total
      -- ordered on all lines this dispatch, minus anything the cap trimmed.
      if v_new_status = 'completed' and v_outstanding > 0 then
        v_title := 'Order closed';
        v_msg := v_token || ': boxes dispatched, ' || v_outstanding ||
                 ' not included — re-order if you still need them.';
      elsif v_new_status = 'completed' then
        v_title := 'Order completed';
        v_msg := v_token || ': ' || v_dispatched || ' boxes dispatched.';
      else
        v_title := 'Dispatch update';
        v_msg := v_token || ': boxes dispatched, ' || v_outstanding ||
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

grant execute on function public.dispatch_inquiry(uuid,jsonb,text,text,text,text,date,boolean,boolean) to authenticated;
