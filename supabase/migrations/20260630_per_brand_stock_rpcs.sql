-- Per-brand stock RPCs: stock_add_holding takes the brand; my_stock exposes the
-- holding's brand and only attaches a holding to brand-free or matching-brand lists.
-- (project_per_brand_stock)

DROP FUNCTION IF EXISTS public.stock_add_holding(uuid, text, integer, uuid);
DROP FUNCTION IF EXISTS public.stock_add_holding(uuid, text, integer, uuid, text);

CREATE OR REPLACE FUNCTION public.stock_add_holding(
  p_library_id uuid, p_quality text, p_qty integer, p_catalog_id uuid,
  p_surface text DEFAULT 'None'::text, p_brand_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_stk uuid; v_design uuid; v_q text; v_surf text; v_name text; v_size text;
        v_brand uuid; v_master_brand uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if p_library_id is null then raise exception 'Pick a design first'; end if;
  select master_design_name, size, brand_id into v_name, v_size, v_master_brand
    from stockist_library where id = p_library_id and stockist_id = v_stk;
  if v_name is null then raise exception 'Design is not in your library'; end if;
  if p_catalog_id is not null and not exists (
       select 1 from stock_catalogs where id = p_catalog_id and stockist_id = v_stk) then
    raise exception 'Stock list does not belong to you';
  end if;
  -- Brand the boxes belong to: caller's choice (M picks it), else the master's own
  -- brand (T/W, where the master already implies the brand).
  v_brand := coalesce(p_brand_id, v_master_brand);

  v_q := coalesce(nullif(btrim(p_quality),''),'Standard');
  v_surf := coalesce(nullif(btrim(p_surface),''),'None');
  select id into v_design from designs
    where stockist_id = v_stk and library_id = p_library_id
      and brand_id is not distinct from v_brand
      and quality = v_q and surface_type = v_surf;
  if v_design is null then
    insert into designs (stockist_id, name, size, quality, surface_type, box_quantity, status, library_id, brand_id)
      values (v_stk, v_name, v_size, v_q, v_surf, 0, 'active', p_library_id, v_brand)
      returning id into v_design;
  end if;

  if p_catalog_id is not null then
    insert into catalog_designs (catalog_id, library_id)
      values (p_catalog_id, p_library_id) on conflict do nothing;
  end if;

  if coalesce(p_qty,0) > 0 then
    perform add_stock(v_design, v_stk, p_qty, '', v_size, v_q);
  end if;
  return v_design;
end; $function$;

CREATE OR REPLACE FUNCTION public.my_stock()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', d.id, 'name', d.name, 'size', d.size, 'quality', d.quality,
    'box_quantity', d.box_quantity, 'status', d.status, 'is_sample', d.is_sample,
    'control_quantity', d.control_quantity,
    'held_quantity', held_of(d.id),
    'f_stock', greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)),
    'library_id', d.library_id, 'created_at', d.created_at, 'updated_at', d.updated_at,
    'surface_type', d.surface_type, 'stock_type', lib.stock_type,
    'tile_type', lib.tile_type, 'pieces_per_box', lib.pieces_per_box,
    'box_weight_kg', lib.box_weight_kg, 'thickness_mm', lib.thickness_mm,
    'colour', lib.colour, 'finish_label', lib.finish_label,
    'image_url', lib.image_url, 'master_design_name', lib.master_design_name,
    'brand_id', coalesce(d.brand_id, lib.brand_id),
    'stockist_key', s.sequential_id, 'stockist_priority', s.priority,
    'catalog_ids', coalesce((select jsonb_agg(cd.catalog_id)
                             from catalog_designs cd
                             join stock_catalogs c on c.id = cd.catalog_id
                             where cd.library_id = d.library_id and c.stockist_id = d.stockist_id
                               and (c.brand_id is null or c.brand_id is not distinct from coalesce(d.brand_id, lib.brand_id))),
                            '[]'::jsonb)
  ) order by d.created_at desc), '[]'::jsonb)
  from designs d
  join stockists s on s.id = d.stockist_id
  left join stockist_library lib on lib.id = d.library_id
  where d.stockist_id = (select id from stockists where user_id = auth.uid());
$function$;
