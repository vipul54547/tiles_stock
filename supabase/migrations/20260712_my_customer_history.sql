-- Customer history, Phase B — the read.
--
-- "The same customer came back — what did he take last time?" Returns one saved
-- customer's dispatch history (walk-in AND order dispatches, since both now stamp
-- dispatch_notes.customer_id — Phase A), newest first, with the design lines.
--
-- Mirrors my_dispatches' join shape exactly (dispatches ⋈ designs ⋈ stockist_library),
-- NOT inquiry_items: a walk-in has no inquiry_items and dispatch is the truth.
-- Scoped: the customer must belong to the caller's own stockist. my_ prefix.
-- (docs/CUSTOMER_HISTORY_PLAN.md)

create or replace function public.my_customer_history(p_customer_id uuid)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  with cust as (
    select c.*
    from stockist_customers c
    where c.id = p_customer_id
      and c.stockist_id in (select id from stockists where user_id = auth.uid())
  ),
  notes as (
    select dn.*
    from dispatch_notes dn
    where dn.customer_id = p_customer_id
      and dn.stockist_id in (select id from stockists where user_id = auth.uid())
  )
  select case
    when not exists (select 1 from cust) then null   -- not yours / not found
    else jsonb_build_object(
      'customer', (select jsonb_build_object(
          'id', id, 'name', name, 'phone', phone, 'country_code', country_code,
          'city', city, 'district', district, 'state', state, 'pincode', pincode)
        from cust),
      'summary', jsonb_build_object(
          'dispatch_count', (select count(*) from notes),
          'total_boxes', (select coalesce(sum(dp.quantity_dispatched), 0)
                          from dispatches dp
                          where dp.dispatch_note_id in (select id from notes)),
          'last_dispatched_on', (select max(dispatched_on) from notes)),
      'dispatches', coalesce((
        select jsonb_agg(row order by row->>'dispatched_on' desc, row->>'created_at' desc)
        from (
          select jsonb_build_object(
            'id', dn.id, 'dispatch_no', dn.dispatch_no, 'dispatched_on', dn.dispatched_on,
            'created_at', dn.created_at, 'invoice_no', dn.invoice_no, 'vehicle_no', dn.vehicle_no,
            'transporter', dn.transporter, 'note', dn.note, 'token', i.token,
            'total_boxes', (select coalesce(sum(dp.quantity_dispatched), 0)
                            from dispatches dp where dp.dispatch_note_id = dn.id),
            'lines', (
              select coalesce(jsonb_agg(jsonb_build_object(
                'design_id', d.id,
                'design_name', d.name,                 -- verbatim, per-brand name
                'size', d.size,
                'brand', br.name,
                'quality', d.quality,
                'surface_label', d.surface_label,      -- Word …
                'surface_type', d.surface_type,        -- … (Canonical)
                'image', nullif(btrim(coalesce(lib.image_url,'')),''),
                'quantity', dp.quantity_dispatched) order by d.name), '[]'::jsonb)
              from dispatches dp
              join designs d on d.id = dp.design_id
              left join stockist_library lib on lib.id = d.library_id
              left join brands br on br.id = d.brand_id
              where dp.dispatch_note_id = dn.id)
          ) as row
          from notes dn
          left join inquiries i on i.id = dn.inquiry_id
        ) t), '[]'::jsonb)
    )
  end;
$function$;
