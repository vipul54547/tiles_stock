-- BOX chapter — HOTFIX to 20260713_box_step3_derive_thickness.sql
--
-- Two bugs, both in the BOX chapter, both fixed here because fixing only the first one
-- ACTIVATES the second.
--
-- (1) Add design / Edit design died for every stockist with:
--         PostgrestException: record "new" has no field "library_id"   (42703)
--
--     _trg_rederive_thickness is ONE function on TWO tables, and it chose the library id with
--     a single CASE expression:
--
--         v_lib := case tg_table_name
--                    when 'stockist_library_brand_names' then coalesce(new.library_id, old.library_id)
--                    else coalesce(new.id, old.id) end;
--
--     plpgsql compiles that CASE as ONE SQL expression, so `new.library_id` must resolve even
--     when the trigger fires on stockist_library — whose NEW row has no library_id. A branch not
--     taken is still a branch compiled. library_upsert_master always runs an
--     `update stockist_library set tile_type = ...`, which fires the trigger, so EVERY product
--     create and edit raised 42703.
--
--     Fix: never name a column that the other table lacks. Read the key out of the row as jsonb,
--     which is legal for any rowtype.
--
-- (2) library_upsert_master DELETED and re-inserted the brand-name rows on every save. Those
--     rows ARE the boxes now — they carry pieces_per_box and box_weight_kg. So the first
--     successful edit after (1) was fixed would have wiped every brand's packing and dropped
--     the derived thickness to 0. The brand names must be SYNCED, never recreated.

-- ── (1) The trigger ──────────────────────────────────────────────────────────────────────────
create or replace function public._trg_rederive_thickness()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_row jsonb; v_lib uuid; v_new numeric;
begin
  -- to_jsonb() works on ANY rowtype, so this function stays honest on both of its tables.
  if tg_op = 'DELETE' then v_row := to_jsonb(old); else v_row := to_jsonb(new); end if;

  v_lib := case tg_table_name
             when 'stockist_library_brand_names' then v_row->>'library_id'
             else                                     v_row->>'id'
           end::uuid;

  if v_lib is null then return coalesce(new, old); end if;

  v_new := coalesce(_derive_thickness(v_lib), 0);

  update stockist_library
     set thickness_mm = v_new,
         updated_at   = now()
   where id = v_lib
     and thickness_mm is distinct from v_new;

  return coalesce(new, old);
end; $function$;

-- ── (2) The upsert must not eat the boxes ────────────────────────────────────────────────────
-- Signature is UNCHANGED (adding/removing a param would create an overload and break the live
-- app's call shape with 42725). p_pieces / p_weight / p_thickness are still ACCEPTED and now all
-- three are IGNORED: pieces and weight are per-BRAND box facts and this entry point carries a
-- single value for the whole product — applying it would flatten every brand's packing to one
-- number. library_set_box is the only writer of a box's packing; thickness is derived.
create or replace function public.library_upsert_master(p_id uuid, p_size text, p_master_name text, p_image_url text, p_aliases jsonb, p_brand_id uuid DEFAULT NULL::uuid, p_surface text DEFAULT NULL::text, p_stock_type text DEFAULT NULL::text, p_tile_type text DEFAULT NULL::text, p_pieces integer DEFAULT NULL::integer, p_weight numeric DEFAULT NULL::numeric, p_thickness numeric DEFAULT NULL::numeric, p_colour text DEFAULT NULL::text, p_finish text DEFAULT NULL::text)
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
    colour         = case when p_colour     is null then m.colour         else coalesce(btrim(p_colour),'') end,
    finish_label   = case when p_finish     is null then m.finish_label   else nullif(btrim(p_finish),'') end,
    updated_at = now()
  where m.id = v_id;

  -- The brand-name rows ARE THE BOXES. They carry pieces_per_box and box_weight_kg, so they are
  -- SYNCED in place — deleting and re-inserting them would throw away the packing of every brand.
  -- p_aliases null = "don't touch the names"; an explicit list is the whole truth of which brands
  -- name this product.
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

    -- A brand that no longer names this product no longer boxes it.
    delete from stockist_library_brand_names a
     where a.library_id = v_id
       and not exists (
         select 1 from jsonb_array_elements(p_aliases) e
          where nullif(e->>'brand_id','')::uuid = a.brand_id
            and btrim(coalesce(e->>'name','')) <> '');
  end if;

  return v_id;
end; $function$;
