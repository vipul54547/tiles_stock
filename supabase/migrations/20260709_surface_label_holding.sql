-- Holdings carry surface_label (stockist's word) + surface_type (canonical).
-- The key includes surface_label so two words of one finish stay separate rows.

CREATE OR REPLACE FUNCTION public.stock_add_holding(
    p_library_id uuid, p_quality text, p_qty integer, p_catalog_id uuid,
    p_surface text DEFAULT 'None'::text, p_brand_id uuid DEFAULT NULL::uuid,
    p_surface_label text DEFAULT NULL::text)
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

  select id into v_design from designs
    where stockist_id = v_stk and library_id = p_library_id
      and brand_id is not distinct from v_brand
      and quality = v_q and surface_type = v_surf
      and surface_label is not distinct from v_label;
  if v_design is null then
    insert into designs (stockist_id, name, size, quality, surface_type, surface_label,
                         box_quantity, status, library_id, brand_id)
      values (v_stk, v_name, v_size, v_q, v_surf, v_label, 0, 'active', p_library_id, v_brand)
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

-- add_inventory_batch: pass surface_label through; in_name remembers word+canonical
-- on the print (map once → auto-fill). Every holding carries the picked word.
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

  for e in select * from jsonb_array_elements(coalesce(p_entries, '[]'::jsonb)) loop
    v_q    := greatest(coalesce((e->>'quantity')::int, 0), 0);
    v_lib  := (e->>'library_id')::uuid;
    v_brand := nullif(btrim(coalesce(e->>'brand_id', '')), '')::uuid;
    v_surf := coalesce(nullif(btrim(e->>'surface'), ''), 'None');
    v_label := nullif(btrim(coalesce(e->>'surface_label','')), '');

    if v_biz = 'M' then
      select surface_mode into v_mode from stockists where id = v_stk;
    else
      select surface_mode into v_mode from brands
        where id = coalesce(v_brand, (select brand_id from stockist_library where id = v_lib));
    end if;
    v_mode := coalesce(v_mode, 'in_name');

    v_id := public.stock_add_holding(
      v_lib,
      coalesce(nullif(btrim(e->>'quality'), ''), 'Standard'),
      v_q, null, v_surf, v_brand, v_label);

    -- in_name: remember the word + canonical on the print for auto-fill.
    if v_mode <> 'attribute' and lower(v_surf) <> 'none' then
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
