-- Migration: import_stock_batch_dna_merge
-- Applied to Supabase project buxjebeeiwyrsakeucyk on 2026-06-22 (LIVE).
--
-- WHAT CHANGED: import_stock_batch DNA tagging went from OVERWRITE -> MERGE.
--   Old behaviour: for each DNA attribute in the row, DELETE all existing
--   library_dna values for that attribute on the design, then INSERT the new
--   ones (a re-import clobbered prior DNA).
--   New behaviour (never overwrite), keyed on dna_attributes.is_multi:
--     * multi-value chips (only Colour, is_multi=true) -> UNION: insert new
--       values, keep existing (on conflict do nothing vs library_dna_uq).
--     * single-value chips (the other 9) -> FILL-IF-EMPTY: insert v_vals[1]
--       only when the design has no value for that attribute yet; an existing
--       value is never replaced.
-- No schema change. Benefits both the PDF and Excel importers (same RPC).

CREATE OR REPLACE FUNCTION public.import_stock_batch(p_batch_id uuid, p_catalog_id uuid, p_brand_id uuid, p_pdf_filename text, p_rows jsonb, p_mode text DEFAULT 'add'::text)
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
  v_name text; v_size text; v_quality text; v_surface text;
  v_qty int; v_image text;
  v_master_name text; v_aliases jsonb;
  v_skip_master boolean;
  v_master uuid; v_design uuid;
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
    v_qty     := coalesce((r->>'qty')::int, 0);
    v_image   := nullif(btrim(coalesce(r->>'image_url','')),'');
    v_skip_master := coalesce((r->>'skip_master')::boolean, false);
    v_master_name := coalesce(nullif(btrim(coalesce(r->>'master_name','')),''), v_name);

    if jsonb_typeof(r->'aliases') = 'array' and jsonb_array_length(r->'aliases') > 0 then
      v_aliases := r->'aliases';
    elsif p_brand_id is not null then
      v_aliases := jsonb_build_array(jsonb_build_object('brand_id', p_brand_id::text, 'name', v_name));
    else
      v_aliases := '[]'::jsonb;
    end if;

    v_master := library_map_upsert(v_size, v_master_name, v_aliases);
    v_masters := v_masters + 1;

    if not v_skip_master then
      perform _library_apply_identity(v_master, jsonb_build_object(
        'stock_type', r->>'stock_type',
        'tile_type', r->>'tile_type', 'pieces_per_box', r->>'pieces_per_box',
        'box_weight_kg', r->>'box_weight_kg', 'thickness_mm', r->>'thickness_mm',
        'colour', r->>'colour', 'finish_label', r->>'finish_label'));

      if v_image is not null and p_brand_id is not null then
        perform library_contribute(p_brand_id, v_name, v_size, v_image);
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

          -- MERGE (never overwrite): multi-value chips UNION with existing;
          -- single-value chips fill only when the design has no value yet.
          select is_multi into v_is_multi from dna_attributes where id = v_attr_id;

          if coalesce(v_is_multi, false) then
            -- multi-value (e.g. Colour): add new values, keep existing ones
            insert into library_dna(library_id, value_id)
              select v_master, x from unnest(v_vals) x on conflict do nothing;
            v_dna_tagged := v_dna_tagged + 1;
          else
            -- single-value: fill-if-empty, never replace an existing value
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

    -- Stock holding — keyed by (library, quality, surface). Only when qty given.
    if v_qty > 0 and v_master is not null then
      select id into v_design from designs
        where stockist_id = v_stk and library_id = v_master and quality = v_quality and surface_type = v_surface;

      if v_design is null then
        insert into designs (stockist_id, name, size, quality, surface_type, box_quantity, status, library_id)
          values (v_stk, v_name, v_size, v_quality, v_surface, 0, 'active', v_master)
          returning id into v_design;
        v_created := v_created + 1;
      else
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

  if v_mode = 'replace_all' and p_catalog_id is not null then
    with z as (
      update designs set box_quantity = 0, updated_at = now()
       where stockist_id = v_stk and box_quantity <> 0 and not (id = any(v_touched))
         and library_id in (select library_id from catalog_designs where catalog_id = p_catalog_id)
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
