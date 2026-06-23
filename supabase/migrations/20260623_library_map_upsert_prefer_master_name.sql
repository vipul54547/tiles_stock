-- Migration: library_map_upsert_prefer_master_name
--
-- WHAT CHANGED: library_map_upsert named a newly-created master after the FIRST
--   brand alias (coalesce(first_alias, master_name)), so an M mapping sheet with
--   an explicit "Master Design" column produced a master mis-named after brand-1's
--   alias (e.g. master "Bottega Cloud" instead of "CLOUD ONYX"). Found on device
--   2026-06-23 testing m_mapping.xlsx (finding #5).
--
-- FIX: prefer the explicit master (company) name; fall back to the first alias
--   only when no master name is given (T/W mapping carries no separate master, so
--   the alias IS the name — unchanged). Applied consistently in BOTH places that
--   use the name: the lookup key (v_key, step 2) and the create (step 3), so a
--   re-import still dedupes to the same master. Step 1 (link-by-existing-alias)
--   is the primary dedup and is unchanged. Also used by import_stock_batch for
--   combined sheets — same, correct behaviour there.
--
-- Verified: m_mapping.xlsx now creates masters CLOUD ONYX / DUNE BEIGE /
--   PLAIN KHAKHI with the right per-brand aliases. T/W (master == default-brand
--   alias) unchanged.

CREATE OR REPLACE FUNCTION public.library_map_upsert(p_size text, p_master_name text, p_aliases jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_stk uuid; v_id uuid;
        v_name text := btrim(coalesce(p_master_name,''));
        v_size text := btrim(coalesce(p_size,''));
        r jsonb; v_brand uuid; v_alias text;
        v_brand1 uuid; v_alias1 text; v_key text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
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

  -- 2) Else find this brand's own master by the (master-preferred) name + size.
  if v_id is null and v_brand1 is not null then
    select id into v_id from stockist_library
    where stockist_id = v_stk and brand_id = v_brand1
      and lower(master_design_name) = v_key and size = v_size
    limit 1;
  elsif v_id is null then
    select id into v_id from stockist_library
    where stockist_id = v_stk and brand_id is null
      and lower(master_design_name) = v_key and size = v_size
    limit 1;
  end if;

  -- 3) Else create with the master (company) name, under the first alias's brand.
  if v_id is null then
    insert into stockist_library (stockist_id, size, master_design_name, brand_id)
      values (v_stk, v_size, coalesce(nullif(v_name,''), v_alias1), v_brand1)
      returning id into v_id;
  end if;

  -- Attach / merge the per-brand aliases.
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
