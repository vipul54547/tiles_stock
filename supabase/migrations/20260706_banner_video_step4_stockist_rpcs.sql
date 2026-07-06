-- ============================================================================
-- BANNER VIDEO — step 4: STOCKIST write RPCs ("My Videos")
-- (project: "Banner Video" / project_tutorial_videos_plan)
--
-- A stockist manages their OWN collection/promo videos. Every function
-- auto-scopes to the caller's stockist (via auth.uid()); a stockist can never
-- touch admin/global rows or another stockist's rows. Whether these actually
-- DISPLAY is governed by the admin-set mode (off/admin/mixed/stockist) — the
-- stockist is always allowed to ADD, the admin decides if they show. Library
-- (<=50) and active (<=5) caps are enforced by the existing trigger.
-- ============================================================================

-- Caller's stockist id, or raise if the caller isn't a stockist.
create or replace function public._my_stockist_id()
 returns uuid
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select id from public.stockists where user_id = auth.uid();
$function$;

-- 1. Read: own videos (INCLUDING hidden), for the My Videos list.
create or replace function public.stockist_my_videos()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_sid uuid;
begin
  v_sid := public._my_stockist_id();
  if v_sid is null then raise exception 'not a stockist'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'id', v.id, 'kind', v.kind, 'title', v.title, 'subtitle', v.subtitle,
        'youtube_id', v.youtube_id, 'video_url', v.video_url,
        'sort_order', v.sort_order, 'is_active', v.is_active,
        'thumbnail', 'https://img.youtube.com/vi/' || v.youtube_id || '/hqdefault.jpg'
      ) order by v.sort_order, v.created_at)
    from public.tutorial_videos v
    where v.stockist_id = v_sid and v.deleted_at is null
  ), '[]'::jsonb);
end;
$function$;

-- 2. The admin-set display mode for the caller's stockist (read-only note).
create or replace function public.stockist_my_video_mode()
 returns text
 language plpgsql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_sid uuid;
begin
  v_sid := public._my_stockist_id();
  if v_sid is null then raise exception 'not a stockist'; end if;
  return coalesce((select tutorial_video_mode from public.stockists where id = v_sid), 'mixed');
end;
$function$;

-- 3. Upsert own video (p_id null = insert). youtube_id derived from the link.
create or replace function public.stockist_save_video(
  p_id uuid, p_kind text, p_title text, p_subtitle text, p_url text,
  p_sort_order int default 0, p_is_active boolean default true)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_sid uuid; v_yt text; v_id uuid;
begin
  v_sid := public._my_stockist_id();
  if v_sid is null then raise exception 'not a stockist'; end if;

  v_yt := public.yt_video_id(p_url);
  if v_yt is null then
    raise exception 'Could not read a YouTube video id from: %', coalesce(p_url,'(empty)');
  end if;
  if coalesce(p_kind,'') not in ('tutorial','collection') then
    raise exception 'invalid kind: %', p_kind;
  end if;

  if p_id is null then
    insert into public.tutorial_videos
      (stockist_id, kind, title, subtitle, video_url, youtube_id, sort_order, is_active)
    values (v_sid, p_kind, coalesce(p_title,''), coalesce(p_subtitle,''),
       p_url, v_yt, coalesce(p_sort_order,0), coalesce(p_is_active,true))
    returning id into v_id;
  else
    update public.tutorial_videos
       set kind = p_kind, title = coalesce(p_title,''), subtitle = coalesce(p_subtitle,''),
           video_url = p_url, youtube_id = v_yt,
           sort_order = coalesce(p_sort_order, sort_order), is_active = coalesce(p_is_active, is_active)
     where id = p_id and stockist_id = v_sid   -- own rows only
    returning id into v_id;
    if v_id is null then raise exception 'video not found'; end if;
  end if;
  return v_id;
end;
$function$;

-- 4. Show/hide + soft-delete/restore — own rows only.
create or replace function public.stockist_set_video_active(p_id uuid, p_active boolean)
 returns void language plpgsql security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_sid uuid;
begin
  v_sid := public._my_stockist_id();
  if v_sid is null then raise exception 'not a stockist'; end if;
  update public.tutorial_videos set is_active = coalesce(p_active,false)
   where id = p_id and stockist_id = v_sid;
end;
$function$;

create or replace function public.stockist_delete_video(p_id uuid)
 returns void language plpgsql security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_sid uuid;
begin
  v_sid := public._my_stockist_id();
  if v_sid is null then raise exception 'not a stockist'; end if;
  update public.tutorial_videos set deleted_at = now()
   where id = p_id and stockist_id = v_sid and deleted_at is null;
end;
$function$;

create or replace function public.stockist_restore_video(p_id uuid)
 returns void language plpgsql security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_sid uuid;
begin
  v_sid := public._my_stockist_id();
  if v_sid is null then raise exception 'not a stockist'; end if;
  update public.tutorial_videos set deleted_at = null
   where id = p_id and stockist_id = v_sid;
end;
$function$;

-- Grants: authenticated only (each function self-scopes to the caller).
revoke execute on function public._my_stockist_id() from public;
revoke execute on function public.stockist_my_videos() from public;
revoke execute on function public.stockist_my_video_mode() from public;
revoke execute on function public.stockist_save_video(uuid, text, text, text, text, int, boolean) from public;
revoke execute on function public.stockist_set_video_active(uuid, boolean) from public;
revoke execute on function public.stockist_delete_video(uuid) from public;
revoke execute on function public.stockist_restore_video(uuid) from public;

grant execute on function public.stockist_my_videos() to authenticated;
grant execute on function public.stockist_my_video_mode() to authenticated;
grant execute on function public.stockist_save_video(uuid, text, text, text, text, int, boolean) to authenticated;
grant execute on function public.stockist_set_video_active(uuid, boolean) to authenticated;
grant execute on function public.stockist_delete_video(uuid) to authenticated;
grant execute on function public.stockist_restore_video(uuid) to authenticated;
