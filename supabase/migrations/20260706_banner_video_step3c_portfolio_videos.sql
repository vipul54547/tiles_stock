-- ============================================================================
-- BANNER VIDEO — step 3c: per-supplier videos for the in-app portfolio
-- (project: "Banner Video" / project_tutorial_videos_plan)
--
-- A logged-in buyer viewing a supplier in the app (StockistPortfolioScreen)
-- opens that supplier by sequential_id, not a share token. This resolves the
-- stockist by sequential_id and applies the SAME 4-step mode + mixed 2:1
-- interleave as public_list_videos(token). Read-only; granted to authenticated.
-- ============================================================================
create or replace function public.stockist_public_videos(p_seq text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_sid  uuid;
  v_mode text;
begin
  select s.id, coalesce(s.tutorial_video_mode, 'mixed')
    into v_sid, v_mode
  from public.stockists s
  where s.is_active and s.sequential_id = p_seq
  limit 1;

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
      ) order by pos, created_at)
    from ordered
  ), '[]'::jsonb);
end;
$function$;

revoke execute on function public.stockist_public_videos(text) from public;
grant  execute on function public.stockist_public_videos(text) to anon, authenticated;
