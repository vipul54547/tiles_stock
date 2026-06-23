-- Migration: admin_stockist_library
--
-- Admin-on-behalf reader for the bulk image-import preview: returns a target
-- stockist's library keys (master name + size + brand) so the import screen can
-- flag each folder design as NEW vs already-in-library. Admin-role-checked
-- (my_library resolves the stockist via auth.uid(), so admins can't use it).

create or replace function public.admin_stockist_library(p_seq text)
 returns table(master_design_name text, size text, brand_id uuid)
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
begin
  if current_user_role() <> 'admin' then
    raise exception 'Only admins can read another stockist''s library';
  end if;
  return query
    select l.master_design_name, l.size, l.brand_id
    from stockist_library l
    join stockists s on s.id = l.stockist_id
    where s.sequential_id = p_seq;
end; $function$;
