-- ═══ STEP 3 of docs/PACKING_BOX_HOLD_PLAN.md — A HOLD IS BOXES OF A BOX ═══════════════════════
--
--   ARTWORK → TILE → PACKING → BOX → **HOLD**
--
-- 🔢 A HOLD is "how many boxes you have". Until now it hung off the TILE + the BRAND, and that
-- cannot be counted:
--
--     TEN BOXES OF A 5-PIECE PACKING AND TEN BOXES OF A 4-PIECE PACKING
--     ARE NOT THE SAME AMOUNT OF TILE.
--
-- A box quantity means nothing without the packing inside it. So a hold must point at a BOX — a
-- packing in a brand's cover — and the box carries its packing.
--
--   designs.box_id  →  boxes  →  packings  →  stockist_library
--                          └──→  brands
--
-- 🔑 HOW THIS IS DONE SAFELY. 45 functions and 2 views read `designs.library_id` / `brand_id`.
-- Rewriting all of them at once is how you empty a Library (`1b47acd` did exactly that). So:
--
--     box_id becomes THE TRUTH.
--     library_id and brand_id stay as TRIGGER-MAINTAINED MIRRORS of it.
--
-- One writer, so they cannot drift — the same pattern `stockist_library.size` already uses for its
-- print. Every reader that only wants "which tile / which brand" keeps working untouched. Only the
-- handful that need the PACKING — the square-footage ones — are rewritten here, and they are the
-- ones that were WRONG.
--
-- ⚠️ NEVER WRITE library_id OR brand_id BY HAND AGAIN. They are a cache of box_id, not a source.
--
-- `designs` is EMPTY (14 Jul clean slate), so box_id can be NOT NULL from the first row. There is
-- no such thing as a hold with no box.

-- ── 1. The hold points at a box ─────────────────────────────────────────────────────────────
alter table public.designs
  add column if not exists box_id uuid references public.boxes(id) on delete restrict;

-- ── 2. library_id + brand_id become MIRRORS of the box ──────────────────────────────────────
create or replace function public._trg_holding_from_box()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_lib uuid; v_brand uuid;
begin
  if new.box_id is null then return new; end if;

  select p.library_id, b.brand_id
    into v_lib, v_brand
    from boxes b join packings p on p.id = b.packing_id
   where b.id = new.box_id;

  if v_lib is null then raise exception 'That box does not exist'; end if;

  -- The box IS the answer to "which tile, which brand". Anything the caller passed is overwritten:
  -- these two are a cache, not an opinion.
  new.library_id := v_lib;
  new.brand_id   := v_brand;
  return new;
end $function$;

drop trigger if exists aa_holding_from_box on public.designs;
create trigger aa_holding_from_box
  before insert or update of box_id on public.designs
  for each row execute function _trg_holding_from_box();

-- ── 3. THE HOLDING KEY IS THE BOX ───────────────────────────────────────────────────────────
-- Was (stockist, library, brand, quality, surface_type) — which merged two different packings of
-- one tile into a single row and made the box count meaningless.
drop index if exists public.designs_holding_uniq;
create unique index designs_holding_uniq
  on public.designs (stockist_id, box_id, quality);

create index if not exists idx_designs_box on public.designs (box_id);

-- ── 4. The packing OF A HOLD — this is what makes the square footage right ──────────────────
-- _box_pieces(library_id, brand_id) answers "a packing of this tile" — ANY of them, because it
-- cannot know which box you are holding. For a HOLD that is not good enough: it is the box you
-- have, and its packing, that says how much tile ten boxes is.
create or replace function public._box_pieces_of(p_box_id uuid)
returns integer
language sql
stable
set search_path to 'public', 'pg_temp'
as $function$
  select p.pieces from boxes b join packings p on p.id = b.packing_id where b.id = p_box_id;
$function$;

create or replace function public._box_weight_of(p_box_id uuid)
returns numeric
language sql
stable
set search_path to 'public', 'pg_temp'
as $function$
  select p.weight_kg from boxes b join packings p on p.id = b.packing_id where b.id = p_box_id;
$function$;

-- ── 5. Find (or make) the BOX for a tile + brand + packing ──────────────────────────────────
-- The cover a brand puts round a packing. Created on demand: wrapping a FAMOUS cover round a
-- packing he already has is not a new fact to confirm, it is just a box.
--
-- p_packing_id null → the tile's FIRST packing. That keeps every existing caller working: today
-- nobody picks a packing, and almost every tile has exactly one. Step 7 gives Add Stock a real
-- box picker, and then the caller says which.
create or replace function public._box_for(
  p_library_id uuid, p_brand_id uuid, p_packing_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_packing uuid; v_box uuid;
begin
  if p_brand_id is null then raise exception 'A box needs a brand — it is the cover.'; end if;

  if p_packing_id is not null then
    select id into v_packing from packings
     where id = p_packing_id and library_id = p_library_id;
    if v_packing is null then raise exception 'That packing is not this design''s'; end if;
  else
    select id into v_packing from packings
     where library_id = p_library_id order by created_at limit 1;
  end if;

  if v_packing is null then
    raise exception 'This design has no packing yet, so there is no box to count. '
                    'Set its pieces and weight first.';
  end if;

  select id into v_box from boxes where packing_id = v_packing and brand_id = p_brand_id;
  if v_box is null then
    insert into boxes (packing_id, brand_id) values (v_packing, p_brand_id)
      returning id into v_box;
  end if;
  return v_box;
end $function$;

revoke all on function public._box_for(uuid, uuid, uuid) from public, anon;
grant execute on function public._box_for(uuid, uuid, uuid) to authenticated;

-- ── 6. stock_add_holding lands the stock on a BOX ───────────────────────────────────────────
create or replace function public.stock_add_holding(
  p_library_id uuid,
  p_quality text,
  p_qty integer,
  p_catalog_id uuid,
  p_surface text default null,
  p_brand_id uuid default null,
  p_surface_label text default null,
  p_packing_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_stk uuid; v_design uuid; v_q text; v_surf text; v_label text;
        v_name text; v_size text; v_brand uuid; v_master_brand uuid;
        v_lib_surf text; v_lib_label text; v_box uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if p_library_id is null then raise exception 'Pick a design first'; end if;

  select p.print_name, p.size, l.brand_id, l.surface_type, l.surface_label
    into v_name, v_size, v_master_brand, v_lib_surf, v_lib_label
    from stockist_library l join print_master p on p.id = l.print_id
   where l.id = p_library_id and l.stockist_id = v_stk;
  if v_name is null then raise exception 'Design is not in your library'; end if;

  if p_catalog_id is not null and not exists (
       select 1 from stock_catalogs where id = p_catalog_id and stockist_id = v_stk) then
    raise exception 'Stock list does not belong to you';
  end if;

  v_brand := coalesce(p_brand_id, v_master_brand);
  v_q     := coalesce(nullif(btrim(p_quality),''),'Standard');

  -- THE STOCK INHERITS THE DESIGN'S SURFACE. A surface may CONFIRM it, never contradict it: the
  -- caller already said WHICH design, and choosing the design is not stock entry's job.
  v_surf := coalesce(nullif(btrim(p_surface),''), v_lib_surf);
  if v_surf is null or v_surf = '' or lower(v_surf) = 'none' then
    raise exception 'This design has no surface set. Open it in your Library and pick one.';
  end if;
  if v_surf is distinct from v_lib_surf then
    raise exception
      'This design is %, not %. Surface is part of a design''s identity — pick the % design in the list, or add it in your Library first.',
      v_lib_surf, v_surf, v_surf;
  end if;

  v_label := coalesce(nullif(btrim(coalesce(p_surface_label,'')),''), v_lib_label);

  -- 🔢 THE BOX. A hold is BOXES OF A BOX — the cover, and the packing inside it. Ten boxes of a
  -- 5-piece packing and ten of a 4-piece packing are not the same amount of tile, so the quantity
  -- is meaningless without this.
  v_box := _box_for(p_library_id, v_brand, p_packing_id);

  select id into v_design from designs
    where stockist_id = v_stk and box_id = v_box and quality = v_q;

  if v_design is null then
    -- library_id / brand_id are NOT passed: the trigger fills them from the box. They are a mirror.
    insert into designs (stockist_id, name, size, quality, surface_type, surface_label,
                         box_quantity, status, box_id)
      values (v_stk, v_name, v_size, v_q, v_surf, v_label, 0, 'active', v_box)
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

-- Adding a parameter creates an OVERLOAD, and the old call shape then dies with 42725. Drop it.
drop function if exists public.stock_add_holding(uuid, text, integer, uuid, text, uuid, text);

revoke all on function public.stock_add_holding(uuid, text, integer, uuid, text, uuid, text, uuid)
  from public, anon;
grant execute on function public.stock_add_holding(uuid, text, integer, uuid, text, uuid, text, uuid)
  to authenticated;

-- ── 7. import_stock_batch + the SQUARE-FOOTAGE readers now use the BOX HE HOLDS ─────────────
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
  v_box uuid;
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

      -- 🔢 A HOLD IS BOXES OF A BOX. Ten boxes of a 5-piece packing and ten of a 4-piece packing
      -- are not the same amount of tile, so the quantity is meaningless without the box.
      v_box := _box_for(v_master, v_hold_brand, null);

      select id into v_design from designs
        where stockist_id = v_stk and box_id = v_box and quality = v_quality;

      if v_design is null then
        -- library_id / brand_id are not passed: the trigger mirrors them off the box.
        insert into designs (stockist_id, name, size, quality, surface_type, surface_label, box_quantity, status, box_id)
          values (v_stk, v_name, v_size, v_quality, v_surface, v_label, 0, 'active', v_box)
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
    'surface_type', d.surface_type, 'surface_label', d.surface_label, 'stock_type', lib.stock_type,
    'tile_type', lib.tile_type, 'pieces_per_box', _box_pieces_of(d.box_id),
    'box_weight_kg', _box_weight_of(d.box_id), 'thickness_mm', lib.thickness_mm,
    'colour', _dna_colour(lib.id), 'finish_label', lib.finish_label,
    'library_created_at', lib.created_at,
    'image_url', pm.image_url, 'master_design_name', pm.print_name,
    'family_key', _family_effective_key(d.library_id),
    'brand_id', coalesce(d.brand_id, lib.brand_id),
    'stockist_key', s.sequential_id, 'stockist_priority', s.priority,
    'catalog_ids', (
      select coalesce(jsonb_agg(cid), '[]'::jsonb) from (
        select cd.catalog_id as cid
        from catalog_designs cd
        join stock_catalogs c on c.id = cd.catalog_id
        where cd.library_id = d.library_id and c.stockist_id = d.stockist_id
          and coalesce(c.list_type,'permanent') = 'temporary'
          and (c.brand_id is null or c.brand_id is not distinct from coalesce(d.brand_id, lib.brand_id))
        union
        select c.id as cid
        from stock_catalogs c
        where c.stockist_id = d.stockist_id and c.is_active
          and coalesce(c.list_type,'permanent') = 'permanent'
          and (array_length(c.filter_brand_ids,1) is null or d.brand_id = any(c.filter_brand_ids))
          and (array_length(c.filter_qualities,1) is null or d.quality = any(c.filter_qualities))
          and (array_length(c.filter_surfaces,1) is null or d.surface_type = any(c.filter_surfaces))
          and (array_length(c.filter_sizes,1) is null or d.size = any(c.filter_sizes))
          and (array_length(c.filter_tile_types,1) is null or lib.tile_type = any(c.filter_tile_types))
          and (array_length(c.filter_stock_types,1) is null or effective_stock_type(lib.stock_type, d.quality) = any(c.filter_stock_types))
          and (c.filter_box_min is null or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) >= c.filter_box_min)
          and (c.filter_box_max is null or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) <= c.filter_box_max)
      ) t
    )
  ) order by d.created_at desc), '[]'::jsonb)
  from designs d
  join stockists s on s.id = d.stockist_id
  left join stockist_library lib on lib.id = d.library_id
  left join print_master pm on pm.id = lib.print_id
  where d.stockist_id = (select id from stockists where user_id = auth.uid());
$function$
;

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
           'finish', lib.finish_label, 'weight', _box_weight_of(d.box_id),
           'pieces', _box_pieces_of(d.box_id), 'stock_type', effective_stock_type(lib.stock_type, d.quality),
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
           'finish', lib.finish_label, 'weight', _box_weight_of(d.box_id),
           'pieces', _box_pieces_of(d.box_id), 'stock_type', effective_stock_type(lib.stock_type, d.quality),
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

CREATE OR REPLACE FUNCTION public.my_private_designs()
 RETURNS TABLE(id uuid, name text, size text, surface_type text, surface_label text, quality text, colour text, stock_type text, box_quantity integer, pieces_per_box integer, box_weight_kg numeric, thickness_mm numeric, face_image_urls text[], status text, created_at timestamp with time zone, updated_at timestamp with time zone, finish_label text, tile_type text, catalog_ids uuid[], stockist_priority numeric, stockist_key text, stockist_display_name text, stockist_city text, brand_name text, library_id uuid, family_key text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  select d.id,
         coalesce((select bn.brand_design_name from stockist_library_brand_names bn
                   where bn.library_id = d.library_id
                     and bn.brand_id = coalesce(d.brand_id, lib.brand_id)),
                  pm.print_name, d.name) as name,
         d.size, d.surface_type, d.surface_label, d.quality, _dna_colour(lib.id),
         public.effective_stock_type(lib.stock_type, d.quality) as stock_type,
         greatest(0, d.box_quantity - d.control_quantity - held_of(d.id))::int as box_quantity,
         _box_pieces_of(d.box_id),
         _box_weight_of(d.box_id)::numeric(8,2), lib.thickness_mm::numeric(6,2),
         case when nullif(btrim(coalesce(pm.image_url,'')),'') is not null
              then array[pm.image_url] else '{}'::text[] end,
         d.status, d.created_at, d.updated_at, lib.finish_label, lib.tile_type,
         cat.ids as catalog_ids,
         s.priority as stockist_priority,
         s.sequential_id as stockist_key, s.name as stockist_display_name,
         s.city as stockist_city, br.name as brand_name,
         d.library_id, public._family_effective_key(d.library_id) as family_key
  from designs d
  join stockists s on s.id = d.stockist_id
  join stockist_library lib on lib.id = d.library_id
  join print_master pm on pm.id = lib.print_id
  left join brands br on br.id = coalesce(d.brand_id, lib.brand_id)
  cross join lateral (
    select array_agg(distinct c.id) as ids
    from dealer_catalog_access a
    join stock_catalogs c on c.id = a.catalog_id
    where a.end_user_id = (select id from end_users where user_id = auth.uid())
      and a.is_active and c.is_active and c.stockist_id = d.stockist_id
      and (
        (coalesce(c.list_type,'permanent') = 'temporary' and exists (
          select 1 from catalog_designs cd
          where cd.catalog_id = c.id and cd.library_id = d.library_id
        ))
        or
        (coalesce(c.list_type,'permanent') = 'permanent'
          and (array_length(c.filter_brand_ids,1) is null
               or coalesce(d.brand_id, lib.brand_id) = any(c.filter_brand_ids))
          and (array_length(c.filter_qualities,1) is null or d.quality = any(c.filter_qualities))
          and (array_length(c.filter_surfaces,1) is null or d.surface_type = any(c.filter_surfaces))
          and (array_length(c.filter_sizes,1) is null or d.size = any(c.filter_sizes))
          and (array_length(c.filter_tile_types,1) is null or lib.tile_type = any(c.filter_tile_types))
          and (array_length(c.filter_stock_types,1) is null
               or effective_stock_type(lib.stock_type, d.quality) = any(c.filter_stock_types))
          and (c.filter_box_min is null
               or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) >= c.filter_box_min)
          and (c.filter_box_max is null
               or greatest(0, d.box_quantity - d.control_quantity - held_of(d.id)) <= c.filter_box_max)
        )
      )
  ) cat
  where s.is_active
    and (d.box_quantity - d.control_quantity - held_of(d.id)) > 0
    and d.status <> 'out_of_stock'
    and cat.ids is not null;
$function$
;

-- ── 8. The public views ─────────────────────────────────────────────────────────────────────
create or replace view public.public_designs as
 SELECT d.id,
    d.stockist_id,
    d.name,
    d.size,
    d.surface_type,
    d.quality,
    _dna_colour(lib.id) AS colour,
    effective_stock_type(lib.stock_type, d.quality) AS stock_type,
    d.box_quantity,
    _box_pieces_of(d.box_id) AS pieces_per_box,
    (_box_weight_of(d.box_id))::numeric(8,2) AS box_weight_kg,
    (lib.thickness_mm)::numeric(6,2) AS thickness_mm,
        CASE
            WHEN (NULLIF(btrim(COALESCE(pm.image_url, ''::text)), ''::text) IS NOT NULL) THEN ARRAY[pm.image_url]
            ELSE '{}'::text[]
        END AS face_image_urls,
    d.status,
    d.created_at,
    d.updated_at,
    lib.finish_label,
    s.priority AS stockist_priority,
    lib.tile_type
   FROM (((designs d
     JOIN stockists s ON ((s.id = d.stockist_id)))
     LEFT JOIN stockist_library lib ON ((lib.id = d.library_id)))
     LEFT JOIN print_master pm ON ((pm.id = lib.print_id)))
  WHERE (s.is_active AND (d.status <> 'out_of_stock'::text) AND (d.box_quantity > 0) AND (EXISTS ( SELECT 1
           FROM stock_catalogs c
          WHERE ((c.stockist_id = d.stockist_id) AND (c.visibility = 'public'::text) AND c.show_in_marketplace AND c.is_active AND (((COALESCE(c.list_type, 'permanent'::text) = 'temporary'::text) AND (EXISTS ( SELECT 1
                   FROM catalog_designs cd
                  WHERE ((cd.catalog_id = c.id) AND (cd.library_id = d.library_id))))) OR ((COALESCE(c.list_type, 'permanent'::text) = 'permanent'::text) AND ((array_length(c.filter_brand_ids, 1) IS NULL) OR (COALESCE(d.brand_id, lib.brand_id) = ANY (c.filter_brand_ids))) AND ((array_length(c.filter_qualities, 1) IS NULL) OR (d.quality = ANY (c.filter_qualities))) AND ((array_length(c.filter_surfaces, 1) IS NULL) OR (d.surface_type = ANY (c.filter_surfaces))) AND ((array_length(c.filter_sizes, 1) IS NULL) OR (d.size = ANY (c.filter_sizes))) AND ((array_length(c.filter_tile_types, 1) IS NULL) OR (lib.tile_type = ANY (c.filter_tile_types))) AND ((array_length(c.filter_stock_types, 1) IS NULL) OR (effective_stock_type(lib.stock_type, d.quality) = ANY (c.filter_stock_types))) AND ((c.filter_box_min IS NULL) OR (GREATEST(0, ((d.box_quantity - d.control_quantity) - held_of(d.id))) >= c.filter_box_min)) AND ((c.filter_box_max IS NULL) OR (GREATEST(0, ((d.box_quantity - d.control_quantity) - held_of(d.id))) <= c.filter_box_max))))))))
;
create or replace view public.market_designs as
 SELECT d.id,
    d.name,
    d.size,
    d.surface_type,
    d.quality,
    _dna_colour(lib.id) AS colour,
    effective_stock_type(lib.stock_type, d.quality) AS stock_type,
    GREATEST(0, ((d.box_quantity - d.control_quantity) - held_of(d.id))) AS box_quantity,
    _box_pieces_of(d.box_id) AS pieces_per_box,
    (_box_weight_of(d.box_id))::numeric(8,2) AS box_weight_kg,
    (lib.thickness_mm)::numeric(6,2) AS thickness_mm,
        CASE
            WHEN (NULLIF(btrim(COALESCE(pm.image_url, ''::text)), ''::text) IS NOT NULL) THEN ARRAY[pm.image_url]
            ELSE '{}'::text[]
        END AS face_image_urls,
    d.status,
    d.created_at,
    d.updated_at,
    lib.finish_label,
    lib.tile_type,
    NULL::uuid AS catalog_id,
    s.priority AS stockist_priority,
    s.sequential_id AS stockist_key,
    s.name AS stockist_display_name,
    s.city AS stockist_city,
    br.name AS brand_name,
    d.library_id,
    _family_effective_key(d.library_id) AS family_key,
    d.surface_label
   FROM ((((designs d
     JOIN stockists s ON ((s.id = d.stockist_id)))
     LEFT JOIN stockist_library lib ON ((lib.id = d.library_id)))
     LEFT JOIN print_master pm ON ((pm.id = lib.print_id)))
     LEFT JOIN brands br ON ((br.id = lib.brand_id)))
  WHERE (s.is_active AND s.is_listed AND (d.status <> 'out_of_stock'::text) AND (((d.box_quantity - d.control_quantity) - held_of(d.id)) > 0) AND (EXISTS ( SELECT 1
           FROM stock_catalogs c
          WHERE ((c.stockist_id = d.stockist_id) AND (c.visibility = 'public'::text) AND c.show_in_marketplace AND c.is_active AND (((COALESCE(c.list_type, 'permanent'::text) = 'temporary'::text) AND (EXISTS ( SELECT 1
                   FROM catalog_designs cd
                  WHERE ((cd.catalog_id = c.id) AND (cd.library_id = d.library_id))))) OR ((COALESCE(c.list_type, 'permanent'::text) = 'permanent'::text) AND ((array_length(c.filter_brand_ids, 1) IS NULL) OR (COALESCE(d.brand_id, lib.brand_id) = ANY (c.filter_brand_ids))) AND ((array_length(c.filter_qualities, 1) IS NULL) OR (d.quality = ANY (c.filter_qualities))) AND ((array_length(c.filter_surfaces, 1) IS NULL) OR (d.surface_type = ANY (c.filter_surfaces))) AND ((array_length(c.filter_sizes, 1) IS NULL) OR (d.size = ANY (c.filter_sizes))) AND ((array_length(c.filter_tile_types, 1) IS NULL) OR (lib.tile_type = ANY (c.filter_tile_types))) AND ((array_length(c.filter_stock_types, 1) IS NULL) OR (effective_stock_type(lib.stock_type, d.quality) = ANY (c.filter_stock_types))) AND ((c.filter_box_min IS NULL) OR (GREATEST(0, ((d.box_quantity - d.control_quantity) - held_of(d.id))) >= c.filter_box_min)) AND ((c.filter_box_max IS NULL) OR (GREATEST(0, ((d.box_quantity - d.control_quantity) - held_of(d.id))) <= c.filter_box_max))))))))
;
