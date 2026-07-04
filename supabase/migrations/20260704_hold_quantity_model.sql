-- Hold-Quantity order model.
-- Replaces timed-guarantee + buyer-Accept booking with a simple stockist Hold/Un-hold.
-- "Hold" = set order status='locked' (reuses dispatch gate) + set held_qty per line.
-- H_Quantity (held_of) drives F_Stock on my_stock + public_catalog (already subtract held_of).

-- 1) per-line held amount (enables partial "hold selected")
alter table inquiry_items
  add column if not exists held_qty int not null default 0
  check (held_qty >= 0);

-- 2) held_of driven purely by held_qty on held/dispatching orders
create or replace function public.held_of(p_design uuid)
returns integer language sql stable security definer
set search_path to 'public','extensions','pg_temp' as $$
  select coalesce(sum(greatest(ii.held_qty - ii.dispatched_qty, 0)),0)::int
  from inquiry_items ii
  join inquiries i on i.id = ii.inquiry_id
  where ii.design_id = p_design
    and i.status in ('locked','dispatching');
$$;

-- 3) hold whole order (full ordered qty)
create or replace function public.hold_order(p_id uuid)
returns void language plpgsql security definer
set search_path to 'public','extensions','pg_temp' as $$
declare v_st uuid; v_status text;
begin
  select i.stockist_id, i.status into v_st, v_status
  from inquiries i join stockists s on s.id=i.stockist_id
  where i.id=p_id and s.user_id=auth.uid();
  if v_st is null then raise exception 'Not allowed'; end if;
  if v_status not in ('sent','confirmed','locked') then
    raise exception 'Only an open order can be held'; end if;
  update inquiry_items set held_qty = quantity where inquiry_id = p_id;
  update inquiries set status='locked', locked_at=now(), updated_at=now() where id=p_id;
end; $$;

-- 4) hold selected quantities per design  (p_items = [{design_id, held_qty}, ...])
create or replace function public.hold_order_items(p_id uuid, p_items jsonb)
returns void language plpgsql security definer
set search_path to 'public','extensions','pg_temp' as $$
declare v_st uuid; v_status text; it jsonb;
begin
  select i.stockist_id, i.status into v_st, v_status
  from inquiries i join stockists s on s.id=i.stockist_id
  where i.id=p_id and s.user_id=auth.uid();
  if v_st is null then raise exception 'Not allowed'; end if;
  if v_status not in ('sent','confirmed','locked') then
    raise exception 'Only an open order can be held'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop
    update inquiry_items
    set held_qty = least(greatest((it->>'held_qty')::int,0), quantity)
    where inquiry_id = p_id and design_id = (it->>'design_id')::uuid;
  end loop;
  update inquiries set status='locked', locked_at=now(), updated_at=now() where id=p_id;
end; $$;

-- 5) un-hold: clear holds WITHOUT deleting items, back to open (fixes old unlock_inquiry
--    which deleted items and would wipe a web order's contents)
create or replace function public.unhold_order(p_id uuid)
returns void language plpgsql security definer
set search_path to 'public','extensions','pg_temp' as $$
declare v_st uuid;
begin
  select i.stockist_id into v_st
  from inquiries i join stockists s on s.id=i.stockist_id
  where i.id=p_id and s.user_id=auth.uid() and i.status='locked';
  if v_st is null then raise exception 'Only a held order can be un-held'; end if;
  update inquiry_items set held_qty = 0 where inquiry_id = p_id;
  update inquiries set status='sent', locked_at=null,
    guarantee_until=null, accepted_at=null, guarantee_days=null, updated_at=now()
  where id=p_id;
end; $$;

grant execute on function public.hold_order(uuid)             to authenticated;
grant execute on function public.hold_order_items(uuid,jsonb) to authenticated;
grant execute on function public.unhold_order(uuid)           to authenticated;

-- Held-orders view helper (for the one-tap "Held Orders" screen) — optional; the
-- client can also just filter my_inquiries by status='locked' + held_qty>0.
