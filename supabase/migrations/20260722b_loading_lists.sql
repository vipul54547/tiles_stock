-- 20260722b — 📋 LOADING LIST: the step between HOLD and DISPATCH.
--
-- The yard reality (DDPI 22 Jul): a truck arrives → the stockist prepares a LOADING LIST (what to
-- pull, from which batch, at what location, per truck) → the supervisor loads by that sheet, skipping
-- broken/mismatched boxes → only then is the actual dispatch recorded. So the loading list is its own
-- object, prepared BEFORE loading and recorded AFTER. (docs/LOT_LAYER_PLAN.md · Loading List)
--
-- A list is a DRAFT until it is dispatched. Its designs come from the party's booked order (already
-- named — no re-selection); each design's batches are typed inline (reusing the L3 lot entry). The
-- ordered qty is only the phone estimate, so loaded boxes may be MORE or LESS. Dispatch reuses the
-- existing per-lot record path (dispatch_inquiry / dispatch_walkin) — this layer only prepares.

-- ── tables ──────────────────────────────────────────────────────────────────────────────────────
create table if not exists public.loading_lists (
  id              uuid primary key default gen_random_uuid(),
  stockist_id     uuid not null references public.stockists(id) on delete cascade,
  customer_id     uuid references public.stockist_customers(id) on delete set null,
  inquiry_id      uuid references public.inquiries(id) on delete set null,  -- the booked order
  party_order_no  text not null default '',                                 -- buyer's own PO number
  truck_no        text not null default '',
  transporter     text not null default '',
  loading_date    date not null default current_date,
  note            text not null default '',
  status          text not null default 'draft',                            -- 'draft' | 'dispatched'
  dispatch_note_id uuid references public.dispatch_notes(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists loading_lists_stockist_idx
  on public.loading_lists (stockist_id, status, updated_at desc);

-- One line = one (design, batch) to pull. batch + location are SNAPSHOT off the lot so the printed
-- sheet survives the lot draining or being renamed; lot_id still points at the exact lot to take from.
create table if not exists public.loading_list_items (
  id              uuid primary key default gen_random_uuid(),
  loading_list_id uuid not null references public.loading_lists(id) on delete cascade,
  design_id       uuid not null references public.designs(id) on delete cascade,
  lot_id          uuid references public.stock_lots(id) on delete set null,
  batch           text not null default '',
  location        text not null default '',
  boxes           integer not null default 0 check (boxes >= 0),
  created_at      timestamptz not null default now()
);
create index if not exists loading_list_items_list_idx
  on public.loading_list_items (loading_list_id);

alter table public.loading_lists       enable row level security;
alter table public.loading_list_items  enable row level security;
-- RPC-only: no direct policies, all access through the security-definer functions below.
revoke all on public.loading_lists      from anon, authenticated;
revoke all on public.loading_list_items from anon, authenticated;

-- ── create / update a draft (replaces its items) ─────────────────────────────────────────────────
create or replace function public.loading_list_upsert(
  p_id uuid, p_customer uuid, p_inquiry uuid, p_party_order_no text,
  p_truck text, p_transporter text, p_date date, p_note text, p_items jsonb)
 returns uuid
 language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_st uuid; v_id uuid; it jsonb;
begin
  select id into v_st from stockists where user_id = auth.uid();
  if v_st is null then raise exception 'Only stockists'; end if;

  if p_customer is not null and not exists (
    select 1 from stockist_customers where id = p_customer and stockist_id = v_st) then
    raise exception 'That customer is not yours';
  end if;
  if p_inquiry is not null and not exists (
    select 1 from inquiries where id = p_inquiry and stockist_id = v_st) then
    raise exception 'That order is not yours';
  end if;

  if p_id is null then
    insert into loading_lists (stockist_id, customer_id, inquiry_id, party_order_no,
      truck_no, transporter, loading_date, note)
    values (v_st, p_customer, p_inquiry, coalesce(p_party_order_no,''),
      coalesce(p_truck,''), coalesce(p_transporter,''), coalesce(p_date, current_date),
      coalesce(p_note,''))
    returning id into v_id;
  else
    update loading_lists set
      customer_id = p_customer, inquiry_id = p_inquiry,
      party_order_no = coalesce(p_party_order_no,''), truck_no = coalesce(p_truck,''),
      transporter = coalesce(p_transporter,''), loading_date = coalesce(p_date, current_date),
      note = coalesce(p_note,''), updated_at = now()
    where id = p_id and stockist_id = v_st and status = 'draft'
    returning id into v_id;
    if v_id is null then raise exception 'That loading list is not yours, or already dispatched'; end if;
  end if;

  delete from loading_list_items where loading_list_id = v_id;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    -- Guard every line to the caller's own holdings.
    if not exists (select 1 from designs d where d.id = (it->>'design_id')::uuid
                    and d.stockist_id = v_st) then
      raise exception 'A design on this list is not yours';
    end if;
    insert into loading_list_items (loading_list_id, design_id, lot_id, batch, location, boxes)
    values (v_id, (it->>'design_id')::uuid, nullif(it->>'lot_id','')::uuid,
      coalesce(it->>'batch',''), coalesce(it->>'location',''),
      greatest(coalesce((it->>'boxes')::int, 0), 0));
  end loop;

  return v_id;
end $function$;

-- ── the stockist's lists (drafts first) ──────────────────────────────────────────────────────────
create or replace function public.my_loading_lists()
 returns jsonb language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', ll.id, 'status', ll.status,
      'customer', c.name, 'order_token', i.token,
      'party_order_no', ll.party_order_no, 'truck_no', ll.truck_no,
      'loading_date', ll.loading_date, 'updated_at', ll.updated_at,
      'lines', (select count(*) from loading_list_items x where x.loading_list_id = ll.id),
      'boxes', (select coalesce(sum(x.boxes),0) from loading_list_items x where x.loading_list_id = ll.id)
    ) order by (ll.status <> 'draft'), ll.updated_at desc), '[]'::jsonb)
  from loading_lists ll
  join stockists s on s.id = ll.stockist_id
  left join stockist_customers c on c.id = ll.customer_id
  left join inquiries i on i.id = ll.inquiry_id
  where s.user_id = auth.uid();
$function$;

-- ── full detail for reopening a draft ────────────────────────────────────────────────────────────
create or replace function public.loading_list_get(p_id uuid)
 returns jsonb language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  select jsonb_build_object(
    'id', ll.id, 'status', ll.status, 'customer_id', ll.customer_id,
    'inquiry_id', ll.inquiry_id, 'party_order_no', ll.party_order_no,
    'truck_no', ll.truck_no, 'transporter', ll.transporter,
    'loading_date', ll.loading_date, 'note', ll.note,
    'dispatch_note_id', ll.dispatch_note_id,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'design_id', it.design_id, 'lot_id', it.lot_id,
        -- prefer the lot's live batch/location; fall back to the saved snapshot.
        'batch', coalesce(nullif(lot.batch,''), it.batch),
        'location', coalesce(loc.code, it.location),
        'boxes', it.boxes) order by it.created_at)
      from loading_list_items it
      left join stock_lots lot on lot.id = it.lot_id
      left join stock_locations loc on loc.id = lot.location_id
      where it.loading_list_id = ll.id), '[]'::jsonb))
  from loading_lists ll
  join stockists s on s.id = ll.stockist_id
  where ll.id = p_id and s.user_id = auth.uid();
$function$;

-- ── delete a draft ───────────────────────────────────────────────────────────────────────────────
create or replace function public.loading_list_delete(p_id uuid)
 returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_st uuid;
begin
  select id into v_st from stockists where user_id = auth.uid();
  delete from loading_lists where id = p_id and stockist_id = v_st and status = 'draft';
end $function$;

-- ── mark a list dispatched once its dispatch note is recorded ────────────────────────────────────
create or replace function public.loading_list_mark_dispatched(p_id uuid, p_note_id uuid)
 returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_st uuid;
begin
  select id into v_st from stockists where user_id = auth.uid();
  update loading_lists set status = 'dispatched', dispatch_note_id = p_note_id, updated_at = now()
  where id = p_id and stockist_id = v_st;
end $function$;

revoke all on function public.loading_list_upsert(uuid,uuid,uuid,text,text,text,date,text,jsonb) from public, anon;
revoke all on function public.my_loading_lists() from public, anon;
revoke all on function public.loading_list_get(uuid) from public, anon;
revoke all on function public.loading_list_delete(uuid) from public, anon;
revoke all on function public.loading_list_mark_dispatched(uuid,uuid) from public, anon;
grant execute on function public.loading_list_upsert(uuid,uuid,uuid,text,text,text,date,text,jsonb) to authenticated;
grant execute on function public.my_loading_lists() to authenticated;
grant execute on function public.loading_list_get(uuid) to authenticated;
grant execute on function public.loading_list_delete(uuid) to authenticated;
grant execute on function public.loading_list_mark_dispatched(uuid,uuid) to authenticated;
