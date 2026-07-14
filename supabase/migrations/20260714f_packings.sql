-- ═══ STEP 1 of docs/PACKING_BOX_HOLD_PLAN.md — THE PACKING ═════════════════════════════════════
--
--   ARTWORK → TILE → **PACKING** → BOX → HOLD
--
-- 📦 **A PACKING IS PIECES + WEIGHT, AND IT HAS NO BRAND.**
--
-- His words: "packing is how many pieces contain and what is weight, its call 'packing'. after that
-- when we put corrugated cover on this its call 'box'. if we cover Famous cover than Brand is
-- 'Famous', if we give Anuj cover than its 'Anuj' brand."
--
-- A factory PACKS ONCE and COVERS DIFFERENTLY. So pieces + weight were never the brand's — they sat
-- on `stockist_library_brand_names` (the box) only because the old rule wrongly said "one print
-- under two brands packs two ways, independently". They move off the brand entirely.
-- 🔑 This is also why the folder import must not ask for a brand: the THICKNESS comes from the
-- PACKING, and the packing is brand-free.
--
-- 🔑 A TILE MAY HAVE SEVERAL PACKINGS — "it will be different number of pieces in packing depend
-- upon stockist, his market and market move." A 300x450 goes out 5-a-box for one market and 4-a-box
-- for another. Same tile.
--
-- 🔑 AND THEY MUST ALL AGREE ON THE THICKNESS. 5 pcs × 10.5 kg and 4 pcs × 8.4 kg are both
-- **2.1 kg a piece** — one tile, two packings, one thickness. So:
--
--     A PACKING WHOSE THICKNESS IS MORE THAN 1 mm FROM THE TILE'S IS NOT A PACKING.
--     IT IS A DIFFERENT TILE.
--
-- The packing is where the fork gets caught. (1 mm, not a band edge: box weight DRIFTS in the trade
-- — a 600x1200 2-piece box went 28 kg → 26 kg, which is 0.62 mm, and that is the SAME tile.)
--
-- This step is ADDITIVE. The box table keeps its pieces/weight until step 2 moves them, so nothing
-- that reads them breaks today. `_derive_thickness` learns to prefer a PACKING and fall back to the
-- box, so both worlds work during the transition.

-- ── 1. The table ────────────────────────────────────────────────────────────────────────────
create table if not exists public.packings (
  id          uuid primary key default gen_random_uuid(),
  library_id  uuid not null references public.stockist_library(id) on delete cascade,
  pieces      integer not null check (pieces > 0),
  weight_kg   numeric not null check (weight_kg > 0),
  created_at  timestamptz not null default now(),
  -- The same pieces+weight twice is the same packing, not a second one.
  unique (library_id, pieces, weight_kg)
);

create index if not exists packings_library_idx on public.packings (library_id, created_at);

comment on table public.packings is
  'HOW THE TILE IS PACKED: pieces + weight. NO BRAND — a factory packs once and covers differently; '
  'the brand belongs to the BOX (the corrugated cover). A tile may have several packings, and they '
  'must all agree on its thickness (>1 mm apart = a different tile).';

-- 🔐 A new public table starts with grants to anon/authenticated. Every read and write goes through
-- a SECURITY DEFINER RPC, so the table itself is closed. (feedback_new_public_table_anon_grants)
alter table public.packings enable row level security;
revoke all on table public.packings from anon, authenticated;

-- ── 2. The thickness derives from a PACKING ─────────────────────────────────────────────────
-- Prefer a packing; fall back to the box's pieces/weight until step 2 moves them off it. The old
-- body of this function already knew the principle — "ANY box will do: weight-per-piece is a
-- property of the TILE, not of the packing" — it was just reading from the wrong table.
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
    return null;   -- unknown size, or no BODY declared -> the density is unknown -> unknowable
  end if;

  -- THE PACKING. Any of them will do: weight-per-piece is a property of the TILE.
  select p.pieces, p.weight_kg into v_pieces, v_weight
    from packings p
   where p.library_id = p_library_id
   order by p.created_at
   limit 1;

  -- TRANSITIONAL: no packing yet, but the old box may still carry pieces/weight. Dropped in step 2.
  if coalesce(v_pieces,0) <= 0 or coalesce(v_weight,0) <= 0 then
    select a.pieces_per_box, a.box_weight_kg into v_pieces, v_weight
      from stockist_library_brand_names a
     where a.library_id = p_library_id
       and coalesce(a.pieces_per_box,0) > 0
       and coalesce(a.box_weight_kg,0) > 0
     order by a.created_at
     limit 1;
  end if;

  if coalesce(v_pieces,0) <= 0 or coalesce(v_weight,0) <= 0 then
    return null;   -- no packing yet -> no thickness yet, and the Library says so
  end if;

  return round(v_weight / (v_pieces * v_area * v_density) * 1000, 2);
end; $function$;

-- A packing appearing, changing or going away re-derives the tile's thickness — same as the box
-- trigger does today.
drop trigger if exists zz_packing_rederive_thickness on public.packings;
create trigger zz_packing_rederive_thickness
  after insert or delete or update of pieces, weight_kg on public.packings
  for each row execute function _trg_rederive_thickness();

-- ── 3. packing_add — the only way a packing is created ──────────────────────────────────────
-- Returns { packing_id, thickness_mm, first }.
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
        v_new numeric; v_id uuid; v_first boolean;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can add a packing'; end if;

  select l.size, l.tile_type, l.thickness_mm into v_size, v_body, v_have
    from stockist_library l
   where l.id = p_library_id and l.stockist_id = v_stk;
  if v_size is null then raise exception 'That design is not in your library'; end if;

  if coalesce(p_pieces,0) <= 0 then raise exception 'Pieces per box must be more than 0'; end if;
  if coalesce(p_weight,0) <= 0 then raise exception 'Box weight must be more than 0'; end if;

  -- 🚫 NO BODY, NO THICKNESS. The density comes from the body, so a perfectly good packing on a
  -- body-less tile still yields nothing. Say the true reason — do not send him to fix the packing.
  if coalesce(btrim(coalesce(v_body,'')),'') = '' then
    raise exception 'This design has no body yet, so its thickness cannot be worked out. '
                    'Set the body (Ceramic / PGVT & GVT / …) first.';
  end if;

  v_new := _thickness_for(v_size, v_body, p_pieces, p_weight);
  if v_new is null then
    raise exception 'Cannot work out a thickness from % pieces at % kg for a % (%). '
                    'Check the pieces and the weight.', p_pieces, p_weight, v_body, v_size;
  end if;

  -- 🔑 THE 1 mm RULE. Every packing of one tile must land on the same thickness: 5 × 10.5 kg and
  -- 4 × 8.4 kg are both 2.1 kg a piece. Further than 1 mm away and this is not another way of
  -- packing THIS tile — it is a DIFFERENT TILE, and it must be added as one.
  if v_have is not null and abs(v_new - v_have) > 1.0 then
    raise exception
      'That packing works out at % mm, but this design is % mm. More than 1 mm apart is a '
      'DIFFERENT TILE, not another packing — add it as its own design.', v_new, v_have;
  end if;

  insert into packings (library_id, pieces, weight_kg)
       values (p_library_id, p_pieces, p_weight)
  on conflict (library_id, pieces, weight_kg) do nothing
    returning id into v_id;

  v_first := v_id is not null and v_have is null;
  if v_id is null then   -- already had exactly this packing
    select id into v_id from packings
     where library_id = p_library_id and pieces = p_pieces and weight_kg = p_weight;
  end if;

  return jsonb_build_object(
    'packing_id', v_id,
    'thickness_mm', (select thickness_mm from stockist_library where id = p_library_id),
    'first', coalesce(v_first, false));

exception
  -- The tile's thickness just moved into another tile's 0.5 mm band. That other tile is the same
  -- print + surface + body at almost this thickness — so it IS this tile, entered twice.
  when exclusion_violation then
    raise exception 'You already have this design at almost this thickness. '
                    'Check the pieces and the box weight.';
end; $function$;

revoke all on function public.packing_add(uuid, integer, numeric) from public, anon;
grant execute on function public.packing_add(uuid, integer, numeric) to authenticated;

-- ── 4. packing_remove ───────────────────────────────────────────────────────────────────────
create or replace function public.packing_remove(p_packing_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;

  delete from packings p
   using stockist_library l
   where p.id = p_packing_id and l.id = p.library_id and l.stockist_id = v_stk;

  if not found then raise exception 'That packing is not yours'; end if;
end; $function$;

revoke all on function public.packing_remove(uuid) from public, anon;
grant execute on function public.packing_remove(uuid) to authenticated;

-- ── 5. my_packings — a tile's packings, for the Library ─────────────────────────────────────
create or replace function public.my_packings(p_library_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'pieces', p.pieces, 'weight_kg', p.weight_kg)
         order by p.created_at), '[]'::jsonb)
    from packings p
    join stockist_library l on l.id = p.library_id
    join stockists s on s.id = l.stockist_id
   where p.library_id = p_library_id and s.user_id = auth.uid();
$function$;

revoke all on function public.my_packings(uuid) from public, anon;
grant execute on function public.my_packings(uuid) to authenticated;

-- ── 6. The re-derive trigger must know where the tile id lives ──────────────────────────────
-- 🪤 It mapped table → tile id with a CASE whose ELSE assumed "the row IS the tile":
--
--     when 'stockist_library_brand_names' then v_row->>'library_id'
--     else                                     v_row->>'id'          -- packings fell in HERE
--
-- so a packing handed its OWN id in as the tile's, updated zero rows, and the thickness silently
-- stayed NULL — which then made the 1 mm rule dead code, because every packing looked like the
-- first one. Name every table; never let a new one land in the else by accident.
create or replace function public._trg_rederive_thickness()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_row jsonb; v_lib uuid; v_new numeric;
begin
  -- to_jsonb() works on ANY rowtype, so this function stays honest on all of its tables.
  if tg_op = 'DELETE' then v_row := to_jsonb(old); else v_row := to_jsonb(new); end if;

  v_lib := case tg_table_name
             when 'packings'                     then v_row->>'library_id'
             when 'stockist_library_brand_names' then v_row->>'library_id'
             when 'stockist_library'             then v_row->>'id'
             else null
           end::uuid;

  if v_lib is null then return coalesce(new, old); end if;

  -- No coalesce: a tile with no packing has an UNKNOWN thickness, not a zero one.
  v_new := _derive_thickness(v_lib);

  update stockist_library
     set thickness_mm = v_new,
         updated_at   = now()
   where id = v_lib
     and thickness_mm is distinct from v_new;

  return coalesce(new, old);
end; $function$;
