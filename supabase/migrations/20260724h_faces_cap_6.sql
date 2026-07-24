-- 20260724h — 🖼️ MEDIA PORTFOLIO: cap faces at 6 per artwork (main + 5 extras).
--
-- Faces are shown TOGETHER as a comparison grid (main design Faces-1 + extras). Six is the most
-- that reads at a glance, so print_face_add now refuses a 6th EXTRA (Faces-1 is the print image, the
-- extras live in print_faces → max 5 rows). Storage is unchanged: each face is the original,
-- full-resolution Cloudinary upload (kept for future auto room-mockup generation) — only the VIEW
-- shrinks them.

create or replace function public.print_face_add(p_print_id uuid, p_image_url text)
 returns void
 language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_next int;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;

  if not exists (select 1 from print_master
                  where id = p_print_id and stockist_id = v_stk) then
    raise exception 'That artwork is not yours';
  end if;

  if btrim(coalesce(p_image_url, '')) = '' then
    raise exception 'A face needs an image';
  end if;

  -- 6 faces total including the main design (Faces-1 = the print image) → at most 5 EXTRA faces.
  if (select count(*) from print_faces where print_id = p_print_id) >= 5 then
    raise exception 'An artwork can have at most 6 faces (the main design + 5 more).';
  end if;

  -- Faces-1 is the print's own image_url (position 1), so the first EXTRA face is 2.
  select coalesce(max(position), 1) + 1 into v_next
    from print_faces where print_id = p_print_id;

  insert into print_faces (print_id, position, image_url)
  values (p_print_id, v_next, btrim(p_image_url));
end $function$;
