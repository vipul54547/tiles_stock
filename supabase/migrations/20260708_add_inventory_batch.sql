-- Batch manual stock entry: the stockist builds a list of {design, brand,
-- quality, quantity} rows and commits them together. Each row reuses the
-- verified stock_add_holding (which finds-or-creates the per-brand holding and
-- bumps P_Stock via add_stock). NO stock list — adding stock only touches
-- P_Stock; list membership is a separate concern (user decision 2026-07-08).
-- Atomic: the whole batch commits or fails as one transaction.
create or replace function public.add_inventory_batch(p_entries jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  e jsonb; v_id uuid; v_count int := 0; v_boxes int := 0; v_q int;
begin
  for e in select * from jsonb_array_elements(coalesce(p_entries, '[]'::jsonb)) loop
    v_q := greatest(coalesce((e->>'quantity')::int, 0), 0);
    v_id := public.stock_add_holding(
      (e->>'library_id')::uuid,
      coalesce(nullif(btrim(e->>'quality'), ''), 'Standard'),
      v_q,
      null,                                             -- no stock list (P_Stock only)
      coalesce(nullif(btrim(e->>'surface'), ''), 'None'),
      nullif(btrim(coalesce(e->>'brand_id', '')), '')::uuid
    );
    if v_id is not null then
      v_count := v_count + 1;
      v_boxes := v_boxes + v_q;
    end if;
  end loop;
  return jsonb_build_object('count', v_count, 'boxes', v_boxes);
end;
$function$;

grant execute on function public.add_inventory_batch(jsonb) to authenticated;
