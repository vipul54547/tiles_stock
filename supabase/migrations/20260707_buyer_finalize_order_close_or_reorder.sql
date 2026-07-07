-- Buyer-side finalization of a closed-short order. When the stockist closes an
-- order with a remaining, the buyer decides in My Orders: Re-order the rest
-- (new order + finalize old) or Close (finalize old). Finalized orders (this +
-- fully-dispatched + rejected) move to the buyer's "My Dispatch" record.
alter table public.inquiries add column if not exists buyer_closed_at timestamptz;

create or replace function public.buyer_close_order(p_inquiry uuid)
 returns void language plpgsql security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
begin
  update inquiries set buyer_closed_at = now(), updated_at = now()
  where id = p_inquiry
    and end_user_id in (select id from end_users where user_id = auth.uid())
    and status = 'completed';
  if not found then raise exception 'Order not found or not closeable'; end if;
end; $function$;
revoke execute on function public.buyer_close_order(uuid) from public;
grant  execute on function public.buyer_close_order(uuid) to authenticated;

create or replace function public.reorder_remaining(p_inquiry uuid)
 returns integer language plpgsql security definer
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

  update inquiries set buyer_closed_at = now(), updated_at = now()
  where id = p_inquiry and status = 'completed';
  return v_rows;
end; $function$;

-- my_orders exposes buyer_closed_at (client splits My Orders vs My Dispatch).
create or replace function public.my_orders()
 returns jsonb language sql stable security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
  select coalesce(jsonb_agg(row order by row->>'updated_at' desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', i.id, 'token', i.token, 'status', i.status,
      'created_at', i.created_at, 'updated_at', i.updated_at,
      'confirmed_at', i.confirmed_at, 'locked_at', i.locked_at,
      'buyer_closed_at', i.buyer_closed_at,
      'guarantee_until', i.guarantee_until, 'accepted_at', i.accepted_at,
      'guarantee_days', i.guarantee_days,
      'stockist_id', i.stockist_id,
      'stockist_key',  s.sequential_id,
      'stockist_name', s.name,
      'line_count', (select count(*) from inquiry_items it where it.inquiry_id=i.id),
      'total_boxes', (select coalesce(sum(it.quantity),0) from inquiry_items it where it.inquiry_id=i.id),
      'dispatched_boxes', (select coalesce(sum(it.dispatched_qty),0) from inquiry_items it where it.inquiry_id=i.id),
      'remaining_boxes', (select coalesce(sum(greatest(it.quantity - it.dispatched_qty,0)),0) from inquiry_items it where it.inquiry_id=i.id)
    ) as row
    from inquiries i join stockists s on s.id = i.stockist_id
    where i.end_user_id in (select id from end_users where user_id = auth.uid())
  ) t;
$function$;
