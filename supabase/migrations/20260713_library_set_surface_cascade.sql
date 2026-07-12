-- Changing a product's SURFACE must move its stock with it.
--
-- Surface is part of the product's identity, so editing it is an identity change — not a
-- cosmetic tweak. But library_upsert_master only ever wrote stockist_library.surface_type
-- and left designs.surface_type alone. Proven with a rolled-back trial on prod: flip
-- STANZA GREEN Matt -> Rocker and the product says Rocker while its 262 boxes still say
-- Matt — 2 invariant violations, the exact desync the whole migration exists to prevent.
--
-- This matters NOW because Add Stock no longer asks for a surface when surface_mode is not
-- 'attribute'. The Library is therefore the ONLY place a stockist can set or correct one,
-- so that edit path has to be airtight.
--
-- 1. library_set_surface — a small, focused RPC for the Library's surface chip: change the
--    surface (and the stockist's word for it) and CASCADE to every holding.
-- 2. library_upsert_master — same cascade, so the full editor cannot desync either.

create or replace function public.library_set_surface(
  p_library_id uuid, p_surface text, p_label text default null::text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_name text; v_size text; v_old text;
        v_surf  text := nullif(btrim(coalesce(p_surface,'')),'');
        v_label text := nullif(btrim(coalesce(p_label,'')),'');
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can edit the library'; end if;
  if v_surf is null or lower(v_surf) = 'none' then
    raise exception 'Pick a surface — it is part of the design.';
  end if;
  if not exists (select 1 from surface_types t where t.name = v_surf and t.is_active) then
    raise exception '"%" is not one of the available surfaces', v_surf;
  end if;

  select master_design_name, size, surface_type into v_name, v_size, v_old
    from stockist_library where id = p_library_id and stockist_id = v_stk;
  if v_name is null then raise exception 'Design not found'; end if;

  -- Moving to a surface this print already has would be two products becoming one.
  if v_surf <> v_old and exists (
       select 1 from stockist_library
        where stockist_id = v_stk
          and lower(master_design_name) = lower(v_name)
          and size = v_size and surface_type = v_surf
          and id <> p_library_id) then
    raise exception '"%" (% · %) already exists — that would be a duplicate. '
                    'Merge them in your Library instead.', v_name, v_size, v_surf;
  end if;

  update stockist_library
     set surface_type  = v_surf,
         surface_label = coalesce(v_label, surface_label),
         updated_at    = now()
   where id = p_library_id and stockist_id = v_stk;

  -- CASCADE: a holding of this product IS this product. Its surface follows.
  -- (No collision possible: every holding of this library moves together, and the holding
  --  key is (stockist, library, brand, quality, surface) — brand+quality stay distinct.)
  update designs d
     set surface_type  = v_surf,
         surface_label = coalesce(v_label, (select surface_label from stockist_library
                                             where id = p_library_id)),
         updated_at    = now()
   where d.library_id = p_library_id and d.stockist_id = v_stk;
end; $function$;


-- The full editor must cascade too.
create or replace function public.library_upsert_master(
  p_id uuid, p_size text, p_master_name text, p_image_url text, p_aliases jsonb,
  p_brand_id uuid default null::uuid, p_surface text default null::text,
  p_stock_type text default null::text, p_tile_type text default null::text,
  p_pieces integer default null::integer, p_weight numeric default null::numeric,
  p_thickness numeric default null::numeric, p_colour text default null::text,
  p_finish text default null::text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_id uuid;
        v_name text := btrim(coalesce(p_master_name,''));
        v_size text := btrim(coalesce(p_size,''));
        v_surf text := nullif(btrim(coalesce(p_surface,'')),'');
        r jsonb; v_brand uuid; v_alias text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can edit the library'; end if;
  if v_name = '' then raise exception 'Master design name cannot be empty'; end if;
  if v_size = '' then raise exception 'Size is required'; end if;
  if v_surf is null or lower(v_surf) = 'none' then
    raise exception 'Pick a surface — it is part of the design.';
  end if;

  if exists (select 1 from stockist_library
             where stockist_id = v_stk
               and lower(master_design_name) = lower(v_name)
               and size = v_size and surface_type = v_surf
               and (p_id is null or id <> p_id)) then
    raise exception '"%" (% · %) is already in your library', v_name, v_size, v_surf;
  end if;

  if p_id is null then
    insert into stockist_library (stockist_id, size, master_design_name, image_url,
                                  brand_id, surface_type)
      values (v_stk, v_size, v_name, nullif(btrim(coalesce(p_image_url,'')), ''),
              p_brand_id, v_surf)
      returning id into v_id;
  else
    update stockist_library set
      size = v_size, master_design_name = v_name,
      image_url = nullif(btrim(coalesce(p_image_url,'')), ''),
      brand_id = coalesce(p_brand_id, brand_id),
      surface_type = v_surf,
      updated_at = now()
    where id = p_id and stockist_id = v_stk
    returning id into v_id;
    if v_id is null then raise exception 'Design not found'; end if;

    -- CASCADE: the stock follows its product's surface (and name/size, which are copied
    -- onto the holding for display).
    update designs d
       set surface_type = v_surf,
           name         = v_name,
           size         = v_size,
           updated_at   = now()
     where d.library_id = v_id and d.stockist_id = v_stk;
  end if;

  update stockist_library m set
    stock_type     = case when p_stock_type is null then m.stock_type     else coalesce(nullif(btrim(p_stock_type),''),'Uncertain') end,
    tile_type      = case when p_tile_type  is null then m.tile_type      else coalesce(btrim(p_tile_type),'') end,
    pieces_per_box = case when p_pieces     is null then m.pieces_per_box else coalesce(p_pieces,0) end,
    box_weight_kg  = case when p_weight     is null then m.box_weight_kg  else coalesce(p_weight,0) end,
    thickness_mm   = case when p_thickness  is null then m.thickness_mm   else coalesce(p_thickness,0) end,
    colour         = case when p_colour     is null then m.colour         else coalesce(btrim(p_colour),'') end,
    finish_label   = case when p_finish     is null then m.finish_label   else nullif(btrim(p_finish),'') end,
    updated_at = now()
  where m.id = v_id;

  delete from stockist_library_brand_names where library_id = v_id;
  if p_aliases is not null then
    for r in select * from jsonb_array_elements(p_aliases) loop
      v_brand := nullif(r->>'brand_id','')::uuid;
      v_alias := btrim(coalesce(r->>'name',''));
      if v_alias <> '' and v_brand is not null
         and exists (select 1 from brands where id = v_brand and stockist_id = v_stk) then
        if exists (
          select 1 from stockist_library m2
          join stockist_library_brand_names a2 on a2.library_id = m2.id
          where m2.stockist_id = v_stk and m2.id <> v_id
            and a2.brand_id = v_brand and lower(a2.brand_design_name) = lower(v_alias)
            and m2.size = v_size and m2.surface_type = v_surf
        ) then
          raise exception 'Design name "%" is already used for another tile in that brand at size % · %',
            v_alias, v_size, v_surf;
        end if;
        insert into stockist_library_brand_names (library_id, brand_id, brand_design_name)
          values (v_id, v_brand, v_alias)
          on conflict (library_id, brand_id) do update set brand_design_name = excluded.brand_design_name;
      end if;
    end loop;
  end if;
  return v_id;
end; $function$;
