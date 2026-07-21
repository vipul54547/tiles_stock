-- 20260721c — 🧱 LOT LAYER, L2: batch + location flow INTO the stock-add path.
--
-- L1 made every add a lot (NULL batch/location). L2 lets the stockist actually SET batch + location
-- when he adds stock. Gated by the two flags from L1 (track_batches, track_locations) — those decide
-- only whether the UI shows the fields; the data path is the same. (docs/LOT_LAYER_PLAN.md)

-- The pending queue must carry batch/location too, so a held-then-approved add restores the right lot.
alter table public.stock_in
  add column if not exists batch       text,
  add column if not exists location_id uuid references public.stock_locations(id) on delete set null;

-- ── location pick-list CRUD (his own codes, add on the fly) ──────────────────────────────────────
create or replace function public.my_stock_locations()
 returns jsonb language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'code', code) order by lower(code)), '[]'::jsonb)
  from stock_locations where stockist_id in (select id from stockists where user_id = auth.uid());
$function$;

create or replace function public.stock_location_add(p_code text)
 returns uuid language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid; v_code text := nullif(btrim(coalesce(p_code, '')), ''); v_id uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if v_code is null then raise exception 'Enter a location code'; end if;
  select id into v_id from stock_locations where stockist_id = v_stk and lower(code) = lower(v_code);
  if v_id is null then
    insert into stock_locations (stockist_id, code) values (v_stk, v_code) returning id into v_id;
  end if;
  return v_id;
end $function$;

create or replace function public.stock_location_delete(p_id uuid)
 returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  delete from stock_locations where id = p_id and stockist_id = v_stk;  -- lots' location_id -> NULL (FK)
end $function$;

-- ── admin toggles for the two flags (mirror admin_set_stockist_book_orders) ──────────────────────
create or replace function public.admin_set_stockist_track_batches(p_seq text, p_enabled boolean)
 returns void language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
begin
  if current_user_role() <> 'admin' then raise exception 'Only admins'; end if;
  update stockists set track_batches = coalesce(p_enabled, false) where sequential_id = p_seq;
end $function$;

create or replace function public.admin_set_stockist_track_locations(p_seq text, p_enabled boolean)
 returns void language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
begin
  if current_user_role() <> 'admin' then raise exception 'Only admins'; end if;
  update stockists set track_locations = coalesce(p_enabled, false) where sequential_id = p_seq;
end $function$;

-- ── add_stock gains batch + location (6-arg -> 8-arg; trailing defaults, so import's 6-arg call
--    still resolves). The lot it makes now carries them; the pending row remembers them. ──────────
drop function if exists public.add_stock(uuid, uuid, integer, text, text, text);
create or replace function public.add_stock(p_design_id uuid, p_stockist_id uuid, p_quantity integer, p_pdf_filename text, p_size text, p_quality text, p_batch text default null, p_location uuid default null)
 returns void
 language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_hold_threshold int := 35000;
  v_jump_floor     int := 10000;
  v_today          int;
  v_today_approved int;
  v_existing       int;
  v_after          int;
  v_prior_pend     int;
  v_hold           boolean;
  v_jump_now       boolean;
  v_jump_before    boolean;
  v_name           text;
  v_seq            text;
begin
  select coalesce(sum(quantity_added), 0) into v_today
  from stock_in
  where stockist_id = p_stockist_id
    and created_at >= now() - interval '24 hours'
    and status in ('approved', 'pending');

  select coalesce(sum(quantity_added), 0) into v_today_approved
  from stock_in
  where stockist_id = p_stockist_id
    and created_at >= now() - interval '24 hours'
    and status = 'approved';

  select coalesce(sum(box_quantity), 0) - v_today_approved into v_existing
  from designs where stockist_id = p_stockist_id;
  if v_existing < 0 then v_existing := 0; end if;

  v_after := v_today + p_quantity;
  v_hold := v_after > v_hold_threshold;

  v_jump_now := v_after > v_jump_floor
            and v_existing >= v_jump_floor
            and v_after > 0.30 * v_existing;
  v_jump_before := v_today > v_jump_floor
            and v_existing >= v_jump_floor
            and v_today > 0.30 * v_existing;

  select count(*) into v_prior_pend
  from stock_in
  where stockist_id = p_stockist_id and status = 'pending'
    and created_at >= now() - interval '24 hours';

  insert into stock_in
    (design_id, stockist_id, quantity_added, pdf_filename, size, quality, status, batch, location_id)
  values
    (p_design_id, p_stockist_id, p_quantity, p_pdf_filename, p_size, p_quality,
     case when v_hold then 'pending' else 'approved' end,
     nullif(btrim(coalesce(p_batch,'')),''), p_location);

  if v_hold then
    if v_prior_pend = 0 then
      select name, sequential_id into v_name, v_seq
      from stockists where id = p_stockist_id;
      insert into notifications(recipient_id, type, title, body)
      select p.id, 'stock_pending', 'Large stock awaiting approval',
             coalesce(v_name,'A stockist') || ' (' || coalesce(v_seq,'?') ||
             ') added 35,000+ boxes in a day. It is held — review to approve.'
      from profiles p where p.role = 'admin';
    end if;
  else
    perform _lot_add(p_design_id, p_batch, p_location, p_quantity);

    if v_jump_now and not v_jump_before then
      select name, sequential_id into v_name, v_seq
      from stockists where id = p_stockist_id;
      insert into notifications(recipient_id, type, title, body)
      select p.id, 'stock_big_live', 'Large stock added (live)',
             coalesce(v_name,'A stockist') || ' (' || coalesce(v_seq,'?') ||
             ') added a large batch (~' || v_after ||
             ' boxes today, over 30% of their existing stock). Live — for your awareness.'
      from profiles p where p.role = 'admin';
    end if;
  end if;
end $function$;

-- set_pending_stock — approve the held rows into lots, now grouped by (design, batch, location).
create or replace function public.set_pending_stock(p_stockist_id uuid, p_approve boolean)
 returns integer
 language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_owner uuid; v_total int; r record;
begin
  if current_user_role() <> 'admin' then
    raise exception 'Only admins can review stock';
  end if;
  select user_id into v_owner from stockists where id = p_stockist_id;
  select coalesce(sum(quantity_added), 0) into v_total
  from stock_in where stockist_id = p_stockist_id and status = 'pending';
  if v_total = 0 then return 0; end if;

  if p_approve then
    for r in select design_id, batch, location_id, sum(quantity_added) as q
               from stock_in
              where stockist_id = p_stockist_id and status = 'pending'
              group by design_id, batch, location_id loop
      perform _lot_add(r.design_id, r.batch, r.location_id, r.q);
    end loop;

    update stock_in set status = 'approved'
    where stockist_id = p_stockist_id and status = 'pending';

    if v_owner is not null then
      perform _notify(v_owner, 'stock_approved', 'Stock approved',
        v_total || ' boxes of pending stock were approved and are now live.',
        '{}'::jsonb);
    end if;
  else
    update stock_in set status = 'rejected'
    where stockist_id = p_stockist_id and status = 'pending';
    if v_owner is not null then
      perform _notify(v_owner, 'stock_rejected', 'Stock rejected',
        v_total || ' boxes of pending stock were rejected by the admin.',
        '{}'::jsonb);
    end if;
  end if;
  return v_total;
end $function$;

-- stock_add_holding gains batch + location (8-arg -> 10-arg), validates the location is his, and
-- threads them into add_stock. Old 8-arg dropped so Dart hits the new one.
drop function if exists public.stock_add_holding(uuid, text, integer, uuid, text, uuid, text, uuid);
create or replace function public.stock_add_holding(p_library_id uuid, p_quality text, p_qty integer, p_catalog_id uuid, p_surface text DEFAULT NULL::text, p_brand_id uuid DEFAULT NULL::uuid, p_surface_label text DEFAULT NULL::text, p_packing_id uuid DEFAULT NULL::uuid, p_batch text DEFAULT NULL::text, p_location_id uuid DEFAULT NULL::uuid)
 returns uuid
 language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_stk uuid; v_design uuid; v_q text; v_surf text; v_label text;
        v_name text; v_size text; v_brand uuid; v_master_brand uuid;
        v_lib_surf text; v_lib_label text; v_box uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if p_library_id is null then raise exception 'Pick a design first'; end if;

  if p_location_id is not null and not exists (
       select 1 from stock_locations where id = p_location_id and stockist_id = v_stk) then
    raise exception 'That location is not yours';
  end if;

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

  v_box := _box_for(p_library_id, v_brand, p_packing_id);

  select id into v_design from designs
    where stockist_id = v_stk and box_id = v_box and quality = v_q;

  if v_design is null then
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
    perform add_stock(v_design, v_stk, p_qty, '', v_size, v_q, p_batch, p_location_id);
  end if;
  return v_design;
end $function$;

-- grants (drop+create loses them)
revoke all on function public.my_stock_locations() from public, anon;
revoke all on function public.stock_location_add(text) from public, anon;
revoke all on function public.stock_location_delete(uuid) from public, anon;
revoke all on function public.admin_set_stockist_track_batches(text, boolean) from public, anon;
revoke all on function public.admin_set_stockist_track_locations(text, boolean) from public, anon;
revoke all on function public.add_stock(uuid, uuid, integer, text, text, text, text, uuid) from public, anon;
revoke all on function public.set_pending_stock(uuid, boolean) from public, anon;
revoke all on function public.stock_add_holding(uuid, text, integer, uuid, text, uuid, text, uuid, text, uuid) from public, anon;
grant execute on function public.my_stock_locations() to authenticated;
grant execute on function public.stock_location_add(text) to authenticated;
grant execute on function public.stock_location_delete(uuid) to authenticated;
grant execute on function public.admin_set_stockist_track_batches(text, boolean) to authenticated;
grant execute on function public.admin_set_stockist_track_locations(text, boolean) to authenticated;
grant execute on function public.add_stock(uuid, uuid, integer, text, text, text, text, uuid) to authenticated;
grant execute on function public.set_pending_stock(uuid, boolean) to authenticated;
grant execute on function public.stock_add_holding(uuid, text, integer, uuid, text, uuid, text, uuid, text, uuid) to authenticated;
