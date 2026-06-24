-- M identity redesign — POLISH (#4 cleanup tool): make library_merge_masters
-- TRULY LOSSLESS for stock + lists.
--
-- The prior version moved only brand aliases, DNA and (if absent) the image,
-- then DELETEd the dropped master. But designs.library_id is ON DELETE SET NULL
-- and catalog_designs.library_id is ON DELETE CASCADE — so a dropped box that
-- carried stock would leave its holdings ORPHANED (detached from any master) and
-- its stock-list memberships would VANISH. The historic dup groups happen to
-- carry no stock today, but the Find-duplicates tool now actively steers the
-- human to merge, so the merge must never lose stock.
--
-- New behaviour (additionally):
--   • catalog_designs (list memberships) → re-pointed to keep (dedup).
--   • designs (holdings) → non-colliding ones MOVED to keep (id preserved, so
--     all their stock_in / dispatch / inquiry history follows). A holding that
--     COLLIDES with a keep holding of the same quality+surface is SUMMED into it,
--     its accounting ledgers re-pointed, and the empty drop holding removed.
-- Reversible: re-apply the previous library_merge_masters definition.

CREATE OR REPLACE FUNCTION public.library_merge_masters(p_keep_id uuid, p_drop_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_stk uuid;
  v_keep_size text; v_drop_size text;
  v_keep_img text; v_drop_img text;
  rec record; v_keep_hold uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can merge the library'; end if;
  if p_keep_id = p_drop_id then raise exception 'Cannot merge a design into itself'; end if;

  select size, nullif(btrim(coalesce(image_url,'')),'') into v_keep_size, v_keep_img
  from stockist_library where id = p_keep_id and stockist_id = v_stk;
  select size, nullif(btrim(coalesce(image_url,'')),'') into v_drop_size, v_drop_img
  from stockist_library where id = p_drop_id and stockist_id = v_stk;
  if v_keep_size is null or v_drop_size is null then
    raise exception 'Both designs must be yours';
  end if;
  if v_keep_size <> v_drop_size then
    raise exception 'Only same-size designs can be merged (% vs %)', v_keep_size, v_drop_size;
  end if;

  -- Move the dropped master's brand aliases that the kept one does not already have.
  update stockist_library_brand_names d
     set library_id = p_keep_id
   where d.library_id = p_drop_id
     and not exists (select 1 from stockist_library_brand_names k
                     where k.library_id = p_keep_id and k.brand_id = d.brand_id);
  -- Remove any leftover (brand already present on keep) aliases on the drop.
  delete from stockist_library_brand_names where library_id = p_drop_id;

  -- Carry DNA values the kept master doesn't already have (lossless merge).
  insert into library_dna (library_id, value_id)
    select p_keep_id, d.value_id
    from library_dna d
    where d.library_id = p_drop_id
      and not exists (select 1 from library_dna k
                      where k.library_id = p_keep_id and k.value_id = d.value_id);

  -- Re-point stock-list memberships to keep (dedup); leftover drop rows cascade
  -- away with the drop box.
  update catalog_designs c set library_id = p_keep_id
   where c.library_id = p_drop_id
     and not exists (select 1 from catalog_designs k
                     where k.catalog_id = c.catalog_id and k.library_id = p_keep_id);

  -- Re-point stock holdings to keep. Non-colliding holdings simply move (id kept
  -- → all their ledger/dispatch/inquiry history follows). A holding that collides
  -- with a keep holding of the same quality+surface is summed into it.
  for rec in select * from designs where library_id = p_drop_id and stockist_id = v_stk loop
    select id into v_keep_hold from designs
     where library_id = p_keep_id and stockist_id = v_stk
       and quality = rec.quality and surface_type = rec.surface_type;
    if v_keep_hold is null then
      update designs set library_id = p_keep_id, updated_at = now() where id = rec.id;
    else
      update designs
         set box_quantity = coalesce(box_quantity,0) + coalesce(rec.box_quantity,0),
             updated_at = now()
       where id = v_keep_hold;
      update stock_in         set design_id = v_keep_hold where design_id = rec.id;
      update stock_adjustments set design_id = v_keep_hold where design_id = rec.id;
      update dispatches       set design_id = v_keep_hold where design_id = rec.id;
      update inquiry_items    set design_id = v_keep_hold where design_id = rec.id;
      delete from my_choices  where design_id = rec.id; -- buyer pick of a removed holding
      delete from designs     where id = rec.id;
    end if;
  end loop;

  -- Keep an image: if the kept master has none, adopt the dropped one's.
  if v_keep_img is null and v_drop_img is not null then
    update stockist_library set image_url = v_drop_img where id = p_keep_id;
  end if;

  delete from stockist_library where id = p_drop_id; -- cascades drop's library_dna
  return p_keep_id;
end;
$function$;
