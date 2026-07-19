-- ═══ EDIT MODE support + BODY-COLOUR edit/delete ═════════════════════════════════════════════
--
-- The design page becomes create-AND-edit. Editing a design's IDENTITY (body / body colour) moves
-- the product, so it is refused while the design holds stock. And a stockist's free-text values
-- (body colours here; Series/Punch Type already have dna_rename/delete) need edit + delete, guarded
-- so a value that is IN USE cannot be pulled out from under a product.

-- ── 1. my_library returns the held-box count (drives the identity lock in Edit mode) ────────
create or replace function public.my_library()
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists have a library'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id, 'brand_id', m.brand_id,
      'brand_name', coalesce((select b.name from brands b where b.id = m.brand_id), ''),
      'size', pm.size, 'master_design_name', pm.print_name, 'image_url', pm.image_url,
      'print_id', m.print_id, 'surface_type', m.surface_type, 'surface_label', m.surface_label,
      'stock_type', m.stock_type, 'tile_type', m.tile_type,
      'pieces_per_box', (select p.pieces from packings p where p.library_id = m.id order by p.created_at limit 1),
      'box_weight_kg',  (select p.weight_kg from packings p where p.library_id = m.id order by p.created_at limit 1),
      'thickness_mm', m.thickness_mm, 'created_at', m.created_at,
      'colour', _dna_colour(m.id), 'finish_label', m.finish_label,
      'body_colour', (select jsonb_build_object('id', bc.id, 'name', bc.name, 'l', bc.l, 'a', bc.a, 'b', bc.b, 'hex', bc.hex)
                      from body_colours bc where bc.id = m.body_colour_id),
      -- 🔒 boxes of stock held on this design — Edit mode locks identity when this is > 0.
      'held', (select coalesce(sum(d.box_quantity), 0) from designs d where d.library_id = m.id),
      'packings', coalesce((select jsonb_agg(jsonb_build_object('id', pk.id, 'pieces', pk.pieces, 'weight_kg', pk.weight_kg)
                         order by pk.created_at) from packings pk where pk.library_id = m.id), '[]'::jsonb),
      'aliases', coalesce((select jsonb_agg(jsonb_build_object('brand_id', a.brand_id, 'name', a.brand_design_name))
                 from stockist_library_brand_names a where a.library_id = m.id), '[]'::jsonb)
    ) order by pm.print_name, pm.size)
    from stockist_library m join print_master pm on pm.id = m.print_id
    where m.stockist_id = v_stk
  ), '[]'::jsonb);
end; $function$;

-- ── 2. change a design's BODY (+ body colour) — identity, so refused while it holds stock ───
create or replace function public.library_set_body(
  p_library_id uuid, p_tile_type text, p_body_colour_id uuid default null)
 returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_body text := nullif(btrim(coalesce(p_tile_type,'')),'');
        v_through boolean; v_bcid uuid; v_held int;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if not exists (select 1 from stockist_library where id = p_library_id and stockist_id = v_stk) then
    raise exception 'Not your design'; end if;

  select coalesce(sum(box_quantity), 0) into v_held from designs where library_id = p_library_id;
  if v_held > 0 then
    raise exception 'This design holds % boxes of stock — clear the stock before changing its identity.', v_held;
  end if;

  v_through := lower(coalesce(v_body, '')) in ('full body', 'colour body');
  if v_through then
    if p_body_colour_id is null then raise exception 'Pick a body colour for a Full Body / Colour Body.'; end if;
    if not exists (select 1 from body_colours where id = p_body_colour_id and stockist_id = v_stk) then
      raise exception 'That body colour is not yours'; end if;
    v_bcid := p_body_colour_id;
  else
    v_bcid := null;
  end if;

  update stockist_library set tile_type = v_body, body_colour_id = v_bcid, updated_at = now()
   where id = p_library_id;
exception
  when unique_violation or exclusion_violation then
    raise exception 'A design with this body / body colour already exists for this artwork and surface.';
end; $function$;
revoke all on function public.library_set_body(uuid, text, uuid) from public, anon;
grant execute on function public.library_set_body(uuid, text, uuid) to authenticated;

-- ── 3. body colour edit + delete (guarded) ──────────────────────────────────────────────────
create or replace function public.body_colour_update(
  p_id uuid, p_name text, p_l numeric default null, p_a numeric default null,
  p_b numeric default null, p_hex text default null)
 returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_name text := btrim(coalesce(p_name, ''));
        v_has_lab boolean := (p_l is not null or p_a is not null or p_b is not null);
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if v_name = '' then raise exception 'A body colour needs a name'; end if;
  if not exists (select 1 from body_colours where id = p_id and stockist_id = v_stk) then
    raise exception 'That body colour is not yours'; end if;
  update body_colours
     set name = v_name, l = p_l, a = p_a, b = p_b,
         hex = case when v_has_lab then null else nullif(btrim(coalesce(p_hex,'')),'') end
   where id = p_id and stockist_id = v_stk;
exception
  when unique_violation then raise exception 'You already have a body colour named "%".', v_name;
end; $function$;
revoke all on function public.body_colour_update(uuid, text, numeric, numeric, numeric, text) from public, anon;
grant execute on function public.body_colour_update(uuid, text, numeric, numeric, numeric, text) to authenticated;

create or replace function public.body_colour_delete(p_id uuid)
 returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_used int;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if not exists (select 1 from body_colours where id = p_id and stockist_id = v_stk) then
    raise exception 'That body colour is not yours'; end if;
  select count(*) into v_used from stockist_library where body_colour_id = p_id;
  if v_used > 0 then
    raise exception 'This body colour is used by % design(s) — remove it there before deleting it.', v_used;
  end if;
  delete from body_colours where id = p_id and stockist_id = v_stk;
end; $function$;
revoke all on function public.body_colour_delete(uuid) from public, anon;
grant execute on function public.body_colour_delete(uuid) to authenticated;

-- ── 4. self-check ───────────────────────────────────────────────────────────────────────────
do $$
begin
  perform 'public.library_set_body(uuid, text, uuid)'::regprocedure;
  perform 'public.body_colour_update(uuid, text, numeric, numeric, numeric, text)'::regprocedure;
  perform 'public.body_colour_delete(uuid)'::regprocedure;
  raise notice 'OK: edit-mode + body-colour CRUD RPCs ready';
end $$;
