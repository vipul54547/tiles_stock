-- 20260724c — 🖼️ MEDIA PORTFOLIO, P1 slice 3a: the hand-pick GRID CANDIDATES read.
--
-- Builds on 20260724a/b. This is the read that backs the visibility grid in Add Material / Manage
-- (#4): given the artworks tagged on a shot, list EVERY tile cut from them so the stockist can
-- untick exceptions (shown=false) and caption each tile's role (placement wall/floor/both).
--
-- 🔑 Default visibility is SHOW-ALL: an asset shows on every tile of every tagged artwork. So the
--   grid's effective state = coalesce(the saved media_asset_tile override, {shown:true, both}).
--   For a NEW asset (no id yet) the UI passes the tags it has picked → every row defaults on.
--   For an EXISTING asset the UI passes its id (and, when re-tagging, the live tag set) → the saved
--   overrides overlay the candidates.
--
-- Stockist-only (my_*), own tiles only. Pure additive read — no schema change.

-- p_print_ids : uuid[] as jsonb — the artworks currently tagged in the UI (drives the candidates).
--               When empty AND p_asset is given, falls back to the asset's already-tagged artworks.
-- p_asset     : the asset being edited (overlays its saved shown/placement); NULL for a new upload.
create or replace function public.my_media_grid(
  p_print_ids jsonb default '[]'::jsonb, p_asset uuid default null)
 returns jsonb
 language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  with me as (select id from stockists where user_id = auth.uid()),
  prints as (
    -- artworks the UI passed (the current tag selection) ...
    select (jsonb_array_elements_text(coalesce(p_print_ids, '[]'::jsonb)))::uuid as print_id
    union
    -- ... or, when none were passed, the asset's already-saved tags
    select ma.print_id
      from media_asset_artwork ma
     where p_asset is not null
       and coalesce(jsonb_array_length(p_print_ids), 0) = 0
       and ma.asset_id = p_asset
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'library_id',    l.id,
           'print_id',      l.print_id,
           'name',          pm.print_name,
           'size',          pm.size,
           'image_url',     pm.image_url,
           'surface_type',  l.surface_type,
           'surface_label', l.surface_label,
           'tile_type',     l.tile_type,
           'finish',        l.finish_label,
           'body_colour',   bc.name,
           'body_hex',      bc.hex,
           'shown',         coalesce(mt.shown, true),
           'placement',     coalesce(mt.placement, 'both'),
           'placement_label', (select label from admin_lookups
                                where list_key = 'placement' and value = coalesce(mt.placement, 'both'))
         ) order by pm.print_name, l.surface_type, l.tile_type), '[]'::jsonb)
    from stockist_library l
    join print_master pm on pm.id = l.print_id
    left join body_colours bc on bc.id = l.body_colour_id
    left join media_asset_tile mt on mt.asset_id = p_asset and mt.library_id = l.id
   where l.stockist_id = (select id from me)
     and l.print_id in (select print_id from prints);
$function$;
