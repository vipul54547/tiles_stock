-- Design "Family" (concept) grouping. Tiles sold as a coordinated set of
-- variants (1803 / 1803-A / 1803-B, 1305 Light / 1305-HL1 / 1305-Dark,
-- greccisa bianco / decor / gray) are auto-grouped by name-root (STRICT: only
-- when the extra part is a recognised variant token), per stockist + size.
-- The grouping is computed LIVE from names; only the stockist's corrections
-- are stored (library_family_overrides). Buyer sees the whole family with each
-- member's stock (incl. out-of-stock, shown greyed).

-- ── corrections store ───────────────────────────────────────────────────────
create table if not exists public.library_family_overrides (
  library_id  uuid primary key references public.stockist_library(id) on delete cascade,
  stockist_id uuid not null references public.stockists(id) on delete cascade,
  family_key  text not null,
  created_at  timestamptz not null default now()
);
alter table public.library_family_overrides enable row level security;

-- ── name-root → family key (STRICT variant tokens) ──────────────────────────
create or replace function public.family_key_of(p_name text)
 returns text
 language plpgsql
 immutable
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_norm text := btrim(regexp_replace(upper(coalesce(p_name,'')), '[-_\s]+', ' ', 'g'));
  v_root text; v_rem text; w text; v_ok boolean := true;
  -- recognised variant words (besides single letters / digits)
  v_variants text[] := array[
    'HL','HL1','HL2','HL3','HL4','LT','LIGHT','DK','DARK','DEC','DECOR','HIGHLIGHT'];
  v_colours text[] := array[
    'BIANCO','GRAY','GREY','BLUE','BROWN','BEIGE','CREAM','IVORY','BLACK','WHITE',
    'GREEN','RED','GOLD','SILVER','MULTI','NERO','ROSSO','MARRONE','ONYX','STATUARIO'];
begin
  if v_norm = '' then return ''; end if;
  -- root = leading digit run, else the first word
  if v_norm ~ '^[0-9]' then
    v_root := (regexp_match(v_norm, '^[0-9]+'))[1];
    v_rem  := btrim(substr(v_norm, length(v_root) + 1));
  else
    v_root := split_part(v_norm, ' ', 1);
    v_rem  := btrim(substr(v_norm, length(v_root) + 1));
  end if;

  if v_rem = '' then
    return v_root;                    -- the base tile
  end if;

  -- STRICT: every remaining word must be a recognised variant/colour token,
  -- a single letter, or a short variant number — else the tile stands alone.
  foreach w in array regexp_split_to_array(v_rem, '\s+') loop
    if not (
         (length(w) = 1 and w ~ '^[A-Z0-9]$')
      or w = any(v_variants)
      or w = any(v_colours)
      or w ~ '^(HL|LT|DK|DEC)[0-9]+$'
    ) then
      v_ok := false;
    end if;
  end loop;

  return case when v_ok then v_root else v_norm end;
end; $function$;

-- ── effective key of a master (override wins over the auto key) ──────────────
create or replace function public._family_effective_key(p_lib uuid)
 returns text
 language sql
 stable
 set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(
    (select o.family_key from library_family_overrides o where o.library_id = p_lib),
    family_key_of((select master_design_name from stockist_library where id = p_lib))
  );
$function$;

-- ── family members (shared by buyer + stockist views) ───────────────────────
-- Every master of the same stockist + size sharing the effective key, with the
-- master's live F_stock summed over its holdings (0 = out of stock). Base tile
-- first (shortest name), then alphabetical.
create or replace function public._family_members(
  p_stockist uuid, p_size text, p_key text, p_current uuid)
 returns jsonb
 language sql
 stable
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(x order by length(x->>'name'), lower(x->>'name')), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'library_id', m.id,
      'name', m.master_design_name,
      'size', m.size,
      'image_url', m.image_url,
      'f_stock', coalesce((
        select sum(greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)))
        from designs d
        where d.library_id = m.id and d.stockist_id = p_stockist), 0),
      'is_current', (m.id = p_current)
    ) as x
    from stockist_library m
    where m.stockist_id = p_stockist and m.size = p_size
      and _family_effective_key(m.id) = p_key
  ) t;
$function$;

-- ── buyer: a design's family (>=2 members, else empty) ──────────────────────
create or replace function public.design_family(p_design_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_lib uuid; v_stk uuid; v_size text; v_key text; v_members jsonb;
begin
  select d.library_id, d.stockist_id into v_lib, v_stk
    from designs d where d.id = p_design_id;
  if v_lib is null then return '[]'::jsonb; end if;
  select size into v_size from stockist_library where id = v_lib;
  v_key := _family_effective_key(v_lib);
  v_members := _family_members(v_stk, v_size, v_key, v_lib);
  if jsonb_array_length(v_members) < 2 then return '[]'::jsonb; end if;
  return v_members;
end; $function$;

-- ── stockist: the family for one of their own masters (incl. just itself) ────
create or replace function public.my_family_for(p_library_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_stk uuid; v_size text; v_key text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if not exists (select 1 from stockist_library
                 where id = p_library_id and stockist_id = v_stk) then
    raise exception 'Not your design';
  end if;
  select size into v_size from stockist_library where id = p_library_id;
  v_key := _family_effective_key(p_library_id);
  return jsonb_build_object(
    'family_key', v_key,
    'members', _family_members(v_stk, v_size, v_key, p_library_id));
end; $function$;

-- ── stockist corrections ────────────────────────────────────────────────────
-- Attach a master to a family key (add to family). "Remove from family" =
-- attach it to its own id (a unique key → stands alone).
create or replace function public.family_set_override(p_library_id uuid, p_family_key text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_key text := btrim(coalesce(p_family_key,''));
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if not exists (select 1 from stockist_library
                 where id = p_library_id and stockist_id = v_stk) then
    raise exception 'Not your design';
  end if;
  if v_key = '' then raise exception 'Family key required'; end if;
  insert into library_family_overrides (library_id, stockist_id, family_key)
    values (p_library_id, v_stk, v_key)
    on conflict (library_id) do update set family_key = excluded.family_key;
end; $function$;

-- Reset a master back to automatic grouping (drop the override).
create or replace function public.family_clear_override(p_library_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  delete from library_family_overrides
   where library_id = p_library_id and stockist_id = v_stk;
end; $function$;

grant execute on function public.design_family(uuid) to anon, authenticated;
grant execute on function public.my_family_for(uuid) to authenticated;
grant execute on function public.family_set_override(uuid, text) to authenticated;
grant execute on function public.family_clear_override(uuid) to authenticated;
