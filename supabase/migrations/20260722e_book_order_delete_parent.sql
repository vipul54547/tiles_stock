-- 20260722e — 🐞 book_order_delete: deleting the LEFTOVER PARENT of a sliced order.
--
-- When part of a booked order is taken into production it SLICES: a child order (parent_id → this)
-- goes into production and the parent keeps the un-produced remainder. Deleting that leftover parent
-- hit `book_orders_parent_id_fkey` (ON DELETE RESTRICT) and leaked the raw Postgres error to the UI.
-- The slice is real work already in production — so orphan it (drop the parent link, it survives as a
-- standalone order) rather than block. The parent's own produced_qty is still the delete guard.

create or replace function public.book_order_delete(p_id uuid)
 returns void language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp'
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
  -- Orphan any production slices so the FK doesn't block; they keep their own
  -- token and their place in production, just without the (now-gone) parent link.
  update book_orders set parent_id = null, updated_at = now()
   where parent_id = p_id and stockist_id = v_stk;
  delete from book_orders where id = p_id and stockist_id = v_stk;
end $function$;
