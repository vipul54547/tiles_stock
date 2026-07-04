-- Stockist permanently deletes a REJECTED order to keep the inquiry list clean.
-- Owner-only; only 'rejected' orders (safety). Cascades inquiry_items + share links.
create or replace function public.delete_inquiry(p_id uuid)
returns void language plpgsql security definer
set search_path to 'public','extensions','pg_temp' as $$
declare v_ok int;
begin
  select count(*) into v_ok
  from inquiries i join stockists s on s.id = i.stockist_id
  where i.id = p_id and s.user_id = auth.uid() and i.status = 'rejected';
  if v_ok = 0 then
    raise exception 'Only a rejected order can be deleted';
  end if;
  delete from inquiries where id = p_id;
end; $$;

grant execute on function public.delete_inquiry(uuid) to authenticated;
