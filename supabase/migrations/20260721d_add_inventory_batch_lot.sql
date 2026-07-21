-- 20260721d — 🧱 LOT L2 (cont.): the BATCH stock-add grid carries batch + location per row.
--
-- The real Add-Stock screen is the grid (add_stock_batch_screen), which saves through
-- add_inventory_batch — not the single add form. It loops stock_add_holding (now 10-arg), so each
-- entry just reads its own batch + location_id and passes them down. (docs/LOT_LAYER_PLAN.md)

create or replace function public.add_inventory_batch(p_entries jsonb)
 returns jsonb
 language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  e jsonb; v_id uuid; v_count int := 0; v_boxes int := 0; v_q int;
  v_stk uuid; v_lib uuid; v_brand uuid; v_surf text; v_label text;
  v_packing uuid; v_batch text; v_loc uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;

  for e in select * from jsonb_array_elements(coalesce(p_entries, '[]'::jsonb)) loop
    v_q     := greatest(coalesce((e->>'quantity')::int, 0), 0);
    v_lib   := (e->>'library_id')::uuid;
    v_brand := nullif(btrim(coalesce(e->>'brand_id', '')), '')::uuid;
    v_surf  := nullif(btrim(coalesce(e->>'surface','')), '');
    if lower(coalesce(v_surf,'')) = 'none' then v_surf := null; end if;
    v_label := nullif(btrim(coalesce(e->>'surface_label','')), '');
    v_packing := nullif(btrim(coalesce(e->>'packing_id','')), '')::uuid;
    v_batch := nullif(btrim(coalesce(e->>'batch','')), '');
    v_loc   := nullif(btrim(coalesce(e->>'location_id','')), '')::uuid;

    v_id := public.stock_add_holding(
      v_lib,
      coalesce(nullif(btrim(e->>'quality'), ''), 'Standard'),
      v_q, null, v_surf, v_brand, v_label, v_packing, v_batch, v_loc);

    if v_id is not null then
      v_count := v_count + 1;
      v_boxes := v_boxes + v_q;
    end if;
  end loop;
  return jsonb_build_object('count', v_count, 'boxes', v_boxes);
end $function$;
