-- ============================================================================
-- BANNER VIDEO — step 2 (DB half): admin WRITE RPCs
-- (project: "Banner Video" / project_tutorial_videos_plan)
--
-- Powers the Admin "Banner Video" screen:
--   * manage GLOBAL learning videos (add / edit / show-hide / soft-delete)
--   * set each stockist's 4-step display mode (off | admin | mixed | stockist)
--
-- All functions are admin-gated (coalesce(current_user_role(),'') = 'admin' —
-- NULL-safe so a session with no profiles row fails CLOSED); they run
-- security definer so they bypass RLS but self-check the role, mirroring
-- admin_set_stockist_td. Stockists manage their OWN videos through separate
-- stockist_* RPCs (step 4) — nothing here writes a stockist's own rows except
-- the mode column, which is the admin's lever by design.
-- ============================================================================

-- 1. Set a stockist's display mode -------------------------------------------
create or replace function public.admin_set_stockist_video_mode(p_seq text, p_mode text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
begin
  if coalesce(current_user_role(),'') <> 'admin' then
    raise exception 'admin only';
  end if;
  if coalesce(p_mode,'') not in ('off','admin','mixed','stockist') then
    raise exception 'invalid mode: %', p_mode;
  end if;
  update public.stockists set tutorial_video_mode = p_mode
   where sequential_id = p_seq;
end;
$function$;

revoke execute on function public.admin_set_stockist_video_mode(text, text) from public;
grant  execute on function public.admin_set_stockist_video_mode(text, text) to authenticated;

-- 2. Upsert a video (p_id null = insert). Admin screen creates GLOBAL rows
--    (p_stockist_id null); the param is kept so admin can also seed a stockist
--    row if ever needed. youtube_id is derived from the pasted link. ----------
create or replace function public.admin_save_video(
  p_id          uuid,
  p_kind        text,
  p_title       text,
  p_subtitle    text,
  p_url         text,
  p_sort_order  int     default 0,
  p_is_active   boolean default true,
  p_stockist_id uuid    default null
)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_yt text;
  v_id uuid;
begin
  if coalesce(current_user_role(),'') <> 'admin' then
    raise exception 'admin only';
  end if;

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
    values
      (p_stockist_id, p_kind, coalesce(p_title,''), coalesce(p_subtitle,''),
       p_url, v_yt, coalesce(p_sort_order,0), coalesce(p_is_active,true))
    returning id into v_id;
  else
    update public.tutorial_videos
       set kind        = p_kind,
           title       = coalesce(p_title,''),
           subtitle    = coalesce(p_subtitle,''),
           video_url   = p_url,
           youtube_id  = v_yt,
           sort_order  = coalesce(p_sort_order, sort_order),
           is_active   = coalesce(p_is_active, is_active)
     where id = p_id
    returning id into v_id;
    if v_id is null then
      raise exception 'video not found: %', p_id;
    end if;
  end if;

  return v_id;
end;
$function$;

revoke execute on function public.admin_save_video(uuid, text, text, text, text, int, boolean, uuid) from public;
grant  execute on function public.admin_save_video(uuid, text, text, text, text, int, boolean, uuid) to authenticated;

-- 3. Show / hide (is_active). Trigger still enforces the 5-active cap for a
--    stockist row; global rows are uncapped. -------------------------------
create or replace function public.admin_set_video_active(p_id uuid, p_active boolean)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
begin
  if coalesce(current_user_role(),'') <> 'admin' then
    raise exception 'admin only';
  end if;
  update public.tutorial_videos set is_active = coalesce(p_active,false)
   where id = p_id;
end;
$function$;

revoke execute on function public.admin_set_video_active(uuid, boolean) from public;
grant  execute on function public.admin_set_video_active(uuid, boolean) to authenticated;

-- 4. Soft-delete + restore (24h grace, like brands/lists). ------------------
create or replace function public.admin_delete_video(p_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
begin
  if coalesce(current_user_role(),'') <> 'admin' then
    raise exception 'admin only';
  end if;
  update public.tutorial_videos set deleted_at = now()
   where id = p_id and deleted_at is null;
end;
$function$;

create or replace function public.admin_restore_video(p_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
begin
  if coalesce(current_user_role(),'') <> 'admin' then
    raise exception 'admin only';
  end if;
  -- clearing deleted_at re-runs the limits trigger (caps re-checked)
  update public.tutorial_videos set deleted_at = null
   where id = p_id;
end;
$function$;

revoke execute on function public.admin_delete_video(uuid)  from public;
revoke execute on function public.admin_restore_video(uuid) from public;
grant  execute on function public.admin_delete_video(uuid)  to authenticated;
grant  execute on function public.admin_restore_video(uuid) to authenticated;

-- 5. Read: global videos for the admin manage list (INCLUDING hidden ones, so
--    the admin can toggle them). Excludes soft-deleted. -----------------------
create or replace function public.admin_list_videos()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
begin
  if coalesce(current_user_role(),'') <> 'admin' then
    raise exception 'admin only';
  end if;
  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', v.id, 'kind', v.kind, 'title', v.title, 'subtitle', v.subtitle,
        'youtube_id', v.youtube_id, 'video_url', v.video_url,
        'sort_order', v.sort_order, 'is_active', v.is_active,
        'thumbnail', 'https://img.youtube.com/vi/' || v.youtube_id || '/hqdefault.jpg'
      ) order by v.sort_order, v.created_at
    )
    from public.tutorial_videos v
    where v.stockist_id is null and v.deleted_at is null
  ), '[]'::jsonb);
end;
$function$;

revoke execute on function public.admin_list_videos() from public;
grant  execute on function public.admin_list_videos() to authenticated;

-- 6. Read: every stockist + its current mode + own-video counts, for the
--    per-stockist mode selector list. -----------------------------------------
create or replace function public.admin_stockist_video_modes()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
begin
  if coalesce(current_user_role(),'') <> 'admin' then
    raise exception 'admin only';
  end if;
  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'seq',  s.sequential_id,
        'name', s.name,
        'city', s.city,
        'mode', coalesce(s.tutorial_video_mode,'mixed'),
        'active_count', (select count(*) from public.tutorial_videos v
                          where v.stockist_id = s.id and v.is_active and v.deleted_at is null),
        'lib_count',    (select count(*) from public.tutorial_videos v
                          where v.stockist_id = s.id and v.deleted_at is null)
      ) order by s.name
    )
    from public.stockists s
    where s.is_active
  ), '[]'::jsonb);
end;
$function$;

revoke execute on function public.admin_stockist_video_modes() from public;
grant  execute on function public.admin_stockist_video_modes() to authenticated;
