-- BOX chapter — STEP 3 of 5: thickness is DERIVED. Always. By trigger.
-- (docs/BOX_AND_DERIVED_THICKNESS_PLAN.md)
--
-- USER DECISION 2026-07-13: "always derived, no manual override."
--
--     thickness_mm = box_weight_kg / (pieces_per_box × area_m2 × density) × 1000
--
-- Enforced by a TRIGGER rather than trusted to each writer — 11 functions read or write these
-- columns, and any one of them forgetting would silently desync the thickness. A trigger
-- cannot be forgotten.
--
-- WHICH BOX does a multi-box product derive from? ANY of them, and that is not a fudge:
--   box_weight / pieces = the weight of ONE tile, which is identical however a brand packs it.
-- So every box of a product must yield the same thickness. Two boxes disagreeing means one has
-- bad data — we take the first and leave the discrepancy to be found, rather than inventing a
-- tie-break that would hide it.
--
-- thickness_mm cannot be a GENERATED column: generated columns may not reference another
-- table, and pieces/weight now live on the box. (thickness_band IS generated off thickness_mm,
-- so it follows for free.)

-- Area of one tile in m², parsed from the size text ('600x600 mm', '800x1200', ...).
create or replace function public._tile_area_m2(p_size text)
 returns numeric
 language sql
 immutable
as $function$
  select case
    when p_size ~ '[0-9]+ *x *[0-9]+' then
      (split_part(regexp_replace(p_size,'[^0-9x]','','g'),'x',1))::numeric / 1000
    * (split_part(regexp_replace(p_size,'[^0-9x]','','g'),'x',2))::numeric / 1000
    else null
  end;
$function$;

-- The single source of truth for a product's thickness.
create or replace function public._derive_thickness(p_library_id uuid)
 returns numeric
 language plpgsql
 stable
 set search_path to 'public', 'pg_temp'
as $function$
declare v_area numeric; v_density numeric; v_pieces int; v_weight numeric;
begin
  select _tile_area_m2(l.size), t.density_kg_m3
    into v_area, v_density
    from stockist_library l
    left join tile_types t on t.name = l.tile_type
   where l.id = p_library_id;

  if v_area is null or v_area <= 0 or v_density is null or v_density <= 0 then
    return null;                       -- unknown size or unknown body type -> unknowable
  end if;

  -- ANY box will do: weight-per-piece is a property of the TILE, not of the packing.
  select a.pieces_per_box, a.box_weight_kg
    into v_pieces, v_weight
    from stockist_library_brand_names a
   where a.library_id = p_library_id
     and coalesce(a.pieces_per_box,0) > 0
     and coalesce(a.box_weight_kg,0) > 0
   order by a.created_at
   limit 1;

  if coalesce(v_pieces,0) <= 0 or coalesce(v_weight,0) <= 0 then
    return null;                       -- no box spec yet -> no thickness yet
  end if;

  return round(v_weight / (v_pieces * v_area * v_density) * 1000, 2);
end; $function$;

create or replace function public._trg_rederive_thickness()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_lib uuid;
begin
  v_lib := case tg_table_name
             when 'stockist_library_brand_names'
               then coalesce(new.library_id, old.library_id)
             else coalesce(new.id, old.id)
           end;

  update stockist_library
     set thickness_mm = coalesce(_derive_thickness(v_lib), 0),
         updated_at   = now()
   where id = v_lib
     and thickness_mm is distinct from coalesce(_derive_thickness(v_lib), 0);

  return coalesce(new, old);
end; $function$;

-- A box's packing changed -> the product's thickness follows.
drop trigger if exists zz_box_rederive_thickness on stockist_library_brand_names;
create trigger zz_box_rederive_thickness
  after insert or update of pieces_per_box, box_weight_kg or delete
  on stockist_library_brand_names
  for each row execute function _trg_rederive_thickness();

-- The product's size or body type changed -> its thickness follows. (Guarded on the columns
-- that matter, so the trigger's own UPDATE of thickness_mm cannot re-fire it.)
drop trigger if exists zz_library_rederive_thickness on stockist_library;
create trigger zz_library_rederive_thickness
  after update of size, tile_type
  on stockist_library
  for each row execute function _trg_rederive_thickness();

-- Backfill every product from its box, now that the rule exists.
update stockist_library l
   set thickness_mm = coalesce(_derive_thickness(l.id), 0),
       updated_at   = now()
 where thickness_mm is distinct from coalesce(_derive_thickness(l.id), 0);
