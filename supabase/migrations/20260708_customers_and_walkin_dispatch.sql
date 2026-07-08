-- Unified dispatch foundation + opt-in customers.
--
-- Trust model (user decision): the platform NEVER depends on customer contact
-- data. "My Customers" is an admin-gated, opt-in feature per stockist
-- (customers_enabled). When OFF: the dispatch Customer field is plain optional
-- text, NOTHING is saved — dispatch works exactly as before. When ON: a stockist
-- may save customers (name + OPTIONAL phone + state/district/pincode/city) and
-- reuse them. Phone is optional so a saved number just enables WhatsApp-direct.

-- 1) Per-stockist opt-in flag (admin sets at create / edit). Default OFF.
alter table public.stockists
  add column if not exists customers_enabled boolean not null default false;

-- 2) Saved customers (only ever written when customers_enabled). No hard contact
--    requirement — name is the only required field.
create table if not exists public.stockist_customers (
  id           uuid primary key default gen_random_uuid(),
  stockist_id  uuid not null references public.stockists(id) on delete cascade,
  name         text not null,
  phone        text,
  country_code text default '+91',
  state        text,
  district     text,
  pincode      text,
  city         text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists idx_stockist_customers_stockist
  on public.stockist_customers(stockist_id);

alter table public.stockist_customers enable row level security;
drop policy if exists stockist_customers_owner on public.stockist_customers;
create policy stockist_customers_owner on public.stockist_customers
  for all to authenticated
  using (stockist_id in (select id from public.stockists where user_id = auth.uid()))
  with check (stockist_id in (select id from public.stockists where user_id = auth.uid()));

-- 3) A dispatch note may point at a saved customer (order-less / walk-in case).
alter table public.dispatch_notes
  add column if not exists customer_id uuid references public.stockist_customers(id);

-- 4) Save (or reuse) a customer. Blocked unless the stockist is customers_enabled.
--    Matches an existing customer by case-insensitive name so re-typing the same
--    name reuses the record rather than duplicating.
create or replace function public.upsert_customer(
  p_id uuid, p_name text, p_phone text default null, p_country_code text default '+91',
  p_state text default null, p_district text default null,
  p_pincode text default null, p_city text default null)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_st uuid; v_enabled boolean; v_id uuid; v_name text;
begin
  select id, coalesce(customers_enabled, false) into v_st, v_enabled
  from stockists where user_id = auth.uid();
  if v_st is null then raise exception 'Only stockists'; end if;
  if not v_enabled then raise exception 'Customers feature is not enabled'; end if;
  v_name := nullif(btrim(coalesce(p_name, '')), '');
  if v_name is null then raise exception 'Customer name is required'; end if;

  if p_id is not null then
    update stockist_customers set
      name = v_name, phone = p_phone, country_code = coalesce(p_country_code, '+91'),
      state = p_state, district = p_district, pincode = p_pincode, city = p_city,
      updated_at = now()
    where id = p_id and stockist_id = v_st
    returning id into v_id;
    if v_id is not null then return v_id; end if;
  end if;

  select id into v_id from stockist_customers
  where stockist_id = v_st and lower(name) = lower(v_name) limit 1;
  if v_id is null then
    insert into stockist_customers (stockist_id, name, phone, country_code, state, district, pincode, city)
    values (v_st, v_name, p_phone, coalesce(p_country_code, '+91'), p_state, p_district, p_pincode, p_city)
    returning id into v_id;
  else
    update stockist_customers set
      phone = coalesce(nullif(btrim(coalesce(p_phone,'')),''), phone),
      state = coalesce(p_state, state), district = coalesce(p_district, district),
      pincode = coalesce(p_pincode, pincode), city = coalesce(p_city, city),
      updated_at = now()
    where id = v_id;
  end if;
  return v_id;
end;
$function$;

-- 5) The stockist's saved customers (for the dispatch picker + future My Customers).
create or replace function public.list_customers()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'phone', phone, 'country_code', country_code,
      'state', state, 'district', district, 'pincode', pincode, 'city', city)
      order by name), '[]'::jsonb)
  from stockist_customers
  where stockist_id in (select id from stockists where user_id = auth.uid());
$function$;

-- 6) Order-less dispatch (the old "walk-in"): reduce stock, make one dispatch note
--    (optionally tied to a saved customer), log dispatches. NO order/remaining
--    tracking. Over-dispatch is allowed (dispatch = final truth → stock floors at
--    0). Mirrors the dispatch mechanics of dispatch_inquiry, minus the inquiry.
create or replace function public.dispatch_walkin(
  p_lines jsonb,
  p_customer_id uuid default null, p_customer_name text default ''::text,
  p_invoice text default ''::text, p_vehicle text default ''::text,
  p_transporter text default ''::text, p_note text default ''::text,
  p_date date default current_date, p_reduce_stock boolean default true)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_st uuid; ln jsonb; v_design uuid; v_disp int; v_total int;
  v_note_id uuid; v_dispatch_no text; v_label text; v_cust uuid;
begin
  select id into v_st from stockists where user_id = auth.uid();
  if v_st is null then raise exception 'Only stockists'; end if;

  if exists (
    select 1 from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e
    left join designs d on d.id = (e->>'design_id')::uuid
    where d.id is null or d.stockist_id <> v_st) then
    raise exception 'A design does not belong to you';
  end if;

  select coalesce(sum(greatest((e->>'dispatch')::int, 0)), 0) into v_total
  from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e;
  if v_total <= 0 then raise exception 'Nothing to dispatch'; end if;

  -- Only keep a customer link if the stockist actually owns that customer record.
  select id into v_cust from stockist_customers
  where id = p_customer_id and stockist_id = v_st;
  v_label := coalesce(nullif(btrim(p_customer_name), ''), 'Walk-in');

  insert into dispatch_notes (stockist_id, inquiry_id, end_user_id, customer_id,
    invoice_no, vehicle_no, transporter, note, dispatched_on)
  values (v_st, null, null, v_cust,
    coalesce(p_invoice, ''), coalesce(p_vehicle, ''), coalesce(p_transporter, ''),
    coalesce(p_note, ''), coalesce(p_date, current_date))
  returning id, dispatch_no into v_note_id, v_dispatch_no;

  for ln in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    v_design := (ln->>'design_id')::uuid;
    v_disp := greatest(coalesce((ln->>'dispatch')::int, 0), 0);
    if v_disp > 0 then
      insert into dispatches (design_id, stockist_id, quantity_dispatched, buyer_name, notes, dispatch_note_id)
      values (v_design, v_st, v_disp, v_label, 'Walk-in', v_note_id);
      if p_reduce_stock then
        update designs
        set box_quantity = greatest(0, box_quantity - v_disp),
            status = case when greatest(0, box_quantity - v_disp) = 0
                          then 'out_of_stock' else 'active' end,
            updated_at = now()
        where id = v_design;
      end if;
    end if;
  end loop;

  return jsonb_build_object('dispatch_no', v_dispatch_no, 'total', v_total);
end;
$function$;

grant execute on function public.upsert_customer(uuid,text,text,text,text,text,text,text) to authenticated;
grant execute on function public.list_customers() to authenticated;
grant execute on function public.dispatch_walkin(jsonb,uuid,text,text,text,text,text,date,boolean) to authenticated;
