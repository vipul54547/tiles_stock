-- CHAPTER 4, step 2 — the 'Special' surface, the death of 'None', and the DNA flags.
--
-- 🔴 THE IMPORT IS CURRENTLY DEAD. `import_stock_batch` defaults a blank surface to the literal
--    'None', and `library_map_upsert` RAISES on 'None' ("Pick a surface - every design must have
--    one."). The whole batch is ONE transaction, so a single surface-less row throws and NOTHING
--    lands. The library-only M-PDF import sends 'None' on EVERY row, so it cannot run at all.
--
-- The fix is 'Special' — and it is NOT 'None' wearing a new hat:
--   * 'None' meant "we don't know yet" while sitting in the PRODUCT KEY, so it spawned a phantom
--     product beside the real one.
--   * 'Special' is a REAL surface. It is a legitimate PERMANENT answer for a stockist whose
--     surfaces cannot sensibly be enumerated, and stock now INHERITS a product's surface rather
--     than asking for one, so it cannot spawn a twin. A product left at 'Special' is safely fixed
--     later - `library_set_surface` cascades the correction onto its holdings.
--
-- 🔑 WHERE 'Special' APPLIES (user, 2026-07-13):
--     PDF parse         -> surface = 'Special'   the ONLY place it is automatic. We never ask
--                                                mid-parse, so we must not GUESS mid-parse either.
--     Manual add-design -> surface = BLANK       NO default. Selection is COMPULSORY. The human is
--                                                standing right there - so ask him.
--     'None'            -> DEAD. Never written, never offered.
-- 🚫 NO free text under 'Special'. surface_label is not identity, so two 'Special' tiles told apart
--    only by a label would COLLIDE into one product.

-- ---------------------------------------------------------------- 1. the 'Special' surface
insert into surface_types (name, sort_order, is_active, is_system)
select 'Special', coalesce((select max(sort_order) from surface_types), 0) + 10, true, false
where not exists (select 1 from surface_types where lower(name) = 'special');

-- ---------------------------------------------------------------- 2. import_stock_batch: 'None' -> 'Special'
-- Patched by rewriting the LIVE definition rather than retyping 200 lines of it - retyping a body
-- this size to change one literal is how a transcription bug gets in. The guard makes the
-- migration fail loudly if the line ever stops matching.
do $$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'import_stock_batch';

  if v_def is null then
    raise exception 'FAILED: import_stock_batch not found';
  end if;

  v_new := replace(
    v_def,
    $x$v_surface := coalesce(nullif(btrim(coalesce(r->>'surface','')),''),'None');$x$,
    $x$v_surface := coalesce(nullif(btrim(coalesce(r->>'surface','')),''),'Special');$x$);

  if v_new = v_def then
    raise exception 'FAILED: the ''None'' default was not found in import_stock_batch - '
                    'read the live body before assuming this patch still applies';
  end if;

  execute v_new;
  raise notice 'OK: import_stock_batch now defaults a blank surface to Special';
end $$;

-- ---------------------------------------------------------------- 3. DNA flags
-- The DNA split (user, 2026-07-13). Neither CASCADE is cut by the print/product boundary:
--   PRINT   : Look Type -> Natural Name · Print Type · Design Joint · Colour(multi)   [admin]
--   PRODUCT : Punch -> Punch Type · Application            [stockist OR admin]
--             Series                                       [STOCKIST ONLY]
--             Behaviour Type · Use Type                    [AUTO-GENERATED later]

-- free text: the stockist types his own punch pattern / his own series name
update dna_attributes set is_free_text = true
 where name in ('Punch Type','Series') and is_free_text is distinct from true;

-- Behaviour Type (Antiskid/Slippery) and Use Type (Floor/Wall/Outdoor) are DERIVABLE from the
-- product's own key - Antiskid follows from a MATT surface; Floor/Wall from body + thickness +
-- surface. Hand-mapping them would be a SECOND SOURCE OF TRUTH for a fact we can compute. Turn
-- mapping OFF so nobody types guesses into them in the meantime, and hide them until the rule
-- engine exists.
-- ⚠️ They are NOT deleted. They are waiting.
update dna_attributes set allow_mapping = false, show_in_facets = false
 where name in ('Behaviour Type','Use Type');

-- Series is the ONLY attribute flagged as a buyer facet, and it has ZERO values - an empty filter.
-- Off until it has something in it.
update dna_attributes set show_in_facets = false
 where name = 'Series' and show_in_facets;

-- ---------------------------------------------------------------- 4. self-check
do $$
declare v_special int; v_none_default int; v_free int; v_nomap int;
begin
  select count(*) into v_special from surface_types where name = 'Special' and is_active;
  select count(*) into v_free    from dna_attributes where name in ('Punch Type','Series') and is_free_text;
  select count(*) into v_nomap   from dna_attributes where name in ('Behaviour Type','Use Type') and not allow_mapping;
  select count(*) into v_none_default
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'import_stock_batch'
     and pg_get_functiondef(p.oid) like '%''''),''None'')%';

  if v_special <> 1 then raise exception 'FAILED: Special surface missing'; end if;
  if v_free    <> 2 then raise exception 'FAILED: free-text flags = %', v_free; end if;
  if v_nomap   <> 2 then raise exception 'FAILED: allow_mapping flags = %', v_nomap; end if;
  if v_none_default > 0 then raise exception 'FAILED: import_stock_batch still defaults to None'; end if;
  raise notice 'OK: Special surface live; None default gone; DNA flags set';
end $$;
