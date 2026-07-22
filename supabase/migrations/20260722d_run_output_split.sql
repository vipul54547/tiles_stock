-- 20260722d — 🏭 MADE flow (Phase 3 support): split each run box's made into Premium / Standard.
--
-- The Production POSITION page shows, per design: Program (planned) · Premium made · Standard made.
-- my_production_runs already carries target + total made per box; add the two grade sub-totals so the
-- position reads straight off the same call. (docs/PRODUCTION_REDESIGN_PLAN.md §Phase 3)

create or replace function public.my_production_runs()
 returns jsonb
 language sql stable security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(row order by row->>'created_at' desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', r.id, 'name', r.name, 'status', r.status, 'note', coalesce(r.note,''),
      'created_at', r.created_at, 'closed_at', r.closed_at,
      'target_boxes', (select coalesce(sum(b.target_boxes),0)
                         from production_run_boxes b where b.run_id = r.id),
      'made_boxes', (select coalesce(sum(o.boxes),0)
                       from production_run_output o where o.run_id = r.id),
      'customers', coalesce((select jsonb_agg(distinct coalesce(c.name,
                                nullif(btrim(coalesce(bo.customer_hint,'')),''),'Walk-in'))
                       from production_run_demand d
                       join book_order_lines bl on bl.id = d.book_order_line_id
                       join book_orders bo on bo.id = bl.order_id
                       left join stockist_customers c on c.id = bo.customer_id
                      where d.run_id = r.id), '[]'::jsonb),
      'boxes', coalesce((select jsonb_agg(jsonb_build_object(
                    'box_id', b.box_id,
                    'cover_word', coalesce(nullif(btrim(coalesce(bn.brand_design_name,'')),''), pm.print_name),
                    'brand', br.name, 'surface', lib.surface_type, 'size', pm.size,
                    'pieces', pk.pieces,
                    'target', b.target_boxes,
                    'made', (select coalesce(sum(o.boxes),0) from production_run_output o
                              where o.run_id = r.id and o.box_id = b.box_id),
                    'premium_made', (select coalesce(sum(o.boxes),0) from production_run_output o
                              where o.run_id = r.id and o.box_id = b.box_id and o.quality = 'Premium'),
                    'standard_made', (select coalesce(sum(o.boxes),0) from production_run_output o
                              where o.run_id = r.id and o.box_id = b.box_id and o.quality = 'Standard'))
                    order by pm.print_name)
                  from production_run_boxes b
                  join boxes bx on bx.id = b.box_id
                  join packings pk on pk.id = bx.packing_id
                  join stockist_library lib on lib.id = pk.library_id
                  join print_master pm on pm.id = lib.print_id
                  join brands br on br.id = bx.brand_id
                  left join stockist_library_brand_names bn
                         on bn.library_id = lib.id and bn.brand_id = bx.brand_id
                 where b.run_id = r.id), '[]'::jsonb)
    ) as row
    from production_runs r
    where r.stockist_id in (select id from stockists where user_id = auth.uid())
  ) t;
$function$;
