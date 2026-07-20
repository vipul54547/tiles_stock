-- 20260720j — a saved customer can be REMOVED, and the removal refuses to orphan history.
--
-- 👥 There was no delete at all: `upsert_customer` could create and (given an id) update, but
-- nothing could remove a customer — and no screen ever passed an id, so even a typo in a name was
-- permanent. This adds the missing writer.
--
-- ⚠️ `inquiries.customer_id` and `dispatch_notes.customer_id` are plain FKs (NO ACTION), so a raw
-- delete on a customer with history throws a bare 23503 at the user. Worse would be CASCADE — the
-- orders and dispatches ARE the reason to save a customer, so losing them is never the right
-- answer. The function counts them and refuses in plain English instead.
create or replace function public.customer_delete(p_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_stk uuid; v_orders int; v_dispatches int; v_name text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;

  select name into v_name from stockist_customers
   where id = p_id and stockist_id = v_stk;
  if v_name is null then raise exception 'That customer is not yours'; end if;

  select count(*) into v_orders     from inquiries      where customer_id = p_id;
  select count(*) into v_dispatches from dispatch_notes where customer_id = p_id;

  if v_orders > 0 or v_dispatches > 0 then
    raise exception
      '% cannot be removed — % order(s) and % dispatch(es) are recorded against them. '
      'That history is the point of saving a customer.',
      v_name, v_orders, v_dispatches;
  end if;

  delete from stockist_customers where id = p_id;
end $function$;

revoke all on function public.customer_delete(uuid) from public, anon;
grant execute on function public.customer_delete(uuid) to authenticated;
