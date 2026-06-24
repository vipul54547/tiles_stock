-- M identity redesign — core #7 fix (DDPI implementation, branch feat/m-identity-redesign).
-- Make library_map_upsert TYPE-AWARE so M is brand-agnostic:
--   • M  : a tile is ONE box across ALL its brands. Match the master by name+size
--          regardless of brand_id; brand lives only in the alias junction. New M
--          boxes are created with brand_id = NULL. (This dissolves bug #7 — the
--          ENTRY/mapping import no longer creates a duplicate master per brand.)
--   • T/W: unchanged — brand-scoped silo (same name under another brand = a
--          different design).
-- Reversible: re-apply 20260623_library_map_upsert_prefer_master_name.sql to revert.
-- See docs/M_IDENTITY_REDESIGN_PLAN.md + memory project_addflow_redesign_ddpi.

CREATE OR REPLACE FUNCTION public.library_map_upsert(p_size text, p_master_name text, p_aliases jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_stk uuid; v_id uuid; v_type text;
        v_name text := btrim(coalesce(p_master_name,''));
        v_size text := btrim(coalesce(p_size,''));
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
        limit 1;
      end if;
    end loop;
  end if;

  -- 2) Else find the master by (master-preferred) name + size.
  --    M  = brand-AGNOSTIC (one tile is one box across ALL its brands). #7 fix.
  --    T/W = brand-scoped silo.
  if v_id is null then
    if v_type = 'M' then
      select id into v_id from stockist_library
      where stockist_id = v_stk
        and lower(master_design_name) = v_key and size = v_size
      order by created_at        -- deterministic: oldest existing box wins
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
  if v_id is null then
    insert into stockist_library (stockist_id, size, master_design_name, brand_id)
      values (v_stk, v_size, coalesce(nullif(v_name,''), v_alias1),
              case when v_type = 'M' then null else v_brand1 end)
      returning id into v_id;
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
