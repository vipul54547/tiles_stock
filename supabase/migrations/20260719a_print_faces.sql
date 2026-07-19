-- ═══ FACES — an artwork carries MORE THAN ONE picture ═════════════════════════════════════════
--
-- His words: "artwork is print for different type of faces. which image we uploaded is basically
-- Faces-1; for the remaining faces I need an upload button, and the name is automatic like
-- 'ant bianco faces-1', 'ant bianco faces-2', 'faces-3', 'faces-4'."
--
-- A design ships with 2/3/4 different prints — the faces. They belong to the ARTWORK (the picture),
-- not to a box: every tile ever cut from the print carries all of them. This is portfolio media,
-- NOT identity — the print key (stockist + print_name + size), the tile, the box and the holding
-- are all untouched. Purely additive.
--
-- 🔑 Faces-1 stays as print_master.image_url (the card/primary image every reader already uses).
--    The EXTRA faces (2, 3, 4 …) live here. The NAME is derived, never stored — "<print> faces-N".

-- ── 1. the table ────────────────────────────────────────────────────────────────────────────
create table if not exists print_faces (
  id         uuid primary key default gen_random_uuid(),
  print_id   uuid not null references print_master(id) on delete cascade,
  position   int  not null check (position >= 2),   -- Faces-1 is print_master.image_url
  image_url  text not null,
  created_at timestamptz not null default now(),
  constraint print_faces_uniq unique (print_id, position)
);
create index if not exists print_faces_print on print_faces (print_id);

comment on table print_faces is
  'The EXTRA faces of an artwork (Faces-2, 3, 4 …). Faces-1 is print_master.image_url. Portfolio '
  'media only, never identity. The display name is composed "<print_name> faces-<position>", '
  'never stored.';

-- Supabase grants anon/authenticated full DML on every new public table — revoke it here; all
-- access goes through the SECURITY DEFINER RPCs below.
alter table print_faces enable row level security;
revoke all on print_faces from anon, authenticated;

-- ── 2. add a face ───────────────────────────────────────────────────────────────────────────
-- Appends at the next free position (first extra face = 2). Ownership-checked.
create or replace function public.print_face_add(p_print_id uuid, p_image_url text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
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

  -- Faces-1 is the print's own image_url (position 1), so the first EXTRA face is 2.
  select coalesce(max(position), 1) + 1 into v_next
    from print_faces where print_id = p_print_id;

  insert into print_faces (print_id, position, image_url)
  values (p_print_id, v_next, btrim(p_image_url));
end $function$;

revoke all on function public.print_face_add(uuid, text) from public, anon;
grant execute on function public.print_face_add(uuid, text) to authenticated;

-- ── 3. delete a face ────────────────────────────────────────────────────────────────────────
-- Removes one extra face and re-sequences the rest so positions stay contiguous (2, 3, 4 …) —
-- there is no such thing as "faces-2, faces-4". Ownership-checked.
create or replace function public.print_face_delete(p_face_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_print uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;

  select pf.print_id into v_print
    from print_faces pf
    join print_master pm on pm.id = pf.print_id
   where pf.id = p_face_id and pm.stockist_id = v_stk;
  if v_print is null then raise exception 'That face is not yours'; end if;

  delete from print_faces where id = p_face_id;

  -- Close the gap: renumber the survivors from 2 upward, in their current order.
  with ordered as (
    select id, row_number() over (order by position) + 1 as new_pos
      from print_faces where print_id = v_print
  )
  update print_faces pf
     set position = o.new_pos
    from ordered o
   where pf.id = o.id and pf.position <> o.new_pos;
end $function$;

revoke all on function public.print_face_delete(uuid) from public, anon;
grant execute on function public.print_face_delete(uuid) to authenticated;

-- ── 4. my_artworks() now returns the faces array ────────────────────────────────────────────
-- Identical to 20260714n except for the new 'faces' key. image_url (Faces-1) is unchanged, so
-- every existing reader keeps working.
create or replace function public.my_artworks()
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  with me as (select id from stockists where user_id = auth.uid())
  select coalesce(jsonb_agg(jsonb_build_object(
           'print_id', pm.id,
           'name', pm.print_name,
           'size', pm.size,
           'image_url', pm.image_url,
           'created_at', pm.created_at,
           'tiles', (select count(*) from stockist_library l where l.print_id = pm.id),
           -- The EXTRA faces (2, 3, 4 …). Faces-1 is image_url above.
           'faces', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'id', pf.id, 'position', pf.position, 'image_url', pf.image_url)
                    order by pf.position)
               from print_faces pf where pf.print_id = pm.id
           ), '[]'::jsonb),
           'dna', coalesce((
             select jsonb_object_agg(g.aid::text, g.vals)
               from (
                 select v.attribute_id as aid, jsonb_agg(v.id::text) as vals
                   from print_dna pd
                   join dna_values v on v.id = pd.value_id and v.is_active
                  where pd.print_id = pm.id
                  group by v.attribute_id
               ) g
           ), '{}'::jsonb))
         order by pm.created_at desc, pm.print_name), '[]'::jsonb)
    from print_master pm
   where pm.stockist_id = (select id from me);
$function$;

revoke all on function public.my_artworks() from public, anon;
grant execute on function public.my_artworks() to authenticated;

-- ── 5. self-check (raise only on FAILURE — a plain RAISE would roll the migration back) ──────
do $$
declare v_faces_tbl regclass; v_add regprocedure; v_del regprocedure;
begin
  v_faces_tbl := to_regclass('public.print_faces');
  if v_faces_tbl is null then raise exception 'FAILED: print_faces table missing'; end if;
  perform 'public.print_face_add(uuid, text)'::regprocedure;
  perform 'public.print_face_delete(uuid)'::regprocedure;
  raise notice 'OK: print_faces + add/delete + my_artworks ready';
end $$;
