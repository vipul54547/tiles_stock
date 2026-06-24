-- M identity redesign — POLISH: make library_map_upsert SURFACE-AWARE.
-- (DDPI implementation; follows 20260624_library_map_upsert_type_aware_brand_agnostic.sql.)
--
-- Locked M model: a box = master + surface. So the same master_design_name+size
-- in two different surfaces is TWO boxes (e.g. CLOUD ONYX Matt vs Glossy). This
-- adds p_surface to the matcher and the box identity key for M.
--
-- Safety — 'None' surface is a WILDCARD that ABSORBS, never splits:
--   • an existing box with surface 'None' matches ANY incoming surface (and gets
--     its surface filled in), and an incoming 'None' matches ANY existing box.
--   • only two DIFFERENT, both-real surfaces produce two boxes.
--   This prevents a re-import (real surface) from spawning a phantom sibling of a
--   box that was created surface-less (the historic/back-compat path).
--
-- T/W: matching is left byte-for-byte UNCHANGED (brand-scoped, no surface in the
-- key — surface is welded to their design, only quality splits stock). New boxes
-- and surface-less boxes still get their surface recorded (harmless fill).
--
-- Signature changes (3 -> 4 args) so the old function is DROPped first.
-- Reversible: re-apply 20260624_library_map_upsert_type_aware_brand_agnostic.sql
-- (and 20260622_import_stock_batch_dna_merge.sql) to revert.

DROP FUNCTION IF EXISTS public.library_map_upsert(text, text, jsonb);

CREATE OR REPLACE FUNCTION public.library_map_upsert(
  p_size text, p_master_name text, p_aliases jsonb, p_surface text DEFAULT 'None')
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
  -- Prefer the explicit master (company) name; fall back to the first brand alias
  -- (T/W mapping carries no separate master, so the alias is the name).
  v_key := lower(coalesce(nullif(v_name,''), v_alias1));
  if v_key = '' then raise exception 'Design name cannot be empty'; end if;

  -- 1) LINK: reuse a master if ANY provided alias (brand+name+size) already exists.
  --    For M the surface must be COMPATIBLE ('None' on either side = wildcard).
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
          and (v_type <> 'M'
               or lower(coalesce(nullif(btrim(m.surface_type),''),'none')) = v_surf
               or lower(coalesce(nullif(btrim(m.surface_type),''),'none')) = 'none'
               or v_surf = 'none')
        order by (lower(coalesce(nullif(btrim(m.surface_type),''),'none')) = v_surf) desc,
                 m.created_at
        limit 1;
      end if;
    end loop;
  end if;

  -- 2) Else find the master by (master-preferred) name + size.
  --    M  = brand-AGNOSTIC + SURFACE-AWARE (box = master + surface). #7 fix.
  --    T/W = brand-scoped silo (surface NOT in the key — unchanged).
  if v_id is null then
    if v_type = 'M' then
      select id into v_id from stockist_library
      where stockist_id = v_stk
        and lower(master_design_name) = v_key and size = v_size
        and (lower(coalesce(nullif(btrim(surface_type),''),'none')) = v_surf
             or lower(coalesce(nullif(btrim(surface_type),''),'none')) = 'none'
             or v_surf = 'none')
      order by (lower(coalesce(nullif(btrim(surface_type),''),'none')) = v_surf) desc,
               created_at        -- prefer an exact-surface box, then oldest
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

  -- 3) Else create. M boxes are brand-AGNOSTIC (brand_id NULL); T/W are brand-bound.
  --    Record the surface on the box for both.
  if v_id is null then
    insert into stockist_library (stockist_id, size, master_design_name, brand_id, surface_type)
      values (v_stk, v_size, coalesce(nullif(v_name,''), v_alias1),
              case when v_type = 'M' then null else v_brand1 end,
              coalesce(nullif(btrim(p_surface),''),'None'))
      returning id into v_id;
  elsif v_surf <> 'none' then
    -- Matched a surface-less box with a real incoming surface → FILL it (never
    -- overwrite an existing real surface).
    update stockist_library
       set surface_type = coalesce(nullif(btrim(p_surface),''),'None')
     where id = v_id
       and lower(coalesce(nullif(btrim(surface_type),''),'none')) = 'none';
  end if;

  -- Attach / merge the per-brand aliases (the N:M brand-names layer).
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
