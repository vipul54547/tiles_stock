-- T/W stops having a surface_mode, and the "remembered" surface moves from the
-- library identity row to the stock history. (project_per_brand_surface_mode)
--
-- WHY
-- The mode never affected how stock is keyed: stock_add_holding matches on
-- library + brand + quality + surface_type + surface_label, and
-- add_inventory_batch always passes the surface through regardless of mode. So
-- a T/W can already hold Glossy and Matt of one print as separate lines with no
-- mode at all. The flag only ever did two things: force the picker to be filled,
-- and gate the library stamp below.
--
-- Dropping the force is deliberate (a trader picks their word, or picks None --
-- one screen serves a factory that writes surface into the name and one that
-- ships it in its own column). But the stamp MUST go with it:
--
--   if v_mode <> 'attribute' and surf <> 'none' then
--     update stockist_library set surface_type = ..., surface_label = ...
--
-- A T/W is always non-attribute, so that fired on every entry. Stock one print
-- in Glossy, then in Matt, and the LIBRARY row -- the design's identity -- ends
-- up Matt. Last entry wins. Harmless while a print had exactly one surface (an
-- M with surface-in-name: a different surface IS a different print), corruption
-- once a trader holds several surfaces of one print.
--
-- So: stamp only for M. For M the surface is part of the name, so writing it to
-- identity is right. For T/W the surface lives on the holding, and nowhere else.
--
-- Nothing to migrate: every brand is already 'in_name'. brands.surface_mode and
-- admin_set_brand_surface_mode are left in place (vestigial, admin-only); only
-- add_inventory_batch stops reading them.

CREATE OR REPLACE FUNCTION public.add_inventory_batch(p_entries jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  e jsonb; v_id uuid; v_count int := 0; v_boxes int := 0; v_q int;
  v_stk uuid; v_biz text;
  v_lib uuid; v_brand uuid; v_mode text; v_surf text; v_label text;
begin
  select id, business_type into v_stk, v_biz
    from stockists where user_id = auth.uid();

  -- Only an M has a surface convention: it IS the factory, and its brands are
  -- alternate names for the same print. A T/W carries other factories' brands
  -- and simply records whichever surface arrived on the dispatch note.
  if v_biz = 'M' then
    select coalesce(surface_mode, 'in_name') into v_mode
      from stockists where id = v_stk;
  else
    v_mode := null;
  end if;

  for e in select * from jsonb_array_elements(coalesce(p_entries, '[]'::jsonb)) loop
    v_q    := greatest(coalesce((e->>'quantity')::int, 0), 0);
    v_lib  := (e->>'library_id')::uuid;
    v_brand := nullif(btrim(coalesce(e->>'brand_id', '')), '')::uuid;
    v_surf := coalesce(nullif(btrim(e->>'surface'), ''), 'None');
    v_label := nullif(btrim(coalesce(e->>'surface_label','')), '');

    v_id := public.stock_add_holding(
      v_lib,
      coalesce(nullif(btrim(e->>'quality'), ''), 'Standard'),
      v_q, null, v_surf, v_brand, v_label);

    -- M + surface-in-name only: the surface is part of the print's identity.
    -- Never for T/W -- one print may carry many surfaces on the shelf.
    if v_biz = 'M' and v_mode <> 'attribute' and lower(v_surf) <> 'none' then
      update stockist_library set surface_type = v_surf, surface_label = v_label
        where id = v_lib and stockist_id = v_stk;
    end if;

    if v_id is not null then
      v_count := v_count + 1;
      v_boxes := v_boxes + v_q;
    end if;
  end loop;
  return jsonb_build_object('count', v_count, 'boxes', v_boxes);
end;
$function$;

-- The surface this stockist last ADDED stock in, per print, so Add Stock can
-- prefill it. Replaces the library stamp as the "remember" mechanism: memory now
-- lives in stock HISTORY, not in the design's identity.
--
-- { "<library_id>": { "surface_type": "Sugar", "surface_label": "Raindrops" } }
-- 'None' holdings are skipped -- they carry no word worth remembering.
--
-- Ordered by the newest stock_in row (where add_stock records every addition),
-- NOT by designs.updated_at: dispatching also bumps updated_at, so a print last
-- DISPATCHED in Glossy would otherwise prefill Glossy when the stockist is
-- restocking the Matt they added yesterday. Falls back to the holding's own
-- created_at for a row created with zero quantity (stock_add_holding inserts the
-- design row, and only calls add_stock when qty > 0).
create or replace function public.my_last_surface_by_library()
 returns jsonb
 language sql
 stable
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_object_agg(t.library_id::text, jsonb_build_object(
           'surface_type',  t.surface_type,
           'surface_label', coalesce(t.surface_label, ''))), '{}'::jsonb)
  from (
    select distinct on (d.library_id)
           d.library_id, d.surface_type, d.surface_label
    from designs d
    left join lateral (
      select max(si.created_at) as last_add
      from stock_in si where si.design_id = d.id
    ) a on true
    where d.stockist_id = (select id from stockists where user_id = auth.uid())
      and d.library_id is not null
      and lower(coalesce(d.surface_type, 'none')) <> 'none'
    order by d.library_id, coalesce(a.last_add, d.created_at) desc
  ) t;
$function$;

-- authenticated only, per 20260710_tighten_my_rpc_grants.sql.
revoke execute on function public.my_last_surface_by_library() from anon, public;
grant  execute on function public.my_last_surface_by_library() to authenticated, service_role;
