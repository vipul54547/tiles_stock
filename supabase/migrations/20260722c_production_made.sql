-- 20260722c — 🏭 MADE flow (Phase 2, server): two-grade output with batch+location.
--
-- Supersedes the single-grade `production_declare_output`. One transactional submit records BOTH
-- grades of a run's output for a design (docs/PRODUCTION_REDESIGN_PLAN.md §Phase 2–3):
--   • PREMIUM — under the run's brand cover → stock + a LOT (batch/location), and bumps the RUN's
--     ticked book-order lines (`produced_qty`). Progress = premium only. NO auto-close here — closing
--     moves to "Order from stock" (M4); surplus premium is just free stock.
--   • STANDARD — under a chosen cover (default brand if its toggle is on, else the produced brand) →
--     free stock + a LOT. NEVER allocated to anyone.
-- Batch/location only matter when the stockist tracks lots; a blank row is simply skipped.
--
-- `production_declare_output` is LEFT in place (the current dialog still calls it) until the M2 UI
-- switches to `production_made`; a later cleanup drops it.

-- ── the per-brand "standard packs in the default brand" toggle (drives Row-2's default) ──────────
alter table public.brands
  add column if not exists standard_in_default boolean not null default false;

create or replace function public.stockist_set_brand_standard_in_default(p_brand_id uuid, p_on boolean)
 returns void language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_stk uuid;
begin
  select b.stockist_id into v_stk from brands b join stockists s on s.id = b.stockist_id
  where b.id = p_brand_id and s.user_id = auth.uid();
  if v_stk is null then raise exception 'Not your brand'; end if;
  update brands set standard_in_default = coalesce(p_on, false) where id = p_brand_id;
end $function$;

-- ── get-or-create a location by code, scoped to a stockist (null code → null id) ─────────────────
create or replace function public._made_loc(p_stk uuid, p_code text)
 returns uuid language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_code text := nullif(btrim(coalesce(p_code, '')), ''); v_id uuid;
begin
  if v_code is null then return null; end if;
  select id into v_id from stock_locations where stockist_id = p_stk and lower(code) = lower(v_code);
  if v_id is null then
    insert into stock_locations (stockist_id, code) values (p_stk, v_code) returning id into v_id;
  end if;
  return v_id;
end $function$;

-- ── the covers of a design, for Row-2's brand ▾ (every brand that has a box for this library) ────
create or replace function public.my_covers_for_design(p_box_id uuid)
 returns jsonb language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  with lib as (
    select pk.library_id
    from boxes bx join packings pk on pk.id = bx.packing_id
    join stockist_library l on l.id = pk.library_id
    join stockists s on s.id = l.stockist_id
    where bx.id = p_box_id and s.user_id = auth.uid())
  select coalesce(jsonb_agg(jsonb_build_object(
      'box_id', bx.id, 'brand_id', b.id, 'brand', b.name,
      'is_default', b.is_default, 'standard_in_default', b.standard_in_default)
      order by b.is_default desc, b.sort_order, b.name), '[]'::jsonb)
  from boxes bx
  join packings pk on pk.id = bx.packing_id
  join brands b on b.id = bx.brand_id
  where pk.library_id = (select library_id from lib);
$function$;

-- ── the two-grade MADE submit ────────────────────────────────────────────────────────────────────
-- p_premium / p_standard: `{box_id, boxes, batch, location}` (location = code text) or null.
create or replace function public.production_made(
  p_run_id uuid, p_premium jsonb DEFAULT NULL, p_standard jsonb DEFAULT NULL)
 returns jsonb
 language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_stk uuid;
  v_prem_design uuid; v_std_design uuid;
  v_prem_boxes int; v_std_boxes int;
  v_run_alloc int := 0;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if not exists (select 1 from production_runs where id = p_run_id and stockist_id = v_stk) then
    raise exception 'That run is not yours';
  end if;

  v_prem_boxes := greatest(coalesce((p_premium->>'boxes')::int, 0), 0);
  v_std_boxes  := greatest(coalesce((p_standard->>'boxes')::int, 0), 0);
  if v_prem_boxes <= 0 and v_std_boxes <= 0 then
    raise exception 'How many boxes came off the line?';
  end if;

  -- PREMIUM → run's cover, bump the run's ticked lines (no surplus-to-others, no auto-close).
  if v_prem_boxes > 0 then
    declare
      v_lib uuid; v_brand uuid; v_pack uuid; v_loc uuid;
      v_box uuid := (p_premium->>'box_id')::uuid; v_left int; v_take int; r record;
    begin
      select pk.library_id, bx.brand_id, pk.id into v_lib, v_brand, v_pack
        from boxes bx join packings pk on pk.id = bx.packing_id
        join stockist_library l on l.id = pk.library_id
       where bx.id = v_box and l.stockist_id = v_stk;
      if v_lib is null then raise exception 'That box is not yours'; end if;
      v_loc := _made_loc(v_stk, p_premium->>'location');

      v_prem_design := stock_add_holding(v_lib, 'Premium', v_prem_boxes, null, null, v_brand, null,
                        v_pack, nullif(btrim(coalesce(p_premium->>'batch','')), ''), v_loc);
      insert into production_run_output (run_id, box_id, quality, boxes, design_id)
      values (p_run_id, v_box, 'Premium', v_prem_boxes, v_prem_design);

      v_left := v_prem_boxes;
      for r in
        select l.id, least(l.quantity - l.produced_qty, d.planned_boxes) owed
          from production_run_demand d
          join book_order_lines l on l.id = d.book_order_line_id
          join book_orders o on o.id = l.order_id
         where d.run_id = p_run_id and l.box_id = v_box
           and o.status = 'open' and l.quantity > l.produced_qty
         order by l.is_urgent desc, o.created_at
      loop
        exit when v_left <= 0;
        v_take := least(v_left, r.owed);
        if v_take > 0 then
          update book_order_lines set produced_qty = produced_qty + v_take where id = r.id;
          v_left := v_left - v_take;
          v_run_alloc := v_run_alloc + v_take;
        end if;
      end loop;
    end;
  end if;

  -- STANDARD → chosen cover, FREE stock, no allocation.
  if v_std_boxes > 0 then
    declare
      v_lib uuid; v_brand uuid; v_pack uuid; v_loc uuid; v_box uuid := (p_standard->>'box_id')::uuid;
    begin
      select pk.library_id, bx.brand_id, pk.id into v_lib, v_brand, v_pack
        from boxes bx join packings pk on pk.id = bx.packing_id
        join stockist_library l on l.id = pk.library_id
       where bx.id = v_box and l.stockist_id = v_stk;
      if v_lib is null then raise exception 'That standard box is not yours'; end if;
      v_loc := _made_loc(v_stk, p_standard->>'location');

      v_std_design := stock_add_holding(v_lib, 'Standard', v_std_boxes, null, null, v_brand, null,
                       v_pack, nullif(btrim(coalesce(p_standard->>'batch','')), ''), v_loc);
      insert into production_run_output (run_id, box_id, quality, boxes, design_id)
      values (p_run_id, v_box, 'Standard', v_std_boxes, v_std_design);
    end;
  end if;

  return jsonb_build_object(
    'premium_design', v_prem_design, 'standard_design', v_std_design,
    'premium_boxes', v_prem_boxes, 'standard_boxes', v_std_boxes,
    'to_this_run', v_run_alloc,
    'premium_free', v_prem_boxes - v_run_alloc);
end $function$;

revoke all on function public.stockist_set_brand_standard_in_default(uuid, boolean) from public, anon;
revoke all on function public.my_covers_for_design(uuid) from public, anon;
revoke all on function public.production_made(uuid, jsonb, jsonb) from public, anon;
revoke all on function public._made_loc(uuid, text) from public, anon;
grant execute on function public.stockist_set_brand_standard_in_default(uuid, boolean) to authenticated;
grant execute on function public.my_covers_for_design(uuid) to authenticated;
grant execute on function public.production_made(uuid, jsonb, jsonb) to authenticated;
