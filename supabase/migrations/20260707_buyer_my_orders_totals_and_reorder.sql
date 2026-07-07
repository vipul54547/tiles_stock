-- Phase 3 buyer order tracker: my_orders gains dispatched/remaining totals, plus
-- reorder_remaining to drop a completed order's leftover back into the basket.
-- NOTE: my_orders is redefined again in 20260707_send_order_split_freeze_and_clear
-- (draft-only basket branch) — that later file is the authoritative my_orders.
create or replace function public.reorder_remaining(p_inquiry uuid)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
declare v_eu uuid; v_rows int;
begin
  select end_user_id into v_eu from inquiries
  where id = p_inquiry
    and end_user_id in (select id from end_users where user_id = auth.uid());
  if v_eu is null then raise exception 'Not allowed'; end if;

  insert into my_choices (end_user_id, design_id, quantity)
  select v_eu, it.design_id, (it.quantity - it.dispatched_qty)
  from inquiry_items it
  where it.inquiry_id = p_inquiry and (it.quantity - it.dispatched_qty) > 0
  on conflict (end_user_id, design_id) do update set quantity = excluded.quantity;
  get diagnostics v_rows = row_count;
  return v_rows;
end; $function$;
revoke execute on function public.reorder_remaining(uuid) from public;
grant  execute on function public.reorder_remaining(uuid) to authenticated;
