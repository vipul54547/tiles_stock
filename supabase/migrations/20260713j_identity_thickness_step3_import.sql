-- CHAPTER 3, STEP 3 of 3 — the IMPORT declares thickness + body.
-- (docs/THICKNESS_AND_BODY_IDENTITY_PLAN.md)
--
-- ⚠️ library_map_upsert gains two parameters. `create or replace` with new defaulted params does
-- NOT replace — it creates an OVERLOAD, and the old 4-arg call then dies with 42725 (ambiguous).
-- The old signature is DROPPED in this same migration.
--
-- 🔑 The lookup problem this has to solve:
-- The 930 legacy products carry tile_type = NULL and nominal_thickness_mm = NULL. If the lookup
-- simply matched on the full key, an import that DOES supply "Ceramic / 8 mm" would fail to match
-- them and would spawn a duplicate beside every one. So the lookup ADOPTS an undeclared row and
-- fills in its blanks — the import teaches the legacy row what it is. A row that is already
-- declared as something ELSE is correctly NOT matched: it is a different product.

drop function if exists public.library_map_upsert(text, text, jsonb, text);

create or replace function public.library_map_upsert(
  p_size text,
  p_master_name text,
  p_aliases jsonb,
  p_surface text default null,
  p_tile_type text default null,
  p_thickness numeric default null)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_id uuid;
        v_name text := btrim(coalesce(p_master_name,''));
        v_size text := btrim(coalesce(p_size,''));
        v_surf text := nullif(btrim(coalesce(p_surface,'')),'');
        v_tile text := nullif(btrim(coalesce(p_tile_type,'')),'');
        v_thk  numeric;
        r jsonb; v_brand uuid; v_alias text; v_brand1 uuid; v_alias1 text; v_key text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can edit the library'; end if;
  if v_size = '' then raise exception 'Size is required'; end if;
  if v_surf is null or lower(v_surf) = 'none' then
    raise exception 'Pick a surface — every design must have one.';
  end if;

  v_thk := _nominal_thickness(p_thickness);   -- raises if it is not on the fixed list

  if p_aliases is not null and jsonb_array_length(p_aliases) > 0 then
    v_brand1 := nullif(p_aliases->0->>'brand_id','')::uuid;
    v_alias1 := btrim(coalesce(p_aliases->0->>'name',''));
  end if;
  v_key := lower(coalesce(nullif(v_name,''), v_alias1));
  if v_key = '' then raise exception 'Design name cannot be empty'; end if;

  -- 1) by a brand's alias name + size + surface (+ body/thickness when we know them).
  --    A row that is UNDECLARED (null body/thickness) is adoptable; one declared DIFFERENTLY is a
  --    different product and must not match. A fully-declared exact match wins over an adoptable one.
  if p_aliases is not null then
    for r in select * from jsonb_array_elements(p_aliases) loop
      exit when v_id is not null;
      v_brand := nullif(r->>'brand_id','')::uuid;
      v_alias := btrim(coalesce(r->>'name',''));
      if v_brand is not null and v_alias <> '' then
        select m.id into v_id from stockist_library m
          join stockist_library_brand_names a on a.library_id = m.id
         where m.stockist_id = v_stk and a.brand_id = v_brand
           and lower(a.brand_design_name) = lower(v_alias)
           and m.size = v_size and m.surface_type = v_surf
           and (v_tile is null or m.tile_type            is null or m.tile_type            = v_tile)
           and (v_thk  is null or m.nominal_thickness_mm is null or m.nominal_thickness_mm = v_thk)
         order by (m.tile_type is not null and m.nominal_thickness_mm is not null) desc,
                  m.created_at
         limit 1;
      end if;
    end loop;
  end if;

  -- 2) by the master name + size + surface (+ body/thickness), same adoption rule.
  if v_id is null then
    select id into v_id from stockist_library m
     where m.stockist_id = v_stk and lower(m.master_design_name) = v_key
       and m.size = v_size and m.surface_type = v_surf
       and (v_tile is null or m.tile_type            is null or m.tile_type            = v_tile)
       and (v_thk  is null or m.nominal_thickness_mm is null or m.nominal_thickness_mm = v_thk)
     order by (m.tile_type is not null and m.nominal_thickness_mm is not null) desc,
              m.created_at
     limit 1;
  end if;

  if v_id is null then
    insert into stockist_library (stockist_id, size, master_design_name, brand_id,
                                  surface_type, tile_type, nominal_thickness_mm)
      values (v_stk, v_size, coalesce(nullif(v_name,''), v_alias1), v_brand1,
              v_surf, v_tile, v_thk)
      returning id into v_id;
  else
    -- ADOPT: the import teaches an undeclared legacy row what it is. Only ever fills a BLANK —
    -- it must never overwrite a declared value, because that would move the product to a
    -- different identity behind the stockist's back.
    update stockist_library m
       set tile_type            = coalesce(m.tile_type,            v_tile),
           nominal_thickness_mm = coalesce(m.nominal_thickness_mm, v_thk),
           updated_at           = now()
     where m.id = v_id
       and ((m.tile_type is null and v_tile is not null)
         or (m.nominal_thickness_mm is null and v_thk is not null));
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
