-- 20260720l — 🐞 BRAND BELONGS TO THE LINE, NOT THE ORDER.
--
-- `create_book_order` took ONE `p_brand_id` for the whole order. That was a wrong model decision,
-- and it silently damaged data: with quantities already entered under FAMOUS, choosing KHAKHI
-- rewrote which brand those boxes were for, and the screen dropped every line KHAKHI did not
-- cover. His "showroom order" came out as a single KHAKHI 50 when he had entered FAMOUS lines.
--
-- 🔑 **The model always had this right.** A BOX is `(packing, brand)` and an order line points at a
-- `box_id` — so **every line has ALWAYS carried its own brand**. The single-brand-per-order rule
-- existed only in this function and the screen; nothing in the schema asked for it.
--
-- One order may therefore hold FAMOUS lines and KHAKHI lines together, which is what a real order
-- looks like: a customer takes some designs under one cover and some under another.
--
-- ⚠️ The old 4-arg signature is DROPPED, not left beside this one. A changed parameter list creates
-- an OVERLOAD, and PostgREST then cannot choose (42725).
drop function if exists public.create_book_order(text, uuid, jsonb, uuid);

-- p_lines = [{library_id, brand_id, quantity, quality?, is_urgent?, packing_id?}]
create or replace function public.create_book_order(
  p_hint text,
  p_lines jsonb,
  p_customer_id uuid default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_stk uuid; v_id uuid; v_token text; v_code text; v_cust uuid;
  ln jsonb; v_lib uuid; v_brand uuid; v_pk uuid; v_box uuid;
  v_qty int; v_qual text;
  v_brand_name text; v_design text; v_lines int := 0; v_first_brand uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can book an order'; end if;

  if not coalesce((select book_orders_enabled from stockists where id = v_stk), false) then
    raise exception 'Book Order is not switched on for you. Ask the admin to enable it.';
  end if;

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
    v_lib   := nullif(ln->>'library_id','')::uuid;
    v_brand := nullif(ln->>'brand_id','')::uuid;
    v_pk    := nullif(ln->>'packing_id','')::uuid;
    v_qty   := greatest(coalesce((ln->>'quantity')::int, 0), 0);
    v_qual  := nullif(btrim(coalesce(ln->>'quality','')),'');
    if v_qty <= 0 then continue; end if;

    if not exists (select 1 from stockist_library
                    where id = v_lib and stockist_id = v_stk) then
      raise exception 'That design is not yours';
    end if;

    select name into v_brand_name from brands where id = v_brand and stockist_id = v_stk;
    if v_brand_name is null then
      raise exception 'Every line needs one of your brands — a box is its cover.';
    end if;

    -- 🚫 RESOLVE ONLY. No cover, no order — booking may not mint a box (20260720e).
    v_box := _box_resolve(v_lib, v_brand, v_pk);
    if v_box is null then
      select pm.print_name into v_design
        from stockist_library l join print_master pm on pm.id = l.print_id
       where l.id = v_lib;
      raise exception
        '% has no cover for "%" — open the design in your Design Library and tick % on it first.',
        v_brand_name, coalesce(v_design,'this design'), v_brand_name;
    end if;

    insert into inquiry_items (inquiry_id, box_id, quantity, quality, is_urgent)
    values (v_id, v_box, v_qty, v_qual, coalesce((ln->>'is_urgent')::boolean, false))
    on conflict (inquiry_id, box_id) where box_id is not null
      do update set quantity = excluded.quantity,
                    quality  = excluded.quality,
                    is_urgent = excluded.is_urgent;
    v_lines := v_lines + 1;
    v_first_brand := coalesce(v_first_brand, v_brand);
  end loop;

  if v_lines = 0 then
    raise exception 'Every line had a quantity of 0.';
  end if;

  -- 🏷️ Remember the cover this customer takes — the FIRST line's brand, and only into a blank.
  -- Never overwrites a choice already made, and an order that mixes brands does not fight over it.
  if v_cust is not null and v_first_brand is not null then
    update stockist_customers set default_brand_id = v_first_brand, updated_at = now()
     where id = v_cust and default_brand_id is null;
  end if;

  return jsonb_build_object('id', v_id, 'token', v_token, 'connection_code', v_code,
                            'lines', v_lines);
end $function$;

revoke all on function public.create_book_order(text, jsonb, uuid) from public, anon;
grant execute on function public.create_book_order(text, jsonb, uuid) to authenticated;
