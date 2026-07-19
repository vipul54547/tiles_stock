-- ═══ Series defaults to "Regular" · clean the orphan Punch Type ═══════════════════════════════
--
-- 1) A new design should read "Regular", not blank/None — Series has a default, and it is Regular.
--    tile_add now tags the admin "Regular" onto every NEW tile (never on adoption of an existing
--    one, which keeps whatever series it already has).
-- 2) An orphan Punch Type value ("Wave", stockist-owned, no parent) survived from before Punch
--    Type became a value-list. Under the value-list model a parent-less Punch Type is meaningless,
--    so drop it and its one tag.

-- ── 1. orphan Punch Type cleanup (parent-less stockist values) ──────────────────────────────
delete from library_dna ld
 using dna_values v join dna_attributes a on a.id = v.attribute_id
 where ld.value_id = v.id and a.name = 'Punch Type'
   and v.stockist_id is not null and v.parent_value_id is null;

delete from dna_values v
 using dna_attributes a
 where v.attribute_id = a.id and a.name = 'Punch Type'
   and v.stockist_id is not null and v.parent_value_id is null;

-- ── 2. tile_add seeds Series = Regular on a NEW tile ────────────────────────────────────────
create or replace function public.tile_add(
  p_print_id uuid, p_surface text, p_tile_type text default null::text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_id uuid; v_new boolean := false; v_series uuid;
        v_surf text := nullif(btrim(coalesce(p_surface,'')),'');
        v_body text := nullif(btrim(coalesce(p_tile_type,'')),'');
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;

  if not exists (select 1 from print_master
                  where id = p_print_id and stockist_id = v_stk) then
    raise exception 'That artwork is not yours';
  end if;

  -- 🚫 Surface is IDENTITY and it is compulsory. It is never guessed and never defaulted: a wrong
  -- one forges a different tile. He is standing right here, so he says it.
  if v_surf is null or lower(v_surf) = 'none' then
    raise exception 'Pick a surface — every design has one, and it is part of what the design IS.';
  end if;

  select id into v_id from stockist_library
   where stockist_id = v_stk and print_id = p_print_id and surface_type = v_surf
     and (v_body is null or tile_type is null or tile_type = v_body)
   order by (tile_type is not null) desc, created_at
   limit 1;

  if v_id is null then
    insert into stockist_library (stockist_id, print_id, surface_type, tile_type)
      values (v_stk, p_print_id, v_surf, v_body)
      returning id into v_id;
    v_new := true;
  else
    -- ADOPTION: fill a blank body, never overwrite a declared one.
    update stockist_library m
       set tile_type = coalesce(m.tile_type, v_body), updated_at = now()
     where m.id = v_id and m.tile_type is null and v_body is not null;
  end if;

  -- Series defaults to "Regular" on a NEW design (the admin canonical, so no duplicate is minted).
  if v_new then
    select v.id into v_series
      from dna_values v join dna_attributes a on a.id = v.attribute_id
     where a.name = 'Series' and v.stockist_id is null and lower(v.name) = 'regular'
     limit 1;
    if v_series is not null then
      insert into library_dna (library_id, value_id) values (v_id, v_series)
      on conflict do nothing;
    end if;
  end if;

  return v_id;
end $function$;

-- ── 3. self-check (raise only on FAILURE) ───────────────────────────────────────────────────
do $$
declare v_orphans int;
begin
  select count(*) into v_orphans
    from dna_values v join dna_attributes a on a.id = v.attribute_id
   where a.name = 'Punch Type' and v.stockist_id is not null and v.parent_value_id is null;
  if v_orphans > 0 then raise exception 'FAILED: % orphan Punch Types remain', v_orphans; end if;
  raise notice 'OK: orphan Punch Types cleared; tile_add seeds Series=Regular on new designs';
end $$;
