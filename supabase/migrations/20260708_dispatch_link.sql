-- Dispatch link: a login-free, read-only receipt of ONE dispatch (a dispatch
-- note) that the stockist shares with the buyer as `<shareBaseUrl>/d/<token>`.
-- Replaces the stockist "Order link" as the shareable surface — it now lives on
-- the All Dispatches page, one link per recorded dispatch. Reuses the
-- stockist_share_links token/expiry infra (now dispatch-scoped via
-- dispatch_note_id), mirroring the order-link plumbing but READ-ONLY (no confirm).
alter table public.stockist_share_links
  add column if not exists dispatch_note_id uuid
    references public.dispatch_notes(id) on delete cascade;

-- Stockist mints (or reuses) a share link for one of their dispatch notes.
-- Reusing an existing active link keeps the URL stable across taps. p_days null
-- = never expires. Only the note's own stockist may create it.
create or replace function public.create_dispatch_link(p_note uuid, p_days integer default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_st uuid; v_token text;
begin
  select dn.stockist_id into v_st
  from dispatch_notes dn join stockists s on s.id = dn.stockist_id
  where dn.id = p_note and s.user_id = auth.uid();
  if v_st is null then raise exception 'Dispatch not found'; end if;

  select token into v_token
  from stockist_share_links
  where dispatch_note_id = p_note and is_active
    and (expires_at is null or expires_at > now())
  order by created_at desc
  limit 1;

  if v_token is null then
    insert into stockist_share_links (stockist_id, dispatch_note_id, label, expires_at)
    values (v_st, p_note, 'Dispatch',
            case when coalesce(p_days,0) > 0 then now() + (p_days || ' days')::interval else null end)
    returning token into v_token;
  end if;

  return jsonb_build_object('token', v_token);
end;
$function$;

-- Public (login-free) view of a dispatch behind a dispatch-link token: supplier
-- contact + note meta (invoice/vehicle/transporter/date) + the dispatched lines.
-- Read-only. Null if the link is invalid/expired or the supplier is inactive.
create or replace function public.public_dispatch(p_token text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_note uuid;
begin
  select l.dispatch_note_id into v_note
  from stockist_share_links l
  join dispatch_notes dn on dn.id = l.dispatch_note_id
  join stockists s on s.id = dn.stockist_id
  where l.token = p_token and l.is_active and l.dispatch_note_id is not null
    and (l.expires_at is null or l.expires_at > now()) and s.is_active;
  if v_note is null then return null; end if;

  return (select jsonb_build_object(
    'dispatch_no', dn.dispatch_no,
    'dispatched_on', dn.dispatched_on,
    'invoice_no', dn.invoice_no, 'vehicle_no', dn.vehicle_no,
    'transporter', dn.transporter, 'note', dn.note,
    'order_token', i.token,
    'buyer', coalesce(nullif(btrim(e.company_name), ''),
                      (select buyer_name from dispatches where dispatch_note_id = dn.id
                        and nullif(btrim(coalesce(buyer_name,'')),'') is not null limit 1), ''),
    'stockist', jsonb_build_object(
        'name', s.name, 'phone', s.phone, 'country_code', s.country_code,
        'city', s.city, 'brand_color', s.brand_color),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', coalesce(lib.master_design_name, d.name),
        'size', d.size, 'surface', d.surface_type,
        'image', case when nullif(btrim(coalesce(lib.image_url,'')),'') is not null
                      then lib.image_url else null end,
        'quantity', dp.quantity_dispatched)
        order by d.name)
      from dispatches dp
      join designs d on d.id = dp.design_id
      left join stockist_library lib on lib.id = d.library_id
      where dp.dispatch_note_id = dn.id), '[]'::jsonb),
    'total', coalesce((select sum(quantity_dispatched) from dispatches where dispatch_note_id = dn.id), 0)
  )
  from dispatch_notes dn
  join stockists s on s.id = dn.stockist_id
  left join inquiries i on i.id = dn.inquiry_id
  left join end_users e on e.id = dn.end_user_id
  where dn.id = v_note);
end;
$function$;

grant execute on function public.create_dispatch_link(uuid, integer) to authenticated;
grant execute on function public.public_dispatch(text) to anon, authenticated;
