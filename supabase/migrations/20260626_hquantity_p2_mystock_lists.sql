-- ── H_Quantity Phase 2 · P2a: wire H into my_stock + expose booking fields ──

-- my_stock: now returns held_quantity (H) and F = max(0, P - C - H).
create or replace function public.my_stock()
 returns jsonb
 language sql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', d.id, 'name', d.name, 'size', d.size, 'quality', d.quality,
    'box_quantity', d.box_quantity, 'status', d.status, 'is_sample', d.is_sample,
    'control_quantity', d.control_quantity,
    'held_quantity', held_of(d.id),
    'f_stock', greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)),
    'library_id', d.library_id, 'created_at', d.created_at, 'updated_at', d.updated_at,
    'surface_type', d.surface_type, 'stock_type', lib.stock_type,
    'tile_type', lib.tile_type, 'pieces_per_box', lib.pieces_per_box,
    'box_weight_kg', lib.box_weight_kg, 'thickness_mm', lib.thickness_mm,
    'colour', lib.colour, 'finish_label', lib.finish_label,
    'image_url', lib.image_url, 'master_design_name', lib.master_design_name,
    'brand_id', lib.brand_id,
    'stockist_key', s.sequential_id, 'stockist_priority', s.priority,
    'catalog_ids', coalesce((select jsonb_agg(cd.catalog_id)
                             from catalog_designs cd
                             join stock_catalogs c on c.id = cd.catalog_id
                             where cd.library_id = d.library_id and c.stockist_id = d.stockist_id),
                            '[]'::jsonb)
  ) order by d.created_at desc), '[]'::jsonb)
  from designs d
  join stockists s on s.id = d.stockist_id
  left join stockist_library lib on lib.id = d.library_id
  where d.stockist_id = (select id from stockists where user_id = auth.uid());
$function$;

-- my_orders (buyer): expose guarantee window + acceptance so the buyer can Accept.
create or replace function public.my_orders()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
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
      'stockist_key',  case when s.is_anonymous then s.public_code         else s.sequential_id end,
      'stockist_name', case when s.is_anonymous then s.public_display_name else s.name          end,
      'line_count', case when i.status in ('draft','sent','confirmed')
        then (select count(*) from my_choices mc join designs d on d.id=mc.design_id
               where mc.end_user_id=i.end_user_id and d.stockist_id=i.stockist_id)
        else (select count(*) from inquiry_items it where it.inquiry_id=i.id) end,
      'total_boxes', case when i.status in ('draft','sent','confirmed')
        then (select coalesce(sum(mc.quantity),0) from my_choices mc join designs d on d.id=mc.design_id
               where mc.end_user_id=i.end_user_id and d.stockist_id=i.stockist_id)
        else (select coalesce(sum(it.quantity),0) from inquiry_items it where it.inquiry_id=i.id) end
    ) as row
    from inquiries i join stockists s on s.id = i.stockist_id
    where i.end_user_id in (select id from end_users where user_id = auth.uid())
  ) t;
$function$;

-- my_inquiries (stockist): expose guarantee window + acceptance for the hub cards.
create or replace function public.my_inquiries()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(row order by row->>'updated_at' desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', i.id, 'token', i.token, 'status', i.status,
      'created_at', i.created_at, 'updated_at', i.updated_at,
      'confirmed_at', i.confirmed_at, 'locked_at', i.locked_at,
      'guarantee_until', i.guarantee_until, 'accepted_at', i.accepted_at,
      'guarantee_days', i.guarantee_days,
      'end_user_id', i.end_user_id,
      'company', e.company_name, 'contact', e.contact_person,
      'phone', e.phone, 'country_code', e.country_code, 'city', e.city,
      'line_count', case when i.status in ('draft','sent','confirmed')
        then (select count(*) from my_choices mc join designs d on d.id=mc.design_id
               where mc.end_user_id=i.end_user_id and d.stockist_id=i.stockist_id)
        else (select count(*) from inquiry_items it where it.inquiry_id=i.id) end,
      'total_boxes', case when i.status in ('draft','sent','confirmed')
        then (select coalesce(sum(mc.quantity),0) from my_choices mc join designs d on d.id=mc.design_id
               where mc.end_user_id=i.end_user_id and d.stockist_id=i.stockist_id)
        else (select coalesce(sum(it.quantity),0) from inquiry_items it where it.inquiry_id=i.id) end,
      'designs', case when i.status in ('draft','sent','confirmed')
        then coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'name',d.name) order by d.name)
               from my_choices mc join designs d on d.id=mc.design_id
               where mc.end_user_id=i.end_user_id and d.stockist_id=i.stockist_id), '[]'::jsonb)
        else coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'name',d.name) order by d.name)
               from inquiry_items it join designs d on d.id=it.design_id where it.inquiry_id=i.id), '[]'::jsonb) end,
      'brands', case when i.status in ('draft','sent','confirmed')
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
    from inquiries i join end_users e on e.id = i.end_user_id
    where i.stockist_id in (select id from stockists where user_id = auth.uid())
  ) t;
$function$;

-- inquiry_detail: header gets booking fields; lines carry per-design held (H)
-- so the dispatch screen can warn when shipping would break other commitments.
create or replace function public.inquiry_detail(p_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_eu uuid; v_st uuid; v_status text; v_lines jsonb;
begin
  select end_user_id, stockist_id, status into v_eu, v_st, v_status
  from inquiries where id = p_id;
  if v_eu is null then raise exception 'Order not found'; end if;
  if not (
    v_eu in (select id from end_users where user_id = auth.uid())
    or v_st in (select id from stockists where user_id = auth.uid())
    or current_user_role() = 'admin') then
    raise exception 'Not allowed';
  end if;

  if v_status in ('draft','sent','confirmed') then
    select coalesce(jsonb_agg(jsonb_build_object(
      'design_id', d.id, 'design_name', d.name, 'size', d.size,
      'surface', d.surface_type, 'quality', d.quality,
      'image', nullif(btrim(coalesce(lib.image_url,'')),''),
      'quantity', mc.quantity, 'dispatched_qty', 0, 'available', d.box_quantity,
      'held', held_of(d.id))
      order by d.name), '[]'::jsonb)
    into v_lines
    from my_choices mc join designs d on d.id = mc.design_id
    left join stockist_library lib on lib.id = d.library_id
    where mc.end_user_id = v_eu and d.stockist_id = v_st;
  else
    select coalesce(jsonb_agg(jsonb_build_object(
      'design_id', d.id, 'design_name', d.name, 'size', d.size,
      'surface', d.surface_type, 'quality', d.quality,
      'image', nullif(btrim(coalesce(lib.image_url,'')),''),
      'quantity', it.quantity, 'dispatched_qty', it.dispatched_qty, 'available', d.box_quantity,
      'held', held_of(d.id))
      order by d.name), '[]'::jsonb)
    into v_lines
    from inquiry_items it join designs d on d.id = it.design_id
    left join stockist_library lib on lib.id = d.library_id
    where it.inquiry_id = p_id;
  end if;

  return (select jsonb_build_object(
    'id', i.id, 'token', i.token, 'status', i.status,
    'created_at', i.created_at, 'updated_at', i.updated_at,
    'confirmed_at', i.confirmed_at, 'locked_at', i.locked_at,
    'guarantee_until', i.guarantee_until, 'accepted_at', i.accepted_at,
    'guarantee_days', i.guarantee_days,
    'lines', v_lines)
    from inquiries i where i.id = p_id);
end; $function$;
