-- 20260724d — 🖼️ MEDIA PORTFOLIO, P1 slice 3c: the buyer read `public_portfolio`.
--
-- Builds on 20260724a/b/c. The login-free /s/ page calls this ALONGSIDE the existing
-- `public_catalog` (which still owns the stockist header + the stock cards). This read owns
-- ONLY the media, and it is STOCK-BLIND (#10): no qty, no quality, no price — design identity +
-- media, so a zero-stock design still shows.
--
-- Shape: { assets:[ {id,type,url,space,space_label,sort_order, artworks:[...], designs:[...]} ] }
--   • artworks = the tagged prints (the "+N variants" grouping key; empty for a bare close-look).
--   • designs  = the tiles this asset is VISIBLE on, with placement. Visibility mirrors
--     my_media_grid: an artwork-bound asset shows on EVERY tile of its tagged artworks unless a
--     media_asset_tile row hides it (shown=false); a close-look shows on its explicit tile rows.
--   The buyer app derives both views from this one list: the Mockup/Aligning/360/Video TABS group
--   by type; the per-design View modal filters by library_id; "+N variants" groups designs by print.
--
-- Token resolves to the STOCKIST (a stockist share link, or a catalogue's owning stockist) — media
-- is stockist-wide and brand-neutral. Per-catalogue brand-scoping of media is a slice-3b concern
-- (no portfolio catalogue link is minted yet, so nothing over-shares today).
--
-- SECURITY DEFINER (bypasses the media tables' revoked anon grants); anon-callable like every
-- public_* read. Additive — no schema change.

create or replace function public.public_portfolio(p_token text)
 returns jsonb
 language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  with stk as (
    -- token → stockist: a stockist share link ...
    select s.id
      from stockists s
     where s.is_active
       and (s.share_token = p_token
            or exists (select 1 from stockist_share_links l
                        where l.stockist_id = s.id and l.token = p_token and l.is_active
                          and (l.expires_at is null or l.expires_at > now())))
    union
    -- ... or a catalogue link (resolve to its owning stockist)
    select c.stockist_id
      from stock_catalogs c join stockists s on s.id = c.stockist_id
     where c.is_active and s.is_active
       and (c.share_token = p_token
            or exists (select 1 from stockist_share_links l
                        where l.catalog_id = c.id and l.token = p_token and l.is_active
                          and (l.expires_at is null or l.expires_at > now())))
    limit 1
  )
  select jsonb_build_object('assets', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', a.id, 'type', a.type, 'url', a.url,
      'space', a.space,
      'space_label', (select label from admin_lookups where list_key='space' and value = a.space),
      'sort_order', a.sort_order,
      'artworks', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'print_id', pm.id, 'name', pm.print_name, 'size', pm.size, 'image_url', pm.image_url)
               order by pm.print_name)
          from media_asset_artwork ma join print_master pm on pm.id = ma.print_id
         where ma.asset_id = a.id), '[]'::jsonb),
      'designs', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'library_id', l.id, 'print_id', l.print_id, 'name', pm.print_name,
                 'size', pm.size, 'image_url', pm.image_url,
                 'surface_type', l.surface_type, 'surface_label', l.surface_label,
                 'tile_type', l.tile_type, 'finish', l.finish_label,
                 'placement', coalesce(mt.placement, 'both'),
                 'placement_label', (select label from admin_lookups
                                      where list_key='placement' and value = coalesce(mt.placement,'both')))
               order by pm.print_name, l.surface_type, l.tile_type)
          from stockist_library l
          join print_master pm on pm.id = l.print_id
          left join media_asset_tile mt on mt.asset_id = a.id and mt.library_id = l.id
         where l.stockist_id = a.stockist_id
           and (
             -- artwork-bound: tile's print is tagged, and not explicitly hidden
             ( l.print_id in (select print_id from media_asset_artwork where asset_id = a.id)
               and coalesce(mt.shown, true) )
             -- explicitly attached tile (close-look, or an explicit shown tile)
             or coalesce(mt.shown, false)
           )), '[]'::jsonb)
    ) order by a.type, a.sort_order, a.created_at desc)
    from media_asset a
    where a.stockist_id = (select id from stk)
  ), '[]'::jsonb));
$function$;
