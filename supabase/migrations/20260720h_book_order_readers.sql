-- 20260720h — BOOK ORDER, step 1b: the readers learn about a BOX line.
--             ⚠️ AND it repairs a REGRESSION that 20260720g introduced.
--
-- ── THE REGRESSION (fix first) ──────────────────────────────────────────────────────────────────
-- 20260720g dropped `UNIQUE (inquiry_id, design_id)` and replaced it with a unique index on
-- `(inquiry_id, coalesce(design_id, box_id))`. That expression index **cannot be inferred by
-- `ON CONFLICT (inquiry_id, design_id)`**, so two live writers began failing with 42P10:
--     create_stockist_order  ·  dispatch_inquiry
-- i.e. "step 1 is invisible" was NOT true — creating a stockist order was broken the moment g
-- landed. It went unnoticed because the step-1 self-test inserted rows DIRECTLY instead of calling
-- the writer RPCs. 🔑 **Verify a schema change through the RPCs that use it, not with raw SQL.**
-- (Nothing was lost: prod holds 0 orders and 0 lines.)
--
-- The repair keeps the original constraint, because it does the right thing on its own:
-- `UNIQUE (inquiry_id, design_id)` is NULLS DISTINCT by default, so any number of BOOK lines
-- (design_id NULL) coexist happily under it, and ON CONFLICT infers it exactly as before. A second
-- partial index covers the box side. Together with the XOR check they are equivalent to the
-- coalesce index — and no function body has to change for the fix.

drop index if exists public.inquiry_items_one_per_thing;

alter table public.inquiry_items
  add constraint inquiry_items_inquiry_id_design_id_key unique (inquiry_id, design_id);

create unique index if not exists inquiry_items_one_box_per_order
  on public.inquiry_items (inquiry_id, box_id) where box_id is not null;

-- ── THE READERS ─────────────────────────────────────────────────────────────────────────────────
-- Every reader inner-joined `designs`, so a book line was silently DROPPED — not an error, just
-- quietly absent from the order. Proved in step 1: a 2-line order came back with 1 line.
--
-- A book line has no hold, so its display facts come from the other side of the chain:
--     BOX → packing → TILE (stockist_library) → ARTWORK (print_master)
-- and its NAME is the word that brand prints (`stockist_library_brand_names`), falling back to the
-- artwork's own name — never invented.
--
-- ✅ Left alone deliberately:
--   * `held_of`  — keys on `design_id`, so book lines are already excluded. **A BOOK LINE HOLDS
--     NOTHING** — there is no stock to hold. Correct as it stands.
--   * `hold_order_items` — updates `where design_id = ...`, so it cannot touch a book line.
--   * `my_orders` — counts `inquiry_items` without joining `designs`; already correct. (And the
--     buyer is shown nothing about production anyway — that step is deleted from the plan.)
--   * `dispatch_inquiry` — its prune is `not (design_id = any(v_keep))`, and for a book line
--     `design_id` is NULL, so the predicate is NULL and the row is NOT deleted. Book lines already
--     survive a dispatch untouched, which is the behaviour we want. Dispatching a book line is
--     step 5 (it must become stock first), so its body is left alone on purpose.

-- ── inquiry_detail: emit both kinds, one shape ──────────────────────────────────────────────────
create or replace function public.inquiry_detail(p_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_eu uuid; v_st uuid; v_lines jsonb;
begin
  select end_user_id, stockist_id into v_eu, v_st from inquiries where id = p_id;
  if v_st is null then raise exception 'Order not found'; end if;
  if not (
    v_eu in (select id from end_users where user_id = auth.uid())
    or v_st in (select id from stockists where user_id = auth.uid())
    or current_user_role() = 'admin') then
    raise exception 'Not allowed';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    -- 'kind' tells the two apart without the caller guessing from a null.
    'kind', case when it.design_id is not null then 'stock' else 'book' end,
    'design_id', d.id, 'box_id', it.box_id,
    'design_name', coalesce(d.name, nullif(btrim(coalesce(bn.brand_design_name,'')),''),
                            pm.print_name),
    'size', coalesce(d.size, pm.size),
    'surface', coalesce(d.surface_type, lib.surface_type),
    -- A stock line's grade is the hold's. A book line carries its own; NULL means Premium.
    'quality', coalesce(d.quality, it.quality, 'Premium'),
    'brand', coalesce(b.name, ''),
    'image', nullif(btrim(coalesce(pm.image_url,'')),''),
    'quantity', it.quantity, 'dispatched_qty', it.dispatched_qty,
    'produced_qty', it.produced_qty, 'is_urgent', it.is_urgent,
    -- For a book line "available" is whatever stock that BOX already carries — that is exactly the
    -- number that tells him how much of the order is ready and how much must still be made.
    'available', coalesce(d.box_quantity,
                          (select coalesce(sum(dd.box_quantity),0) from designs dd
                            where dd.box_id = it.box_id), 0),
    -- 🚫 A book line holds nothing.
    'held', case when it.design_id is not null then held_of(d.id) else 0 end,
    'line_held', it.held_qty)
    order by coalesce(d.name, pm.print_name), it.created_at), '[]'::jsonb)
  into v_lines
  from inquiry_items it
  left join designs d on d.id = it.design_id
  left join boxes bx on bx.id = it.box_id
  left join packings pk on pk.id = bx.packing_id
  left join brands b on b.id = bx.brand_id
  -- the TILE: from the hold's library, or from the box's packing
  left join stockist_library lib on lib.id = coalesce(d.library_id, pk.library_id)
  left join print_master pm on pm.id = lib.print_id
  left join stockist_library_brand_names bn
         on bn.library_id = lib.id and bn.brand_id = bx.brand_id
  where it.inquiry_id = p_id;

  return (select jsonb_build_object(
    'id', i.id, 'token', i.token, 'status', i.status,
    'connection_code', i.connection_code, 'customer_hint', i.customer_hint,
    'source', i.source,
    'created_at', i.created_at, 'updated_at', i.updated_at,
    'confirmed_at', i.confirmed_at, 'locked_at', i.locked_at,
    'guarantee_until', i.guarantee_until, 'accepted_at', i.accepted_at,
    'guarantee_days', i.guarantee_days,
    'lines', v_lines)
    from inquiries i where i.id = p_id);
end; $function$;

-- ── my_inquiries: the name list and the brand list must see book lines ──────────────────────────
create or replace function public.my_inquiries()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(row order by row->>'updated_at' desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', i.id, 'token', i.token, 'status', i.status,
      'connection_code', i.connection_code, 'customer_hint', i.customer_hint,
      'source', i.source,
      'created_at', i.created_at, 'updated_at', i.updated_at,
      'confirmed_at', i.confirmed_at, 'locked_at', i.locked_at,
      'guarantee_until', i.guarantee_until, 'accepted_at', i.accepted_at,
      'guarantee_days', i.guarantee_days,
      'end_user_id', i.end_user_id,
      'company', coalesce(e.company_name, ''), 'contact', coalesce(e.contact_person, ''),
      'phone', coalesce(e.phone, ''), 'country_code', coalesce(e.country_code, '+91'),
      'city', coalesce(e.city, ''),
      'held_boxes', (select coalesce(sum(it.held_qty),0) from inquiry_items it where it.inquiry_id=i.id),
      'line_count', (select count(*) from inquiry_items it where it.inquiry_id=i.id),
      'total_boxes', (select coalesce(sum(it.quantity),0) from inquiry_items it where it.inquiry_id=i.id),
      -- 📕 how much of this order is still to be MADE — 0 on a pure stock order
      'book_boxes', (select coalesce(sum(greatest(it.quantity - it.produced_qty,0)),0)
                       from inquiry_items it
                      where it.inquiry_id=i.id and it.box_id is not null),
      'urgent', (select bool_or(it.is_urgent) from inquiry_items it where it.inquiry_id=i.id),
      -- Names: the hold's name for a stock line; for a book line the word that brand prints,
      -- else the artwork's own name.
      'designs', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'id', coalesce(d.id, it.box_id),
                   'name', coalesce(d.name, nullif(btrim(coalesce(bn.brand_design_name,'')),''),
                                    pm.print_name))
                 order by coalesce(d.name, pm.print_name))
          from inquiry_items it
          left join designs d on d.id = it.design_id
          left join boxes bx on bx.id = it.box_id
          left join packings pk on pk.id = bx.packing_id
          left join stockist_library lib on lib.id = coalesce(d.library_id, pk.library_id)
          left join print_master pm on pm.id = lib.print_id
          left join stockist_library_brand_names bn
                 on bn.library_id = lib.id and bn.brand_id = bx.brand_id
          where it.inquiry_id=i.id), '[]'::jsonb),
      -- Brands: stock is per-brand on the hold; a book line's brand IS its box's cover.
      'brands', coalesce((
          select jsonb_agg(distinct b.name)
          from inquiry_items it
          left join designs d on d.id = it.design_id
          left join boxes bx on bx.id = it.box_id
          left join stockist_library lib on lib.id = d.library_id
          join brands b on b.id = coalesce(bx.brand_id, d.brand_id, lib.brand_id)
                       and not b.is_default
          where it.inquiry_id=i.id), '[]'::jsonb)
    ) as row
    from inquiries i left join end_users e on e.id = i.end_user_id
    where i.stockist_id in (select id from stockists where user_id = auth.uid())
      and not (i.end_user_id is not null and i.status = 'draft')
  ) t;
$function$;

-- ── update_order_items: MUST NOT WIPE BOOK LINES ────────────────────────────────────────────────
-- It deleted every line of the order and re-inserted from p_lines, which carries only design_ids.
-- Once a book line existed, editing a stock order would DELETE THE CUSTOMER'S PRODUCTION ORDER.
-- This editor manages stock lines; book lines are edited in the Book Order screen (step 2).
create or replace function public.update_order_items(p_id uuid, p_hint text, p_lines jsonb)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_st uuid; v_eu uuid; v_status text;
begin
  select i.stockist_id, i.end_user_id, i.status into v_st, v_eu, v_status
  from inquiries i join stockists s on s.id = i.stockist_id
  where i.id = p_id and s.user_id = auth.uid();
  if v_st is null then raise exception 'Not allowed'; end if;
  if v_eu is not null then
    raise exception 'Only a stockist-managed order (no app buyer) can be edited';
  end if;
  if v_status not in ('draft','sent') then
    raise exception 'Only an open (not held/dispatched) order can be edited';
  end if;
  if exists (
    select 1 from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) e
    left join designs d on d.id = (e->>'design_id')::uuid
    where d.id is null or d.stockist_id <> v_st) then
    raise exception 'A design does not belong to you';
  end if;

  -- 🔑 STOCK LINES ONLY. A book line is not in p_lines and must survive untouched.
  delete from inquiry_items where inquiry_id = p_id and design_id is not null;
  insert into inquiry_items (inquiry_id, design_id, quantity)
  select p_id, (e->>'design_id')::uuid, greatest((e->>'quantity')::int, 0)
  from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) e
  where greatest((e->>'quantity')::int, 0) > 0;

  update inquiries
  set customer_hint = coalesce(p_hint, customer_hint), updated_at = now()
  where id = p_id;
end; $function$;
