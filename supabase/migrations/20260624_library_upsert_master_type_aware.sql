-- M identity redesign — close the #7 gap in the MANUAL Design-editor path.
-- The editor saves via library_upsert_master (14-arg overload). Make it
-- TYPE-AWARE to match the model:
--   • M  : a tile is ONE box across all brands → dup guard is brand-AGNOSTIC,
--          keyed by name+size+SURFACE; new/edited boxes are brand_id NULL.
--          (Add a brand name by EDITING the existing design, not making a 2nd.)
--   • T/W: unchanged — brand silo (unique within the brand by name+size).
-- Pairs with the editor's _isDuplicate (brand-agnostic+surface for M).
-- NOTE: only the 14-arg overload (the one the editor uses) is changed; the
-- legacy 6-arg overload is left as-is.

CREATE OR REPLACE FUNCTION public.library_upsert_master(p_id uuid, p_size text, p_master_name text, p_image_url text, p_aliases jsonb, p_brand_id uuid DEFAULT NULL::uuid, p_surface text DEFAULT NULL::text, p_stock_type text DEFAULT NULL::text, p_tile_type text DEFAULT NULL::text, p_pieces integer DEFAULT NULL::integer, p_weight numeric DEFAULT NULL::numeric, p_thickness numeric DEFAULT NULL::numeric, p_colour text DEFAULT NULL::text, p_finish text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_stk uuid; v_id uuid; v_type text;
        v_name text := btrim(coalesce(p_master_name,''));
        v_size text := btrim(coalesce(p_size,''));
        v_surf text := coalesce(nullif(btrim(coalesce(p_surface,'')),''),'None');
        r jsonb; v_brand uuid; v_alias text;
begin
  select id, business_type into v_stk, v_type from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can edit the library'; end if;
  if v_name = '' then raise exception 'Master design name cannot be empty'; end if;
  if v_size = '' then raise exception 'Size is required'; end if;

  if v_type = 'M' then
    if exists (select 1 from stockist_library
               where stockist_id = v_stk and lower(master_design_name) = lower(v_name)
                 and size = v_size and coalesce(surface_type,'None') = v_surf
                 and (p_id is null or id <> p_id)) then
      raise exception 'This tile "%" (% / %) is already in your library — open it to add another brand''s name', v_name, v_size, v_surf;
    end if;
  else
    if exists (select 1 from stockist_library
               where stockist_id = v_stk and lower(master_design_name) = lower(v_name)
                 and size = v_size and brand_id is not distinct from p_brand_id
                 and (p_id is null or id <> p_id)) then
      raise exception 'A design named "%" at size % already exists for this brand', v_name, v_size;
    end if;
  end if;

  if p_id is null then
    insert into stockist_library (stockist_id, size, master_design_name, image_url, brand_id)
      values (v_stk, v_size, v_name, nullif(btrim(coalesce(p_image_url,'')), ''),
              case when v_type = 'M' then null else p_brand_id end)
      returning id into v_id;
  else
    update stockist_library set
      size = v_size, master_design_name = v_name,
      image_url = nullif(btrim(coalesce(p_image_url,'')), ''),
      brand_id = case when v_type = 'M' then null else coalesce(p_brand_id, brand_id) end,
      updated_at = now()
    where id = p_id and stockist_id = v_stk
    returning id into v_id;
    if v_id is null then raise exception 'Design not found'; end if;
  end if;

  update stockist_library m set
    surface_type   = case when p_surface     is null then m.surface_type   else v_surf end,
    stock_type     = case when p_stock_type  is null then m.stock_type     else coalesce(nullif(btrim(p_stock_type),''),'Uncertain') end,
    tile_type      = case when p_tile_type   is null then m.tile_type      else coalesce(btrim(p_tile_type),'') end,
    pieces_per_box = case when p_pieces       is null then m.pieces_per_box else coalesce(p_pieces,0) end,
    box_weight_kg  = case when p_weight       is null then m.box_weight_kg  else coalesce(p_weight,0) end,
    thickness_mm   = case when p_thickness    is null then m.thickness_mm   else coalesce(p_thickness,0) end,
    colour         = case when p_colour      is null then m.colour          else coalesce(btrim(p_colour),'') end,
    finish_label   = case when p_finish      is null then m.finish_label    else nullif(btrim(p_finish),'') end,
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
            and m2.size = v_size
        ) then
          raise exception 'Design name "%" is already used for another tile in that brand at size %', v_alias, v_size;
        end if;
        insert into stockist_library_brand_names (library_id, brand_id, brand_design_name)
          values (v_id, v_brand, v_alias)
          on conflict (library_id, brand_id) do update set brand_design_name = excluded.brand_design_name;
      end if;
    end loop;
  end if;
  return v_id;
end; $function$;
