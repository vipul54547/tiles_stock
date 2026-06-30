-- Phase E — make inquiry_detail null-buyer-safe (stockist/web orders have no
-- end_user). Not-found guard keys off the row/stockist, and an open no-buyer
-- order reads its items (not the absent my_choices basket).
-- (project_dispatch_order_redesign)
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
  if v_st is null then raise exception 'Order not found'; end if;
  if not (
    v_eu in (select id from end_users where user_id = auth.uid())
    or v_st in (select id from stockists where user_id = auth.uid())
    or current_user_role() = 'admin') then
    raise exception 'Not allowed';
  end if;

  if v_eu is not null and v_status in ('draft','sent','confirmed') then
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
