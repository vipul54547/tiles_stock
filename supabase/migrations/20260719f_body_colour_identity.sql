-- ═══ BODY COLOUR is IDENTITY for Full Body / Colour Body ══════════════════════════════════════
--
-- A through-body tile (Full Body / Colour Body) is coloured in the biscuit, and that colour SPLITS
-- products: one print + surface in body colour "Earth" vs "Milky Body" are TWO different products.
-- So body colour is compulsory for those two bodies and it joins the identity key — it is NOT a
-- describe-it DNA tag (that was the wrong home, which is why it never fit).
--
-- The stockist's WORD is the identity ("Earth", "Milky Body" — their own vocabulary). Each carries
-- an accuracy value: L*a*b* (preferred) or Hex (fallback). The colours are a reusable palette.

-- ── 1. the palette ──────────────────────────────────────────────────────────────────────────
create table if not exists body_colours (
  id          uuid primary key default gen_random_uuid(),
  stockist_id uuid not null references stockists(id) on delete cascade,
  name        text not null,
  l           numeric,   -- L*  (lightness)      · optional, for accuracy
  a           numeric,   -- a*  (green→red)       · optional
  b           numeric,   -- b*  (blue→yellow)     · optional
  hex         text,      -- fallback only — used when there is no L*a*b*
  created_at  timestamptz not null default now(),
  constraint body_colours_name_not_blank check (btrim(name) <> '')
);
create unique index if not exists body_colours_uniq on body_colours (stockist_id, lower(name));
alter table body_colours enable row level security;
revoke all on body_colours from anon, authenticated;

comment on table body_colours is
  'A stockist''s reusable body-colour palette. The NAME is the product identity for a Full/Colour '
  'Body tile; L*a*b* (preferred) or Hex is the accuracy spec.';

-- ── 2. the identity column ──────────────────────────────────────────────────────────────────
alter table stockist_library add column if not exists body_colour_id uuid references body_colours(id);
create index if not exists stockist_library_body_colour on stockist_library (body_colour_id);

-- ── 3. body colour joins the identity key ───────────────────────────────────────────────────
-- Existing rows all have body_colour_id = NULL, so adding it (NULLS NOT DISTINCT / coalesced to '')
-- cannot split or collide anything that was fine before.
drop index if exists stockist_library_uniq_no_thickness;
create unique index stockist_library_uniq_no_thickness
  on stockist_library (print_id, surface_type, tile_type, body_colour_id)
  nulls not distinct where (thickness_mm is null);

alter table stockist_library drop constraint if exists stockist_library_thickness_apart;
alter table stockist_library add constraint stockist_library_thickness_apart
  exclude using gist (
    print_id                         with =,
    surface_type                     with =,
    coalesce(tile_type, ''::text)    with =,
    coalesce(body_colour_id::text, '') with =,
    numrange(thickness_mm - 0.5, thickness_mm + 0.5) with &&
  ) where (thickness_mm is not null);

-- ── 4. retire the old "Body Colour" DNA attribute — it is a column now, not a tag ───────────
update dna_attributes set is_active = false where name = 'Body Colour';

-- ── 5. palette RPCs ─────────────────────────────────────────────────────────────────────────
create or replace function public.body_colour_upsert(
  p_name text, p_l numeric default null, p_a numeric default null,
  p_b numeric default null, p_hex text default null)
 returns uuid
 language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_id uuid; v_name text := btrim(coalesce(p_name,''));
        v_has_lab boolean := (p_l is not null or p_a is not null or p_b is not null);
        v_hex text := nullif(btrim(coalesce(p_hex,'')),'');
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if v_name = '' then raise exception 'A body colour needs a name'; end if;

  insert into body_colours (stockist_id, name, l, a, b, hex)
    values (v_stk, v_name, p_l, p_a, p_b, case when v_has_lab then null else v_hex end)
  on conflict (stockist_id, lower(name)) do update
    set l   = coalesce(excluded.l,   body_colours.l),
        a   = coalesce(excluded.a,   body_colours.a),
        b   = coalesce(excluded.b,   body_colours.b),
        hex = coalesce(excluded.hex, body_colours.hex)
  returning id into v_id;
  return v_id;
end $function$;
revoke all on function public.body_colour_upsert(text, numeric, numeric, numeric, text) from public, anon;
grant execute on function public.body_colour_upsert(text, numeric, numeric, numeric, text) to authenticated;

create or replace function public.my_body_colours()
 returns jsonb language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  with me as (select id from stockists where user_id = auth.uid())
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', bc.id, 'name', bc.name, 'l', bc.l, 'a', bc.a, 'b', bc.b, 'hex', bc.hex)
           order by lower(bc.name)), '[]'::jsonb)
    from body_colours bc where bc.stockist_id = (select id from me);
$function$;
revoke all on function public.my_body_colours() from public, anon;
grant execute on function public.my_body_colours() to authenticated;

-- ── 6. tile_add takes the body colour, and enforces the rule ────────────────────────────────
-- Adding a param makes an overload, so drop the old 3-arg signature first (42725 otherwise).
drop function if exists public.tile_add(uuid, text, text);
create or replace function public.tile_add(
  p_print_id uuid, p_surface text, p_tile_type text default null,
  p_body_colour_id uuid default null)
 returns uuid
 language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_id uuid; v_new boolean := false; v_series uuid;
        v_surf text := nullif(btrim(coalesce(p_surface,'')),'');
        v_body text := nullif(btrim(coalesce(p_tile_type,'')),'');
        v_through boolean; v_bcid uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if not exists (select 1 from print_master where id = p_print_id and stockist_id = v_stk) then
    raise exception 'That artwork is not yours'; end if;
  if v_surf is null or lower(v_surf) = 'none' then
    raise exception 'Pick a surface — every design has one, and it is part of what the design IS.'; end if;

  -- 🎨 Body colour is IDENTITY + COMPULSORY for a Full/Colour Body, and does not exist for the rest.
  v_through := lower(coalesce(v_body,'')) in ('full body', 'colour body');
  if v_through then
    if p_body_colour_id is null then
      raise exception 'Pick a body colour — a Full Body / Colour Body design is told apart by it.';
    end if;
    if not exists (select 1 from body_colours where id = p_body_colour_id and stockist_id = v_stk) then
      raise exception 'That body colour is not yours';
    end if;
    v_bcid := p_body_colour_id;
  else
    v_bcid := null;
  end if;

  select id into v_id from stockist_library
   where stockist_id = v_stk and print_id = p_print_id and surface_type = v_surf
     and (v_body is null or tile_type is null or tile_type = v_body)
     and body_colour_id is not distinct from v_bcid
   order by (tile_type is not null) desc, created_at
   limit 1;

  if v_id is null then
    insert into stockist_library (stockist_id, print_id, surface_type, tile_type, body_colour_id)
      values (v_stk, p_print_id, v_surf, v_body, v_bcid)
      returning id into v_id;
    v_new := true;
  else
    update stockist_library m
       set tile_type = coalesce(m.tile_type, v_body), updated_at = now()
     where m.id = v_id and m.tile_type is null and v_body is not null;
  end if;

  if v_new then
    select v.id into v_series
      from dna_values v join dna_attributes a on a.id = v.attribute_id
     where a.name = 'Series' and v.stockist_id is null and lower(v.name) = 'regular'
     limit 1;
    if v_series is not null then
      insert into library_dna (library_id, value_id) values (v_id, v_series) on conflict do nothing;
    end if;
  end if;

  return v_id;
end $function$;
revoke all on function public.tile_add(uuid, text, text, uuid) from public, anon;
grant execute on function public.tile_add(uuid, text, text, uuid) to authenticated;

-- ── 7. self-check (raise only on FAILURE) ───────────────────────────────────────────────────
do $$
declare v_tbl regclass; v_col int;
begin
  v_tbl := to_regclass('public.body_colours');
  select count(*) into v_col from information_schema.columns
   where table_name='stockist_library' and column_name='body_colour_id';
  if v_tbl is null or v_col <> 1 then raise exception 'FAILED: body colour schema missing'; end if;
  perform 'public.tile_add(uuid, text, text, uuid)'::regprocedure;
  perform 'public.body_colour_upsert(text, numeric, numeric, numeric, text)'::regprocedure;
  raise notice 'OK: body colour is now identity; palette + tile_add ready';
end $$;
