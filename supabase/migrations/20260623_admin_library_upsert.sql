-- Migration: admin_library_upsert
--
-- Admin-on-behalf library writer for the ADMIN bulk image-folder import. The
-- existing library_upsert_master / library_map_upsert resolve the stockist via
-- auth.uid() (the logged-in stockist), so an admin can't use them to seed a
-- stockist's library. This RPC takes the TARGET stockist (by sequential_id),
-- is admin-role-checked, and is create-OR-MATCH by (stockist, name, size, brand)
-- so re-running a folder import is idempotent (updates, never duplicates/errors).
--
-- Sets identity (surface/tile-type/pieces/weight/thickness) where provided, sets
-- the image only when a non-empty URL is given (a re-run without an image never
-- wipes an existing photo), and MERGES the per-brand alias (multi-brand safe —
-- it never deletes another brand's alias on the same master).
--
-- Bulk import only ever creates LIBRARY masters (identity + image); stock is a
-- separate, stockist-driven action.

create or replace function public.admin_library_upsert(
  p_seq text,
  p_size text,
  p_master_name text,
  p_brand_id uuid,
  p_image_url text default null,
  p_surface text default null,
  p_tile_type text default null,
  p_pieces integer default null,
  p_weight numeric default null,
  p_thickness numeric default null,
  p_aliases jsonb default null
) returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_id uuid;
        v_name text := btrim(coalesce(p_master_name,''));
        v_size text := btrim(coalesce(p_size,''));
        r jsonb; v_brand uuid; v_alias text;
begin
  if current_user_role() <> 'admin' then
    raise exception 'Only admins can bulk-import on behalf of a stockist';
  end if;
  select id into v_stk from stockists where sequential_id = p_seq;
  if v_stk is null then raise exception 'Stockist not found'; end if;
  if v_name = '' then raise exception 'Design name cannot be empty'; end if;
  if v_size = '' then raise exception 'Size is required'; end if;

  -- Create-or-match by (stockist, name, size, brand) → idempotent re-imports.
  select id into v_id from stockist_library
  where stockist_id = v_stk and lower(master_design_name) = lower(v_name)
    and size = v_size and brand_id is not distinct from p_brand_id
  limit 1;

  if v_id is null then
    insert into stockist_library (stockist_id, size, master_design_name, image_url, brand_id)
      values (v_stk, v_size, v_name,
              nullif(btrim(coalesce(p_image_url,'')),''), p_brand_id)
      returning id into v_id;
  else
    update stockist_library set
      image_url = coalesce(nullif(btrim(coalesce(p_image_url,'')),''), image_url),
      updated_at = now()
    where id = v_id;
  end if;

  -- Identity attributes (overwrite where provided; NULL = leave as-is).
  update stockist_library m set
    surface_type   = case when p_surface   is null then m.surface_type   else coalesce(nullif(btrim(p_surface),''),'None') end,
    tile_type      = case when p_tile_type is null then m.tile_type      else coalesce(btrim(p_tile_type),'') end,
    pieces_per_box = case when p_pieces    is null then m.pieces_per_box else coalesce(p_pieces,0) end,
    box_weight_kg  = case when p_weight    is null then m.box_weight_kg  else coalesce(p_weight,0) end,
    thickness_mm   = case when p_thickness is null then m.thickness_mm   else coalesce(p_thickness,0) end,
    updated_at = now()
  where m.id = v_id;

  -- Merge the per-brand alias(es) — never delete another brand's alias.
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
end; $function$;
