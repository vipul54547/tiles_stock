-- Kill-list C: collapse the dual line-source. A draft's inquiry_items are kept in
-- sync with the buyer's basket by the trigger, so EVERY read (my_orders /
-- my_inquiries / inquiry_detail) uses inquiry_items — no more "basket for draft,
-- frozen for sent+" branching. my_choices is purely the basket UI state now;
-- inquiry_items is the single source of order lines. Also drops the anonymity
-- name-masking in these reads (stockist_key=sequential_id, stockist_name=name).
-- Verified: add→draft+items synced; my_orders reads items; send→items preserved +
-- basket cleared; remove-last→item+draft auto-cleaned.

create or replace function public.trg_my_choices_sync_inquiry()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
declare v_design uuid; v_eu uuid; v_stockist uuid; v_inq uuid; v_qty int; v_remaining int;
begin
  if (tg_op = 'DELETE') then v_design := old.design_id; v_eu := old.end_user_id;
  else v_design := new.design_id; v_eu := new.end_user_id; v_qty := new.quantity; end if;
  select stockist_id into v_stockist from designs where id = v_design;
  if v_stockist is null then return coalesce(new, old); end if;

  select id into v_inq from inquiries
   where end_user_id = v_eu and stockist_id = v_stockist and status = 'draft'
   limit 1;

  if (tg_op in ('INSERT','UPDATE')) then
    if v_inq is null then
      insert into inquiries(end_user_id, stockist_id, status)
        values (v_eu, v_stockist, 'draft') returning id into v_inq;
    else
      update inquiries set updated_at = now() where id = v_inq;
    end if;
    insert into inquiry_items(inquiry_id, design_id, quantity)
      values (v_inq, v_design, v_qty)
      on conflict (inquiry_id, design_id) do update set quantity = excluded.quantity;
  elsif (tg_op = 'DELETE') then
    if v_inq is not null then
      delete from inquiry_items where inquiry_id = v_inq and design_id = v_design;
      select count(*) into v_remaining from inquiry_items where inquiry_id = v_inq;
      if v_remaining = 0 then delete from inquiries where id = v_inq;
      else update inquiries set updated_at = now() where id = v_inq; end if;
    end if;
  end if;
  return coalesce(new, old);
end; $function$;

create or replace function public.my_orders()
 returns jsonb language sql stable security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
  select coalesce(jsonb_agg(row order by row->>'updated_at' desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', i.id, 'token', i.token, 'status', i.status,
      'created_at', i.created_at, 'updated_at', i.updated_at,
      'confirmed_at', i.confirmed_at, 'locked_at', i.locked_at,
      'guarantee_until', i.guarantee_until, 'accepted_at', i.accepted_at,
      'guarantee_days', i.guarantee_days,
      'stockist_id', i.stockist_id,
      'stockist_key',  s.sequential_id,
      'stockist_name', s.name,
      'line_count', (select count(*) from inquiry_items it where it.inquiry_id=i.id),
      'total_boxes', (select coalesce(sum(it.quantity),0) from inquiry_items it where it.inquiry_id=i.id),
      'dispatched_boxes', (select coalesce(sum(it.dispatched_qty),0) from inquiry_items it where it.inquiry_id=i.id),
      'remaining_boxes', (select coalesce(sum(greatest(it.quantity - it.dispatched_qty,0)),0) from inquiry_items it where it.inquiry_id=i.id)
    ) as row
    from inquiries i join stockists s on s.id = i.stockist_id
    where i.end_user_id in (select id from end_users where user_id = auth.uid())
  ) t;
$function$;

create or replace function public.my_inquiries()
 returns jsonb language sql stable security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
  select coalesce(jsonb_agg(row order by row->>'updated_at' desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', i.id, 'token', i.token, 'status', i.status,
      'connection_code', i.connection_code, 'customer_hint', i.customer_hint,
      'source', i.source,
      'created_at', i.created_at, 'updated_at', i.updated_at,
      'confirmed_at', i.confirmed_at, 'locked_at', i.locked_at,
      'guarantee_until', i.guarantee_until, 'accepted_at', i.accepted_at,
      'guarantee_days', i.guarantee_days,
      'end_user_id', i.end_user_id,
      'company', coalesce(e.company_name, ''), 'contact', coalesce(e.contact_person, ''),
      'phone', coalesce(e.phone, ''), 'country_code', coalesce(e.country_code, '+91'),
      'city', coalesce(e.city, ''),
      'held_boxes', (select coalesce(sum(it.held_qty),0) from inquiry_items it where it.inquiry_id=i.id),
      'line_count', (select count(*) from inquiry_items it where it.inquiry_id=i.id),
      'total_boxes', (select coalesce(sum(it.quantity),0) from inquiry_items it where it.inquiry_id=i.id),
      'designs', coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'name',d.name) order by d.name)
             from inquiry_items it join designs d on d.id=it.design_id where it.inquiry_id=i.id), '[]'::jsonb),
      'brands', coalesce((select jsonb_agg(distinct b.name)
             from inquiry_items it join designs d on d.id=it.design_id
             join catalog_designs cd on cd.library_id=d.library_id
             join stock_catalogs sc on sc.id=cd.catalog_id and sc.stockist_id=i.stockist_id
             join brands b on b.id=sc.brand_id and not b.is_default
             where it.inquiry_id=i.id), '[]'::jsonb)
    ) as row
    from inquiries i left join end_users e on e.id = i.end_user_id
    where i.stockist_id in (select id from stockists where user_id = auth.uid())
  ) t;
$function$;

create or replace function public.inquiry_detail(p_id uuid)
 returns jsonb language plpgsql stable security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
declare v_eu uuid; v_st uuid; v_lines jsonb;
begin
  select end_user_id, stockist_id into v_eu, v_st from inquiries where id = p_id;
  if v_st is null then raise exception 'Order not found'; end if;
  if not (
    v_eu in (select id from end_users where user_id = auth.uid())
    or v_st in (select id from stockists where user_id = auth.uid())
    or current_user_role() = 'admin') then
    raise exception 'Not allowed';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'design_id', d.id, 'design_name', d.name, 'size', d.size,
    'surface', d.surface_type, 'quality', d.quality,
    'image', nullif(btrim(coalesce(lib.image_url,'')),''),
    'quantity', it.quantity, 'dispatched_qty', it.dispatched_qty, 'available', d.box_quantity,
    'held', held_of(d.id), 'line_held', it.held_qty)
    order by d.name), '[]'::jsonb)
  into v_lines
  from inquiry_items it join designs d on d.id = it.design_id
  left join stockist_library lib on lib.id = d.library_id
  where it.inquiry_id = p_id;

  return (select jsonb_build_object(
    'id', i.id, 'token', i.token, 'status', i.status,
    'connection_code', i.connection_code, 'customer_hint', i.customer_hint,
    'source', i.source,
    'created_at', i.created_at, 'updated_at', i.updated_at,
    'confirmed_at', i.confirmed_at, 'locked_at', i.locked_at,
    'guarantee_until', i.guarantee_until, 'accepted_at', i.accepted_at,
    'guarantee_days', i.guarantee_days,
    'lines', v_lines)
    from inquiries i where i.id = p_id);
end;
$function$;
