-- ADDING STOCK MUST NEVER MINT A DESIGN.
--
-- `stock_add_holding` took a p_surface, and when it differed from the chosen product's own surface
-- it THREW THE CHOSEN PRODUCT AWAY: it went looking for another product of the same print with
-- that surface and — if none existed — **INSERTED ONE**, copying the DNA, the boxes and the family
-- across. So Add Stock could create a design, which is precisely the thing we deleted from the
-- import path on 14 Jul (see 20260714b: the stock door creates nothing).
--
-- It was worse than dead weight. The Add Stock surface picker was a WORKAROUND from the days when
-- the design picker showed only the print's name (`1001`) and could not tell the three pieces of
-- that print apart; the surface dropdown was really asking "WHICH PRODUCT?". The picker now names
-- the PIECE — `1001 — MATTE` — so the question is already answered, and having both ask it meant
-- they could DISAGREE: choose `1001 — MATTE`, pick surface `CARV`, and the boxes silently landed
-- on the Carving product instead. famous ceramic's surface list even offers `Golden Series`, which
-- is not a surface at all — picking it would have minted a phantom product.
--
-- After this migration p_surface may only CONFIRM the product's own surface. It may not contradict
-- it, and there is no path from stock to a new product.
--
-- SURFACE IS STILL PRODUCT IDENTITY. Nothing about the model changes — what changes is WHERE the
-- question is asked: in the Library (where a product is made), never at the stock counter.

create or replace function public.stock_add_holding(
  p_library_id uuid,
  p_quality text,
  p_qty integer,
  p_catalog_id uuid,
  p_surface text default null,
  p_brand_id uuid default null,
  p_surface_label text default null
) returns uuid
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_stk uuid; v_design uuid; v_q text; v_surf text; v_label text;
        v_name text; v_size text; v_brand uuid; v_master_brand uuid;
        v_lib_surf text; v_lib_label text;
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

  -- THE STOCK INHERITS THE PRODUCT'S SURFACE. No surface passed = "the product knows its own",
  -- which is now the only thing the app ever sends.
  v_surf := coalesce(nullif(btrim(p_surface),''), v_lib_surf);
  if v_surf is null or v_surf = '' or lower(v_surf) = 'none' then
    raise exception 'This design has no surface set. Open it in your Library and pick one.';
  end if;

  -- A surface may CONFIRM the product, never contradict it. The caller already said WHICH product
  -- (p_library_id); a different surface would mean a different product, and choosing the product is
  -- not something stock entry gets to do behind the stockist's back.
  if v_surf is distinct from v_lib_surf then
    raise exception
      'This design is %, not %. Surface is part of a design''s identity — pick the % design in the list, or add it in your Library first.',
      v_lib_surf, v_surf, v_surf;
  end if;

  v_label := coalesce(nullif(btrim(coalesce(p_surface_label,'')),''), v_lib_label);

  select id into v_design from designs
    where stockist_id = v_stk and library_id = p_library_id
      and brand_id is not distinct from v_brand
      and quality = v_q and surface_type = v_surf;
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

revoke all on function public.stock_add_holding(uuid, text, integer, uuid, text, uuid, text)
  from public, anon;
grant execute on function public.stock_add_holding(uuid, text, integer, uuid, text, uuid, text)
  to authenticated;
