-- ═══ STEP 4 of docs/PACKING_BOX_HOLD_PLAN.md — THE TILE'S OWN DNA ═════════════════════════════
--
-- He locked what one tile carries:
--
--   COMPULSORY (identity):  artwork · surface · body · thickness
--   ITS OWN DESCRIPTION:    Punch ▸ Punch Type (FREE TEXT) · Application · Series (FREE TEXT,
--                           set by the M, default `Regular`)
--
-- The IMAGE DNA (Look Type ▸ Natural Name · Design Joint · Print Type · Colour) belongs to the
-- ARTWORK and already lives on the print (20260714d). This migration is only about the tile's own.

-- ── 1. Punch Type is FREE TEXT ──────────────────────────────────────────────────────────────
-- It was wearing three hats at once: is_free_text = true, free_text_detail = true, AND a list of 5
-- canonical values. free_text_detail is a different mode — "pick a canonical value, then tie your
-- own word to THAT value" (Wave → "water punch"). He said free text, so it is free text: he types
-- the word, full stop.
--
-- The 5 values are LEFT IN PLACE. They are not offered any more (a free-text attribute is edited as
-- typed chips), and deleting them would cascade away any tag that ever used them. Dead, not
-- destroyed.
update dna_attributes
   set is_free_text     = true,
       free_text_detail = false
 where name = 'Punch Type';

-- ── 2. Series is FREE TEXT, and every tile starts as `Regular` ──────────────────────────────
update dna_attributes set is_free_text = true where name = 'Series';

-- The default lives as a shared (admin-owned, stockist_id NULL) value, so every stockist's tiles
-- point at the SAME `Regular` — one row, not one per stockist.
insert into dna_values (attribute_id, name, stockist_id)
select a.id, 'Regular', null
  from dna_attributes a
 where a.name = 'Series'
   and not exists (
     select 1 from dna_values v
      where v.attribute_id = a.id and v.stockist_id is null and lower(v.name) = 'regular');

-- 🔑 A NEW TILE IS `Regular` UNLESS HE SAYS OTHERWISE.
-- This is a DEFAULT, not a guess: "Regular" is what a series IS when nobody has named one, and he
-- can overwrite it the moment he wants to. (Contrast a guessed SURFACE or BODY, which we refuse to
-- write at all — those are identity, and a wrong one forges a different tile. A series is not.)
create or replace function public._trg_tile_default_series()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_regular uuid;
begin
  select v.id into v_regular
    from dna_values v join dna_attributes a on a.id = v.attribute_id
   where a.name = 'Series' and v.stockist_id is null and lower(v.name) = 'regular'
   limit 1;

  if v_regular is null then return new; end if;

  insert into library_dna (library_id, value_id)
       values (new.id, v_regular)
  on conflict do nothing;

  return new;
end $function$;

drop trigger if exists zz_tile_default_series on public.stockist_library;
create trigger zz_tile_default_series
  after insert on public.stockist_library
  for each row execute function _trg_tile_default_series();

-- ── 3. Use Type + Behaviour Type are DERIVED — take them off the board ──────────────────────
-- His words: "use type and behaviour type we will not come from anywhere, we will define condition
-- and we will show this both field by condition — so do not worry about this both."
--
-- Nobody types them. They will be WORKED OUT by condition from what the tile already knows —
-- surface · body · thickness · size — and shown by condition. THE RULES ARE NOT DEFINED YET, so
-- nothing is built: a guessed rule in a displayed field is the same disease as a guessed surface.
--
-- Deactivating is exactly how "never offer this" is spelled here: `dna_catalog` filters on
-- is_active, so they disappear from the DNA editor AND from the importer's DNA column detection in
-- one stroke. The rows and their values stay, so nothing is destroyed and it is one UPDATE to undo.
update dna_attributes
   set is_active = false
 where name in ('Use Type', 'Behaviour Type');
