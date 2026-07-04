-- Stockist edits an OPEN, no-buyer order (web/stockist/walk-in): replace its line
-- items + update the customer hint. Owner-only; blocked once held/dispatched, and
-- for app-buyer orders (their basket is buyer-controlled).
create or replace function public.update_order_items(p_id uuid, p_hint text, p_lines jsonb)
returns void language plpgsql security definer
set search_path to 'public','extensions','pg_temp' as $$
declare v_st uuid; v_eu uuid; v_status text;
begin
  select i.stockist_id, i.end_user_id, i.status into v_st, v_eu, v_status
  from inquiries i join stockists s on s.id = i.stockist_id
  where i.id = p_id and s.user_id = auth.uid();
  if v_st is null then raise exception 'Not allowed'; end if;
  if v_eu is not null then
    raise exception 'Only a stockist-managed order (no app buyer) can be edited';
  end if;
  if v_status not in ('draft','sent') then
    raise exception 'Only an open (not held/dispatched) order can be edited';
  end if;
  if exists (
    select 1 from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) e
    left join designs d on d.id = (e->>'design_id')::uuid
    where d.id is null or d.stockist_id <> v_st) then
    raise exception 'A design does not belong to you';
  end if;

  delete from inquiry_items where inquiry_id = p_id;
  insert into inquiry_items (inquiry_id, design_id, quantity)
  select p_id, (e->>'design_id')::uuid, greatest((e->>'quantity')::int, 0)
  from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) e
  where greatest((e->>'quantity')::int, 0) > 0;

  update inquiries
  set customer_hint = coalesce(p_hint, customer_hint), updated_at = now()
  where id = p_id;
end; $$;

grant execute on function public.update_order_items(uuid,text,jsonb) to authenticated;
