-- ============================================================================
-- BANNER VIDEO — step 1: schema + RLS + read RPCs
-- (project: "Banner Video" / project_tutorial_videos_plan)
--
-- A "▶ Watch" video system shown in the TOP BANNER of a stockist's /s/ weblink
-- (and the buyer app home). The banner alternates shop-identity <-> a 9:16
-- YouTube promo, one at a time. Videos belong to the STOCKIST, or are admin
-- (global). Platform = YouTube only (embedded, closable, auto thumbnail).
--
-- Ownership + control:
--   * tutorial_videos.stockist_id NULL  = admin / global (learning videos)
--   * tutorial_videos.stockist_id set   = that stockist's own (collection/promo)
--   * stockists.tutorial_video_mode  off | admin | mixed | stockist  (admin-set)
--       off      : no video
--       admin    : only global learning videos
--       mixed    : 2 stockist : 1 admin interleave   (DEFAULT)
--       stockist : only that stockist's own videos
--
-- Limits (STOCKIST only; admin/global is uncapped — operator voice):
--   * library (stored) <= 50 per stockist
--   * active  ("Show")  <= 5  per stockist
--   * Show/Hide = is_active toggle (keeps the row in the library)
--   * Delete    = deleted_at (24h soft-delete grace, like brands/lists)
-- ============================================================================

-- 1. Per-stockist display mode ------------------------------------------------
alter table public.stockists
  add column if not exists tutorial_video_mode text not null default 'mixed';

alter table public.stockists
  drop constraint if exists stockists_tutorial_video_mode_chk;
alter table public.stockists
  add constraint stockists_tutorial_video_mode_chk
  check (tutorial_video_mode in ('off','admin','mixed','stockist'));

-- 2. Videos table -------------------------------------------------------------
create table if not exists public.tutorial_videos (
  id          uuid primary key default gen_random_uuid(),
  stockist_id uuid references public.stockists(id) on delete cascade,  -- NULL = admin/global
  kind        text not null default 'tutorial' check (kind in ('tutorial','collection')),
  title       text not null default '',
  subtitle    text not null default '',
  video_url   text not null,
  youtube_id  text not null,
  sort_order  int  not null default 0,
  is_active   boolean not null default true,   -- "Show" (max 5 live per stockist)
  deleted_at  timestamptz,                     -- soft-delete (24h grace)
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists tutorial_videos_owner_idx
  on public.tutorial_videos (stockist_id) where deleted_at is null;
create index if not exists tutorial_videos_active_idx
  on public.tutorial_videos (stockist_id, is_active) where deleted_at is null;

-- 3. YouTube id extractor: any link form -> the 11-char video id ---------------
--    youtu.be/<id> | watch?v=<id> | /shorts/<id> | /embed/<id> | /live/<id>
--    or a bare 11-char id. Returns NULL if nothing matches.
create or replace function public.yt_video_id(p_url text)
 returns text
 language sql
 immutable
as $function$
  select coalesce(
    substring(coalesce(p_url,'')
              from '(?:youtu\.be/|[?&]v=|/shorts/|/embed/|/live/)([A-Za-z0-9_-]{11})'),
    case when coalesce(p_url,'') ~ '^[A-Za-z0-9_-]{11}$' then p_url else null end
  );
$function$;

-- 4. Enforce stockist caps (admin/global uncapped; soft-deleted rows ignored) --
create or replace function public._tutorial_video_limits()
 returns trigger
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_live   int;
  v_active int;
begin
  new.updated_at := now();

  -- admin/global rows and soft-deleted rows are not capped
  if new.stockist_id is null or new.deleted_at is not null then
    return new;
  end if;

  select count(*) into v_live
    from public.tutorial_videos
   where stockist_id = new.stockist_id and deleted_at is null and id <> new.id;
  if v_live + 1 > 50 then
    raise exception 'Video library is full (max 50). Delete an old video first.';
  end if;

  if new.is_active then
    select count(*) into v_active
      from public.tutorial_videos
     where stockist_id = new.stockist_id and deleted_at is null
       and is_active and id <> new.id;
    if v_active + 1 > 5 then
      raise exception 'Only 5 videos can be shown at once. Hide one first.';
    end if;
  end if;

  return new;
end;
$function$;

drop trigger if exists trg_tutorial_video_limits on public.tutorial_videos;
create trigger trg_tutorial_video_limits
  before insert or update on public.tutorial_videos
  for each row execute function public._tutorial_video_limits();

-- 5. RLS ----------------------------------------------------------------------
alter table public.tutorial_videos enable row level security;

-- public (anon + buyers): read only live, shown rows
drop policy if exists tutorial_videos_public_read on public.tutorial_videos;
create policy tutorial_videos_public_read on public.tutorial_videos
  for select to anon, authenticated
  using (is_active and deleted_at is null);

-- stockist: full control of own rows (including hidden ones)
drop policy if exists tutorial_videos_stockist_all on public.tutorial_videos;
create policy tutorial_videos_stockist_all on public.tutorial_videos
  for all to authenticated
  using (stockist_id in (select id from public.stockists where user_id = auth.uid()))
  with check (stockist_id in (select id from public.stockists where user_id = auth.uid()));

-- admin: full control of everything (including global rows)
drop policy if exists tutorial_videos_admin_all on public.tutorial_videos;
create policy tutorial_videos_admin_all on public.tutorial_videos
  for all to authenticated
  using (public.current_user_role() = 'admin')
  with check (public.current_user_role() = 'admin');

-- 6. Read RPC: buyer app home = global admin learning videos ------------------
create or replace function public.global_videos()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', v.id, 'kind', v.kind, 'title', v.title, 'subtitle', v.subtitle,
      'youtube_id', v.youtube_id, 'video_url', v.video_url,
      'thumbnail', 'https://img.youtube.com/vi/' || v.youtube_id || '/hqdefault.jpg',
      'owner', 'admin'
    ) order by v.sort_order, v.created_at
  ), '[]'::jsonb)
  from public.tutorial_videos v
  where v.stockist_id is null and v.is_active and v.deleted_at is null;
$function$;

grant execute on function public.global_videos() to anon, authenticated;

-- 7. Read RPC: a stockist's /s/ weblink, resolved by share token --------------
--    Applies the 4-step mode. Mixed = 2 stockist : 1 admin interleave, so the
--    stockist's own videos keep 2/3 airtime on their own page no matter how many
--    admin videos exist (positions: stockist -> 1,2,4,5,7...; admin -> 3,6,9...).
create or replace function public.public_list_videos(p_token text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_sid  uuid;
  v_mode text;
begin
  -- resolve stockist from token: stockist.share_token OR a stockist share link
  select s.id, coalesce(s.tutorial_video_mode, 'mixed')
    into v_sid, v_mode
  from public.stockists s
  where s.is_active
    and (s.share_token = p_token
         or exists (select 1 from public.stockist_share_links l
                    where l.stockist_id = s.id and l.token = p_token and l.is_active
                      and (l.expires_at is null or l.expires_at > now())))
  limit 1;

  -- token may be a per-catalog link OR a catalog share_token -> map to stockist
  if v_sid is null then
    select s.id, coalesce(s.tutorial_video_mode, 'mixed')
      into v_sid, v_mode
    from public.stock_catalogs c
    join public.stockists s on s.id = c.stockist_id and s.is_active
    where c.is_active
      and (c.share_token = p_token
           or exists (select 1 from public.stockist_share_links l
                      where l.catalog_id = c.id and l.token = p_token and l.is_active
                        and (l.expires_at is null or l.expires_at > now())))
    limit 1;
  end if;

  if v_sid is null or v_mode = 'off' then
    return '[]'::jsonb;
  end if;

  return coalesce((
    with vids as (
      select v.*,
        case when v.stockist_id is null then 'admin' else 'stockist' end as owner,
        row_number() over (partition by (v.stockist_id is null)
                           order by v.sort_order, v.created_at) as rn
      from public.tutorial_videos v
      where v.is_active and v.deleted_at is null
        and (
              (v_mode = 'admin'    and v.stockist_id is null)
           or (v_mode = 'stockist' and v.stockist_id = v_sid)
           or (v_mode = 'mixed'    and (v.stockist_id is null or v.stockist_id = v_sid))
        )
    ),
    ordered as (
      select *,
        case when owner = 'stockist'
             then rn + ((rn - 1) / 2)   -- 1,2,4,5,7,8 ...
             else rn * 3                -- 3,6,9 ...
        end as pos
      from vids
    )
    select jsonb_agg(
      jsonb_build_object(
        'id', id, 'kind', kind, 'title', title, 'subtitle', subtitle,
        'youtube_id', youtube_id, 'video_url', video_url,
        'thumbnail', 'https://img.youtube.com/vi/' || youtube_id || '/hqdefault.jpg',
        'owner', owner
      ) order by pos, created_at
    )
    from ordered
  ), '[]'::jsonb);
end;
$function$;

grant execute on function public.public_list_videos(text) to anon, authenticated;
