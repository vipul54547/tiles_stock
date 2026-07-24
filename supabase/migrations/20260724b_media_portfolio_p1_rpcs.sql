-- 20260724b — 🖼️ MEDIA PORTFOLIO, P1 slice 2: the RPC layer (stockist writer + admin + reads).
--
-- Builds on 20260724a (tables). This slice = the STABLE operations whose shape is UI-independent:
--   · generic lookups (space/placement pickers + buyer filter) + admin Managed-lists CRUD
--   · admin per-type gating + quota setters
--   · media CRUD (add/update/tag artworks/set tiles+placement/delete) with gating+quota enforced
--   · management reads (my_media_config, my_media, my_portfolio_matrix)
-- DEFERRED to slice 3 (built with the screens, so the shape matches the UI): the hand-pick grid
--   candidates read and the buyer /s/ "+N variants" portfolio read + catalogue_list extension.
--
-- Convention: admin_* = admin only (current_user_role()='admin'); my_*/media_* = the signed-in
--   stockist's own data; lookup_values = readable by anyone (buyer filter runs anon).

-- ══════════════════════════════════════════════════════════════════════════════════════════════
-- GENERIC LOOKUPS  (space · placement · future list_keys)
-- ══════════════════════════════════════════════════════════════════════════════════════════════

-- Active values of a list, for pickers + the buyer filter. Open to anon (security definer bypasses RLS).
create or replace function public.lookup_values(p_list_key text)
 returns jsonb
 language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object('value', value, 'label', label)
                            order by sort_order, label), '[]'::jsonb)
    from admin_lookups where list_key = p_list_key and active;
$function$;

-- Admin reader — includes INACTIVE rows, for the Managed-lists editor.
create or replace function public.admin_lookups_list(p_list_key text)
 returns jsonb
 language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  select case when current_user_role() <> 'admin' then '[]'::jsonb
    else coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', id, 'value', value, 'label', label,
               'sort_order', sort_order, 'active', active)
             order by sort_order, label)
        from admin_lookups where list_key = p_list_key), '[]'::jsonb)
  end;
$function$;

-- Add a value. Value is slugged from the label (stable, referenced by convention).
create or replace function public.admin_lookup_add(p_list_key text, p_label text)
 returns uuid
 language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_val text; v_id uuid; v_next int;
begin
  if current_user_role() <> 'admin' then raise exception 'Only admins'; end if;
  if btrim(coalesce(p_label,'')) = '' then raise exception 'Label required'; end if;
  v_val := btrim(regexp_replace(lower(p_label), '[^a-z0-9]+', '_', 'g'), '_');
  if v_val = '' then raise exception 'Label must contain letters or digits'; end if;
  select coalesce(max(sort_order),0) + 10 into v_next from admin_lookups where list_key = p_list_key;
  insert into admin_lookups (list_key, value, label, sort_order)
    values (p_list_key, v_val, btrim(p_label), v_next)
    on conflict (list_key, lower(value)) do update set label = excluded.label, active = true
    returning id into v_id;
  return v_id;
end $function$;

create or replace function public.admin_lookup_rename(p_id uuid, p_label text)
 returns void
 language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
begin
  if current_user_role() <> 'admin' then raise exception 'Only admins'; end if;
  if btrim(coalesce(p_label,'')) = '' then raise exception 'Label required'; end if;
  update admin_lookups set label = btrim(p_label) where id = p_id;  -- value (the slug) is stable, never renamed
end $function$;

create or replace function public.admin_lookup_set_active(p_id uuid, p_active boolean)
 returns void
 language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
begin
  if current_user_role() <> 'admin' then raise exception 'Only admins'; end if;
  update admin_lookups set active = coalesce(p_active, false) where id = p_id;
end $function$;

create or replace function public.admin_lookup_set_sort(p_id uuid, p_sort integer)
 returns void
 language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
begin
  if current_user_role() <> 'admin' then raise exception 'Only admins'; end if;
  update admin_lookups set sort_order = coalesce(p_sort, 0) where id = p_id;
end $function$;

-- ══════════════════════════════════════════════════════════════════════════════════════════════
-- ADMIN GATING  (on/off per asset-type · quota on the heavy types)
-- ══════════════════════════════════════════════════════════════════════════════════════════════

create or replace function public.admin_set_stockist_media(p_seq text, p_type text, p_enabled boolean)
 returns void
 language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_on boolean := coalesce(p_enabled, false);
begin
  if current_user_role() <> 'admin' then raise exception 'Only admins'; end if;
  if p_type not in ('mockup','aligning','closelook','360','video') then
    raise exception 'Unknown media type: %', p_type;
  end if;
  update stockists set
    media_mockup_enabled    = case when p_type='mockup'    then v_on else media_mockup_enabled    end,
    media_aligning_enabled  = case when p_type='aligning'  then v_on else media_aligning_enabled  end,
    media_closelook_enabled = case when p_type='closelook' then v_on else media_closelook_enabled end,
    media_360_enabled       = case when p_type='360'       then v_on else media_360_enabled       end,
    media_video_enabled     = case when p_type='video'     then v_on else media_video_enabled     end
  where sequential_id = p_seq;
end $function$;

-- Count quota on the heavy types only (360, video). Controls storage; images have no cap.
create or replace function public.admin_set_stockist_media_quota(p_seq text, p_type text, p_quota integer)
 returns void
 language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_q int := greatest(coalesce(p_quota, 0), 0);
begin
  if current_user_role() <> 'admin' then raise exception 'Only admins'; end if;
  if p_type not in ('360','video') then raise exception 'Quota applies to 360/video only'; end if;
  update stockists set
    media_360_quota   = case when p_type='360'   then v_q else media_360_quota   end,
    media_video_quota = case when p_type='video' then v_q else media_video_quota end
  where sequential_id = p_seq;
end $function$;

-- ══════════════════════════════════════════════════════════════════════════════════════════════
-- STOCKIST: config the app needs (which asset-types are on, quotas, current heavy counts)
-- ══════════════════════════════════════════════════════════════════════════════════════════════

create or replace function public.my_media_config()
 returns jsonb
 language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  with me as (select id from stockists where user_id = auth.uid())
  select coalesce((
    select jsonb_build_object(
      'mockup',    s.media_mockup_enabled,
      'aligning',  s.media_aligning_enabled,
      'closelook', s.media_closelook_enabled,
      '360',       s.media_360_enabled,
      'video',     s.media_video_enabled,
      'quota_360',   s.media_360_quota,
      'quota_video', s.media_video_quota,
      'used_360',   (select count(*) from media_asset a where a.stockist_id = s.id and a.type = '360'),
      'used_video', (select count(*) from media_asset a where a.stockist_id = s.id and a.type = 'video'))
    from stockists s where s.id = (select id from me)
  ), '{}'::jsonb);
$function$;

-- ══════════════════════════════════════════════════════════════════════════════════════════════
-- MEDIA CRUD  (stockist writer — gating + quota enforced)
-- ══════════════════════════════════════════════════════════════════════════════════════════════

-- Internal: the calling stockist, or raise.
create or replace function public._media_me() returns uuid
 language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $function$
declare v uuid;
begin
  select id into v from stockists where user_id = auth.uid();
  if v is null then raise exception 'Only stockists'; end if;
  return v;
end $function$;

-- Internal: is this asset-type enabled for the stockist?
create or replace function public._media_type_enabled(p_stk uuid, p_type text) returns boolean
 language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  select case p_type
    when 'mockup'    then media_mockup_enabled
    when 'aligning'  then media_aligning_enabled
    when 'closelook' then media_closelook_enabled
    when '360'       then media_360_enabled
    when 'video'     then media_video_enabled
    else false end
  from stockists where id = p_stk;
$function$;

-- Create an asset, tag its artworks, and set any tile overrides — all atomically.
-- p_print_ids : uuid[] as jsonb — the designs (artworks) in the shot (mockup/aligning/360/video).
-- p_tiles     : [{library_id, shown, placement}] — hand-pick overrides; for CloseLook this IS the binding.
create or replace function public.media_add(
  p_type text, p_url text, p_space text,
  p_print_ids jsonb default '[]'::jsonb, p_tiles jsonb default '[]'::jsonb)
 returns uuid
 language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare
  v_stk uuid := _media_me();
  v_space text; v_asset uuid; v_used int; v_quota int;
  pid uuid; t jsonb; v_lib uuid; v_place text;
begin
  if p_type not in ('mockup','aligning','closelook','360','video') then
    raise exception 'Unknown media type: %', p_type;
  end if;
  if not _media_type_enabled(v_stk, p_type) then
    raise exception '% is not enabled for you — ask the admin to turn it on.', p_type;
  end if;
  -- quota on the heavy types
  if p_type in ('360','video') then
    select case p_type when '360' then media_360_quota else media_video_quota end
      into v_quota from stockists where id = v_stk;
    select count(*) into v_used from media_asset where stockist_id = v_stk and type = p_type;
    if v_used >= coalesce(v_quota, 0) then
      raise exception 'You have used your % quota (%). Ask the admin to raise it.', p_type, coalesce(v_quota,0);
    end if;
  end if;

  v_space := (select value from admin_lookups
               where list_key = 'space' and active and lower(value) = lower(nullif(btrim(coalesce(p_space,'')),'')));

  insert into media_asset (stockist_id, type, url, space)
    values (v_stk, p_type, coalesce(btrim(p_url),''), v_space)
    returning id into v_asset;

  -- tag artworks (must be the stockist's own prints)
  for pid in select (jsonb_array_elements_text(coalesce(p_print_ids,'[]'::jsonb)))::uuid loop
    if exists (select 1 from print_master where id = pid and stockist_id = v_stk) then
      insert into media_asset_artwork (asset_id, print_id) values (v_asset, pid) on conflict do nothing;
    end if;
  end loop;

  -- tile rows (must be the stockist's own tiles)
  for t in select * from jsonb_array_elements(coalesce(p_tiles,'[]'::jsonb)) loop
    v_lib := nullif(t->>'library_id','')::uuid;
    if v_lib is null or not exists (select 1 from stockist_library where id = v_lib and stockist_id = v_stk) then
      continue;
    end if;
    v_place := coalesce((select value from admin_lookups
                          where list_key='placement' and active and lower(value)=lower(coalesce(t->>'placement',''))), 'both');
    insert into media_asset_tile (asset_id, library_id, shown, placement)
      values (v_asset, v_lib, coalesce((t->>'shown')::boolean, true), v_place)
      on conflict (asset_id, library_id) do update
        set shown = excluded.shown, placement = excluded.placement;
  end loop;

  return v_asset;
end $function$;

-- Internal: assert an asset belongs to the caller, return its stockist.
create or replace function public._media_own(p_asset uuid) returns uuid
 language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid := _media_me(); v_owner uuid;
begin
  select stockist_id into v_owner from media_asset where id = p_asset;
  if v_owner is null then raise exception 'No such material'; end if;
  if v_owner <> v_stk then raise exception 'That material is not yours'; end if;
  return v_stk;
end $function$;

create or replace function public.media_update(p_asset uuid, p_url text, p_space text)
 returns void
 language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid := _media_own(p_asset); v_space text;
begin
  v_space := (select value from admin_lookups
               where list_key='space' and active and lower(value)=lower(nullif(btrim(coalesce(p_space,'')),'')));
  update media_asset set url = coalesce(btrim(p_url),''), space = v_space, updated_at = now()
   where id = p_asset;
end $function$;

create or replace function public.media_set_artworks(p_asset uuid, p_print_ids jsonb)
 returns void
 language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid := _media_own(p_asset); pid uuid;
begin
  delete from media_asset_artwork where asset_id = p_asset;
  for pid in select (jsonb_array_elements_text(coalesce(p_print_ids,'[]'::jsonb)))::uuid loop
    if exists (select 1 from print_master where id = pid and stockist_id = v_stk) then
      insert into media_asset_artwork (asset_id, print_id) values (p_asset, pid) on conflict do nothing;
    end if;
  end loop;
  update media_asset set updated_at = now() where id = p_asset;
end $function$;

-- Replace the asset's tile overrides. Rows: [{library_id, shown, placement}].
create or replace function public.media_set_tiles(p_asset uuid, p_tiles jsonb)
 returns void
 language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid := _media_own(p_asset); t jsonb; v_lib uuid; v_place text;
begin
  delete from media_asset_tile where asset_id = p_asset;
  for t in select * from jsonb_array_elements(coalesce(p_tiles,'[]'::jsonb)) loop
    v_lib := nullif(t->>'library_id','')::uuid;
    if v_lib is null or not exists (select 1 from stockist_library where id = v_lib and stockist_id = v_stk) then
      continue;
    end if;
    v_place := coalesce((select value from admin_lookups
                          where list_key='placement' and active and lower(value)=lower(coalesce(t->>'placement',''))), 'both');
    insert into media_asset_tile (asset_id, library_id, shown, placement)
      values (p_asset, v_lib, coalesce((t->>'shown')::boolean, true), v_place);
  end loop;
  update media_asset set updated_at = now() where id = p_asset;
end $function$;

create or replace function public.media_delete(p_asset uuid)
 returns void
 language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid := _media_own(p_asset);
begin
  delete from media_asset where id = p_asset;   -- cascades artwork + tile rows
end $function$;

-- ══════════════════════════════════════════════════════════════════════════════════════════════
-- STOCKIST READS  (management: list materials · matrix overview)
-- ══════════════════════════════════════════════════════════════════════════════════════════════

-- All the stockist's materials (optionally one type), with tagged artworks + tile overrides.
create or replace function public.my_media(p_type text default null)
 returns jsonb
 language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  with me as (select id from stockists where user_id = auth.uid())
  select coalesce(jsonb_agg(row order by row->>'created_at' desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', a.id, 'type', a.type, 'url', a.url,
      'space', a.space,
      'space_label', (select label from admin_lookups where list_key='space' and value = a.space),
      'sort_order', a.sort_order, 'created_at', a.created_at,
      'artworks', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'print_id', pm.id, 'name', pm.print_name, 'size', pm.size, 'image_url', pm.image_url)
               order by pm.print_name)
          from media_asset_artwork ma join print_master pm on pm.id = ma.print_id
         where ma.asset_id = a.id), '[]'::jsonb),
      'tiles', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'library_id', l.id, 'print_id', l.print_id, 'name', pm.print_name,
                 'surface_type', l.surface_type, 'surface_label', l.surface_label,
                 'tile_type', l.tile_type, 'shown', mt.shown, 'placement', mt.placement)
               order by pm.print_name, l.surface_type)
          from media_asset_tile mt
          join stockist_library l on l.id = mt.library_id
          join print_master pm on pm.id = l.print_id
         where mt.asset_id = a.id), '[]'::jsonb)
    ) as row
    from media_asset a
    where a.stockist_id = (select id from me)
      and (p_type is null or a.type = p_type)
  ) t;
$function$;

-- Overview matrix: one row per artwork × media-type counts (spot gaps).
create or replace function public.my_portfolio_matrix()
 returns jsonb
 language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  with me as (select id from stockists where user_id = auth.uid())
  select coalesce(jsonb_agg(jsonb_build_object(
           'print_id', pm.id, 'name', pm.print_name, 'size', pm.size, 'image_url', pm.image_url,
           'mockup',    (select count(*) from media_asset a join media_asset_artwork ma on ma.asset_id=a.id
                          where ma.print_id=pm.id and a.type='mockup'),
           'aligning',  (select count(*) from media_asset a join media_asset_artwork ma on ma.asset_id=a.id
                          where ma.print_id=pm.id and a.type='aligning'),
           '360',       (select count(*) from media_asset a join media_asset_artwork ma on ma.asset_id=a.id
                          where ma.print_id=pm.id and a.type='360'),
           'video',     (select count(*) from media_asset a join media_asset_artwork ma on ma.asset_id=a.id
                          where ma.print_id=pm.id and a.type='video'),
           'closelook', (select count(distinct a.id) from media_asset a
                          join media_asset_tile mt on mt.asset_id=a.id and mt.shown
                          join stockist_library l on l.id=mt.library_id
                          where l.print_id=pm.id and a.type='closelook'))
         order by pm.print_name), '[]'::jsonb)
    from print_master pm
   where pm.stockist_id = (select id from me);
$function$;
