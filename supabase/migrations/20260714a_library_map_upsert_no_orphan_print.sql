-- library_map_upsert: an ALIAS HIT must not mint a rival PRINT.
--
-- The alias lookup exists precisely to catch "the same tile sold under two names": brand Y's
-- stamped word `CARRARA GOLD` resolves to the product whose print is already named `1001`.
-- That product ALREADY OWNS A PRINT. But the function then ran
--
--     v_print := print_upsert(v_stk, v_key, v_size, null);   -- unconditionally
--
-- and, having found v_id by alias, never pointed anything at the print it had just created.
-- Result: a second print_master row for ONE artwork, orphaned (no product), squatting on the
-- name `CARRARA GOLD` at that size. Verified against the live DB: an alias-hit row carrying a
-- different master name took livok's prints 43 → 44 and left 1 orphan.
--
-- This is exactly the forgery the model forbids — the BOX's word (`brand_design_name`, the
-- factory's, per-brand) becoming a PRINT's word (`print_name`, the stockist's own). The print
-- is the top of the identity chain, so the damage runs all the way down.
--
-- FIX: find-or-create the print ONLY when the alias did not already resolve a product. When it
-- did, inherit that product's print_id. The alias then lands as a BOX on the existing product,
-- which is what an alias hit means.
--
-- Nothing else changes. Same signature (no overload); the fall-back `v_key` and the surface /
-- tile_type / adoption / box behaviour are untouched.

CREATE OR REPLACE FUNCTION public.library_map_upsert(
  p_size text, p_master_name text, p_aliases jsonb,
  p_surface text DEFAULT NULL::text, p_tile_type text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_stk uuid; v_id uuid; v_print uuid;
        v_name text := btrim(coalesce(p_master_name,''));
        v_size text := btrim(coalesce(p_size,''));
        v_surf text := nullif(btrim(coalesce(p_surface,'')),'');
        v_tile text := nullif(btrim(coalesce(p_tile_type,'')),'');
        r jsonb; v_brand uuid; v_alias text; v_brand1 uuid; v_alias1 text; v_key text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can edit the library'; end if;
  if v_size = '' then raise exception 'Size is required'; end if;
  if v_surf is null or lower(v_surf) = 'none' then
    raise exception 'Pick a surface — every design must have one.';
  end if;

  if p_aliases is not null and jsonb_array_length(p_aliases) > 0 then
    v_brand1 := nullif(p_aliases->0->>'brand_id','')::uuid;
    v_alias1 := btrim(coalesce(p_aliases->0->>'name',''));
  end if;
  v_key := coalesce(nullif(v_name,''), v_alias1);
  if coalesce(btrim(v_key),'') = '' then raise exception 'Design name cannot be empty'; end if;

  -- A brand's stamped name can find an EXISTING product of a DIFFERENT print (the same tile sold
  -- under two names), so the alias lookup still comes first.
  if p_aliases is not null then
    for r in select * from jsonb_array_elements(p_aliases) loop
      exit when v_id is not null;
      v_brand := nullif(r->>'brand_id','')::uuid;
      v_alias := btrim(coalesce(r->>'name',''));
      if v_brand is not null and v_alias <> '' then
        select m.id into v_id from stockist_library m
          join stockist_library_brand_names a on a.library_id = m.id
          join print_master p on p.id = m.print_id
         where m.stockist_id = v_stk and a.brand_id = v_brand
           and lower(a.brand_design_name) = lower(v_alias)
           and p.size = v_size and m.surface_type = v_surf
           and (v_tile is null or m.tile_type is null or m.tile_type = v_tile)
         order by (m.tile_type is not null) desc, m.created_at
         limit 1;
      end if;
    end loop;
  end if;

  if v_id is not null then
    -- ALIAS HIT. This product already owns the print for this artwork, and the incoming word is
    -- the BOX's, not the print's. Inherit — minting one from v_key would forge a rival print and
    -- orphan it.
    select m.print_id into v_print from stockist_library m where m.id = v_id;
  else
    -- No product yet. NOW the print is found-or-created: a print with no product is legal, and
    -- this is the row that owns the name, the size and the photo from here on.
    v_print := print_upsert(v_stk, v_key, v_size, null);

    select m.id into v_id from stockist_library m
     where m.stockist_id = v_stk and m.print_id = v_print and m.surface_type = v_surf
       and (v_tile is null or m.tile_type is null or m.tile_type = v_tile)
     order by (m.tile_type is not null) desc, m.created_at
     limit 1;
  end if;

  if v_id is null then
    insert into stockist_library (stockist_id, print_id, brand_id, surface_type, tile_type)
      values (v_stk, v_print, v_brand1, v_surf, v_tile)
      returning id into v_id;
  else
    -- ADOPTION: fill a BLANK body only; never overwrite a declared one.
    update stockist_library m
       set tile_type = coalesce(m.tile_type, v_tile), updated_at = now()
     where m.id = v_id and m.tile_type is null and v_tile is not null;
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
