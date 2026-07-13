-- 🔴 The 0.5 mm BAND was too sharp to be identity. It would have FALSE-SPLIT real products.
--
-- Box weight DRIFTS in the trade. The user's own example: a 600x1200, 2-piece PGVT & GVT box was
-- 28 kg in 2024 and is 26 kg now — the same tile, the same product.
--
--     28 kg → 8.71 mm  → band 8.5–9.0
--     26 kg → 8.09 mm  → band 8.0–8.5     ← a DIFFERENT band
--
-- 2 kg of ordinary drift = only **0.62 mm**, but it crosses a band edge. Keying identity on the band
-- would have quietly turned one product into two — the exact disease this chapter exists to cure.
--
-- It takes 3.22 kg to move that tile a FULL 1 mm (800x1600 needs 5.72 kg; 600x600 needs 3.22 kg), so
-- the threshold must be in MILLIMETRES, not kilos:
--
--   🔑 Thickness makes a DIFFERENT PRODUCT only when it differs by MORE THAN 1 mm.
--
-- A btree unique index cannot express "at least 1 mm apart" — that is a proximity rule, not an
-- equality rule. An EXCLUDE constraint can: give each product the range [t-0.5, t+0.5) and forbid
-- two products of the same print/size/surface/body from OVERLAPPING. Two ranges overlap exactly when
-- |t1 - t2| < 1.0, so surviving rows are ≥ 1 mm apart. ✅ Verified: no existing pair is closer.

create extension if not exists btree_gist;

-- the band is no longer identity — it stays only for DISPLAY and the buyer's thickness filter
drop index if exists stockist_library_uniq;

alter table stockist_library
  drop constraint if exists stockist_library_thickness_apart;

alter table stockist_library
  add constraint stockist_library_thickness_apart
  exclude using gist (
    stockist_id                     with =,
    lower(master_design_name)       with =,
    size                            with =,
    surface_type                    with =,
    coalesce(tile_type, '')         with =,     -- '' so two BODY-less rows still compare equal
    numrange(thickness_mm - 0.5, thickness_mm + 0.5) with &&
  )
  where (thickness_mm is not null);

comment on constraint stockist_library_thickness_apart on stockist_library is
  'Two products of the same print+size+surface+body must be MORE THAN 1 mm apart in thickness. '
  'Anything closer is the SAME tile — box weight drifts in the trade (a 600x1200 2-pc box went '
  '28 kg → 26 kg = 0.62 mm), and that drift must never fork a product in two.';

-- A product with no box yet has no thickness, so the EXCLUDE above cannot see it. Two such twins
-- must still collide rather than quietly duplicate.
drop index if exists stockist_library_uniq_no_thickness;

create unique index stockist_library_uniq_no_thickness
    on stockist_library (stockist_id, lower(master_design_name), size, surface_type, tile_type)
       nulls not distinct
 where thickness_mm is null;

-- Say what actually happened. Postgres would otherwise throw a raw 23P01 naming a gist constraint.
create or replace function public.library_upsert_master(
  p_id uuid, p_size text, p_master_name text, p_image_url text, p_aliases jsonb,
  p_brand_id uuid default null, p_surface text default null, p_stock_type text default null,
  p_tile_type text default null, p_pieces integer default null, p_weight numeric default null,
  p_thickness numeric default null, p_colour text default null, p_finish text default null)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_id uuid;
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

  -- A twin with NO box yet cannot be told apart by thickness, so it is a real clash.
  if exists (select 1 from stockist_library
             where stockist_id = v_stk
               and lower(master_design_name) = lower(v_name)
               and size = v_size and surface_type = v_surf
               and tile_type is not distinct from coalesce(v_tile, tile_type)
               and thickness_mm is null
               and (p_id is null or id <> p_id)) then
    raise exception '"%" (% · % · %) is already in your library and has no box yet — give that one '
                    'its pieces and box weight first, so the two can be told apart by thickness.',
      v_name, v_size, v_surf, v_tile;
  end if;

  if p_id is null then
    insert into stockist_library (stockist_id, size, master_design_name, image_url,
                                  brand_id, surface_type, tile_type)
      values (v_stk, v_size, v_name, nullif(btrim(coalesce(p_image_url,'')), ''),
              p_brand_id, v_surf, v_tile)
      returning id into v_id;
  else
    update stockist_library set
      size = v_size, master_design_name = v_name,
      image_url = nullif(btrim(coalesce(p_image_url,'')), ''),
      brand_id = coalesce(p_brand_id, brand_id),
      surface_type = v_surf,
      tile_type    = coalesce(v_tile, tile_type),
      updated_at = now()
    where id = p_id and stockist_id = v_stk
    returning id into v_id;
    if v_id is null then raise exception 'Design not found'; end if;

    update designs d
       set surface_type = v_surf, name = v_name, size = v_size, updated_at = now()
     where d.library_id = v_id and d.stockist_id = v_stk;
  end if;

  update stockist_library m set
    stock_type   = case when p_stock_type is null then m.stock_type   else coalesce(nullif(btrim(p_stock_type),''),'Uncertain') end,
    colour       = case when p_colour     is null then m.colour       else coalesce(btrim(p_colour),'') end,
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
    update stockist_library_brand_names a
       set pieces_per_box = coalesce(p_pieces, a.pieces_per_box),
           box_weight_kg  = coalesce(p_weight, a.box_weight_kg)
     where a.library_id = v_id;
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
end; $function$;
