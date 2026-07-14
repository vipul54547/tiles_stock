-- ═══ STEP 2 of docs/PACKING_BOX_HOLD_PLAN.md — THE BOX IS A PACKING IN A BRAND'S COVER ════════
--
--   ARTWORK → TILE → PACKING → **BOX** → HOLD
--
-- 🎁 A BOX is what you get when you wrap a corrugated cover round a PACKING. The cover carries the
-- brand: "if we cover Famous cover than Brand is 'Famous', if we give Anuj cover than its 'Anuj'".
--
-- 🔑 THE BRAND'S NAME AND THE BOX ARE TWO DIFFERENT THINGS, and this is the decision this migration
-- rests on:
--
--   • THE NAME is per (TILE, brand). ANUJ prints `601001` on EVERY cover of that design, whatever
--     packing is inside it. It is the brand's word for the tile. It stays where it is, in
--     `stockist_library_brand_names` — which now carries the name and NOTHING ELSE.
--
--   • THE BOX is per (PACKING, brand). It is a physical thing you can count and sell: this many
--     pieces, this weight, in this brand's cover. That is the new `boxes` table.
--
--   Putting the name on the box would repeat it once per packing and let it DRIFT — the same brand
--   ending up with two different words for one design.
--
-- 🚫 `pieces_per_box` and `box_weight_kg` LEAVE `stockist_library_brand_names` for good. They were
-- never the brand's: a factory PACKS ONCE and COVERS DIFFERENTLY. They live on the PACKING now.
--
-- Nothing to migrate — the DB is empty (14 Jul clean slate). This is a rebuild.

-- ── 1. `boxes` — a packing, in a brand's cover ──────────────────────────────────────────────
create table if not exists public.boxes (
  id          uuid primary key default gen_random_uuid(),
  packing_id  uuid not null references public.packings(id) on delete cascade,
  brand_id    uuid not null references public.brands(id)   on delete cascade,
  created_at  timestamptz not null default now(),
  -- One cover per brand per packing. Two of them would be the same box twice.
  unique (packing_id, brand_id)
);

create index if not exists boxes_packing_idx on public.boxes (packing_id);
create index if not exists boxes_brand_idx   on public.boxes (brand_id);

comment on table public.boxes is
  'A PACKING in a BRAND''S corrugated cover — the physical thing you count and sell. The brand''s '
  'NAME for the tile is not here: that is per (tile, brand) in stockist_library_brand_names, '
  'because a brand prints the same name on every cover whatever packing is inside.';

alter table public.boxes enable row level security;
revoke all on table public.boxes from anon, authenticated;

-- ── 2. A PACKING IS A FACT; THE THICKNESS IS DERIVED FROM IT ────────────────────────────────
-- packing_add used to REFUSE a packing on a body-less tile. That conflated two things: the packing
-- (pieces + weight — a fact he read off the box) with the thickness (which needs the body's
-- density). Store the fact; derive what can be derived. A tile with no body simply has no thickness
-- yet, and the Library already says exactly that ("no thickness — set the body").
-- Only a packing that CONTRADICTS the tile is still refused.
create or replace function public.packing_add(
  p_library_id uuid,
  p_pieces integer,
  p_weight numeric
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_size text; v_body text; v_have numeric;
        v_new numeric; v_id uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can add a packing'; end if;

  select l.size, l.tile_type, l.thickness_mm into v_size, v_body, v_have
    from stockist_library l
   where l.id = p_library_id and l.stockist_id = v_stk;
  if v_size is null then raise exception 'That design is not in your library'; end if;

  if coalesce(p_pieces,0) <= 0 then raise exception 'Pieces per box must be more than 0'; end if;
  if coalesce(p_weight,0) <= 0 then raise exception 'Box weight must be more than 0'; end if;

  -- What thickness does this packing imply? NULL when the body is not declared — the density comes
  -- from the body, so it is genuinely unknowable, not zero.
  v_new := _thickness_for(v_size, v_body, p_pieces, p_weight);

  -- 🔑 THE 1 mm RULE. Every packing of one tile must land on the same thickness: 5 × 10.5 kg and
  -- 4 × 8.4 kg are both 2.1 kg a piece. Further than 1 mm away, this is not another way of packing
  -- THIS tile — it is a DIFFERENT TILE, and it must be added as one.
  if v_new is not null and v_have is not null and abs(v_new - v_have) > 1.0 then
    raise exception
      'That packing works out at % mm, but this design is % mm. More than 1 mm apart is a '
      'DIFFERENT TILE, not another packing — add it as its own design.', v_new, v_have;
  end if;

  insert into packings (library_id, pieces, weight_kg)
       values (p_library_id, p_pieces, p_weight)
  on conflict (library_id, pieces, weight_kg) do nothing
    returning id into v_id;

  if v_id is null then   -- he already had exactly this packing
    select id into v_id from packings
     where library_id = p_library_id and pieces = p_pieces and weight_kg = p_weight;
  end if;

  return jsonb_build_object(
    'packing_id', v_id,
    'thickness_mm', (select thickness_mm from stockist_library where id = p_library_id),
    -- No body yet → the packing is stored, but its thickness is unknowable until he says what the
    -- tile is made of. The caller should say so rather than pretend it worked.
    'needs_body', coalesce(btrim(coalesce(v_body,'')),'') = '');

exception
  when exclusion_violation then
    raise exception 'You already have this design at almost this thickness. '
                    'Check the pieces and the box weight.';
end; $function$;

-- ── 3. The thickness comes from the PACKING. Full stop. ─────────────────────────────────────
-- The transitional fallback to the box's pieces/weight goes away with the columns themselves.
create or replace function public._derive_thickness(p_library_id uuid)
returns numeric
language plpgsql
stable
set search_path to 'public', 'pg_temp'
as $function$
declare v_area numeric; v_density numeric; v_pieces int; v_weight numeric;
begin
  select _tile_area_m2(l.size), t.density_kg_m3
    into v_area, v_density
    from stockist_library l
    left join tile_types t on t.name = l.tile_type
   where l.id = p_library_id;

  if v_area is null or v_area <= 0 or v_density is null or v_density <= 0 then
    return null;   -- unknown size, or no BODY -> the density is unknown -> unknowable
  end if;

  -- ANY packing will do: weight-per-piece is a property of the TILE, and every packing of a tile
  -- must agree on it (packing_add enforces the 1 mm rule).
  select p.pieces, p.weight_kg into v_pieces, v_weight
    from packings p
   where p.library_id = p_library_id
   order by p.created_at
   limit 1;

  if coalesce(v_pieces,0) <= 0 or coalesce(v_weight,0) <= 0 then
    return null;   -- no packing yet -> no thickness yet, and the Library says so
  end if;

  return round(v_weight / (v_pieces * v_area * v_density) * 1000, 2);
end; $function$;

-- ── 4. "pieces / weight of this tile" — the BRAND IS IRRELEVANT ─────────────────────────────
-- The signatures keep their brand argument so the ~6 readers of these two need no change today,
-- but the brand is now IGNORED, on purpose: a packing has no brand. Step 3 replaces both with a
-- box-based lookup when `designs.box_id` lands.
create or replace function public._box_pieces(p_library_id uuid, p_brand_id uuid)
returns integer
language sql
stable
set search_path to 'public', 'pg_temp'
as $function$
  select p.pieces from packings p
   where p.library_id = p_library_id
   order by p.created_at limit 1;
$function$;

create or replace function public._box_weight(p_library_id uuid, p_brand_id uuid)
returns numeric
language sql
stable
set search_path to 'public', 'pg_temp'
as $function$
  select p.weight_kg from packings p
   where p.library_id = p_library_id
   order by p.created_at limit 1;
$function$;

-- ── 5. The importer's identity pass writes a PACKING, not a box column ──────────────────────
create or replace function public._library_apply_identity(p_library_id uuid, p_attrs jsonb)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_stock   text    := nullif(btrim(coalesce(p_attrs->>'stock_type','')),'');
  v_pieces  int     := nullif(btrim(coalesce(p_attrs->>'pieces_per_box','')),'')::int;
  v_weight  numeric := nullif(btrim(coalesce(p_attrs->>'box_weight_kg','')),'')::numeric;
  v_finish  text    := nullif(btrim(coalesce(p_attrs->>'finish_label','')),'');
  v_stk uuid;
begin
  if p_library_id is null or p_attrs is null then return; end if;
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then return; end if;

  -- tile_type is NOT set here (library_map_upsert adopts it); colour is DNA now.
  update stockist_library m set
    stock_type   = case when m.stock_type in ('','Uncertain') then coalesce(v_stock, m.stock_type) else m.stock_type end,
    finish_label = case when m.finish_label is null then coalesce(v_finish, m.finish_label) else m.finish_label end,
    updated_at   = now()
  where m.id = p_library_id and m.stockist_id = v_stk;

  -- 📦 Pieces + weight are a PACKING. packing_add is the only way one is made, so the 1 mm rule
  -- applies to an import exactly as it does to a human: a packing that belongs to a different tile
  -- throws, and one bad row throws the whole batch. That is the point.
  if coalesce(v_pieces,0) > 0 and coalesce(v_weight,0) > 0 then
    perform packing_add(p_library_id, v_pieces, v_weight);
  end if;
end; $function$;

-- ── 6. The brand-free replacements for the old box writers ──────────────────────────────────
-- library_set_box(library, BRAND, pieces, weight)      → packing_add(library, pieces, weight)
-- library_set_box_for_size(BRAND, size, pieces, weight)→ packing_add_for_size(size, pieces, weight)
-- library_for_box(library, BRAND, pieces, weight)      → tile_for_packing(library, pieces, weight)
-- The brand is gone from every one of them. It was never theirs.
drop function if exists public.library_set_box(uuid, uuid, integer, numeric);
drop function if exists public.library_set_box_for_size(uuid, text, integer, numeric);

-- Type the packing ONCE for a size — a factory packs a 300x450 the same way whatever design is on
-- it. Lands on every tile of that size. Returns how many it touched.
create or replace function public.packing_add_for_size(
  p_size text, p_pieces integer, p_weight numeric
) returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_size text := btrim(coalesce(p_size,'')); v_n int := 0; r record;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can edit the library'; end if;
  if v_size = '' then raise exception 'Pick a size'; end if;
  if coalesce(p_pieces,0) <= 0 then raise exception 'Pieces per box must be more than 0'; end if;
  if coalesce(p_weight,0) <= 0 then raise exception 'Box weight must be more than 0'; end if;

  for r in
    select l.id from stockist_library l
      join print_master p on p.id = l.print_id
     where l.stockist_id = v_stk and p.size = v_size
  loop
    perform packing_add(r.id, p_pieces, p_weight);
    v_n := v_n + 1;
  end loop;

  return v_n;
end; $function$;

revoke all on function public.packing_add_for_size(text, integer, numeric) from public, anon;
grant execute on function public.packing_add_for_size(text, integer, numeric) to authenticated;

-- ── 7. "Which TILE does this packing belong to?" — brand-free ───────────────────────────────
-- Was library_for_box(library, BRAND, pieces, weight). The brand had no business here: the answer
-- depends on the WEIGHT PER PIECE, which is a property of the tile.
drop function if exists public.library_for_box(uuid, uuid, integer, numeric);

create or replace function public.tile_for_packing(
  p_library_id uuid, p_pieces integer, p_weight numeric
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_lib stockist_library; v_new_mm numeric;
        v_match uuid; v_match_mm numeric; v_id uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can add stock'; end if;

  select * into v_lib from stockist_library
   where id = p_library_id and stockist_id = v_stk;
  if v_lib.id is null then raise exception 'Design is not in your library'; end if;

  if coalesce(p_pieces,0) <= 0 then raise exception 'Pieces per box must be more than 0'; end if;
  if coalesce(p_weight,0) <= 0 then raise exception 'Box weight must be more than 0'; end if;

  v_new_mm := _thickness_for(v_lib.size, v_lib.tile_type, p_pieces, p_weight);
  if v_new_mm is null then
    raise exception 'This design has no body set, so its thickness cannot be worked out. '
                    'Open it in your Library and set one.';
  end if;

  -- Same print + surface + body, within 1 mm? Then it IS that tile — ordinary weight drift. Take
  -- the CLOSEST, so a fork can never be shadowed by a more distant sibling.
  select l.id, l.thickness_mm into v_match, v_match_mm
    from stockist_library l
   where l.stockist_id = v_stk
     and l.print_id = v_lib.print_id
     and l.surface_type = v_lib.surface_type
     and l.tile_type is not distinct from v_lib.tile_type
     and l.thickness_mm is not null
     and abs(l.thickness_mm - v_new_mm) <= 1.0
   order by abs(l.thickness_mm - v_new_mm)
   limit 1;

  if v_match is null then
    -- A tile of this print with NO packing yet is this same design, waiting for its first one.
    select l.id into v_match from stockist_library l
     where l.stockist_id = v_stk
       and l.print_id = v_lib.print_id
       and l.surface_type = v_lib.surface_type
       and l.tile_type is not distinct from v_lib.tile_type
       and l.thickness_mm is null
     order by l.created_at limit 1;
  end if;

  if v_match is not null then
    -- Record the packing. A tile may have several, and packing_add holds them to the 1 mm rule.
    perform packing_add(v_match, p_pieces, p_weight);
    return jsonb_build_object(
      'library_id', v_match, 'forked', false,
      'thickness_mm', (select thickness_mm from stockist_library where id = v_match),
      'matched_thickness_mm', v_match_mm);
  end if;

  -- More than 1 mm from every sibling → a genuinely DIFFERENT tile. Fork it — and note it keeps the
  -- SAME print_id: a fork is the same artwork on a thicker piece.
  insert into stockist_library (
    stockist_id, print_id, is_sample, brand_id,
    surface_type, surface_label, stock_type, tile_type, finish_label)
  values (v_stk, v_lib.print_id, v_lib.is_sample, v_lib.brand_id, v_lib.surface_type,
          v_lib.surface_label, v_lib.stock_type, v_lib.tile_type, v_lib.finish_label)
  returning id into v_id;

  -- The new tile inherits the piece-level DNA, the brands' NAMES for it, and its family. (The image
  -- DNA needs no copying: it is the PRINT's, and the fork shares the print.)
  insert into library_dna (library_id, value_id)
    select v_id, x.value_id from library_dna x where x.library_id = p_library_id;
  insert into stockist_library_brand_names (library_id, brand_id, brand_design_name)
    select v_id, x.brand_id, x.brand_design_name
      from stockist_library_brand_names x where x.library_id = p_library_id;
  insert into library_family_overrides (library_id, stockist_id, family_key)
    select v_id, x.stockist_id, x.family_key
      from library_family_overrides x where x.library_id = p_library_id;

  perform packing_add(v_id, p_pieces, p_weight);

  return jsonb_build_object(
    'library_id', v_id, 'forked', true,
    'thickness_mm', (select thickness_mm from stockist_library where id = v_id),
    'matched_thickness_mm', null);

exception
  when exclusion_violation then
    raise exception 'A tile of this design already sits at almost this thickness. A box weight this '
                    'close is the SAME tile — check the pieces and box weight.';
end; $function$;

revoke all on function public.tile_for_packing(uuid, integer, numeric) from public, anon;
grant execute on function public.tile_for_packing(uuid, integer, numeric) to authenticated;

-- ── 8. my_library · library_upsert_master · admin_library_upsert — pieces/weight from the PACKING ──
CREATE OR REPLACE FUNCTION public.my_library()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_stk uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists have a library'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id,
      'brand_id', m.brand_id,
      'brand_name', coalesce((select b.name from brands b where b.id = m.brand_id), ''),
      -- name · size · photo all come from the PRINT now. The keys are unchanged.
      'size', pm.size,
      'master_design_name', pm.print_name,
      'image_url', pm.image_url,
      'print_id', m.print_id,
      'surface_type', m.surface_type,
      'surface_label', m.surface_label,
      'stock_type', m.stock_type,
      'tile_type', m.tile_type,
      'pieces_per_box', (select p.pieces from packings p
                          where p.library_id = m.id order by p.created_at limit 1),
      'box_weight_kg',  (select p.weight_kg from packings p
                          where p.library_id = m.id order by p.created_at limit 1),
      'thickness_mm', m.thickness_mm,
      'created_at', m.created_at,
      'colour', _dna_colour(m.id),
      'finish_label', m.finish_label,
      'aliases', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'brand_id', a.brand_id,
                 'name', a.brand_design_name))
        from stockist_library_brand_names a where a.library_id = m.id), '[]'::jsonb)
    ) order by pm.print_name, pm.size)
    from stockist_library m
    join print_master pm on pm.id = m.print_id
    where m.stockist_id = v_stk
  ), '[]'::jsonb);
end; $function$
;

CREATE OR REPLACE FUNCTION public.library_upsert_master(p_id uuid, p_size text, p_master_name text, p_image_url text, p_aliases jsonb, p_brand_id uuid DEFAULT NULL::uuid, p_surface text DEFAULT NULL::text, p_stock_type text DEFAULT NULL::text, p_tile_type text DEFAULT NULL::text, p_pieces integer DEFAULT NULL::integer, p_weight numeric DEFAULT NULL::numeric, p_thickness numeric DEFAULT NULL::numeric, p_colour text DEFAULT NULL::text, p_finish text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_stk uuid; v_id uuid; v_print uuid;
        v_name text := btrim(coalesce(p_master_name,''));
        v_size text := btrim(coalesce(p_size,''));
        v_surf text := nullif(btrim(coalesce(p_surface,'')),'');
        v_tile text := nullif(btrim(coalesce(p_tile_type,'')),'');
        r jsonb; v_brand uuid; v_alias text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can edit the library'; end if;
  if v_name = '' then raise exception 'Master design name cannot be empty'; end if;
  if v_size = '' then raise exception 'Size is required'; end if;
  if v_surf is null or lower(v_surf) = 'none' then
    raise exception 'Pick a surface — it is part of the design.';
  end if;
  if p_id is null and v_tile is null then
    raise exception 'Pick a tile type — it is part of the design.';
  end if;

  -- Editing the NAME or the SIZE re-points the product at a DIFFERENT print (that is what a rename
  -- IS, now that the print owns the name). The photo goes on the print, first-writer-wins.
  v_print := print_upsert(v_stk, v_name, v_size, p_image_url);

  -- A twin with NO box yet cannot be told apart by thickness, so it is a real clash.
  if exists (select 1 from stockist_library
             where stockist_id = v_stk and print_id = v_print and surface_type = v_surf
               and tile_type is not distinct from coalesce(v_tile, tile_type)
               and thickness_mm is null
               and (p_id is null or id <> p_id)) then
    raise exception '"%" (% · % · %) is already in your library and has no box yet — give that one '
                    'its pieces and box weight first, so the two can be told apart by thickness.',
      v_name, v_size, v_surf, v_tile;
  end if;

  if p_id is null then
    insert into stockist_library (stockist_id, print_id, brand_id, surface_type, tile_type)
      values (v_stk, v_print, p_brand_id, v_surf, v_tile)
      returning id into v_id;
  else
    update stockist_library set
      print_id     = v_print,
      brand_id     = coalesce(p_brand_id, brand_id),
      surface_type = v_surf,
      tile_type    = coalesce(v_tile, tile_type),
      updated_at   = now()
    where id = p_id and stockist_id = v_stk
    returning id into v_id;
    if v_id is null then raise exception 'Design not found'; end if;

    -- the holding still carries a name/size copy of its own
    update designs d
       set surface_type = v_surf, name = v_name, size = v_size, updated_at = now()
     where d.library_id = v_id and d.stockist_id = v_stk;
  end if;

  -- An explicit image ALWAYS wins on an edit: the stockist just chose it. (print_upsert only fills
  -- a blank, which is the right rule for an IMPORT, not for a human at the form.)
  if nullif(btrim(coalesce(p_image_url,'')),'') is not null then
    update print_master set image_url = btrim(p_image_url), updated_at = now()
     where id = v_print;
  end if;

  update stockist_library m set
    stock_type   = case when p_stock_type is null then m.stock_type   else coalesce(nullif(btrim(p_stock_type),''),'Uncertain') end,
    finish_label = case when p_finish     is null then m.finish_label else nullif(btrim(p_finish),'') end,
    updated_at = now()
  where m.id = v_id;

  if p_aliases is not null then
    for r in select * from jsonb_array_elements(p_aliases) loop
      v_brand := nullif(r->>'brand_id','')::uuid;
      v_alias := btrim(coalesce(r->>'name',''));
      if v_alias <> '' and v_brand is not null
         and exists (select 1 from brands where id = v_brand and stockist_id = v_stk) then
        insert into stockist_library_brand_names (library_id, brand_id, brand_design_name)
          values (v_id, v_brand, v_alias)
          on conflict (library_id, brand_id) do update set brand_design_name = excluded.brand_design_name;
      end if;
    end loop;

    delete from stockist_library_brand_names a
     where a.library_id = v_id
       and not exists (
         select 1 from jsonb_array_elements(p_aliases) e
          where nullif(e->>'brand_id','')::uuid = a.brand_id
            and btrim(coalesce(e->>'name','')) <> '');
  end if;

  -- CREATE only: seed the first box, so the thickness derives at once and the identity is complete.
  if p_id is null and (coalesce(p_pieces,0) > 0 or coalesce(p_weight,0) > 0) then
    -- 📦 Pieces + weight are a PACKING now, not a column on the brand's row.
    if coalesce(p_pieces,0) > 0 and coalesce(p_weight,0) > 0 then
      perform packing_add(v_id, p_pieces, p_weight);
    end if;
  end if;

  return v_id;

exception
  when exclusion_violation then
    raise exception 'You already have "%" (% · % · %) at almost this thickness. A box weight this '
                    'close is the SAME tile — thickness has to differ by more than 1 mm to be a '
                    'different product. Check the pieces and box weight.',
      v_name, v_size, v_surf, v_tile;
  when unique_violation then
    raise exception '"%" (% · % · %) is already in your library.', v_name, v_size, v_surf, v_tile;
end; $function$
;

CREATE OR REPLACE FUNCTION public.admin_library_upsert(p_seq text, p_size text, p_master_name text, p_brand_id uuid, p_image_url text DEFAULT NULL::text, p_surface text DEFAULT NULL::text, p_tile_type text DEFAULT NULL::text, p_pieces integer DEFAULT NULL::integer, p_weight numeric DEFAULT NULL::numeric, p_thickness numeric DEFAULT NULL::numeric, p_aliases jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_stk uuid; v_id uuid; v_print uuid;
        v_name text := btrim(coalesce(p_master_name,''));
        v_size text := btrim(coalesce(p_size,''));
        v_surf text := nullif(btrim(coalesce(p_surface,'')),'');
        r jsonb; v_brand uuid; v_alias text;
begin
  if current_user_role() <> 'admin' then
    raise exception 'Only admins can bulk-import on behalf of a stockist';
  end if;
  select id into v_stk from stockists where sequential_id = p_seq;
  if v_stk is null then raise exception 'Stockist not found'; end if;
  if v_name = '' then raise exception 'Design name cannot be empty'; end if;
  if v_size = '' then raise exception 'Size is required'; end if;
  if v_surf is null or lower(v_surf) = 'none' then
    raise exception 'A surface is required for "%" (%)', v_name, v_size;
  end if;

  v_print := print_upsert(v_stk, v_name, v_size, p_image_url);

  select id into v_id from stockist_library
   where stockist_id = v_stk and print_id = v_print and surface_type = v_surf
   limit 1;

  if v_id is null then
    insert into stockist_library (stockist_id, print_id, brand_id, surface_type)
      values (v_stk, v_print, p_brand_id, v_surf)
      returning id into v_id;
  end if;

  update stockist_library m set
    tile_type  = case when p_tile_type is null then m.tile_type else coalesce(btrim(p_tile_type),'') end,
    updated_at = now()
  where m.id = v_id;

  -- 📦 Pieces + weight are a PACKING now, not a column on the brand's row. This is the concierge
  -- (admin-on-behalf) path, so it writes the packing directly: packing_add authenticates the caller
  -- as the OWNING stockist, which an admin is not.
  if coalesce(p_pieces,0) > 0 and coalesce(p_weight,0) > 0 then
    insert into packings (library_id, pieces, weight_kg)
         values (v_id, p_pieces, p_weight)
    on conflict (library_id, pieces, weight_kg) do nothing;
  end if;

  if p_aliases is not null then
    for r in select * from jsonb_array_elements(p_aliases) loop
      v_brand := nullif(r->>'brand_id','')::uuid;
      v_alias := btrim(coalesce(r->>'name',''));
      if v_alias <> '' and v_brand is not null
         and exists (select 1 from brands where id = v_brand and stockist_id = v_stk) then
        insert into stockist_library_brand_names (library_id, brand_id, brand_design_name)
          values (v_id, v_brand, v_alias)
          on conflict (library_id, brand_id) do update set brand_design_name = excluded.brand_design_name;
      end if;
    end loop;
  end if;
  return v_id;
end; $function$
;

-- ── 9. THE COLUMNS GO ───────────────────────────────────────────────────────────────────────
-- Nothing reads them any more (swept from pg_proc: _box_pieces · _box_weight · _derive_thickness ·
-- _library_apply_identity · library_for_box · library_set_box · library_set_box_for_size ·
-- library_upsert_master · admin_library_upsert · my_library — all re-pointed above).
-- They were never the brand's: a factory PACKS ONCE and COVERS DIFFERENTLY.
-- The box table's re-derive trigger fired on pieces_per_box / box_weight_kg. Those are gone, and
-- `packings` carries its own trigger now, so this one is both broken and redundant.
drop trigger if exists zz_box_rederive_thickness on public.stockist_library_brand_names;

alter table public.stockist_library_brand_names
  drop column if exists pieces_per_box,
  drop column if exists box_weight_kg;

comment on table public.stockist_library_brand_names is
  'THE BRAND''S NAME FOR A TILE — the word that brand prints on its cover (1001 on FAMOUS, 601001 '
  'on ANUJ). One row per (tile, brand). It carries the NAME and nothing else: how the tile is '
  'PACKED has no brand (see packings), and a BOX is a packing in one of these covers (see boxes).';

-- ── 10. my_library hands the app the TILE'S PACKINGS ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.my_library()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_stk uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists have a library'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id,
      'brand_id', m.brand_id,
      'brand_name', coalesce((select b.name from brands b where b.id = m.brand_id), ''),
      -- name · size · photo all come from the PRINT now. The keys are unchanged.
      'size', pm.size,
      'master_design_name', pm.print_name,
      'image_url', pm.image_url,
      'print_id', m.print_id,
      'surface_type', m.surface_type,
      'surface_label', m.surface_label,
      'stock_type', m.stock_type,
      'tile_type', m.tile_type,
      'pieces_per_box', (select p.pieces from packings p
                          where p.library_id = m.id order by p.created_at limit 1),
      'box_weight_kg',  (select p.weight_kg from packings p
                          where p.library_id = m.id order by p.created_at limit 1),
      'thickness_mm', m.thickness_mm,
      'created_at', m.created_at,
      'colour', _dna_colour(m.id),
      'finish_label', m.finish_label,
      -- 📦 THE TILE'S PACKINGS — pieces + weight, and NO BRAND. A tile may have several (5-a-box
      -- for one market, 4-a-box for another); they all agree on its thickness.
      'packings', coalesce((
        select jsonb_agg(jsonb_build_object('id', pk.id, 'pieces', pk.pieces, 'weight_kg', pk.weight_kg)
                         order by pk.created_at)
        from packings pk where pk.library_id = m.id), '[]'::jsonb),
      'aliases', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'brand_id', a.brand_id,
                 'name', a.brand_design_name))
        from stockist_library_brand_names a where a.library_id = m.id), '[]'::jsonb)
    ) order by pm.print_name, pm.size)
    from stockist_library m
    join print_master pm on pm.id = m.print_id
    where m.stockist_id = v_stk
  ), '[]'::jsonb);
end; $function$
;
