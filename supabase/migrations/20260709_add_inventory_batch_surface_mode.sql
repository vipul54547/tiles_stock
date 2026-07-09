-- add_inventory_batch: route surface by the FACTORY's surface convention.
--
--   attribute  → surface is a fact of the stock run → on the HOLDING
--                (designs.surface_type), as before. Same print in two surfaces
--                = two holdings.
--   in_name    → surface is part of the print's identity → the picked value is
--                stored as the print's "Surface" Design DNA value (library_dna),
--                and the holding stays 'None'. The verbatim design_name is never
--                touched. 'None' = no change (opt-in; never wipes a prior tag).
--
-- Mode: M → stockists.surface_mode ; T/W → the entry's brand.surface_mode.
-- (project_per_brand_surface_mode / project_design_name_is_verbatim_truth)
CREATE OR REPLACE FUNCTION public.add_inventory_batch(p_entries jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  e jsonb; v_id uuid; v_count int := 0; v_boxes int := 0; v_q int;
  v_stk uuid; v_biz text; v_surf_attr uuid;
  v_lib uuid; v_brand uuid; v_mode text; v_surf text; v_hold_surf text; v_val uuid;
begin
  select id, business_type into v_stk, v_biz
    from stockists where user_id = auth.uid();
  select id into v_surf_attr from dna_attributes where lower(name) = 'surface' limit 1;

  for e in select * from jsonb_array_elements(coalesce(p_entries, '[]'::jsonb)) loop
    v_q    := greatest(coalesce((e->>'quantity')::int, 0), 0);
    v_lib  := (e->>'library_id')::uuid;
    v_brand := nullif(btrim(coalesce(e->>'brand_id', '')), '')::uuid;
    v_surf := coalesce(nullif(btrim(e->>'surface'), ''), 'None');

    -- Resolve the factory's convention for this entry.
    if v_biz = 'M' then
      select surface_mode into v_mode from stockists where id = v_stk;
    else
      select surface_mode into v_mode from brands
        where id = coalesce(v_brand, (select brand_id from stockist_library where id = v_lib));
    end if;
    v_mode := coalesce(v_mode, 'in_name');

    -- attribute keeps surface on the holding; in_name keeps the holding clean.
    v_hold_surf := case when v_mode = 'attribute' then v_surf else 'None' end;

    v_id := public.stock_add_holding(
      v_lib,
      coalesce(nullif(btrim(e->>'quality'), ''), 'Standard'),
      v_q,
      null,
      v_hold_surf,
      v_brand
    );

    -- in_name: store the picked surface as the print's Surface DNA value.
    -- 'None' is a no-op so adding stock never wipes a previously-set surface.
    if v_mode <> 'attribute' and v_surf_attr is not null
       and lower(v_surf) <> 'none' then
      select id into v_val from dna_values
        where attribute_id = v_surf_attr and lower(name) = lower(v_surf)
              and stockist_id is null
        limit 1;
      if v_val is not null then
        delete from library_dna ld using dna_values v
          where ld.value_id = v.id and ld.library_id = v_lib
                and v.attribute_id = v_surf_attr;
        insert into library_dna(library_id, value_id)
          values (v_lib, v_val) on conflict do nothing;
      end if;
    end if;

    if v_id is not null then
      v_count := v_count + 1;
      v_boxes := v_boxes + v_q;
    end if;
  end loop;
  return jsonb_build_object('count', v_count, 'boxes', v_boxes);
end;
$function$;
