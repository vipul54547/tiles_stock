-- 20260721b — 🧱 LOT LAYER, L1: batch + location BELOW the holding (foundation, invisible).
--
-- Locked 13 Jul (project_print_master_model), built now because stock is EMPTY (0 rows) — the safe
-- moment — and because the coming production "Made" is itself a stock-add, the natural home for
-- batch + location. (docs/LOT_LAYER_PLAN.md)
--
-- 🔑 THE INVARIANT: `designs.box_quantity` is the SUM of a holding's lots, maintained by a trigger.
--   Nothing writes box_quantity (or status) directly any more — every quantity change goes through a
--   LOT. The 9 functions that used to write it now call _lot_add / _lot_take.
--
-- 🔓 Batch (= shade, off the carton) and location are OPTIONAL, in NO key — they DECOMPOSE a holding,
--   never split it. A stockist who tracks neither gets ONE lot (batch+location NULL), invisible.
--   TWO separate admin flags (track_batches, track_locations) — a stockist may use one without the
--   other. They gate DISPLAY only (no second data path). This migration is L1: flags OFF ⇒ one NULL
--   lot per holding ⇒ behaves exactly like today. The UI + picker + dispatch-lot-picker are L2–L4.

-- ── tables ────────────────────────────────────────────────────────────────────────────────────
create table if not exists public.stock_locations (
  id          uuid primary key default gen_random_uuid(),
  stockist_id uuid not null references public.stockists(id) on delete cascade,
  code        text not null,
  created_at  timestamptz not null default now()
);
create unique index if not exists stock_locations_uniq
  on public.stock_locations (stockist_id, lower(code));

create table if not exists public.stock_lots (
  id           uuid primary key default gen_random_uuid(),
  holding_id   uuid not null references public.designs(id) on delete cascade,
  batch        text,                                              -- = shade, off the carton; NULL ok
  location_id  uuid references public.stock_locations(id) on delete set null,
  box_quantity integer not null default 0 check (box_quantity >= 0),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
-- merge key: same holding + same batch + same location = ONE lot (NULLs normalised).
create unique index if not exists stock_lots_uniq on public.stock_lots
  (holding_id, coalesce(lower(btrim(batch)), ''), coalesce(location_id::text, ''));
create index if not exists stock_lots_holding_idx on public.stock_lots (holding_id, created_at);

alter table public.stockists
  add column if not exists track_batches  boolean not null default false,
  add column if not exists track_locations boolean not null default false;

alter table public.stock_locations enable row level security;
alter table public.stock_lots      enable row level security;
revoke all on public.stock_locations, public.stock_lots from anon, authenticated;

comment on table public.stock_lots is
  'A LOT decomposes a holding by batch (=shade) + location. box_quantity SUMs to designs via trigger. '
  'Transient: a lot at 0 is deleted; the holding survives. Batch/location optional, never identity.';

-- ── the invariant: box_quantity + status derive from the lot sum ────────────────────────────────
create or replace function public._trg_holding_box_qty() returns trigger
 language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_holding uuid; v_sum int;
begin
  v_holding := coalesce(new.holding_id, old.holding_id);
  select coalesce(sum(box_quantity), 0) into v_sum from stock_lots where holding_id = v_holding;
  update designs
     set box_quantity = v_sum,
         status       = case when v_sum = 0 then 'out_of_stock' else 'active' end,
         updated_at   = now()
   where id = v_holding;
  return null;
end $function$;

drop trigger if exists stock_lots_sum_aiud on public.stock_lots;
create trigger stock_lots_sum_aiud
  after insert or update or delete on public.stock_lots
  for each row execute function public._trg_holding_box_qty();

-- ── helpers every stock writer now calls ────────────────────────────────────────────────────────
-- Add p_qty boxes to the (holding, batch, location) lot — creating it, or topping it up.
create or replace function public._lot_add(
  p_holding uuid, p_batch text, p_location uuid, p_qty int)
 returns void
 language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_batch text := nullif(btrim(coalesce(p_batch, '')), '');
begin
  if coalesce(p_qty, 0) <= 0 then return; end if;
  update stock_lots
     set box_quantity = box_quantity + p_qty, updated_at = now()
   where holding_id = p_holding
     and coalesce(lower(btrim(batch)), '') = coalesce(lower(v_batch), '')
     and coalesce(location_id::text, '') = coalesce(p_location::text, '');
  if not found then
    insert into stock_lots (holding_id, batch, location_id, box_quantity)
    values (p_holding, v_batch, p_location, p_qty);
  end if;
end $function$;

-- Take p_qty boxes off a holding, OLDEST lot first (L3 will let him pick). A lot at 0 is deleted.
-- Clamps: if the holding hasn't got that many, it takes what is there (callers already guard totals).
create or replace function public._lot_take(p_holding uuid, p_qty int)
 returns void
 language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_left int := greatest(coalesce(p_qty, 0), 0); r record;
begin
  for r in select id, box_quantity from stock_lots
            where holding_id = p_holding and box_quantity > 0
            order by created_at, id loop
    exit when v_left <= 0;
    if r.box_quantity <= v_left then
      v_left := v_left - r.box_quantity;
      delete from stock_lots where id = r.id;
    else
      update stock_lots set box_quantity = box_quantity - v_left, updated_at = now() where id = r.id;
      v_left := 0;
    end if;
  end loop;
end $function$;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- The 9 writers, converted. Each ONLY swaps its `update designs set box_quantity…` for a lot call;
-- everything else (audit rows, notifications, order logic) is verbatim from the live definitions.
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- add_stock — the add incrementer. The one live box_quantity += now goes to a lot (NULL/NULL at L1).
create or replace function public.add_stock(p_design_id uuid, p_stockist_id uuid, p_quantity integer, p_pdf_filename text, p_size text, p_quality text)
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
    (design_id, stockist_id, quantity_added, pdf_filename, size, quality, status)
  values
    (p_design_id, p_stockist_id, p_quantity, p_pdf_filename, p_size, p_quality,
     case when v_hold then 'pending' else 'approved' end);

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
    perform _lot_add(p_design_id, null, null, p_quantity);   -- was: update designs set box_quantity += …

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

-- set_pending_stock — admin approves held stock. Each design's approved boxes go to a lot.
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
    for r in select design_id, sum(quantity_added) as q
               from stock_in
              where stockist_id = p_stockist_id and status = 'pending'
              group by design_id loop
      perform _lot_add(r.design_id, null, null, r.q);       -- was: update designs set box_quantity += q
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

-- adjust_stock — a manual absolute-SET correction. Collapses the holding to one lot at the new total.
create or replace function public.adjust_stock(p_design_id uuid, p_new_quantity integer, p_reason text, p_note text)
 returns boolean
 language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_old      int;
  v_stockist uuid;
  v_new      int := greatest(p_new_quantity, 0);
begin
  select d.box_quantity, d.stockist_id into v_old, v_stockist
  from designs d
  join stockists s on s.id = d.stockist_id
  where d.id = p_design_id and s.user_id = auth.uid()
  for update;

  if v_old is null then
    return false;
  end if;

  insert into stock_adjustments
    (design_id, stockist_id, old_quantity, new_quantity, delta, reason, note)
  values
    (p_design_id, v_stockist, v_old, v_new, v_new - v_old,
     coalesce(p_reason, ''), coalesce(p_note, ''));

  -- was: update designs set box_quantity = v_new. A blunt set collapses to a single NULL lot.
  delete from stock_lots where holding_id = p_design_id;
  if v_new > 0 then perform _lot_add(p_design_id, null, null, v_new); end if;

  return true;
end $function$;

-- dispatch_stock — single-design dispatch. Guard reads box_quantity (still the lot sum); take a lot.
create or replace function public.dispatch_stock(p_design_id uuid, p_stockist_id uuid, p_quantity integer, p_buyer_name text, p_notes text)
 returns boolean
 language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_current int;
begin
  select box_quantity into v_current
  from designs
  where id = p_design_id
  for update;

  if v_current is null or v_current < p_quantity then
    return false;
  end if;

  insert into dispatches (design_id, stockist_id, quantity_dispatched, buyer_name, notes)
  values (p_design_id, p_stockist_id, p_quantity, p_buyer_name, p_notes);

  perform _lot_take(p_design_id, p_quantity);   -- was: update designs set box_quantity -= …

  return true;
end $function$;

-- dispatch_walkin — multi-line walk-in. Each line takes off a lot.
create or replace function public.dispatch_walkin(p_lines jsonb, p_customer_id uuid DEFAULT NULL::uuid, p_customer_name text DEFAULT ''::text, p_invoice text DEFAULT ''::text, p_vehicle text DEFAULT ''::text, p_transporter text DEFAULT ''::text, p_note text DEFAULT ''::text, p_date date DEFAULT CURRENT_DATE, p_reduce_stock boolean DEFAULT true)
 returns jsonb
 language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_st uuid; ln jsonb; v_design uuid; v_disp int; v_total int;
  v_note_id uuid; v_dispatch_no text; v_label text; v_cust uuid;
begin
  select id into v_st from stockists where user_id = auth.uid();
  if v_st is null then raise exception 'Only stockists'; end if;

  if exists (
    select 1 from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e
    left join designs d on d.id = (e->>'design_id')::uuid
    where d.id is null or d.stockist_id <> v_st) then
    raise exception 'A design does not belong to you';
  end if;

  select coalesce(sum(greatest((e->>'dispatch')::int, 0)), 0) into v_total
  from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e;
  if v_total <= 0 then raise exception 'Nothing to dispatch'; end if;

  select id into v_cust from stockist_customers
  where id = p_customer_id and stockist_id = v_st;
  v_label := coalesce(nullif(btrim(p_customer_name), ''), 'Walk-in');

  insert into dispatch_notes (stockist_id, inquiry_id, end_user_id, customer_id,
    invoice_no, vehicle_no, transporter, note, dispatched_on)
  values (v_st, null, null, v_cust,
    coalesce(p_invoice, ''), coalesce(p_vehicle, ''), coalesce(p_transporter, ''),
    coalesce(p_note, ''), coalesce(p_date, current_date))
  returning id, dispatch_no into v_note_id, v_dispatch_no;

  for ln in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    v_design := (ln->>'design_id')::uuid;
    v_disp := greatest(coalesce((ln->>'dispatch')::int, 0), 0);
    if v_disp > 0 then
      insert into dispatches (design_id, stockist_id, quantity_dispatched, buyer_name, notes, dispatch_note_id)
      values (v_design, v_st, v_disp, v_label, 'Walk-in', v_note_id);
      if p_reduce_stock then
        perform _lot_take(v_design, v_disp);   -- was: update designs set box_quantity = greatest(0, … - v_disp)
      end if;
    end if;
  end loop;

  return jsonb_build_object('dispatch_no', v_dispatch_no, 'total', v_total,
                            'note_id', v_note_id);
end $function$;

-- dispatch_inquiry — order dispatch. Each dispatched line takes off a lot.
create or replace function public.dispatch_inquiry(p_inquiry uuid, p_lines jsonb, p_invoice text DEFAULT ''::text, p_vehicle text DEFAULT ''::text, p_transporter text DEFAULT ''::text, p_note text DEFAULT ''::text, p_date date DEFAULT CURRENT_DATE, p_reduce_stock boolean DEFAULT true, p_close boolean DEFAULT true, p_prune boolean DEFAULT true)
 returns jsonb
 language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_eu uuid; v_st uuid; v_status text; v_token text; v_company text; v_hint text;
  v_cust uuid;
  v_buyer_label text;
  v_keep uuid[]; ln jsonb; v_design uuid; v_disp int;
  v_total int; v_note_id uuid; v_dispatch_no text;
  v_outstanding int; v_dispatched int; v_new_status text; v_buyer uuid;
  v_title text; v_msg text;
begin
  select i.end_user_id, i.stockist_id, i.status, i.token, e.company_name, i.customer_hint,
         i.customer_id
  into v_eu, v_st, v_status, v_token, v_company, v_hint,
       v_cust
  from inquiries i
  join stockists s on s.id = i.stockist_id
  left join end_users e on e.id = i.end_user_id
  where i.id = p_inquiry and s.user_id = auth.uid();
  if v_st is null then raise exception 'Not allowed'; end if;
  if v_status in ('completed','rejected') then
    raise exception 'This order is already closed';
  end if;
  v_buyer_label := coalesce(nullif(btrim(v_company), ''), nullif(btrim(v_hint), ''), 'Walk-in');

  insert into inquiry_items (inquiry_id, design_id, quantity)
  select p_inquiry, mc.design_id, mc.quantity
  from my_choices mc join designs d on d.id = mc.design_id
  where mc.end_user_id = v_eu and d.stockist_id = v_st
  on conflict (inquiry_id, design_id) do nothing;

  select array_agg((e->>'design_id')::uuid) into v_keep
  from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) e;
  v_keep := coalesce(v_keep, array[]::uuid[]);
  if exists (
    select 1 from unnest(v_keep) did
    left join designs d on d.id = did
    where d.id is null or d.stockist_id <> v_st) then
    raise exception 'A design does not belong to you';
  end if;

  if p_prune then
    delete from inquiry_items
    where inquiry_id = p_inquiry and not (design_id = any(v_keep));
  end if;

  select coalesce(sum(greatest((e->>'dispatch')::int,0)),0) into v_total
  from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) e;
  if v_total > 0 then
    insert into dispatch_notes (inquiry_id, stockist_id, end_user_id, customer_id,
      invoice_no, vehicle_no, transporter, note, dispatched_on)
    values (p_inquiry, v_st, v_eu, v_cust,
      coalesce(p_invoice,''), coalesce(p_vehicle,''), coalesce(p_transporter,''),
      coalesce(p_note,''), coalesce(p_date, current_date))
    returning id, dispatch_no into v_note_id, v_dispatch_no;
  end if;

  for ln in select * from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) loop
    v_design := (ln->>'design_id')::uuid;
    v_disp   := coalesce((ln->>'dispatch')::int, 0);

    insert into inquiry_items (inquiry_id, design_id, quantity, dispatched_qty)
    values (p_inquiry, v_design, greatest(v_disp,0), 0)
    on conflict (inquiry_id, design_id) do nothing;

    if v_disp > 0 then
      insert into dispatches (design_id, stockist_id, quantity_dispatched, buyer_name, notes, dispatch_note_id)
      values (v_design, v_st, v_disp, v_buyer_label, 'Order ' || v_token, v_note_id);

      if p_reduce_stock then
        perform _lot_take(v_design, v_disp);   -- was: update designs set box_quantity = greatest(0, … - v_disp)
      end if;

      update inquiry_items set dispatched_qty = dispatched_qty + v_disp
      where inquiry_id = p_inquiry and design_id = v_design;
    end if;
  end loop;

  select coalesce(sum(greatest(quantity - dispatched_qty, 0)),0),
         coalesce(sum(dispatched_qty),0)
  into v_outstanding, v_dispatched
  from inquiry_items where inquiry_id = p_inquiry;

  if v_dispatched > 0 and (v_outstanding = 0 or p_close) then
    v_new_status := 'completed';
    update inquiry_items set held_qty = 0 where inquiry_id = p_inquiry;
    update inquiries set status='completed', completed_at=now(), updated_at=now() where id = p_inquiry;
  elsif v_dispatched > 0 then
    v_new_status := 'dispatching';
    update inquiries set status='dispatching', updated_at=now() where id = p_inquiry;
  else
    v_new_status := v_status;
    update inquiries set updated_at=now() where id = p_inquiry;
  end if;

  if v_total > 0 then
    select user_id into v_buyer from end_users where id = v_eu;
    if v_buyer is not null then
      if v_new_status = 'completed' and v_outstanding > 0 then
        v_title := 'Order closed';
        v_msg := v_token || ': ' || v_total || ' boxes dispatched, ' || v_outstanding ||
                 ' not included — re-order if you still need them.';
      elsif v_new_status = 'completed' then
        v_title := 'Order completed';
        v_msg := v_token || ': ' || v_total || ' boxes dispatched.';
      else
        v_title := 'Dispatch update';
        v_msg := v_token || ': ' || v_total || ' boxes dispatched, ' || v_outstanding ||
                 ' still reserved & coming.';
      end if;
      perform _notify(v_buyer, 'dispatch', v_title, v_msg,
        jsonb_build_object('token', v_token, 'dispatch_no', v_dispatch_no));
    end if;
  end if;

  return jsonb_build_object('status', v_new_status,
                            'outstanding', v_outstanding,
                            'dispatched', v_dispatched,
                            'dispatch_no', v_dispatch_no,
                            'note_id', v_note_id);
end $function$;

-- library_merge_masters — merging two library rows folds their holdings. Move the dropped holding's
-- LOTS onto the keeper (by batch+location) instead of adding box_quantity.
create or replace function public.library_merge_masters(p_keep_id uuid, p_drop_id uuid)
 returns uuid
 language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare
  v_stk uuid;
  v_keep_print uuid; v_drop_print uuid;
  v_keep_size text; v_drop_size text;
  v_keep_img text; v_drop_img text;
  v_keep_surf text; v_drop_surf text;
  rec record; v_keep_hold uuid; lt record;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can merge the library'; end if;
  if p_keep_id = p_drop_id then raise exception 'Cannot merge a design into itself'; end if;

  select l.print_id, p.size, nullif(btrim(coalesce(p.image_url,'')),''), l.surface_type
    into v_keep_print, v_keep_size, v_keep_img, v_keep_surf
  from stockist_library l join print_master p on p.id = l.print_id
  where l.id = p_keep_id and l.stockist_id = v_stk;
  select l.print_id, p.size, nullif(btrim(coalesce(p.image_url,'')),''), l.surface_type
    into v_drop_print, v_drop_size, v_drop_img, v_drop_surf
  from stockist_library l join print_master p on p.id = l.print_id
  where l.id = p_drop_id and l.stockist_id = v_stk;
  if v_keep_size is null or v_drop_size is null then
    raise exception 'Both designs must be yours';
  end if;
  if v_keep_size <> v_drop_size then
    raise exception 'Only same-size designs can be merged (% vs %)', v_keep_size, v_drop_size;
  end if;
  if v_keep_surf <> v_drop_surf then
    raise exception 'Cannot merge across surfaces (% vs %) — they are different products',
      v_keep_surf, v_drop_surf;
  end if;

  update stockist_library_brand_names d
     set library_id = p_keep_id
   where d.library_id = p_drop_id
     and not exists (select 1 from stockist_library_brand_names k
                     where k.library_id = p_keep_id and k.brand_id = d.brand_id);
  delete from stockist_library_brand_names where library_id = p_drop_id;

  insert into library_dna (library_id, value_id)
    select p_keep_id, d.value_id
    from library_dna d
    where d.library_id = p_drop_id
      and not exists (select 1 from library_dna k
                      where k.library_id = p_keep_id and k.value_id = d.value_id);

  update catalog_designs c set library_id = p_keep_id
   where c.library_id = p_drop_id
     and not exists (select 1 from catalog_designs k
                     where k.catalog_id = c.catalog_id and k.library_id = p_keep_id);

  for rec in select * from designs where library_id = p_drop_id and stockist_id = v_stk loop
    select id into v_keep_hold from designs
     where library_id = p_keep_id and stockist_id = v_stk
       and quality = rec.quality and surface_type = rec.surface_type;
    if v_keep_hold is null then
      update designs set library_id = p_keep_id, updated_at = now() where id = rec.id;
    else
      -- move the dropped holding's LOTS onto the keeper (was: box_quantity += rec.box_quantity)
      for lt in select batch, location_id, box_quantity from stock_lots where holding_id = rec.id loop
        perform _lot_add(v_keep_hold, lt.batch, lt.location_id, lt.box_quantity);
      end loop;
      update stock_in          set design_id = v_keep_hold where design_id = rec.id;
      update stock_adjustments set design_id = v_keep_hold where design_id = rec.id;
      update dispatches        set design_id = v_keep_hold where design_id = rec.id;
      update inquiry_items     set design_id = v_keep_hold where design_id = rec.id;
      delete from my_choices   where design_id = rec.id;
      delete from designs      where id = rec.id;   -- cascades the dropped holding's now-empty lots
    end if;
  end loop;

  if v_keep_img is null and v_drop_img is not null then
    update print_master set image_url = v_drop_img, updated_at = now() where id = v_keep_print;
  end if;

  delete from library_family_overrides where library_id = p_drop_id;
  delete from stockist_library where id = p_drop_id;
  return p_keep_id;
end $function$;

-- import_stock_batch — Excel import. 'add' mode already funnels through add_stock (converted above).
-- Its replace_keep/replace_all SET paths and the replace_all wipe now operate on lots.
create or replace function public.import_stock_batch(p_batch_id uuid, p_catalog_id uuid, p_brand_id uuid, p_pdf_filename text, p_rows jsonb, p_mode text DEFAULT 'add'::text, p_wipe_all_brands boolean DEFAULT false, p_wipe_brand_ids uuid[] DEFAULT NULL::uuid[], p_library_only boolean DEFAULT false, p_match_only boolean DEFAULT false)
 returns jsonb
 language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_stk uuid; v_prior jsonb; r jsonb; v_brand_name text;
  v_name text; v_size text; v_quality text; v_surface text; v_label text;
  v_tile text; v_qty int; v_image text;
  v_master_name text; v_aliases jsonb; v_skip_master boolean;
  v_master uuid; v_design uuid; v_hold_brand uuid; v_row_brand uuid;
  v_box uuid; v_pk uuid; v_alias_brand uuid; v_covers int := 0;
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
      v_master := library_map_resolve(v_size, v_master_name, v_aliases, v_surface, v_tile);
      if v_master is null then
        v_unmatched := v_unmatched + 1;
        v_unmatched_rows := v_unmatched_rows || jsonb_build_object(
          'name', v_name, 'size', v_size, 'surface', v_surface, 'quality', v_quality,
          'reason', 'No design matches this row.');
        continue;
      end if;
      select surface_type into v_surface from stockist_library where id = v_master;
    else
      v_surface := coalesce(v_surface, 'Special');
      v_master := library_map_upsert(v_size, v_master_name, v_aliases, v_surface, v_tile);
      v_masters := v_masters + 1;

      if not v_skip_master then
        perform _library_apply_identity(v_master, jsonb_build_object(
          'stock_type', r->>'stock_type',
          'tile_type', r->>'tile_type', 'pieces_per_box', r->>'pieces_per_box',
          'box_weight_kg', r->>'box_weight_kg', 'finish_label', r->>'finish_label'));

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

            if _dna_tag_import(v_master, v_attr_id, v_vals, coalesce(v_is_multi, false)) then
              v_dna_tagged := v_dna_tagged + 1;
            end if;
          end loop;
        end if;

        if v_master is not null then
          select id into v_pk from packings
           where library_id = v_master order by created_at limit 1;
          if v_pk is not null then
            for v_alias_brand in
              select nullif(a->>'brand_id','')::uuid from jsonb_array_elements(v_aliases) a
            loop
              if v_alias_brand is not null
                 and exists (select 1 from brands
                              where id = v_alias_brand and stockist_id = v_stk) then
                perform box_put_cover(v_pk, v_alias_brand);
                v_covers := v_covers + 1;
              end if;
            end loop;
          end if;
        end if;
      end if;
    end if;

    if not coalesce(p_library_only, false) and v_qty > 0 and v_master is not null then
      v_hold_brand := coalesce(v_row_brand, nullif(v_aliases->0->>'brand_id','')::uuid,
                               p_brand_id,
                               (select brand_id from stockist_library where id = v_master));

      v_box := _box_resolve(v_master, v_hold_brand, null);
      if v_box is null then
        v_unmatched := v_unmatched + 1;
        v_unmatched_rows := v_unmatched_rows || jsonb_build_object(
          'name', v_name, 'size', v_size, 'surface', v_surface, 'quality', v_quality,
          'reason', format('%s has no cover for this design — tick it on the design in your Design Library first.',
                           coalesce((select name from brands where id = v_hold_brand), 'That brand')));
        continue;
      end if;

      select id into v_design from designs
        where stockist_id = v_stk and box_id = v_box and quality = v_quality;

      if v_design is null then
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
          perform _lot_add(v_design, null, null, v_qty);   -- was: box_quantity += v_qty (2nd+ row of a replace batch)
          insert into stock_in (design_id, stockist_id, quantity_added, pdf_filename, size, quality, status)
            values (v_design, v_stk, v_qty, coalesce(p_pdf_filename,''), v_size, v_quality, 'approved');
        else
          select coalesce(box_quantity,0) into v_old from designs where id = v_design;
          -- was: box_quantity = v_qty (replace this holding to the sheet's number)
          delete from stock_lots where holding_id = v_design;
          if v_qty > 0 then perform _lot_add(v_design, null, null, v_qty); end if;
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
    -- was: update designs set box_quantity = 0 …  → delete those holdings' lots (trigger zeroes them)
    with targets as (
      select id from designs
       where stockist_id = v_stk and box_quantity <> 0 and not (id = any(v_touched))
         and (
           p_wipe_all_brands
           or (not p_wipe_all_brands and p_wipe_brand_ids is not null
               and brand_id = any(p_wipe_brand_ids))
           or (not p_wipe_all_brands and p_wipe_brand_ids is null
               and brand_id is not distinct from p_brand_id)
         )
    ), z as (
      delete from stock_lots where holding_id in (select id from targets)
    )
    select count(*) into v_zeroed from targets;
  end if;

  insert into import_batches (id, stockist_id, summary)
  values (p_batch_id, v_stk, jsonb_build_object(
    'masters', v_masters, 'created', v_created, 'updated', v_updated,
    'stock_rows', v_stock_rows, 'skipped', v_skipped, 'dna_tagged', v_dna_tagged,
    'covers', v_covers, 'zeroed', v_zeroed, 'mode', v_mode,
    'unmatched', v_unmatched, 'unmatched_rows', v_unmatched_rows));

  return jsonb_build_object('masters', v_masters, 'created', v_created,
    'updated', v_updated, 'stock_rows', v_stock_rows, 'skipped', v_skipped,
    'dna_tagged', v_dna_tagged, 'covers', v_covers, 'zeroed', v_zeroed, 'mode', v_mode,
    'unmatched', v_unmatched, 'unmatched_rows', v_unmatched_rows,
    'already_applied', false);
end $function$;
