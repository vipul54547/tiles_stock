-- Add Stock wedged with: duplicate key value violates "designs_holding_uniq".
--
-- The unique index is (stockist_id, library_id, brand_id, quality, surface_type)
-- -- surface_label is NOT in it. But the holding lookup in stock_add_holding (the
-- 7-arg overload add_inventory_batch calls) and in import_stock_batch also matched
-- on `surface_label is not distinct from v_label`. So when a print/brand/quality
-- already held a surface with one spelling of the word (e.g. 'Matt', from an Excel
-- import) and the stockist re-added it through the picker with a different spelling
-- of the SAME canonical (e.g. 'MATT', the learned-alias display word), the lookup
-- MISSED the existing row, then the insert collided with the unique index. The
-- holding became both un-updatable and un-insertable.
--
-- Option A: surface_label is a display attribute (the stockist's WORD for a
-- canonical surface), NOT holding identity. A canonical surface = one physical
-- surface = one stock line. Key the lookup on surface_type only, matching the
-- index; refresh the stored word to the latest pick on a match. (per-brand surface)
--
-- No data repair: existing holdings have distinct surface_types, so none violate.

-- ── 1) stock_add_holding (7-arg, the surface_label overload) ──────────────────
CREATE OR REPLACE FUNCTION public.stock_add_holding(p_library_id uuid, p_quality text, p_qty integer, p_catalog_id uuid, p_surface text DEFAULT 'None'::text, p_brand_id uuid DEFAULT NULL::uuid, p_surface_label text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_stk uuid; v_design uuid; v_q text; v_surf text; v_label text;
        v_name text; v_size text; v_brand uuid; v_master_brand uuid;
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
  v_brand := coalesce(p_brand_id, v_master_brand);
  v_q    := coalesce(nullif(btrim(p_quality),''),'Standard');
  v_surf := coalesce(nullif(btrim(p_surface),''),'None');
  v_label := nullif(btrim(p_surface_label),'');

  -- Identity = (stockist, library, brand, quality, surface_type) = designs_holding_uniq.
  -- surface_label (the word) is display-only; DON'T key on it (that wedged inserts).
  select id into v_design from designs
    where stockist_id = v_stk and library_id = p_library_id
      and brand_id is not distinct from v_brand
      and quality = v_q and surface_type = v_surf;
  if v_design is null then
    insert into designs (stockist_id, name, size, quality, surface_type, surface_label,
                         box_quantity, status, library_id, brand_id)
      values (v_stk, v_name, v_size, v_q, v_surf, v_label, 0, 'active', p_library_id, v_brand)
      returning id into v_design;
  elsif v_label is not null then
    -- Existing line for this canonical surface: refresh the stockist's word to
    -- their latest pick (surface_type is unchanged, so identity is stable).
    update designs set surface_label = v_label where id = v_design;
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

-- ── 2) import_stock_batch (9-arg) ─────────────────────────────────────────────
-- Same lookup fix; refresh surface_label on a matched holding.
CREATE OR REPLACE FUNCTION public.import_stock_batch(p_batch_id uuid, p_catalog_id uuid, p_brand_id uuid, p_pdf_filename text, p_rows jsonb, p_mode text DEFAULT 'add'::text, p_wipe_all_brands boolean DEFAULT false, p_wipe_brand_ids uuid[] DEFAULT NULL::uuid[], p_library_only boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_stk uuid;
  v_prior jsonb;
  r jsonb;
  v_brand_name text;
  v_name text; v_size text; v_quality text; v_surface text; v_label text;
  v_qty int; v_image text;
  v_master_name text; v_aliases jsonb;
  v_skip_master boolean;
  v_master uuid; v_design uuid;
  v_hold_brand uuid; v_row_brand uuid;
  v_attr_key text; v_attr_vals jsonb; v_attr_id uuid; v_raw text;
  v_val uuid; v_vals uuid[];
  v_is_multi boolean;
  v_mode text := lower(coalesce(nullif(btrim(p_mode),''),'add'));
  v_replace boolean;
  v_old int; v_delta int; v_seen boolean;
  v_touched uuid[] := array[]::uuid[];
  v_zeroed int := 0;
  v_masters int := 0; v_created int := 0; v_updated int := 0;
  v_stock_rows int := 0; v_skipped int := 0; v_dna_tagged int := 0;
begin
  if v_mode not in ('add','replace_all','replace_keep') then v_mode := 'add'; end if;
  v_replace := v_mode in ('replace_all','replace_keep');

  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can import stock'; end if;

  select summary into v_prior from import_batches where id = p_batch_id;
  if v_prior is not null then
    return v_prior || jsonb_build_object('already_applied', true);
  end if;

  if p_catalog_id is not null and not exists (
       select 1 from stock_catalogs where id = p_catalog_id and stockist_id = v_stk) then
    raise exception 'Stock list does not belong to you';
  end if;

  if p_brand_id is not null then
    select name into v_brand_name from brands where id = p_brand_id and stockist_id = v_stk;
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    v_name := btrim(coalesce(r->>'name',''));
    v_size := btrim(coalesce(r->>'size',''));
    if v_name = '' or v_size = '' then v_skipped := v_skipped + 1; continue; end if;

    v_quality := coalesce(nullif(btrim(coalesce(r->>'quality','')),''),'Standard');
    v_surface := coalesce(nullif(btrim(coalesce(r->>'surface','')),''),'None');
    v_label   := nullif(btrim(coalesce(r->>'surface_label','')),'');
    v_qty     := coalesce((r->>'qty')::int, 0);
    v_image   := nullif(btrim(coalesce(r->>'image_url','')),'');
    v_skip_master := coalesce((r->>'skip_master')::boolean, false);
    v_master_name := coalesce(nullif(btrim(coalesce(r->>'master_name','')),''), v_name);
    v_row_brand   := nullif(r->>'brand_id','')::uuid;

    if jsonb_typeof(r->'aliases') = 'array' and jsonb_array_length(r->'aliases') > 0 then
      v_aliases := r->'aliases';
    elsif p_brand_id is not null then
      v_aliases := jsonb_build_array(jsonb_build_object('brand_id', p_brand_id::text, 'name', v_name));
    else
      v_aliases := '[]'::jsonb;
    end if;

    v_master := library_map_upsert(v_size, v_master_name, v_aliases, v_surface);
    v_masters := v_masters + 1;

    if not v_skip_master then
      perform _library_apply_identity(v_master, jsonb_build_object(
        'stock_type', r->>'stock_type',
        'tile_type', r->>'tile_type', 'pieces_per_box', r->>'pieces_per_box',
        'box_weight_kg', r->>'box_weight_kg', 'thickness_mm', r->>'thickness_mm',
        'colour', r->>'colour', 'finish_label', r->>'finish_label'));

      if v_image is not null and v_master is not null then
        update stockist_library
           set image_url = v_image, updated_at = now()
         where id = v_master
           and coalesce(nullif(btrim(image_url),''),'') = '';
      end if;

      if v_master is not null and jsonb_typeof(r->'dna') = 'object' then
        for v_attr_key, v_attr_vals in select key, value from jsonb_each(r->'dna') loop
          begin v_attr_id := v_attr_key::uuid; exception when others then v_attr_id := null; end;
          if v_attr_id is null or jsonb_typeof(v_attr_vals) <> 'array' then continue; end if;
          v_vals := array[]::uuid[];
          for v_raw in select value from jsonb_array_elements_text(v_attr_vals) loop
            v_val := dna_resolve(v_attr_id, v_raw);
            if v_val is not null and not (v_val = any(v_vals)) then
              v_vals := array_append(v_vals, v_val);
            end if;
          end loop;
          if cardinality(v_vals) = 0 then continue; end if;

          select is_multi into v_is_multi from dna_attributes where id = v_attr_id;

          if coalesce(v_is_multi, false) then
            insert into library_dna(library_id, value_id)
              select v_master, x from unnest(v_vals) x on conflict do nothing;
            v_dna_tagged := v_dna_tagged + 1;
          else
            if not exists (
              select 1 from library_dna ld join dna_values dv on dv.id = ld.value_id
               where ld.library_id = v_master and dv.attribute_id = v_attr_id) then
              insert into library_dna(library_id, value_id)
                values (v_master, v_vals[1]) on conflict do nothing;
              v_dna_tagged := v_dna_tagged + 1;
            end if;
          end if;
        end loop;
      end if;
    end if;

    -- library_only (M PDF: build the picture library, no stock rows).
    if not coalesce(p_library_only, false) and v_qty > 0 and v_master is not null then
      v_hold_brand := coalesce(v_row_brand, nullif(v_aliases->0->>'brand_id','')::uuid,
                               p_brand_id,
                               (select brand_id from stockist_library where id = v_master));

      -- Identity = (stockist, library, brand, quality, surface_type). surface_label
      -- is display-only; keying on it collided with designs_holding_uniq.
      select id into v_design from designs
        where stockist_id = v_stk and library_id = v_master
          and brand_id is not distinct from v_hold_brand
          and quality = v_quality and surface_type = v_surface;

      if v_design is null then
        insert into designs (stockist_id, name, size, quality, surface_type, surface_label, box_quantity, status, library_id, brand_id)
          values (v_stk, v_name, v_size, v_quality, v_surface, v_label, 0, 'active', v_master, v_hold_brand)
          returning id into v_design;
        v_created := v_created + 1;
      else
        if v_label is not null then
          update designs set surface_label = v_label where id = v_design;
        end if;
        v_updated := v_updated + 1;
      end if;

      if p_catalog_id is not null then
        insert into catalog_designs (catalog_id, library_id)
          values (p_catalog_id, v_master) on conflict do nothing;
      end if;

      v_seen := v_design = any(v_touched);
      if v_replace then
        if v_seen then
          update designs set box_quantity = coalesce(box_quantity,0) + v_qty,
                 status = 'active', updated_at = now() where id = v_design;
          insert into stock_in (design_id, stockist_id, quantity_added, pdf_filename, size, quality, status)
            values (v_design, v_stk, v_qty, coalesce(p_pdf_filename,''), v_size, v_quality, 'approved');
        else
          select coalesce(box_quantity,0) into v_old from designs where id = v_design;
          update designs set box_quantity = v_qty, status = 'active', updated_at = now() where id = v_design;
          v_delta := v_qty - coalesce(v_old,0);
          if v_delta > 0 then
            insert into stock_in (design_id, stockist_id, quantity_added, pdf_filename, size, quality, status)
              values (v_design, v_stk, v_delta, coalesce(p_pdf_filename,''), v_size, v_quality, 'approved');
          end if;
        end if;
      else
        perform add_stock(v_design, v_stk, v_qty, coalesce(p_pdf_filename,''), v_size, v_quality);
      end if;

      if not v_seen then v_touched := array_append(v_touched, v_design); end if;
      v_stock_rows := v_stock_rows + 1;
    end if;
  end loop;

  if v_mode = 'replace_all'
     and (p_wipe_all_brands or p_wipe_brand_ids is not null or p_brand_id is not null) then
    with z as (
      update designs set box_quantity = 0, updated_at = now()
       where stockist_id = v_stk and box_quantity <> 0 and not (id = any(v_touched))
         and (
           p_wipe_all_brands
           or (not p_wipe_all_brands and p_wipe_brand_ids is not null
               and brand_id = any(p_wipe_brand_ids))
           or (not p_wipe_all_brands and p_wipe_brand_ids is null
               and brand_id is not distinct from p_brand_id)
         )
      returning 1)
    select count(*) into v_zeroed from z;
  end if;

  insert into import_batches (id, stockist_id, summary)
  values (p_batch_id, v_stk, jsonb_build_object(
    'masters', v_masters, 'created', v_created, 'updated', v_updated,
    'stock_rows', v_stock_rows, 'skipped', v_skipped, 'dna_tagged', v_dna_tagged,
    'zeroed', v_zeroed, 'mode', v_mode));

  return jsonb_build_object('masters', v_masters, 'created', v_created,
    'updated', v_updated, 'stock_rows', v_stock_rows, 'skipped', v_skipped,
    'dna_tagged', v_dna_tagged, 'zeroed', v_zeroed, 'mode', v_mode, 'already_applied', false);
end;
$function$;
