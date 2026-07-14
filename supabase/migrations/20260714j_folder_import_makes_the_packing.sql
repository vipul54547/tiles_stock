-- ═══ STEP 5 of docs/PACKING_BOX_HOLD_PLAN.md — THE FOLDER IMPORT MAKES THE TILE *AND* ITS PACKING
--
-- His words: "we will take box_weight and number of pieces entry at here, we will remember only
-- thickness."
--
-- 📦 **AND IT CAN, BECAUSE A PACKING HAS NO BRAND.** That was the whole objection earlier — "why
-- are we importing under brand? it must come without brand." Pieces + weight were on the BOX, per
-- brand, so asking for them meant asking for a brand. They are on the PACKING now, and the packing
-- is brand-free. So the folder import asks for them and STILL never mentions a brand.
--
-- What the folder knows, and what he tells it:
--
--     300x450 / MATTE / 1001.jpg     → the ARTWORK (his filename), the SIZE, the SURFACE
--     he confirms                    → the BODY, the PIECES, the WEIGHT
--     the server works out           → the THICKNESS
--
-- The tile keeps only the thickness. The pieces and the weight are the PACKING, and they live there.
--
-- 🚫 STILL NO BRAND, AND STILL NO BOX. A folder cannot know what a brand prints on its cover
-- (`1001` on FAMOUS, `601001` on ANUJ) — writing the filename there would forge a label he never
-- typed, which is exactly what 20260714e removed. The cover is put on later, by him.

-- Removing/adding parameters creates an OVERLOAD, and the old call shape then dies with 42725.
-- Drop the previous signature in the SAME migration.
drop function if exists public.library_image_upsert(text, text, text, text, text);

create or replace function public.library_image_upsert(
  p_size text,
  p_name text,
  p_image_url text,
  p_surface text,
  p_tile_type text default null,
  p_pieces integer default null,
  p_weight numeric default null
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

  -- THE ARTWORK. The filename is his own word for it — that is why a folder is an honest source and
  -- a supplier PDF is not. The photo is FIRST-WRITER-WINS: re-importing never swaps an image
  -- already on record.
  v_print := print_upsert(v_stk, v_name, v_size, v_img);

  -- THE TILE: this artwork, in this surface, in this body. No brand — identity is brand-free.
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

  -- 📦 THE PACKING — pieces + weight, no brand. The THICKNESS falls out of it, and the tile keeps
  -- only that. packing_add holds it to the 1 mm rule, so a re-import whose weight has drifted far
  -- enough to be a DIFFERENT TILE is refused by name rather than quietly overwriting the reference.
  if coalesce(p_pieces,0) > 0 and coalesce(p_weight,0) > 0 then
    perform packing_add(v_id, p_pieces, p_weight);
  end if;

  -- 🚫 NO BOX. A folder does not know what any brand prints on its cover. He puts the cover on later.
  return v_id;
end; $function$;

revoke all on function public.library_image_upsert(text, text, text, text, text, integer, numeric)
  from public, anon;
grant execute on function public.library_image_upsert(text, text, text, text, text, integer, numeric)
  to authenticated;
