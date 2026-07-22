-- 20260722i — 🔖 my_inquiries exposes book_order_id so the UI can tag a "Ready order".
--
-- A held order minted from a booked order (order-from-stock) carries inquiries.book_order_id. The
-- Inq/Ready Order screen shows a "Ready order" badge + filter for these. (MADE flow M4c)

create or replace function public.my_inquiries()
 returns jsonb
 language sql stable security definer set search_path to 'public', 'extensions', 'pg_temp'
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
      'customer_id', i.customer_id,
      'book_order_id', i.book_order_id,
      'customer_name', coalesce(sc.name, ''),
      'company', coalesce(e.company_name, ''), 'contact', coalesce(e.contact_person, ''),
      'phone', coalesce(e.phone, ''), 'country_code', coalesce(e.country_code, '+91'),
      'city', coalesce(e.city, ''),
      'held_boxes', (select coalesce(sum(it.held_qty),0) from inquiry_items it where it.inquiry_id=i.id),
      'line_count', (select count(*) from inquiry_items it where it.inquiry_id=i.id),
      'total_boxes', (select coalesce(sum(it.quantity),0) from inquiry_items it where it.inquiry_id=i.id),
      'designs', coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'name',d.name) order by d.name)
             from inquiry_items it join designs d on d.id=it.design_id where it.inquiry_id=i.id), '[]'::jsonb),
      'brands', coalesce((select jsonb_agg(distinct b.name)
             from inquiry_items it
             join designs d on d.id=it.design_id
             left join stockist_library lib on lib.id = d.library_id
             join brands b on b.id = coalesce(d.brand_id, lib.brand_id) and not b.is_default
             where it.inquiry_id=i.id), '[]'::jsonb)
    ) as row
    from inquiries i
    left join end_users e on e.id = i.end_user_id
    left join stockist_customers sc on sc.id = i.customer_id
    where i.stockist_id in (select id from stockists where user_id = auth.uid())
      and not (i.end_user_id is not null and i.status = 'draft')
  ) t;
$function$;
