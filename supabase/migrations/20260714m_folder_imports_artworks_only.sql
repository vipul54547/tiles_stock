-- ═══ THE FOLDER IMPORTS ARTWORKS. NOTHING ELSE. ═══════════════════════════════════════════════
--
-- His words: "in folder upload we need only size and image and name" · "we will make part first
-- step we will only import size, image and name. so our layout and structure must be by this way
-- only."
--
--     300x450 / 1001.jpg
--     ^^^^^^^   ^^^^  ^^^
--     size      name  image
--
-- 🖼️ AN ARTWORK IS SIZE + NAME + IMAGE. That is the whole of it, and it is exactly what a folder
-- can honestly give: the size is the folder, the name is what HE called the file, the image is the
-- file. Nothing else on the disk is a fact about the tile.
--
-- 🚫 NO SURFACE FOLDERS. NO BODY. NO PACKING. NO BRAND.
--    • the BODY is not on the disk — he types it
--    • the PACKING (pieces + weight) is not on the disk — he reads it off a box
--    • the SURFACE makes a TILE, not an artwork. `1001` at 300x450 is ONE artwork whether he later
--      cuts a Matt tile, a Carving tile, or both from it.
--
-- So the import stops at the artwork. The TILE — artwork + surface + body + thickness — is made
-- afterwards, from an artwork he already has.
--
-- ⚠️ CONSEQUENCE: an artwork with NO TILE is now the NORMAL state right after an import, not an
-- oddity. `my_library` is built from tiles, so it cannot see one. `my_artworks()` exists for that.

-- ── 1. Import an artwork — size + name + image, and stop ────────────────────────────────────
create or replace function public.artwork_import(
  p_size text, p_name text, p_image_url text
) returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can build a library'; end if;

  -- print_upsert is the ONLY way an artwork is created. Its key is (stockist, lower(name), size),
  -- and the photo is FIRST-WRITER-WINS: re-importing a folder never swaps an image already on
  -- record. Re-importing the same folder is therefore safe and idempotent.
  return print_upsert(v_stk, p_name, p_size, p_image_url);
end $function$;

revoke all on function public.artwork_import(text, text, text) from public, anon;
grant execute on function public.artwork_import(text, text, text) to authenticated;

-- ── 2. The artworks he has no tile for yet ──────────────────────────────────────────────────
-- After a folder import this is ALL of them. The Library must show them, or the import lands and
-- he sees nothing — `my_library` is built from tiles and joins straight through them.
create or replace function public.my_artworks_without_tiles()
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'print_id', pm.id,
           'name', pm.print_name,
           'size', pm.size,
           'image_url', pm.image_url,
           'created_at', pm.created_at)
         order by pm.print_name), '[]'::jsonb)
    from print_master pm
    join stockists s on s.id = pm.stockist_id
   where s.user_id = auth.uid()
     and not exists (select 1 from stockist_library l where l.print_id = pm.id);
$function$;

revoke all on function public.my_artworks_without_tiles() from public, anon;
grant execute on function public.my_artworks_without_tiles() to authenticated;

-- ── 3. Make a TILE from an artwork he already has ───────────────────────────────────────────
-- artwork + surface + body. The thickness is not here: it comes from the PACKING, which he adds
-- next (Library ▸ Packing & covers). A tile with no packing has no thickness, and the card says so.
create or replace function public.tile_add(
  p_print_id uuid, p_surface text, p_tile_type text default null
) returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_id uuid;
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
  else
    -- ADOPTION: fill a blank body, never overwrite a declared one.
    update stockist_library m
       set tile_type = coalesce(m.tile_type, v_body), updated_at = now()
     where m.id = v_id and m.tile_type is null and v_body is not null;
  end if;

  return v_id;
end $function$;

revoke all on function public.tile_add(uuid, text, text) from public, anon;
grant execute on function public.tile_add(uuid, text, text) to authenticated;
