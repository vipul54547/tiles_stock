-- ═══ STEP 6 of docs/PACKING_BOX_HOLD_PLAN.md — PUT A BRAND'S COVER ON A PACKING ═══════════════
--
--   ARTWORK → TILE → PACKING → **BOX** → HOLD
--
-- 🎁 A BOX is a PACKING with a brand's corrugated cover round it. Until now nothing in the app
-- could put one on: `_box_for` created covers implicitly, at stock time. He needs to do it himself,
-- and to say what each brand prints on its cover.
--
-- 🔑 TWO DIFFERENT FACTS, and they are stored in two different places on purpose:
--
--   • THE COVER  — "does FAMOUS wrap this packing?" — is per (PACKING, brand): the `boxes` row.
--     FAMOUS may cover the 5-piece packing and not the 4-piece one.
--
--   • THE WORD ON IT — "FAMOUS prints 1001" — is per (TILE, brand): stockist_library_brand_names.
--     A brand prints the SAME word on every cover of a design, whatever packing is inside. Storing
--     it per packing would repeat it and let it DRIFT — one brand ending up with two words for one
--     design.

-- ── 1. my_packings now says WHO COVERS each packing ─────────────────────────────────────────
create or replace function public.my_packings(p_library_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id,
           'pieces', p.pieces,
           'weight_kg', p.weight_kg,
           -- The covers on THIS packing: which brands wrap it, and the box each one makes.
           'covers', coalesce((
             select jsonb_agg(jsonb_build_object('box_id', b.id, 'brand_id', b.brand_id))
               from boxes b where b.packing_id = p.id), '[]'::jsonb),
           -- Boxes of this packing that are actually HELD. A cover with stock behind it cannot be
           -- taken off — the boxes exist, whatever the app thinks.
           'held', coalesce((
             select sum(d.box_quantity) from designs d
               join boxes b on b.id = d.box_id
              where b.packing_id = p.id), 0))
         order by p.created_at), '[]'::jsonb)
    from packings p
    join stockist_library l on l.id = p.library_id
    join stockists s on s.id = l.stockist_id
   where p.library_id = p_library_id and s.user_id = auth.uid();
$function$;

-- ── 2. Put a cover on / take it off ─────────────────────────────────────────────────────────
create or replace function public.box_put_cover(p_packing_id uuid, p_brand_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_box uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;

  if not exists (
    select 1 from packings p join stockist_library l on l.id = p.library_id
     where p.id = p_packing_id and l.stockist_id = v_stk) then
    raise exception 'That packing is not yours';
  end if;
  if not exists (select 1 from brands where id = p_brand_id and stockist_id = v_stk) then
    raise exception 'That brand is not yours';
  end if;

  insert into boxes (packing_id, brand_id) values (p_packing_id, p_brand_id)
  on conflict (packing_id, brand_id) do nothing
    returning id into v_box;

  if v_box is null then
    select id into v_box from boxes
     where packing_id = p_packing_id and brand_id = p_brand_id;
  end if;
  return v_box;
end $function$;

create or replace function public.box_remove_cover(p_box_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_held int;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;

  if not exists (
    select 1 from boxes b
      join packings p on p.id = b.packing_id
      join stockist_library l on l.id = p.library_id
     where b.id = p_box_id and l.stockist_id = v_stk) then
    raise exception 'That box is not yours';
  end if;

  -- 🚫 A cover you are HOLDING stock in cannot be taken off. The boxes are in the godown whatever
  -- the app says, and the hold points at this box — removing it would make the stock unreachable.
  select coalesce(sum(box_quantity),0) into v_held from designs where box_id = p_box_id;
  if v_held > 0 then
    raise exception 'You are holding % boxes in this cover. Clear the stock first.', v_held;
  end if;

  delete from designs where box_id = p_box_id;  -- an empty hold row, if one is left over
  delete from boxes where id = p_box_id;
end $function$;

-- ── 3. The word that brand prints on its cover ──────────────────────────────────────────────
-- Per (TILE, brand). `1001` on FAMOUS, `601001` on ANUJ.
-- ⚠️ It is HIS to give. It must NEVER be defaulted from a filename — that is the stockist's own
-- word for the ARTWORK, and forging it as a factory's box label is what 20260714e removed.
create or replace function public.cover_name_set(
  p_library_id uuid, p_brand_id uuid, p_name text
) returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_name text := btrim(coalesce(p_name,''));
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;

  if not exists (select 1 from stockist_library
                  where id = p_library_id and stockist_id = v_stk) then
    raise exception 'That design is not yours';
  end if;
  if not exists (select 1 from brands where id = p_brand_id and stockist_id = v_stk) then
    raise exception 'That brand is not yours';
  end if;

  if v_name = '' then
    -- Blank = this brand has no word for this design. Honest, and allowed.
    delete from stockist_library_brand_names
     where library_id = p_library_id and brand_id = p_brand_id;
    return;
  end if;

  insert into stockist_library_brand_names (library_id, brand_id, brand_design_name)
       values (p_library_id, p_brand_id, v_name)
  on conflict (library_id, brand_id) do update
    set brand_design_name = excluded.brand_design_name;
end $function$;

revoke all on function public.box_put_cover(uuid, uuid)    from public, anon;
revoke all on function public.box_remove_cover(uuid)       from public, anon;
revoke all on function public.cover_name_set(uuid, uuid, text) from public, anon;
grant execute on function public.box_put_cover(uuid, uuid)    to authenticated;
grant execute on function public.box_remove_cover(uuid)       to authenticated;
grant execute on function public.cover_name_set(uuid, uuid, text) to authenticated;
