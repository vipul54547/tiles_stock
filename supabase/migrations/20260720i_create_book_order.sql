-- 20260720i — BOOK ORDER, step 2: BOOK an order for a tile that has not been made.
--
-- 📕 The stockist takes an order against a TILE + a BRAND'S COVER. No stock need exist. This is the
-- first step he can actually see in the app.
--
-- 🔑 **The caller names the TILE and the BRAND — never a box id.** The server resolves the box with
-- `_box_resolve`, and RAISES the plain-English sentence when that brand has no cover on the design.
-- 🚫 It never calls `box_put_cover`. Booking an order may not invent a cover, exactly as adding
-- stock may not (20260720e). A cover is declared by a human in the Design Library, and that is what
-- makes the whole chain honest: an order can only exist for a cover he has really declared.
--
-- 🏷️ The BRAND is asked once per order (a customer takes material under one cover) and REMEMBERED
-- on the customer, so next time it prefills. Prefill, never force — same law as the cover word.

-- ── the customer remembers its brand ────────────────────────────────────────────────────────────
create or replace function public.list_customers()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'phone', phone, 'country_code', country_code,
      'state', state, 'district', district, 'pincode', pincode, 'city', city,
      'default_brand_id', default_brand_id)
      order by name), '[]'::jsonb)
  from stockist_customers
  where stockist_id in (select id from stockists where user_id = auth.uid());
$function$;

create or replace function public.customer_set_default_brand(
  p_customer_id uuid, p_brand_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_stk uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if not exists (select 1 from stockist_customers
                  where id = p_customer_id and stockist_id = v_stk) then
    raise exception 'That customer is not yours';
  end if;
  if p_brand_id is not null and not exists (
       select 1 from brands where id = p_brand_id and stockist_id = v_stk) then
    raise exception 'That brand is not yours';
  end if;
  update stockist_customers set default_brand_id = p_brand_id, updated_at = now()
   where id = p_customer_id;
end $function$;

revoke all on function public.customer_set_default_brand(uuid, uuid) from public, anon;
grant execute on function public.customer_set_default_brand(uuid, uuid) to authenticated;

-- ── book the order ──────────────────────────────────────────────────────────────────────────────
-- p_lines = [{library_id, quantity, quality?, is_urgent?, packing_id?}]
-- One brand per order: a customer takes his material under one cover.
create or replace function public.create_book_order(
  p_hint text,
  p_brand_id uuid,
  p_lines jsonb,
  p_customer_id uuid default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_stk uuid; v_id uuid; v_token text; v_code text; v_cust uuid;
  ln jsonb; v_lib uuid; v_pk uuid; v_box uuid; v_qty int; v_qual text;
  v_brand text; v_design text; v_lines int := 0;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can book an order'; end if;

  if not coalesce((select book_orders_enabled from stockists where id = v_stk), false) then
    raise exception 'Book Order is not switched on for you. Ask the admin to enable it.';
  end if;

  select name into v_brand from brands where id = p_brand_id and stockist_id = v_stk;
  if v_brand is null then raise exception 'Pick a brand — a box is its cover.'; end if;

  if p_customer_id is not null then
    select id into v_cust from stockist_customers
     where id = p_customer_id and stockist_id = v_stk;
    if v_cust is null then raise exception 'That customer is not yours'; end if;
  end if;

  if coalesce(jsonb_array_length(p_lines), 0) = 0 then
    raise exception 'Add at least one design to the order.';
  end if;

  insert into inquiries (stockist_id, end_user_id, source, status, customer_hint, customer_id)
  values (v_stk, null, 'stockist', 'sent', nullif(btrim(coalesce(p_hint,'')),''), v_cust)
  returning id, token, connection_code into v_id, v_token, v_code;

  for ln in select * from jsonb_array_elements(p_lines) loop
    v_lib  := nullif(ln->>'library_id','')::uuid;
    v_pk   := nullif(ln->>'packing_id','')::uuid;
    v_qty  := greatest(coalesce((ln->>'quantity')::int, 0), 0);
    -- NULL quality means Premium. Store what he said, or nothing.
    v_qual := nullif(btrim(coalesce(ln->>'quality','')),'');
    if v_qty <= 0 then continue; end if;

    if not exists (select 1 from stockist_library
                    where id = v_lib and stockist_id = v_stk) then
      raise exception 'That design is not yours';
    end if;

    -- 🚫 RESOLVE ONLY. No cover, no order — booking may not mint a box.
    v_box := _box_resolve(v_lib, p_brand_id, v_pk);
    if v_box is null then
      select pm.print_name into v_design
        from stockist_library l join print_master pm on pm.id = l.print_id
       where l.id = v_lib;
      raise exception
        '% has no cover for "%" — open the design in your Design Library and tick % on it first.',
        v_brand, coalesce(v_design,'this design'), v_brand;
    end if;

    insert into inquiry_items (inquiry_id, box_id, quantity, quality, is_urgent)
    values (v_id, v_box, v_qty, v_qual, coalesce((ln->>'is_urgent')::boolean, false))
    on conflict (inquiry_id, box_id) where box_id is not null
      do update set quantity = excluded.quantity,
                    quality  = excluded.quality,
                    is_urgent = excluded.is_urgent;
    v_lines := v_lines + 1;
  end loop;

  if v_lines = 0 then
    raise exception 'Every line had a quantity of 0.';
  end if;

  -- 🏷️ Remember the cover this customer takes, so it prefills next time. Only fills a blank —
  -- never overwrites a choice he already made for that customer.
  if v_cust is not null then
    update stockist_customers set default_brand_id = p_brand_id, updated_at = now()
     where id = v_cust and default_brand_id is null;
  end if;

  return jsonb_build_object('id', v_id, 'token', v_token, 'connection_code', v_code,
                            'lines', v_lines);
end $function$;

revoke all on function public.create_book_order(text, uuid, jsonb, uuid) from public, anon;
grant execute on function public.create_book_order(text, uuid, jsonb, uuid) to authenticated;

-- ── one line's urgency, flipped any time ────────────────────────────────────────────────────────
-- ⭐ HIS mark, set at booking or long after — a line taken last week can become urgent today.
create or replace function public.book_line_set_urgent(p_item_id uuid, p_urgent boolean)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_stk uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  update inquiry_items it set is_urgent = coalesce(p_urgent, false)
    from inquiries i
   where it.id = p_item_id and i.id = it.inquiry_id and i.stockist_id = v_stk;
end $function$;

revoke all on function public.book_line_set_urgent(uuid, boolean) from public, anon;
grant execute on function public.book_line_set_urgent(uuid, boolean) to authenticated;

-- ── admin switch, same shape as customers ───────────────────────────────────────────────────────
create or replace function public.admin_set_stockist_book_orders(p_seq text, p_enabled boolean)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
begin
  if current_user_role() <> 'admin' then raise exception 'Only admins'; end if;
  update stockists set book_orders_enabled = coalesce(p_enabled, false)
   where sequential_id = p_seq;
end $function$;

revoke all on function public.admin_set_stockist_book_orders(text, boolean) from public, anon;
grant execute on function public.admin_set_stockist_book_orders(text, boolean) to authenticated;
