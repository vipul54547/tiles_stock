-- Phase E — stockist-created order. Stockist makes an order for a (possibly
-- non-app) customer: a hint + designs picked from their F_Stock. No buyer
-- account needed. (project_dispatch_order_redesign)
create or replace function public.create_stockist_order(p_hint text, p_lines jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_st uuid; v_id uuid; v_token text; v_code text;
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

  insert into inquiries (stockist_id, end_user_id, source, status, customer_hint)
  values (v_st, null, 'stockist', 'sent', nullif(btrim(coalesce(p_hint,'')),''))
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

-- lock_inquiry: allow no-buyer (stockist/web) orders. The old "Not allowed"
-- guard keyed off end_user_id (now null for these) — key it off stockist_id
-- instead. A no-buyer order has nobody to Accept, so locking auto-accepts it
-- (so held_of holds the boxes like an accepted order, not a lapsing window).
create or replace function public.lock_inquiry(p_id uuid, p_days integer DEFAULT NULL::integer)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_eu uuid; v_st uuid; v_status text; v_token text; v_stname text; v_buyer uuid;
begin
  select i.end_user_id, i.stockist_id, i.status, i.token,
         case when s.is_anonymous then s.public_display_name else s.name end
  into v_eu, v_st, v_status, v_token, v_stname
  from inquiries i join stockists s on s.id = i.stockist_id
  where i.id = p_id and s.user_id = auth.uid();
  if v_st is null then raise exception 'Not allowed'; end if;
  if v_status not in ('draft','sent','confirmed') then
    raise exception 'Only an open inquiry can be confirmed';
  end if;

  -- App order: pull the buyer's live basket into the locked items. (No-op for
  -- a no-buyer order — its items were set when the stockist created it.)
  insert into inquiry_items (inquiry_id, design_id, quantity)
  select p_id, mc.design_id, mc.quantity
  from my_choices mc join designs d on d.id = mc.design_id
  where mc.end_user_id = v_eu and d.stockist_id = v_st
  on conflict (inquiry_id, design_id) do update set quantity = excluded.quantity;

  update inquiries
  set status='locked', locked_at=now(), updated_at=now(),
      accepted_at = case when v_eu is null then now() else null end,
      guarantee_days = nullif(greatest(coalesce(p_days,0),0),0),
      guarantee_until = case when coalesce(p_days,0) > 0
                             then now() + (p_days || ' days')::interval
                             else null end
  where id = p_id;

  select user_id into v_buyer from end_users where id = v_eu;
  if v_buyer is not null then
    perform _notify(v_buyer, 'order', 'Order confirmed',
      coalesce(nullif(trim(v_stname),''),'The supplier') || ' confirmed your order ' || v_token ||
        case when coalesce(p_days,0) > 0
             then '. Boxes reserved for ' || p_days || ' day' || case when p_days=1 then '' else 's' end || ' — tap Accept to lock them.'
             else '.' end,
      jsonb_build_object('token', v_token));
  end if;
end;
$function$;
