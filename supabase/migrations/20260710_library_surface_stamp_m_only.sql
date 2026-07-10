-- The Excel importer was stamping the surface onto the LIBRARY row. Same bug as
-- 20260710_tw_no_surface_mode_and_last_surface.sql fixed in add_inventory_batch,
-- but on the import path, which goes through library_map_upsert instead.
-- (project_per_brand_surface_mode)
--
-- Surface is deliberately NOT part of a print's identity key, so all three rows
-- of livok's "DELTON_8_A" (RAINDROP / Matt / Carv) resolve to ONE library row.
-- Each row then ran:
--
--   elsif v_surf <> 'none' then
--     -- Surface is an attribute -- the imported value wins (data is authoritative)
--     update stockist_library set surface_type = ...
--
-- Last row wins. One print stocked in three surfaces ended up with an identity
-- of 'Carving'. That comment is a fossil of the superseded model in which the
-- surface WAS part of identity.
--
-- The holdings were always correct: six rows, one per quality x surface, each
-- carrying its own surface_type + surface_label. Only identity was wrong.
--
-- Fix, matching add_inventory_batch: stamp the library for M only. An M writes
-- the surface into the design NAME, so a different surface is a different print
-- and a different library row -- stamping identity is right there. A T/W holds
-- one print in many surfaces at once, so its library row must carry none.
--
-- Only the 4-arg overload (the one taking p_surface) is touched.

CREATE OR REPLACE FUNCTION public.library_map_upsert(p_size text, p_master_name text, p_aliases jsonb, p_surface text DEFAULT 'None'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_stk uuid; v_id uuid; v_type text;
        v_name text := btrim(coalesce(p_master_name,''));
        v_size text := btrim(coalesce(p_size,''));
        v_surf text := lower(coalesce(nullif(btrim(p_surface),''),'none'));
        r jsonb; v_brand uuid; v_alias text;
        v_brand1 uuid; v_alias1 text; v_key text;
begin
  select id, business_type into v_stk, v_type from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can edit the library'; end if;
  if v_size = '' then raise exception 'Size is required'; end if;

  if p_aliases is not null and jsonb_array_length(p_aliases) > 0 then
    v_brand1 := nullif(p_aliases->0->>'brand_id','')::uuid;
    v_alias1 := btrim(coalesce(p_aliases->0->>'name',''));
  end if;
  v_key := lower(coalesce(nullif(v_name,''), v_alias1));
  if v_key = '' then raise exception 'Design name cannot be empty'; end if;

  -- Match by an existing brand-alias name (name+size); surface is NOT a key.
  if p_aliases is not null then
    for r in select * from jsonb_array_elements(p_aliases) loop
      exit when v_id is not null;
      v_brand := nullif(r->>'brand_id','')::uuid;
      v_alias := btrim(coalesce(r->>'name',''));
      if v_brand is not null and v_alias <> '' then
        select m.id into v_id from stockist_library m
        join stockist_library_brand_names a on a.library_id = m.id
        where m.stockist_id = v_stk and a.brand_id = v_brand
          and lower(a.brand_design_name) = lower(v_alias) and m.size = v_size
        order by m.created_at
        limit 1;
      end if;
    end loop;
  end if;

  if v_id is null then
    if v_type = 'M' then
      -- M: brand-agnostic, keyed by name+size only.
      select id into v_id from stockist_library
      where stockist_id = v_stk
        and lower(master_design_name) = v_key and size = v_size
      order by created_at
      limit 1;
    elsif v_brand1 is not null then
      select id into v_id from stockist_library
      where stockist_id = v_stk and brand_id = v_brand1
        and lower(master_design_name) = v_key and size = v_size
      limit 1;
    else
      select id into v_id from stockist_library
      where stockist_id = v_stk and brand_id is null
        and lower(master_design_name) = v_key and size = v_size
      limit 1;
    end if;
  end if;

  if v_id is null then
    -- New print. Only an M carries a surface on identity (it is in the name).
    insert into stockist_library (stockist_id, size, master_design_name, brand_id, surface_type)
      values (v_stk, v_size, coalesce(nullif(v_name,''), v_alias1),
              case when v_type = 'M' then null else v_brand1 end,
              case when v_type = 'M'
                   then coalesce(nullif(btrim(p_surface),''),'None')
                   else 'None' end)
      returning id into v_id;
  elsif v_type = 'M' and v_surf <> 'none' then
    -- M only: a different surface is a different print, so the imported value is
    -- authoritative for identity. NEVER for T/W -- one print, many surfaces on
    -- the shelf, and the last imported row would silently rewrite the print.
    update stockist_library
       set surface_type = coalesce(nullif(btrim(p_surface),''),'None')
     where id = v_id;
  end if;

  if p_aliases is not null then
    for r in select * from jsonb_array_elements(p_aliases) loop
      v_brand := nullif(r->>'brand_id','')::uuid;
      v_alias := btrim(coalesce(r->>'name',''));
      if v_alias <> '' and v_brand is not null
         and exists (select 1 from brands where id = v_brand and stockist_id = v_stk) then
        insert into stockist_library_brand_names (library_id, brand_id, brand_design_name)
          values (v_id, v_brand, v_alias)
          on conflict (library_id, brand_id) do update set brand_design_name = excluded.brand_design_name;
      end if;
    end loop;
  end if;
  return v_id;
end; $function$;

-- Repair the rows the old code stamped. T/W library rows carry no surface.
-- 18 rows on 2026-07-10, all livok ceramic (Carving, Glossy, Matt, Rustic,
-- Satin, Sugar). No holding is touched -- the stock rows were always correct.
update stockist_library lib
   set surface_type = 'None', surface_label = null
  from stockists s
 where s.id = lib.stockist_id
   and s.business_type <> 'M'
   and (coalesce(nullif(btrim(lib.surface_type),''),'None') <> 'None'
        or lib.surface_label is not null);
