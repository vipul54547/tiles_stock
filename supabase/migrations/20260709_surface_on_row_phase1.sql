-- Phase 1: surface lives ON THE STOCK ROW (holding), not in DNA.
--
-- Decision (2026-07-09): surface must be present at add → select → dispatch, so
-- it belongs on the holding (designs.surface_type), like attribute mode already
-- does. For in_name it is ALSO a fixed property of the design: mapped once, then
-- auto-filled every time. So we remember it on the print (stockist_library
-- .surface_type) and copy it onto each holding. DNA is no longer used for surface.
-- (project_per_brand_surface_mode / project_design_name_is_verbatim_truth)

-- 1) Move any "Surface" DNA tags onto the print's surface_type (the in_name map),
--    then drop those DNA tags — surface is a row/print attribute now, not DNA.
update stockist_library l
set surface_type = sv.name
from library_dna ld
join dna_values sv on sv.id = ld.value_id
join dna_attributes a on a.id = sv.attribute_id and lower(a.name) = 'surface'
where ld.library_id = l.id
  and coalesce(nullif(btrim(l.surface_type), ''), 'None') = 'None';

delete from library_dna ld
using dna_values sv, dna_attributes a
where ld.value_id = sv.id and sv.attribute_id = a.id and lower(a.name) = 'surface';

-- 2) add_inventory_batch: surface always lands on the holding; in_name also
--    remembers it on the print for auto-fill. 'None' never wipes a saved map.
CREATE OR REPLACE FUNCTION public.add_inventory_batch(p_entries jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  e jsonb; v_id uuid; v_count int := 0; v_boxes int := 0; v_q int;
  v_stk uuid; v_biz text;
  v_lib uuid; v_brand uuid; v_mode text; v_surf text;
begin
  select id, business_type into v_stk, v_biz
    from stockists where user_id = auth.uid();

  for e in select * from jsonb_array_elements(coalesce(p_entries, '[]'::jsonb)) loop
    v_q    := greatest(coalesce((e->>'quantity')::int, 0), 0);
    v_lib  := (e->>'library_id')::uuid;
    v_brand := nullif(btrim(coalesce(e->>'brand_id', '')), '')::uuid;
    v_surf := coalesce(nullif(btrim(e->>'surface'), ''), 'None');

    if v_biz = 'M' then
      select surface_mode into v_mode from stockists where id = v_stk;
    else
      select surface_mode into v_mode from brands
        where id = coalesce(v_brand, (select brand_id from stockist_library where id = v_lib));
    end if;
    v_mode := coalesce(v_mode, 'in_name');

    -- Surface always on the stock row (so it shows at select + dispatch).
    v_id := public.stock_add_holding(
      v_lib,
      coalesce(nullif(btrim(e->>'quality'), ''), 'Standard'),
      v_q, null, v_surf, v_brand);

    -- in_name: remember the surface on the print so it auto-fills next time.
    if v_mode <> 'attribute' and lower(v_surf) <> 'none' then
      update stockist_library set surface_type = v_surf
        where id = v_lib and stockist_id = v_stk;
    end if;

    if v_id is not null then
      v_count := v_count + 1;
      v_boxes := v_boxes + v_q;
    end if;
  end loop;
  return jsonb_build_object('count', v_count, 'boxes', v_boxes);
end;
$function$;
