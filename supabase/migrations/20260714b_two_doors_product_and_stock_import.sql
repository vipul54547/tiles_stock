-- TWO DOORS: one import BUILDS PRODUCTS, one import ADDS STOCK. Neither does the other's job.
--
-- Until now `import_stock_batch` called `library_map_upsert` on EVERY row, so the stock importer
-- was also a product FACTORY: a name it had never seen minted a print + a product, with the surface
-- defaulted to 'Special' and the body left NULL and no box at all. That is where the 444 no-body /
-- no-box / 'Special' rows came from, and it is why NOT NULL can never be enforced.
--
-- After this migration:
--   • product door  → import_stock_batch(p_library_only => true)   -- creates products, no stock
--   • stock   door  → import_stock_batch(p_match_only  => true)    -- creates stock, NO products
--
-- In match-only mode a row that does not resolve to an existing product is NOT created: it is
-- counted and returned in `unmatched_rows` for the human to fix. The stockist imports his products
-- first, then his stock.

-- ── 1. library_map_resolve — the READ-ONLY twin of library_map_upsert ────────────────────────────
-- Same lookup order (alias first, then the print), but it CREATES NOTHING and returns NULL when the
-- product does not exist. It also returns NULL when the row is AMBIGUOUS (one print carried in two
-- surfaces, and the row named no surface) — a stock row must never guess which product it means.
create or replace function public.library_map_resolve(
  p_size       text,
  p_master_name text,
  p_aliases    jsonb,
  p_surface    text default null,
  p_tile_type  text default null
) returns uuid
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_id uuid; v_print uuid; v_n int;
        v_name text := btrim(coalesce(p_master_name,''));
        v_size text := btrim(coalesce(p_size,''));
        v_surf text := nullif(btrim(coalesce(p_surface,'')),'');
        v_tile text := nullif(btrim(coalesce(p_tile_type,'')),'');
        r jsonb; v_brand uuid; v_alias text; v_alias1 text; v_key text;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can read the library'; end if;
  if v_size = '' then return null; end if;

  if p_aliases is not null and jsonb_array_length(p_aliases) > 0 then
    v_alias1 := btrim(coalesce(p_aliases->0->>'name',''));
  end if;
  v_key := coalesce(nullif(v_name,''), v_alias1);
  if coalesce(btrim(v_key),'') = '' then return null; end if;

  -- (a) THE BOX'S WORD. A brand's stamped name finds the product it is stuck to, whatever the
  -- print is called. This is how a stock sheet full of box labels lands on the right product.
  if p_aliases is not null then
    for r in select * from jsonb_array_elements(p_aliases) loop
      exit when v_id is not null;
      v_brand := nullif(r->>'brand_id','')::uuid;
      v_alias := btrim(coalesce(r->>'name',''));
      if v_brand is not null and v_alias <> '' then
        select count(*), (array_agg(m.id order by m.created_at))[1] into v_n, v_id
          from stockist_library m
          join stockist_library_brand_names a on a.library_id = m.id
          join print_master p on p.id = m.print_id
         where m.stockist_id = v_stk and a.brand_id = v_brand
           and lower(a.brand_design_name) = lower(v_alias)
           and p.size = v_size
           and (v_surf is null or m.surface_type = v_surf)
           and (v_tile is null or m.tile_type is null or m.tile_type = v_tile);
        -- Two surfaces of one stamped name and no surface on the row: we do NOT pick one.
        if coalesce(v_n,0) <> 1 then v_id := null; end if;
      end if;
    end loop;
  end if;

  -- (b) THE PRINT'S OWN WORD. No create — a print that does not exist means no product exists.
  if v_id is null then
    select id into v_print from print_master
     where stockist_id = v_stk and lower(print_name) = lower(v_key) and size = v_size;
    if v_print is null then return null; end if;

    select count(*), (array_agg(m.id order by m.created_at))[1] into v_n, v_id
      from stockist_library m
     where m.stockist_id = v_stk and m.print_id = v_print
       and (v_surf is null or m.surface_type = v_surf)
       and (v_tile is null or m.tile_type is null or m.tile_type = v_tile);
    if coalesce(v_n,0) <> 1 then v_id := null; end if;
  end if;

  return v_id;
end $function$;

revoke all on function public.library_map_resolve(text, text, jsonb, text, text) from public, anon;
grant execute on function public.library_map_resolve(text, text, jsonb, text, text) to authenticated;

-- ── 2. import_stock_batch — gains p_match_only ───────────────────────────────────────────────────
-- Adding a parameter creates an OVERLOAD, and the old call shape then dies with 42725 (ambiguous).
-- Drop the previous signature in the SAME migration.
drop function if exists public.import_stock_batch(uuid, uuid, uuid, text, jsonb, text, boolean, uuid[], boolean);

create or replace function public.import_stock_batch(
  p_batch_id uuid, p_catalog_id uuid, p_brand_id uuid, p_pdf_filename text, p_rows jsonb,
  p_mode text default 'add',
  p_wipe_all_brands boolean default false,
  p_wipe_brand_ids uuid[] default null,
  p_library_only boolean default false,
  -- THE STOCK DOOR. Resolve every row against the existing Library; create no print, no product,
  -- no box, no DNA. A row that does not resolve comes back in `unmatched_rows`.
  p_match_only boolean default false
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_stk uuid; v_prior jsonb; r jsonb; v_brand_name text;
  v_name text; v_size text; v_quality text; v_surface text; v_label text;
  v_tile text; v_qty int; v_image text;
  v_master_name text; v_aliases jsonb; v_skip_master boolean;
  v_master uuid; v_design uuid; v_hold_brand uuid; v_row_brand uuid;
  v_attr_key text; v_attr_vals jsonb; v_attr_id uuid; v_raw text;
  v_val uuid; v_vals uuid[]; v_is_multi boolean;
  v_mode text := lower(coalesce(nullif(btrim(p_mode),''),'add'));
  v_replace boolean; v_old int; v_delta int; v_seen boolean;
  v_touched uuid[] := array[]::uuid[]; v_zeroed int := 0;
  v_masters int := 0; v_created int := 0; v_updated int := 0;
  v_stock_rows int := 0; v_skipped int := 0; v_dna_tagged int := 0;
  v_match boolean := coalesce(p_match_only, false);
  v_unmatched int := 0; v_unmatched_rows jsonb := '[]'::jsonb;
begin
  if v_mode not in ('add','replace_all','replace_keep') then v_mode := 'add'; end if;
  v_replace := v_mode in ('replace_all','replace_keep');

  if v_match and coalesce(p_library_only, false) then
    raise exception 'An import either builds products or adds stock — never both.';
  end if;

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
    -- Left NULL when the row says nothing. The product door defaults it to 'Special' below; the
    -- stock door must NOT — it inherits the surface from the product it resolves to.
    v_surface := nullif(btrim(coalesce(r->>'surface','')),'');
    v_label   := nullif(btrim(coalesce(r->>'surface_label','')),'');
    v_tile    := nullif(btrim(coalesce(r->>'tile_type','')),'');
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

    if v_match then
      -- ── THE STOCK DOOR ────────────────────────────────────────────────────────────────────────
      v_master := library_map_resolve(v_size, v_master_name, v_aliases, v_surface, v_tile);
      if v_master is null then
        v_unmatched := v_unmatched + 1;
        v_unmatched_rows := v_unmatched_rows || jsonb_build_object(
          'name', v_name, 'size', v_size, 'surface', v_surface, 'quality', v_quality);
        continue;
      end if;
      -- STOCK INHERITS THE PRODUCT'S SURFACE. The row's own word only chose WHICH product.
      select surface_type into v_surface from stockist_library where id = v_master;
    else
      -- ── THE PRODUCT DOOR ──────────────────────────────────────────────────────────────────────
      -- A machine that has no surface for a row writes 'Special' — never 'None', never a guess.
      v_surface := coalesce(v_surface, 'Special');
      v_master := library_map_upsert(v_size, v_master_name, v_aliases, v_surface, v_tile);
      v_masters := v_masters + 1;

      if not v_skip_master then
        perform _library_apply_identity(v_master, jsonb_build_object(
          'stock_type', r->>'stock_type',
          'tile_type', r->>'tile_type', 'pieces_per_box', r->>'pieces_per_box',
          'box_weight_kg', r->>'box_weight_kg', 'finish_label', r->>'finish_label'));

        -- the PHOTO belongs to the PRINT now. First-writer-wins, exactly as before.
        if v_image is not null and v_master is not null then
          update print_master p
             set image_url = v_image, updated_at = now()
            from stockist_library l
           where l.id = v_master and p.id = l.print_id
             and coalesce(nullif(btrim(p.image_url),''),'') = '';
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
    end if;

    if not coalesce(p_library_only, false) and v_qty > 0 and v_master is not null then
      v_hold_brand := coalesce(v_row_brand, nullif(v_aliases->0->>'brand_id','')::uuid,
                               p_brand_id,
                               (select brand_id from stockist_library where id = v_master));

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
    'zeroed', v_zeroed, 'mode', v_mode,
    'unmatched', v_unmatched, 'unmatched_rows', v_unmatched_rows));

  return jsonb_build_object('masters', v_masters, 'created', v_created,
    'updated', v_updated, 'stock_rows', v_stock_rows, 'skipped', v_skipped,
    'dna_tagged', v_dna_tagged, 'zeroed', v_zeroed, 'mode', v_mode,
    'unmatched', v_unmatched, 'unmatched_rows', v_unmatched_rows,
    'already_applied', false);
end $function$;

revoke all on function public.import_stock_batch(uuid, uuid, uuid, text, jsonb, text, boolean, uuid[], boolean, boolean) from public, anon;
grant execute on function public.import_stock_batch(uuid, uuid, uuid, text, jsonb, text, boolean, uuid[], boolean, boolean) to authenticated;
