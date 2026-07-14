-- ═══ THE IMAGE DNA BELONGS TO THE PRINT ═══════════════════════════════════════════════════════
--
-- His words: "we have image dna from this Look_type>natural_name, design_joint, Print_type, colour
-- this will come under print and when we save data it must save under this only."
--
--   Look Type ▸ Natural Name · Design Joint · Print Type · Colour
--
-- These describe the ARTWORK, so they belong to the artwork — not to a piece cut from it. Tag the
-- print `1001` once and ALL THREE of its pieces (Matt, Carving, GHR) carry it. There is no way for
-- the Matt to be "white marble, bookmatch" while the Carving is something else: same image, same
-- DNA. It also means a fork (a second thickness of one print) inherits the DNA for free — it shares
-- the print.
--
-- The other attributes are untouched and stay on the PIECE. This migration says nothing about them.
--
-- 🔑 A DNA attribute now declares WHERE it is stored (`dna_attributes.scope`), and every writer
-- routes on that one column. The rule cannot be bypassed by a caller that forgets it.
--
-- Done now because the DB is EMPTY (the 14 Jul clean slate) — no data to migrate, no risk.

-- ── 1. An attribute declares its home ───────────────────────────────────────────────────────
alter table dna_attributes
  add column if not exists scope text not null default 'product'
    check (scope in ('print', 'product'));

comment on column dna_attributes.scope is
  'print = describes the ARTWORK, stored in print_dna, shared by every product of that print. '
  'product = describes the PIECE, stored in library_dna.';

update dna_attributes
   set scope = 'print'
 where name in ('Look Type', 'Natural Name', 'Design Joint', 'Print Type', 'Colour');

-- ── 2. One place that answers "what DNA does this piece carry?" ─────────────────────────────
-- Its own (product-scoped) + its print's (print-scoped). Every reader goes through this, so a
-- print-scoped tag can never be invisible to one screen and visible to another.
create or replace function public._dna_of_library(p_library uuid)
returns table (value_id uuid)
language sql
stable
set search_path to 'public', 'pg_temp'
as $function$
  select ld.value_id from library_dna ld where ld.library_id = p_library
  union
  select pd.value_id
    from print_dna pd
    join stockist_library l on l.print_id = pd.print_id
   where l.id = p_library;
$function$;

revoke all on function public._dna_of_library(uuid) from public;
grant execute on function public._dna_of_library(uuid) to authenticated, anon;

-- ── 3. THE WRITER routes on scope ───────────────────────────────────────────────────────────
create or replace function public.dna_set_design(
  p_library_id uuid, p_attribute_id uuid, p_value_ids uuid[]
) returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_parent_attr uuid; v_scope text; v_print uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;

  select print_id into v_print from stockist_library
   where id = p_library_id and stockist_id = v_stk;
  if v_print is null then raise exception 'Not your design'; end if;

  select scope, parent_attribute_id into v_scope, v_parent_attr
    from dna_attributes where id = p_attribute_id;

  -- A child value may only be tagged once its PARENT value is. Look at the table the parent
  -- actually lives in: a parent and its child always share a scope (Natural Name sits under Look
  -- Type, both on the print; Punch Type under Punch, both on the piece).
  if v_parent_attr is not null then
    if exists (
      select 1 from dna_values v
       where v.id = any(coalesce(p_value_ids, array[]::uuid[]))
         and v.attribute_id = p_attribute_id
         and v.parent_value_id is not null
         and not exists (
           select 1 from _dna_of_library(p_library_id) x
            where x.value_id = v.parent_value_id)
    ) then
      raise exception 'Pick the parent value first';
    end if;
  end if;

  if v_scope = 'print' then
    -- 🖼️ THE ARTWORK'S OWN. Written against the PRINT, so every piece of it changes at once.
    delete from print_dna pd using dna_values v
      where pd.value_id = v.id and pd.print_id = v_print
        and v.attribute_id = p_attribute_id;
    insert into print_dna(print_id, value_id)
      select v_print, v.id from dna_values v
       where v.id = any(coalesce(p_value_ids, array[]::uuid[]))
         and v.attribute_id = p_attribute_id
      on conflict do nothing;

    -- Drop any print-scoped child whose parent chain just broke.
    with recursive orphan as (
      select cv.id
        from print_dna pd
        join dna_values cv on cv.id = pd.value_id
        join dna_attributes ca on ca.id = cv.attribute_id
       where pd.print_id = v_print
         and ca.parent_attribute_id = p_attribute_id
         and cv.parent_value_id is not null
         and not exists (
           select 1 from print_dna p
            where p.print_id = v_print and p.value_id = cv.parent_value_id)
      union
      select gv.id
        from orphan o
        join dna_values gv on gv.parent_value_id = o.id
        join print_dna pd on pd.print_id = v_print and pd.value_id = gv.id
    )
    delete from print_dna where print_id = v_print and value_id in (select id from orphan);

  else
    -- 🧱 THE PIECE'S OWN. Unchanged.
    delete from library_dna ld using dna_values v
      where ld.value_id = v.id and ld.library_id = p_library_id
        and v.attribute_id = p_attribute_id;
    insert into library_dna(library_id, value_id)
      select p_library_id, v.id from dna_values v
       where v.id = any(coalesce(p_value_ids, array[]::uuid[]))
         and v.attribute_id = p_attribute_id
      on conflict do nothing;

    with recursive orphan as (
      select cv.id
        from library_dna ld
        join dna_values cv on cv.id = ld.value_id
        join dna_attributes ca on ca.id = cv.attribute_id
       where ld.library_id = p_library_id
         and ca.parent_attribute_id = p_attribute_id
         and cv.parent_value_id is not null
         and not exists (
           select 1 from library_dna p
            where p.library_id = p_library_id and p.value_id = cv.parent_value_id)
      union
      select gv.id
        from orphan o
        join dna_values gv on gv.parent_value_id = o.id
        join library_dna ld on ld.library_id = p_library_id and ld.value_id = gv.id
    )
    delete from library_dna where library_id = p_library_id and value_id in (select id from orphan);
  end if;
end; $function$;

-- ── 4. THE READERS see the piece's DNA *and* its print's ────────────────────────────────────
create or replace function public._dna_colour(p_library uuid)
returns text
language sql
stable
set search_path to 'public', 'pg_temp'
as $function$
  select string_agg(v.name, ', ' order by v.name)
    from _dna_of_library(p_library) x
    join dna_values     v on v.id = x.value_id
    join dna_attributes a on a.id = v.attribute_id
   where a.name = 'Colour' and v.is_active and lower(v.name) <> 'none';
$function$;

create or replace function public.dna_for_design(p_library_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_object_agg(attr_id::text, vals), '{}'::jsonb) from (
    select v.attribute_id as attr_id,
           jsonb_agg(jsonb_build_object(
             'id', v.id, 'name', v.name, 'parent_value_id', v.parent_value_id)) as vals
      from _dna_of_library(p_library_id) x
      join dna_values v on v.id = x.value_id
     group by v.attribute_id
  ) s;
$function$;

create or replace function public.design_dna_tags(p_design_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(
           jsonb_build_object('attribute', attribute, 'label', label,
             'value_id', vid, 'parent_value_id', pvid,
             'attr_sort', attr_sort, 'val_sort', val_sort)
           order by attr_sort, val_sort), '[]'::jsonb)
  from (
    select distinct
           da.name as attribute, da.sort_order as attr_sort,
           dv.sort_order as val_sort, dv.id as vid, dv.parent_value_id as pvid,
           coalesce(
             (select al.raw_text from dna_aliases al
               where al.stockist_id = d.stockist_id and al.value_id = dv.id
               order by lower(al.raw_text) limit 1),
             dv.name) as label
      from designs d
      join _dna_of_library(d.library_id) x on true
      join dna_values dv on dv.id = x.value_id and dv.is_active
      join dna_attributes da on da.id = dv.attribute_id and da.is_active
     where d.id = p_design_id and lower(dv.name) <> 'none'
  ) s;
$function$;

create or replace function public.designs_dna_values(p_design_ids uuid[])
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_object_agg(did::text, vids), '{}'::jsonb)
  from (
    select d.id as did, jsonb_agg(distinct x.value_id::text) as vids
      from designs d
      join _dna_of_library(d.library_id) x on true
      join dna_values dv on dv.id = x.value_id and dv.is_active
                        and lower(dv.name) <> 'none'
     where d.id = any(p_design_ids)
     group by d.id
  ) s;
$function$;

create or replace function public.dna_my_library_tags()
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  with me as (select id from stockists where user_id = auth.uid())
  select coalesce(jsonb_object_agg(lib_id::text, tags), '{}'::jsonb)
  from (
    select lib.id as lib_id,
           jsonb_agg(jsonb_build_object(
             'value_id', dv.id,
             'parent_value_id', dv.parent_value_id,
             'attribute', da.name,
             'attr_sort', da.sort_order,
             'val_sort', dv.sort_order,
             'label', coalesce(
               (select al.raw_text from dna_aliases al
                 where al.stockist_id = (select id from me) and al.value_id = dv.id
                 order by lower(al.raw_text) limit 1),
               dv.name))
             order by da.sort_order, dv.sort_order) as tags
      from stockist_library lib
      join _dna_of_library(lib.id) x on true
      join dna_values dv on dv.id = x.value_id and dv.is_active
      join dna_attributes da on da.id = dv.attribute_id and da.is_active
     where lib.stockist_id = (select id from me) and lower(dv.name) <> 'none'
     group by lib.id
  ) s;
$function$;

-- ── 5. THE IMPORTER routes on scope too ─────────────────────────────────────────────────────
-- One helper, so the import cannot forget the rule. Returns true when it tagged something.
create or replace function public._dna_tag_import(
  p_library uuid, p_attr uuid, p_vals uuid[], p_multi boolean
) returns boolean
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_scope text; v_print uuid; v_already boolean;
begin
  if p_library is null or p_attr is null or coalesce(cardinality(p_vals),0) = 0 then
    return false;
  end if;

  select scope into v_scope from dna_attributes where id = p_attr;

  if v_scope = 'print' then
    select print_id into v_print from stockist_library where id = p_library;
    if v_print is null then return false; end if;

    if p_multi then
      insert into print_dna(print_id, value_id)
        select v_print, x from unnest(p_vals) x on conflict do nothing;
      return true;
    end if;

    -- Single-value: FIRST WRITER WINS. An import must never overwrite what is already declared.
    select exists (
      select 1 from print_dna pd join dna_values dv on dv.id = pd.value_id
       where pd.print_id = v_print and dv.attribute_id = p_attr) into v_already;
    if v_already then return false; end if;

    insert into print_dna(print_id, value_id) values (v_print, p_vals[1]) on conflict do nothing;
    return true;
  end if;

  -- product-scoped: unchanged behaviour
  if p_multi then
    insert into library_dna(library_id, value_id)
      select p_library, x from unnest(p_vals) x on conflict do nothing;
    return true;
  end if;

  select exists (
    select 1 from library_dna ld join dna_values dv on dv.id = ld.value_id
     where ld.library_id = p_library and dv.attribute_id = p_attr) into v_already;
  if v_already then return false; end if;

  insert into library_dna(library_id, value_id) values (p_library, p_vals[1]) on conflict do nothing;
  return true;
end $function$;

revoke all on function public._dna_tag_import(uuid, uuid, uuid[], boolean) from public, anon;
grant execute on function public._dna_tag_import(uuid, uuid, uuid[], boolean) to authenticated;

-- ── 6. import_stock_batch: its DNA block routes through _dna_tag_import ─────────────────────
CREATE OR REPLACE FUNCTION public.import_stock_batch(p_batch_id uuid, p_catalog_id uuid, p_brand_id uuid, p_pdf_filename text, p_rows jsonb, p_mode text DEFAULT 'add'::text, p_wipe_all_brands boolean DEFAULT false, p_wipe_brand_ids uuid[] DEFAULT NULL::uuid[], p_library_only boolean DEFAULT false, p_match_only boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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

            -- WHERE a tag lands is the ATTRIBUTE's business, not the importer's: the image DNA
            -- (Look Type > Natural Name, Design Joint, Print Type, Colour) goes on the PRINT and is
            -- shared by every piece of it; the rest stays on the piece. (dna_attributes.scope)
            if _dna_tag_import(v_master, v_attr_id, v_vals, coalesce(v_is_multi, false)) then
              v_dna_tagged := v_dna_tagged + 1;
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
end $function$
;

-- ── 7. public_catalog: the buyer sees the print DNA too ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.public_catalog(p_token text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  select coalesce(
    (select jsonb_build_object(
       'stockist', jsonb_build_object(
          'name', s.name, 'id',   s.sequential_id,
          'phone', s.phone, 'country_code', s.country_code, 'city', s.city,
          'logo_url', s.logo_url, 'banner_url', s.banner_url,
          'address', s.address, 'map_url', s.map_url,
          'tagline', s.tagline, 'brand_color', s.brand_color),
       'brand', (select case when not b.is_default
                   then jsonb_build_object('name', b.name, 'logo_url', nullif(b.logo_url, ''))
                   else null end from brands b where b.id = c.brand_id),
       'banner', case
         when nullif(btrim(coalesce(c.banner_source,'')),'') is not null then
           jsonb_build_object(
             'source', case when c.banner_source = 'pool' then 'pool' else c.banner_source end,
             'bg_url',  case when c.banner_source = 'pool' then pick_generic_banner(s.id::text) else c.banner_bg_url end,
             'image_url', case when c.banner_source = 'pool' then pick_generic_banner(s.id::text) else c.banner_bg_url end,
             'overlay', case when c.banner_source = 'pool' then true else false end,
             'company_logo_url', c.company_logo_url,
             'company_pos', coalesce(c.company_pos,'none'),
             'td_pos', case when coalesce(nullif(btrim(c.td_pos),''),'none') = 'none' then 'top-right' else c.td_pos end,
             'td_show', s.td_show,
             'banner_heading', c.banner_heading,
             'banner_text', c.banner_text, 'banner_heading_size', c.banner_heading_size, 'banner_heading_color', c.banner_heading_color, 'banner_msg_size', c.banner_msg_size, 'banner_msg_color', c.banner_msg_color, 'banner_text_align', c.banner_text_align, 'banner_text_valign', c.banner_text_valign,
             'name', coalesce((select nullif(b.name,'') from brands b where b.id = c.brand_id), s.name))
         when nullif(btrim(coalesce(c.banner_url,'')),'') is not null
         then jsonb_build_object('source','custom','bg_url',c.banner_url,'image_url',c.banner_url,'overlay',false,'company_logo_url',null,'company_pos','none','td_pos', case when coalesce(nullif(btrim(c.td_pos),''),'none') = 'none' then 'top-right' else c.td_pos end,'td_show', s.td_show,'banner_heading', c.banner_heading,'banner_text', c.banner_text,'name',c.name)
         else jsonb_build_object('source','pool','bg_url',pick_generic_banner(s.id::text),'image_url',pick_generic_banner(s.id::text),'overlay',true,'company_logo_url',null,'company_pos','none','td_pos', case when coalesce(nullif(btrim(c.td_pos),''),'none') = 'none' then 'top-right' else c.td_pos end,'td_show', s.td_show,'banner_heading', c.banner_heading,'banner_text', c.banner_text,'name', s.name) end,
       'catalog', jsonb_build_object('name', c.name, 'visibility', c.visibility),
       'dna_facets', public_dna_facets(c.stockist_id),
       'designs', coalesce((
         select jsonb_agg(jsonb_build_object(
           'id', d.id,
           'library_id', d.library_id,
           'family_key', _family_effective_key(d.library_id),
           'name', coalesce(
             (select bn.brand_design_name from stockist_library_brand_names bn
              where bn.library_id = d.library_id
                and bn.brand_id = coalesce(d.brand_id, c.brand_id)),
             pm.print_name, d.name),
           'size', d.size, 'surface', d.surface_type, 'surface_label', d.surface_label,
           'quality', d.quality, 'colour', _dna_colour(lib.id), 'tile_type', lib.tile_type,
           'boxes', greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)),
           'images', case when nullif(btrim(coalesce(pm.image_url,'')),'') is not null then array[pm.image_url] else '{}'::text[] end,
           'finish', lib.finish_label, 'weight', _box_weight(d.library_id, d.brand_id),
           'pieces', _box_pieces(d.library_id, d.brand_id), 'stock_type', effective_stock_type(lib.stock_type, d.quality),
           'dna', coalesce((select jsonb_agg(distinct ld.value_id)
                            from _dna_of_library(d.library_id) ld
                            join dna_values dv on dv.id = ld.value_id and dv.is_active and lower(dv.name) <> 'none'
                           ), '[]'::jsonb))
           order by d.created_at desc)
         from designs d
         join stockist_library lib on lib.id = d.library_id
         join print_master pm on pm.id = lib.print_id
         where d.stockist_id = c.stockist_id
           and (d.box_quantity - d.control_quantity - held_of(d.id)) > 0
           and d.status <> 'out_of_stock'
           and case
             when coalesce(c.list_type,'permanent') = 'permanent' then
               (array_length(c.filter_brand_ids,1) is null or d.brand_id = any(c.filter_brand_ids))
               and (array_length(c.filter_qualities,1) is null or d.quality = any(c.filter_qualities))
               and (array_length(c.filter_surfaces,1) is null or d.surface_type = any(c.filter_surfaces) or d.surface_label = any(c.filter_surfaces))
               and (array_length(c.filter_sizes,1) is null or d.size = any(c.filter_sizes))
               and (array_length(c.filter_tile_types,1) is null or lib.tile_type = any(c.filter_tile_types))
               and (array_length(c.filter_stock_types,1) is null or effective_stock_type(lib.stock_type, d.quality) = any(c.filter_stock_types))
               and (c.filter_box_min is null or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) >= c.filter_box_min)
               and (c.filter_box_max is null or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) <= c.filter_box_max)
             else
               exists (select 1 from catalog_designs cd
                       where cd.catalog_id = c.id and cd.library_id = d.library_id)
           end), '[]'::jsonb))
     from stock_catalogs c join stockists s on s.id = c.stockist_id
     where (c.share_token = p_token
            or exists (select 1 from stockist_share_links l
                       where l.catalog_id = c.id and l.token = p_token and l.is_active
                         and (l.expires_at is null or l.expires_at > now())))
       and c.is_active and s.is_active),

    (select jsonb_build_object(
       'stockist', jsonb_build_object(
          'name', s.name, 'id', s.sequential_id,
          'phone', s.phone, 'country_code', s.country_code, 'city', s.city,
          'logo_url', s.logo_url, 'banner_url', s.banner_url,
          'address', s.address, 'map_url', s.map_url,
          'tagline', s.tagline, 'brand_color', s.brand_color),
       'banner', jsonb_build_object(
          'source','pool','bg_url',pick_generic_banner(s.id::text),
          'image_url', pick_generic_banner(s.id::text), 'overlay', true,
          'company_logo_url', null, 'company_pos','none','td_pos','top-right','td_show', s.td_show,
          'banner_heading', null, 'banner_text', null, 'name', s.name),
       'dna_facets', public_dna_facets(s.id),
       'designs', coalesce((
         select jsonb_agg(jsonb_build_object(
           'id', d.id,
           'library_id', d.library_id,
           'family_key', _family_effective_key(d.library_id),
           'name', coalesce(pm.print_name, d.name), 'size', d.size,
           'surface', d.surface_type, 'surface_label', d.surface_label, 'quality', d.quality,
           'colour', _dna_colour(lib.id),
           'tile_type', lib.tile_type, 'boxes', greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)),
           'images', case when nullif(btrim(coalesce(pm.image_url,'')),'') is not null then array[pm.image_url] else '{}'::text[] end,
           'finish', lib.finish_label, 'weight', _box_weight(d.library_id, d.brand_id),
           'pieces', _box_pieces(d.library_id, d.brand_id), 'stock_type', effective_stock_type(lib.stock_type, d.quality),
           'dna', coalesce((select jsonb_agg(distinct ld.value_id)
                            from _dna_of_library(d.library_id) ld
                            join dna_values dv on dv.id = ld.value_id and dv.is_active and lower(dv.name) <> 'none'
                           ), '[]'::jsonb))
           order by d.created_at desc)
         from designs d
         join stockist_library lib on lib.id = d.library_id
         join print_master pm on pm.id = lib.print_id
         where d.stockist_id = s.id
           and (d.box_quantity - d.control_quantity - held_of(d.id)) > 0
           and d.status <> 'out_of_stock'
           and (
             exists (select 1 from catalog_designs cd
                    join stock_catalogs c2 on c2.id = cd.catalog_id
                    where cd.library_id = d.library_id and c2.stockist_id = s.id
                      and coalesce(c2.visibility,'public') = 'public' and c2.is_active
                      and coalesce(c2.list_type,'permanent') = 'temporary')
             or
             exists (select 1 from stock_catalogs c2
                    where c2.stockist_id = s.id and c2.is_active
                      and coalesce(c2.visibility,'public') = 'public'
                      and coalesce(c2.list_type,'permanent') = 'permanent'
                      and (array_length(c2.filter_brand_ids,1) is null or d.brand_id = any(c2.filter_brand_ids))
                      and (array_length(c2.filter_qualities,1) is null or d.quality = any(c2.filter_qualities))
                      and (array_length(c2.filter_surfaces,1) is null or d.surface_type = any(c2.filter_surfaces) or d.surface_label = any(c2.filter_surfaces))
                      and (array_length(c2.filter_sizes,1) is null or d.size = any(c2.filter_sizes))
                      and (array_length(c2.filter_tile_types,1) is null or lib.tile_type = any(c2.filter_tile_types))
                      and (array_length(c2.filter_stock_types,1) is null or effective_stock_type(lib.stock_type, d.quality) = any(c2.filter_stock_types))
                      and (c2.filter_box_min is null or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) >= c2.filter_box_min)
                      and (c2.filter_box_max is null or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) <= c2.filter_box_max))
           )), '[]'::jsonb))
     from stockists s
     where s.is_active = true
       and (s.share_token = p_token
            or exists (select 1 from stockist_share_links l
                       where l.stockist_id = s.id and l.token = p_token and l.is_active
                         and (l.expires_at is null or l.expires_at > now())))));
$function$
;

-- ── 8. The catalogue tells the app WHERE each attribute lives ───────────────────────────────
-- The Library card groups by PRINT, so print-scoped DNA must render ONCE under the print header —
-- not repeated identically beneath each of its pieces. The app can only do that if it knows the
-- scope, so hand it over with the attribute.
create or replace function public.dna_catalog()
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  with me as (select id from stockists where user_id = auth.uid())
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', a.id, 'name', a.name, 'is_multi', a.is_multi,
      'is_free_text', a.is_free_text, 'sort_order', a.sort_order,
      'show_in_facets', a.show_in_facets, 'allow_mapping', a.allow_mapping,
      'parent_attribute_id', a.parent_attribute_id, 'free_text_detail', a.free_text_detail,
      'scope', a.scope,
      'values', coalesce((
        select jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name, 'parent_value_id', v.parent_value_id)
                         order by v.sort_order, lower(v.name))
        from dna_values v
        where v.attribute_id = a.id and v.is_active
          and (v.stockist_id is null or v.stockist_id = (select id from me))), '[]'::jsonb)
    ) order by a.sort_order
  ), '[]'::jsonb)
  from dna_attributes a where a.is_active;
$function$;

-- The Library card's tag feed carries the scope too, so it can split print tags from piece tags.
create or replace function public.dna_my_library_tags()
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  with me as (select id from stockists where user_id = auth.uid())
  select coalesce(jsonb_object_agg(lib_id::text, tags), '{}'::jsonb)
  from (
    select lib.id as lib_id,
           jsonb_agg(jsonb_build_object(
             'value_id', dv.id,
             'parent_value_id', dv.parent_value_id,
             'attribute', da.name,
             'scope', da.scope,
             'attr_sort', da.sort_order,
             'val_sort', dv.sort_order,
             'label', coalesce(
               (select al.raw_text from dna_aliases al
                 where al.stockist_id = (select id from me) and al.value_id = dv.id
                 order by lower(al.raw_text) limit 1),
               dv.name))
             order by da.sort_order, dv.sort_order) as tags
      from stockist_library lib
      join _dna_of_library(lib.id) x on true
      join dna_values dv on dv.id = x.value_id and dv.is_active
      join dna_attributes da on da.id = dv.attribute_id and da.is_active
     where lib.stockist_id = (select id from me) and lower(dv.name) <> 'none'
     group by lib.id
  ) s;
$function$;
