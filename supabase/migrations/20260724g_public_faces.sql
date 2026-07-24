-- 20260724g — 🖼️ MEDIA PORTFOLIO, P1 slice 3n: buyer FACES read.
--
-- Faces are the artwork's extra face images (print_faces, position≥2) — "portfolio media, NOT
-- identity" (CLAUDE.md), and DDPI #14 puts them in the buyer viewer's playlist order
-- (…close-look → FACES → 360…). They live per-PRINT, so this is a light per-design map keyed by
-- library_id, resolved by the same /s/ token as public_portfolio. The frontend folds a design's
-- faces into that design's "View" viewer alongside its media assets.
--
-- Stock-blind, anon-callable (SECURITY DEFINER), additive.

create or replace function public.public_faces(p_token text)
 returns jsonb
 language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  with stk as (
    select s.id
      from stockists s
     where s.is_active
       and (s.share_token = p_token
            or exists (select 1 from stockist_share_links l
                        where l.stockist_id = s.id and l.token = p_token and l.is_active
                          and (l.expires_at is null or l.expires_at > now())))
    union
    select c.stockist_id
      from stock_catalogs c join stockists s on s.id = c.stockist_id
     where c.is_active and s.is_active
       and (c.share_token = p_token
            or exists (select 1 from stockist_share_links l
                        where l.catalog_id = c.id and l.token = p_token and l.is_active
                          and (l.expires_at is null or l.expires_at > now())))
    limit 1
  )
  select coalesce(jsonb_agg(jsonb_build_object('library_id', l.id, 'faces', f.faces)), '[]'::jsonb)
    from stockist_library l
    join (select print_id, jsonb_agg(image_url order by position) as faces
            from print_faces group by print_id) f on f.print_id = l.print_id
   where l.stockist_id = (select id from stk);
$function$;
