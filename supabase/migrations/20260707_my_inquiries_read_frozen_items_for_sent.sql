-- Fix: the stockist inquiries list showed 0 boxes/designs for a SENT order,
-- because it read totals from the buyer's basket (my_choices) — which the
-- My-Choice↔Order split now clears on Send (lines are frozen into inquiry_items).
-- Make the basket branch fire only for a DRAFT; sent+ read the frozen items
-- (mirrors my_orders / inquiry_detail).
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
      'line_count', case when i.end_user_id is not null and i.status = 'draft'
        then (select count(*) from my_choices mc join designs d on d.id=mc.design_id
               where mc.end_user_id=i.end_user_id and d.stockist_id=i.stockist_id)
        else (select count(*) from inquiry_items it where it.inquiry_id=i.id) end,
      'total_boxes', case when i.end_user_id is not null and i.status = 'draft'
        then (select coalesce(sum(mc.quantity),0) from my_choices mc join designs d on d.id=mc.design_id
               where mc.end_user_id=i.end_user_id and d.stockist_id=i.stockist_id)
        else (select coalesce(sum(it.quantity),0) from inquiry_items it where it.inquiry_id=i.id) end,
      'designs', case when i.end_user_id is not null and i.status = 'draft'
        then coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'name',d.name) order by d.name)
               from my_choices mc join designs d on d.id=mc.design_id
               where mc.end_user_id=i.end_user_id and d.stockist_id=i.stockist_id), '[]'::jsonb)
        else coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'name',d.name) order by d.name)
               from inquiry_items it join designs d on d.id=it.design_id where it.inquiry_id=i.id), '[]'::jsonb) end,
      'brands', case when i.end_user_id is not null and i.status = 'draft'
        then coalesce((select jsonb_agg(distinct b.name)
               from my_choices mc join designs d on d.id=mc.design_id
               join catalog_designs cd on cd.library_id=d.library_id
               join stock_catalogs sc on sc.id=cd.catalog_id and sc.stockist_id=i.stockist_id
               join brands b on b.id=sc.brand_id and not b.is_default
               where mc.end_user_id=i.end_user_id and d.stockist_id=i.stockist_id), '[]'::jsonb)
        else coalesce((select jsonb_agg(distinct b.name)
               from inquiry_items it join designs d on d.id=it.design_id
               join catalog_designs cd on cd.library_id=d.library_id
               join stock_catalogs sc on sc.id=cd.catalog_id and sc.stockist_id=i.stockist_id
               join brands b on b.id=sc.brand_id and not b.is_default
               where it.inquiry_id=i.id), '[]'::jsonb) end
    ) as row
    from inquiries i left join end_users e on e.id = i.end_user_id
    where i.stockist_id in (select id from stockists where user_id = auth.uid())
  ) t;
$function$;
