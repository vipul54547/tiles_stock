-- ── H_Quantity Phase 2 · P1: booking schema + held helper + lock/accept RPCs ──

-- 1. New columns on inquiries: guarantee window + buyer acceptance.
alter table inquiries
  add column if not exists guarantee_until timestamptz,
  add column if not exists accepted_at    timestamptz,
  add column if not exists guarantee_days  int;

-- 2. held_of() reads inquiry_items by design — index the lookup.
create index if not exists idx_inquiry_items_design on inquiry_items(design_id);

-- 3. held_of(design) = COMMITTED boxes for a design (H_Quantity).
--    Counts outstanding (quantity - dispatched) for orders that are:
--      • locked AND (buyer accepted  OR  still inside the guarantee window), or
--      • dispatching (in-progress, remainder still committed).
--    Un-accepted locks whose guarantee_until has lapsed auto-release (excluded).
create or replace function public.held_of(p_design uuid)
returns int
language sql
stable
security definer
set search_path to 'public','extensions','pg_temp'
as $$
  select coalesce(sum(greatest(ii.quantity - ii.dispatched_qty, 0)), 0)::int
  from inquiry_items ii
  join inquiries i on i.id = ii.inquiry_id
  where ii.design_id = p_design
    and ( (i.status = 'locked'
            and (i.accepted_at is not null or i.guarantee_until > now()))
          or i.status = 'dispatching' );
$$;

-- 4. lock_inquiry now takes the guarantee length (N days) the stockist offers.
--    p_days NULL/0 = no time reservation (boxes held only once the buyer accepts).
drop function if exists public.lock_inquiry(uuid);
create or replace function public.lock_inquiry(p_id uuid, p_days int default null)
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
  if v_eu is null then raise exception 'Not allowed'; end if;
  if v_status not in ('draft','sent','confirmed') then
    raise exception 'Only an open inquiry can be confirmed';
  end if;

  insert into inquiry_items (inquiry_id, design_id, quantity)
  select p_id, mc.design_id, mc.quantity
  from my_choices mc join designs d on d.id = mc.design_id
  where mc.end_user_id = v_eu and d.stockist_id = v_st
  on conflict (inquiry_id, design_id) do update set quantity = excluded.quantity;

  update inquiries
  set status='locked', locked_at=now(), updated_at=now(),
      accepted_at=null,
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
end; $function$;

-- 5. accept_inquiry — the BUYER accepts a stockist's offer (both-side lock).
--    Marks accepted_at so the boxes stay held past the guarantee window.
create or replace function public.accept_inquiry(p_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_eu uuid; v_st uuid; v_token text; v_company text; v_stuser uuid;
begin
  select i.end_user_id, i.stockist_id, i.token, e.company_name
  into v_eu, v_st, v_token, v_company
  from inquiries i
  join end_users e on e.id = i.end_user_id
  where i.id = p_id
    and i.status = 'locked' and i.accepted_at is null
    and i.end_user_id in (select id from end_users where user_id = auth.uid());
  if v_eu is null then raise exception 'This order can no longer be accepted'; end if;

  update inquiries set accepted_at = now(), updated_at = now() where id = p_id;

  select user_id into v_stuser from stockists where id = v_st;
  if v_stuser is not null then
    perform _notify(v_stuser, 'order', 'Order accepted',
      coalesce(nullif(trim(v_company),''),'The buyer') || ' accepted order ' || v_token || '.',
      jsonb_build_object('token', v_token));
  end if;
end; $function$;

-- 6. unlock_inquiry — reopening clears the reservation too.
create or replace function public.unlock_inquiry(p_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_ok int;
begin
  select count(*) into v_ok
  from inquiries i join stockists s on s.id = i.stockist_id
  where i.id = p_id and s.user_id = auth.uid() and i.status = 'locked';
  if v_ok = 0 then raise exception 'Only a locked (not yet dispatched) order can be reopened'; end if;
  delete from inquiry_items where inquiry_id = p_id;
  update inquiries
  set status='confirmed', locked_at=null,
      guarantee_until=null, accepted_at=null, guarantee_days=null,
      updated_at=now()
  where id = p_id;
end; $function$;
