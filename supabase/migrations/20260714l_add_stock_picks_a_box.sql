-- ═══ STEP 7 of docs/PACKING_BOX_HOLD_PLAN.md — ADD STOCK PICKS A BOX ══════════════════════════
--
--   ARTWORK → TILE → PACKING → BOX → **HOLD**
--
-- 🔢 A HOLD is boxes of a BOX — a packing in a brand's cover. Step 3 made `designs.box_id` the
-- truth, but Add Stock still could not SAY which box: it silently used the tile's first packing.
--
--     TEN BOXES OF A 5-PIECE PACKING AND TEN OF A 4-PIECE PACKING
--     ARE NOT THE SAME AMOUNT OF TILE.
--
-- So the entry has to carry the packing. `stock_add_holding` already takes p_packing_id (step 3);
-- this hands it through the batch call the Add Stock screen actually uses.
--
-- Null = the tile's FIRST packing, which is the overwhelmingly common case (one tile, one packing)
-- and keeps every other caller working untouched.
CREATE OR REPLACE FUNCTION public.add_inventory_batch(p_entries jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  e jsonb; v_id uuid; v_count int := 0; v_boxes int := 0; v_q int;
  v_stk uuid; v_lib uuid; v_brand uuid; v_surf text; v_label text;
  v_packing uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;

  for e in select * from jsonb_array_elements(coalesce(p_entries, '[]'::jsonb)) loop
    v_q     := greatest(coalesce((e->>'quantity')::int, 0), 0);
    v_lib   := (e->>'library_id')::uuid;
    v_brand := nullif(btrim(coalesce(e->>'brand_id', '')), '')::uuid;
    -- null (not 'None') = "the product knows its own surface"
    v_surf  := nullif(btrim(coalesce(e->>'surface','')), '');
    if lower(coalesce(v_surf,'')) = 'none' then v_surf := null; end if;
    v_label := nullif(btrim(coalesce(e->>'surface_label','')), '');

    -- 📦 WHICH PACKING is he holding? Ten boxes of a 5-piece packing and ten of a 4-piece packing
    -- are not the same amount of tile, so the box he counts must say which. Null = the tile's first
    -- packing (the overwhelmingly common case: one tile, one packing).
    v_packing := nullif(btrim(coalesce(e->>'packing_id','')), '')::uuid;

    v_id := public.stock_add_holding(
      v_lib,
      coalesce(nullif(btrim(e->>'quality'), ''), 'Standard'),
      v_q, null, v_surf, v_brand, v_label, v_packing);

    if v_id is not null then
      v_count := v_count + 1;
      v_boxes := v_boxes + v_q;
    end if;
  end loop;
  return jsonb_build_object('count', v_count, 'boxes', v_boxes);
end; $function$
;
