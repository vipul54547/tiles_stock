-- Command Center hardening #2: a stockist sees only SENT orders, never a buyer's
-- private My-Choice basket. The buyer's basket auto-creates a DRAFT inquiry (via
-- trg_my_choices_sync_inquiry) the moment they bookmark — that is a still-being-
-- assembled shopping list, not an order, and must stay private until the buyer
-- Sends it. Only buyer baskets are ever 'draft' (stockist/web orders start
-- 'sent'), so we hide exactly `end_user_id is not null and status = 'draft'`.
-- With drafts gone, every returned row reads its frozen inquiry_items (the old
-- draft-basket branches are now dead) → simplified out.
create or replace function public.my_inquiries()
 returns jsonb
 language sql
 stable security definer
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
      and not (i.end_user_id is not null and i.status = 'draft')
  ) t;
$function$;

grant execute on function public.my_inquiries() to authenticated;
