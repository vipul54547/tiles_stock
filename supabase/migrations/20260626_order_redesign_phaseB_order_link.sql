-- Phase B · Part 2 — stockist order link: a customer opens a pre-selected order
-- on the web (login-free), adjusts quantities, and confirms. Reuses
-- stockist_share_links (now order-scoped via inquiry_id) for token + expiry.
-- (project_dispatch_order_redesign)

alter table public.stockist_share_links
  add column if not exists inquiry_id uuid references public.inquiries(id) on delete cascade;

-- Stockist creates an order-scoped share link (optional N-day expiry). Returns
-- the token. Only the order's own stockist may create it.
create or replace function public.create_order_link(p_inquiry uuid, p_days integer default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_st uuid; v_token text;
begin
  select i.stockist_id into v_st
  from inquiries i join stockists s on s.id = i.stockist_id
  where i.id = p_inquiry and s.user_id = auth.uid();
  if v_st is null then raise exception 'Order not found'; end if;

  insert into stockist_share_links (stockist_id, inquiry_id, label, expires_at)
  values (v_st, p_inquiry, 'Order',
          case when coalesce(p_days,0) > 0 then now() + (p_days || ' days')::interval else null end)
  returning token into v_token;

  return jsonb_build_object('token', v_token);
end;
$function$;

-- Public (login-free) view of an order behind an order-link token: stockist
-- contact + the pre-selected lines with current available stock. Never exposes
-- the stockist's private customer_hint. Null if the link is invalid/expired.
create or replace function public.public_order(p_token text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_id uuid; v_st uuid;
begin
  select l.inquiry_id, i.stockist_id into v_id, v_st
  from stockist_share_links l
  join inquiries i on i.id = l.inquiry_id
  join stockists s on s.id = i.stockist_id
  where l.token = p_token and l.is_active and l.inquiry_id is not null
    and (l.expires_at is null or l.expires_at > now())
    and i.status in ('draft','sent','confirmed','locked') and s.is_active;
  if v_id is null then return null; end if;

  return (select jsonb_build_object(
    'token', i.token, 'connection_code', i.connection_code, 'status', i.status,
    'stockist', jsonb_build_object(
      'name', s.name, 'phone', s.phone, 'country_code', s.country_code,
      'city', s.city, 'brand_color', s.brand_color),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'design_id', d.id,
        'name', coalesce(lib.master_design_name, d.name),
        'size', d.size, 'surface', d.surface_type, 'quality', d.quality,
        'image', case when nullif(btrim(coalesce(lib.image_url,'')),'') is not null
                      then lib.image_url else null end,
        'quantity', it.quantity,
        'available', greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)))
        order by d.name)
      from inquiry_items it
      join designs d on d.id = it.design_id
      left join stockist_library lib on lib.id = d.library_id
      where it.inquiry_id = v_id), '[]'::jsonb))
    from inquiries i join stockists s on s.id = i.stockist_id where i.id = v_id);
end;
$function$;

-- Customer confirms the order via the link: saves adjusted quantities (0 drops
-- a line), marks it customer-confirmed, and notifies the stockist. Anonymous-
-- callable (holds the secret token). Returns {token, connection_code}.
create or replace function public.confirm_order_link(p_token text, p_lines jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_id uuid; v_st uuid; v_otoken text; v_code text; v_stuser uuid;
  ln jsonb; v_design uuid; v_qty int;
begin
  select l.inquiry_id, i.stockist_id, i.token, i.connection_code
  into v_id, v_st, v_otoken, v_code
  from stockist_share_links l join inquiries i on i.id = l.inquiry_id
  where l.token = p_token and l.is_active and l.inquiry_id is not null
    and (l.expires_at is null or l.expires_at > now())
    and i.status in ('draft','sent','confirmed');
  if v_id is null then raise exception 'This order link is no longer open'; end if;

  for ln in select * from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) loop
    v_design := (ln->>'design_id')::uuid;
    v_qty := greatest(coalesce((ln->>'quantity')::int, 0), 0);
    if v_qty = 0 then
      delete from inquiry_items where inquiry_id = v_id and design_id = v_design;
    else
      update inquiry_items set quantity = v_qty
      where inquiry_id = v_id and design_id = v_design;
    end if;
  end loop;

  update inquiries
  set status = 'confirmed', confirmed_at = now(), updated_at = now()
  where id = v_id;

  select user_id into v_stuser from stockists where id = v_st;
  if v_stuser is not null then
    perform _notify(v_stuser, 'order', 'Customer confirmed an order',
      'Order ' || v_otoken || ' (' || v_code || ') was confirmed via your link.',
      jsonb_build_object('token', v_otoken, 'connection_code', v_code));
  end if;

  return jsonb_build_object('token', v_otoken, 'connection_code', v_code);
end;
$function$;
