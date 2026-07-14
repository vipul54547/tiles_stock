-- ═══ THE FOLDER IMPORT IS BRAND-FREE ═══════════════════════════════════════════════════════════
--
-- His question: "why we are importing under brand — this is only for M_Stockist so it must come
-- without brand?" He is right, and the old code was doing something worse than asking a pointless
-- question: it wrote
--
--     insert into stockist_library_brand_names (..., brand_design_name, ...) values (..., v_name, ...)
--                                                                                        ^^^^^^
--                                                                                    THE FILENAME
--
-- `brand_design_name` is the name the FACTORY STAMPS ON THAT BRAND'S BOX — `1001` under FAMOUS,
-- `601001` under ANUJ. The filename is the stockist's OWN word for the artwork; it is the PRINT's
-- name. So every folder import was FORGING a box label he never typed — the same guessing that
-- filled the surface column with bodies and joint types and forced the 14 Jul clean slate.
--
-- 🔑 A FOLDER OF IMAGES KNOWS TWO THINGS, AND NEITHER HAS A BRAND:
--      PRINT   the artwork — brand-free by definition
--      PRODUCT the piece   — brand-free by rule (identity is brand-free; brand belongs to the BOX)
--
-- The brand becomes real only when a BOX is declared. So the box — the stamped name, the pieces,
-- the weight — is a SEPARATE step, taken per brand, by him. Until then the product has no box and
-- therefore NO THICKNESS, and the Library says so honestly ("no thickness — set a box").

-- ── 1. library_image_upsert: PRINT + PRODUCT. Nothing else. ─────────────────────────────────
-- Removing parameters creates an overload, and the old call shape then dies with 42725. Drop the
-- old signature in the SAME migration.
drop function if exists public.library_image_upsert(text, text, text, uuid, text, text, integer, numeric);

create or replace function public.library_image_upsert(
  p_size text,
  p_name text,
  p_image_url text,
  p_surface text,
  p_tile_type text default null
) returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_id uuid; v_print uuid;
        v_name text := btrim(coalesce(p_name,''));
        v_size text := btrim(coalesce(p_size,''));
        v_surf text := nullif(btrim(coalesce(p_surface,'')),'');
        v_tile text := nullif(btrim(coalesce(p_tile_type,'')),'');
        v_img  text := nullif(btrim(coalesce(p_image_url,'')),'');
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can build a library'; end if;
  if v_name = '' then raise exception 'Design name cannot be empty'; end if;
  if v_size = '' then raise exception 'Size is required'; end if;
  if v_surf is null or lower(v_surf) = 'none' then
    raise exception 'A surface is required for "%" (%)', v_name, v_size;
  end if;

  -- THE PRINT. The filename is his own word for the artwork — that is the whole reason a folder is
  -- an honest source and a supplier PDF is not. The photo is FIRST-WRITER-WINS, so re-importing a
  -- folder never silently swaps an image already on record.
  v_print := print_upsert(v_stk, v_name, v_size, v_img);

  -- THE PRODUCT: this print, in this surface, in this body. No brand — identity is brand-free.
  select id into v_id from stockist_library
   where stockist_id = v_stk and print_id = v_print and surface_type = v_surf
     and (v_tile is null or tile_type is null or tile_type = v_tile)
   order by (tile_type is not null) desc, created_at
   limit 1;

  if v_id is null then
    insert into stockist_library (stockist_id, print_id, surface_type, tile_type)
      values (v_stk, v_print, v_surf, v_tile)
      returning id into v_id;
  else
    -- ADOPTION: fill a blank body, never overwrite a declared one.
    update stockist_library m
       set tile_type = coalesce(m.tile_type, v_tile), updated_at = now()
     where m.id = v_id and m.tile_type is null and v_tile is not null;
  end if;

  -- 🚫 NO BOX. A folder does not know what any brand stamps on its box, nor how it packs it.
  -- Guessing it is what this function used to do. See library_set_box_for_size.
  return v_id;
end; $function$;

revoke all on function public.library_image_upsert(text, text, text, text, text) from public, anon;
grant execute on function public.library_image_upsert(text, text, text, text, text) to authenticated;

-- ── 2. THE BOX STEP — per brand, per size, declared by HIM ──────────────────────────────────
-- A brand packs one size the same way every time (a 600x1200 box is 2 pieces at 27 kg whatever the
-- design on it), so this is typed ONCE per (brand, size) and lands on every product of that size.
-- The thickness then derives from it — never typed, never guessed.
--
-- The stamped name defaults to the PRINT's name, which is what the M's own brand really stamps. A
-- brand that stamps something else (ANUJ prints `601001` where FAMOUS prints `1001`) is corrected
-- per brand in the Library — that correction is a fact he supplies, not one we invent.
create or replace function public.library_set_box_for_size(
  p_brand_id uuid,
  p_size text,
  p_pieces integer,
  p_weight numeric
) returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_n int; v_size text := btrim(coalesce(p_size,''));
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can edit the library'; end if;
  if p_brand_id is null then raise exception 'Pick a brand'; end if;
  if not exists (select 1 from brands where id = p_brand_id and stockist_id = v_stk) then
    raise exception 'That brand is not yours';
  end if;
  if v_size = '' then raise exception 'Pick a size'; end if;
  if coalesce(p_pieces,0) <= 0 then raise exception 'Pieces per box must be more than 0'; end if;
  if coalesce(p_weight,0) <= 0 then raise exception 'Box weight must be more than 0'; end if;

  insert into stockist_library_brand_names (library_id, brand_id, brand_design_name,
                                            pieces_per_box, box_weight_kg)
  select l.id, p_brand_id, p.print_name, p_pieces, p_weight
    from stockist_library l
    join print_master p on p.id = l.print_id
   where l.stockist_id = v_stk and p.size = v_size
  on conflict (library_id, brand_id) do update
    -- A weight already on record is the REFERENCE the 1 mm rule measures drift against. Do not
    -- silently move it; he can change one box by hand if he really means to.
    set pieces_per_box = case when coalesce(stockist_library_brand_names.pieces_per_box,0) = 0
                              then excluded.pieces_per_box
                              else stockist_library_brand_names.pieces_per_box end,
        box_weight_kg  = case when coalesce(stockist_library_brand_names.box_weight_kg,0) = 0
                              then excluded.box_weight_kg
                              else stockist_library_brand_names.box_weight_kg end;

  get diagnostics v_n = row_count;
  return v_n;

exception
  when exclusion_violation or unique_violation then
    raise exception 'That box weight puts one of these designs at the same thickness as another '
                    'you already have. Check the pieces and the weight.';
end; $function$;

revoke all on function public.library_set_box_for_size(uuid, text, integer, numeric) from public, anon;
grant execute on function public.library_set_box_for_size(uuid, text, integer, numeric) to authenticated;
