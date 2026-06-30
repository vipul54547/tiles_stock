-- Phase B · Part 1 — a login-free web enquiry becomes a real saved order
-- (source='web', no buyer account) with a connection code the buyer carries
-- into WhatsApp, so the stockist can match the chat to the order and fill the
-- hint. Anonymous-callable (mirrors log_link_inquiry's token resolution).
-- (project_dispatch_order_redesign)
create or replace function public.create_web_order(p_token text, p_lines jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_st uuid; v_id uuid; v_otoken text; v_code text; v_stuser uuid;
  ln jsonb; v_design uuid; v_qty int; v_n int := 0;
begin
  -- Resolve the stockist from the share token: catalog token, stockist token,
  -- or an active stockist/catalog share link.
  select c.stockist_id into v_st
  from stock_catalogs c where c.share_token = p_token and c.is_active limit 1;
  if v_st is null then
    select s.id into v_st from stockists s
    where s.share_token = p_token
       or exists (select 1 from stockist_share_links l
                  where l.stockist_id = s.id and l.token = p_token and l.is_active
                    and (l.expires_at is null or l.expires_at > now()));
  end if;
  if v_st is null then
    select c.stockist_id into v_st
    from stockist_share_links l join stock_catalogs c on c.id = l.catalog_id
    where l.token = p_token and l.is_active
      and (l.expires_at is null or l.expires_at > now()) limit 1;
  end if;
  if v_st is null then raise exception 'Invalid link'; end if;

  insert into inquiries (stockist_id, end_user_id, source, status)
  values (v_st, null, 'web', 'sent')
  returning id, token, connection_code into v_id, v_otoken, v_code;

  for ln in select * from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) loop
    v_design := (ln->>'design_id')::uuid;
    v_qty := greatest(coalesce((ln->>'quantity')::int, 0), 0);
    if v_qty > 0 and exists (
        select 1 from designs d where d.id = v_design and d.stockist_id = v_st) then
      insert into inquiry_items (inquiry_id, design_id, quantity, dispatched_qty)
      values (v_id, v_design, v_qty, 0)
      on conflict (inquiry_id, design_id) do update set quantity = excluded.quantity;
      v_n := v_n + 1;
    end if;
  end loop;

  -- No valid lines → don't leave an empty order behind.
  if v_n = 0 then
    delete from inquiries where id = v_id;
    return null;
  end if;

  -- Tell the stockist a web order arrived via their link.
  select user_id into v_stuser from stockists where id = v_st;
  if v_stuser is not null then
    perform _notify(v_stuser, 'order', 'New web order',
      'Order ' || v_otoken || ' (' || v_code || ') came in via your link.',
      jsonb_build_object('token', v_otoken, 'connection_code', v_code));
  end if;

  return jsonb_build_object('token', v_otoken, 'connection_code', v_code);
end;
$function$;
