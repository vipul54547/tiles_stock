-- ═══ THE ARTWORK LIBRARY — print_master, with its IMAGE DNA ═══════════════════════════════════
--
-- His words: "now i need page print_Master where we can see layout like My Design Library and
-- instead of Surface, tile_type, piece and weight we need our option for Look_type>Natural_Name,
-- Print_type, Joint_type, colour — and we will map directly from here. And new add print show first."
--
-- 🖼️ THE ARTWORK LIBRARY is the Design Library's twin, one level up:
--
--     My Design Library   a TILE   → surface · body · packing · covers
--     My Artworks         a PRINT  → Look Type ▸ Natural Name · Print Type · Design Joint · Colour
--
-- Those four ARE the image DNA (scope='print', 20260714d). They describe the PICTURE, so they
-- belong to the picture — and every tile ever cut from it inherits them. Tag `1001` once and its
-- Matt, Carving and GHR all carry it.
--
-- ⚠️ WHY A NEW WRITER. `dna_set_design(library_id, …)` routes by scope, but it resolves the print
-- FROM A TILE. After the folder import an artwork HAS NO TILE — that is now the normal state — so
-- there is no library_id to route through. The image DNA has to be settable on the print directly.

-- ── 1. Every artwork, newest first, with its image DNA ──────────────────────────────────────
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
           -- How many TILES have been cut from it. 0 = he has the picture and has not yet said
           -- what he sells from it. That is honest, not broken.
           'tiles', (select count(*) from stockist_library l where l.print_id = pm.id),
           -- Its IMAGE DNA: attributeId -> [valueId]. The page maps straight from this.
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
         -- 🔑 NEWLY ADDED PRINTS SHOW FIRST.
         order by pm.created_at desc, pm.print_name), '[]'::jsonb)
    from print_master pm
   where pm.stockist_id = (select id from me);
$function$;

revoke all on function public.my_artworks() from public, anon;
grant execute on function public.my_artworks() to authenticated;

-- ── 2. Tag an artwork DIRECTLY — no tile needed ─────────────────────────────────────────────
create or replace function public.print_dna_set(
  p_print_id uuid, p_attribute_id uuid, p_value_ids uuid[]
) returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_scope text; v_parent uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;

  if not exists (select 1 from print_master
                  where id = p_print_id and stockist_id = v_stk) then
    raise exception 'That artwork is not yours';
  end if;

  select scope, parent_attribute_id into v_scope, v_parent
    from dna_attributes where id = p_attribute_id;

  -- 🚫 Only the IMAGE DNA lives on a print. Anything else describes the TILE (Punch, Application,
  -- Series) and has no meaning here — a picture is not made of anything and is not packed.
  if v_scope is distinct from 'print' then
    raise exception 'That is not image DNA — it belongs to a design, not to the artwork.';
  end if;

  -- A child value needs its parent tagged first (Natural Name sits under Look Type).
  if v_parent is not null then
    if exists (
      select 1 from dna_values v
       where v.id = any(coalesce(p_value_ids, array[]::uuid[]))
         and v.attribute_id = p_attribute_id
         and v.parent_value_id is not null
         and not exists (
           select 1 from print_dna pd
            where pd.print_id = p_print_id and pd.value_id = v.parent_value_id)
    ) then
      raise exception 'Pick the parent value first';
    end if;
  end if;

  delete from print_dna pd using dna_values v
    where pd.value_id = v.id and pd.print_id = p_print_id
      and v.attribute_id = p_attribute_id;

  insert into print_dna (print_id, value_id)
    select p_print_id, v.id from dna_values v
     where v.id = any(coalesce(p_value_ids, array[]::uuid[]))
       and v.attribute_id = p_attribute_id
  on conflict do nothing;

  -- Drop any child whose parent chain just broke.
  with recursive orphan as (
    select cv.id
      from print_dna pd
      join dna_values cv on cv.id = pd.value_id
      join dna_attributes ca on ca.id = cv.attribute_id
     where pd.print_id = p_print_id
       and ca.parent_attribute_id = p_attribute_id
       and cv.parent_value_id is not null
       and not exists (
         select 1 from print_dna p2
          where p2.print_id = p_print_id and p2.value_id = cv.parent_value_id)
    union
    select gv.id
      from orphan o
      join dna_values gv on gv.parent_value_id = o.id
      join print_dna pd on pd.print_id = p_print_id and pd.value_id = gv.id
  )
  delete from print_dna where print_id = p_print_id and value_id in (select id from orphan);
end $function$;

revoke all on function public.print_dna_set(uuid, uuid, uuid[]) from public, anon;
grant execute on function public.print_dna_set(uuid, uuid, uuid[]) to authenticated;
