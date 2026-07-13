-- The FOLDER is the only honest source of a PRINT NAME — so the stockist gets his own folder import.
--
-- 🔴 WHY THE PDF CANNOT DO THIS (user, 2026-07-13):
--    A supplier PDF prints the name stamped on the BOX — `brand_design_name`. That is the FACTORY'S
--    word, it is per-brand, and it is free text ("1001", "CARRARA GOLD", "DHORO KHIMO"). It is NOT
--    the stockist's own word for the artwork, and `print_name` is exactly that. Feeding a PDF label
--    into print_name forges a WRONG PRINT for every row, and the print is the top of the identity
--    chain — so the damage runs all the way down.
--    In a FOLDER, the stockist NAMED THE FILES HIMSELF. The filename IS his word for the artwork.
--    → The PDF importer is hidden from the platform. The folder importer replaces it.
--
-- `library_image_upsert` is the stockist-facing twin of `admin_library_upsert`, keyed on auth.uid().
--
-- ⚠️ It is NOT `library_upsert_master`. That one DELETES every brand alias absent from its payload
--    (it backs the Library editor, where the alias list IS the truth). A folder import only ever
--    knows about ONE brand, so calling it would WIPE every other brand's stamped name and its
--    pieces/box weight — silently destroying the BOX rows for the rest of the library.
--    This function only ever MERGES.

create or replace function library_image_upsert(
    p_size text,
    p_name text,
    p_image_url text,
    p_brand_id uuid,
    p_surface text,
    p_tile_type text default null,
    p_pieces integer default null,
    p_weight numeric default null)
returns uuid language plpgsql security definer
set search_path to 'public','pg_temp' as $function$
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
  if p_brand_id is not null
     and not exists (select 1 from brands where id = p_brand_id and stockist_id = v_stk) then
    raise exception 'That brand is not yours';
  end if;

  -- The PRINT: the stockist's own word for the artwork + the size. The photo is
  -- first-writer-wins, so re-importing a folder never silently swaps an existing image.
  v_print := print_upsert(v_stk, v_name, v_size, v_img);

  -- The PRODUCT: this print in this surface + body.
  select id into v_id from stockist_library
   where stockist_id = v_stk and print_id = v_print and surface_type = v_surf
     and (v_tile is null or tile_type is null or tile_type = v_tile)
   order by (tile_type is not null) desc, created_at
   limit 1;

  if v_id is null then
    insert into stockist_library (stockist_id, print_id, brand_id, surface_type, tile_type)
      values (v_stk, v_print, p_brand_id, v_surf, v_tile)
      returning id into v_id;
  else
    -- ADOPTION: fill a blank body, never overwrite a declared one.
    update stockist_library m
       set tile_type = coalesce(m.tile_type, v_tile), updated_at = now()
     where m.id = v_id and m.tile_type is null and v_tile is not null;
  end if;

  -- The BOX. The stamp defaults to the stockist's own name (he corrects it per brand later);
  -- pieces/weight are what derive the thickness, so a re-import may FILL a blank box but must
  -- never overwrite a weight already on record — that weight is the reference the 1 mm rule
  -- measures drift against.
  if p_brand_id is not null then
    insert into stockist_library_brand_names (library_id, brand_id, brand_design_name,
                                              pieces_per_box, box_weight_kg)
    values (v_id, p_brand_id, v_name, p_pieces, p_weight)
    on conflict (library_id, brand_id) do update
      set pieces_per_box = case when coalesce(stockist_library_brand_names.pieces_per_box,0) = 0
                                then excluded.pieces_per_box
                                else stockist_library_brand_names.pieces_per_box end,
          box_weight_kg  = case when coalesce(stockist_library_brand_names.box_weight_kg,0) = 0
                                then excluded.box_weight_kg
                                else stockist_library_brand_names.box_weight_kg end;
  end if;

  return v_id;

exception
  when exclusion_violation then
    raise exception 'You already have "%" (% · %) at almost this thickness. A box weight this close '
                    'is the SAME tile — check the pieces and box weight.', v_name, v_size, v_surf;
end; $function$;

comment on function library_image_upsert is
  'Folder import, for the signed-in stockist. The FILENAME is the print name - his own word for the '
  'artwork - which is why this replaces the PDF importer: a PDF only knows the BOX stamp. MERGES the '
  'brand box; never deletes another brand''s (that is what library_upsert_master does, and why it '
  'must not be used here).';

revoke all on function library_image_upsert(text,text,text,uuid,text,text,integer,numeric)
  from anon;
grant execute on function library_image_upsert(text,text,text,uuid,text,text,integer,numeric)
  to authenticated;

-- self-check
do $$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'library_image_upsert') then
    raise exception 'FAILED: library_image_upsert was not created';
  end if;
  raise notice 'OK: library_image_upsert is live';
end $$;
