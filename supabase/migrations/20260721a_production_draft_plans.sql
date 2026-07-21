-- 20260721a — 📝 PRODUCTION PLANNING gets SAVEABLE DRAFTS.
--
-- A plan is named + dated when he leaves "Choose orders", edited on the Plan page, and becomes a
-- RUN only when taken into production. Until then it is a DRAFT he can close the app and return to.
-- (docs/PRODUCTION_REDESIGN_PLAN.md — Phase 1, sub-step 2)
--
-- 🔑 A draft is NOT a run. It holds no output, touches no stock, allocates nobody. It is only the
-- work-in-progress of a plan: which orders, which lines are ticked (and for how many boxes), and any
-- per-cover "Make" override he typed. `production_take_into_run` is still the only thing that creates
-- a run; the app deletes the draft once that succeeds.
--
-- ⚠️ **Full fidelity** (his choice): the ticks (with per-line quantity — the same home sub-step 4's
-- partial quantity will use) and the Make overrides are stored, so a reopened draft resumes exactly.
-- On reopen the app intersects with LIVE demand, dropping any line/box that has since gone — the
-- draft never resurrects stale demand.

create table if not exists public.production_plans (
  id          uuid primary key default gen_random_uuid(),
  stockist_id uuid not null references public.stockists(id) on delete cascade,
  name        text not null,
  plan_date   date not null default current_date,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists public.production_plan_orders (
  plan_id  uuid not null references public.production_plans(id) on delete cascade,
  order_id uuid not null references public.book_orders(id) on delete cascade,
  primary key (plan_id, order_id)
);

create table if not exists public.production_plan_lines (
  plan_id            uuid not null references public.production_plans(id) on delete cascade,
  book_order_line_id uuid not null references public.book_order_lines(id) on delete cascade,
  planned_boxes      integer not null default 0 check (planned_boxes >= 0),
  primary key (plan_id, book_order_line_id)
);

create table if not exists public.production_plan_makes (
  plan_id      uuid not null references public.production_plans(id) on delete cascade,
  box_id       uuid not null references public.boxes(id) on delete cascade,
  target_boxes integer not null default 0 check (target_boxes >= 0),
  primary key (plan_id, box_id)
);

create index if not exists production_plans_stockist_idx
  on public.production_plans (stockist_id, updated_at desc);

alter table public.production_plans       enable row level security;
alter table public.production_plan_orders enable row level security;
alter table public.production_plan_lines  enable row level security;
alter table public.production_plan_makes  enable row level security;
revoke all on public.production_plans, public.production_plan_orders,
              public.production_plan_lines, public.production_plan_makes
  from anon, authenticated;

comment on table public.production_plans is
  'A saveable production-planning DRAFT (name + date). Not a run: holds no output, touches no stock. '
  'Deleted when taken into production.';

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- CREATE — name the draft, remember the picked orders, and seed the default ticks.
-- ════════════════════════════════════════════════════════════════════════════════════════════
create or replace function public.production_plan_create(
  p_name text, p_date date, p_order_ids uuid[])
 returns uuid
 language plpgsql security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_stk uuid; v_plan uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if coalesce(array_length(p_order_ids, 1), 0) = 0 then
    raise exception 'Pick at least one order to plan.';
  end if;

  insert into production_plans (stockist_id, name, plan_date)
  values (v_stk,
          coalesce(nullif(btrim(coalesce(p_name, '')), ''),
                   'Plan ' || to_char(coalesce(p_date, current_date), 'DD/MM')),
          coalesce(p_date, current_date))
  returning id into v_plan;

  -- Only the caller's own orders that are still open for planning.
  insert into production_plan_orders (plan_id, order_id)
  select v_plan, o.id
    from book_orders o
   where o.id = any(p_order_ids) and o.stockist_id = v_stk
     and o.status = 'open' and o.slice is null;

  -- Default ticks: every line of those orders that still has boxes left, at its remaining quantity.
  insert into production_plan_lines (plan_id, book_order_line_id, planned_boxes)
  select v_plan, l.id, greatest(l.quantity - l.produced_qty, 0)
    from book_order_lines l
    join production_plan_orders po on po.order_id = l.order_id and po.plan_id = v_plan
   where greatest(l.quantity - l.produced_qty, 0) > 0;

  return v_plan;
end $function$;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- SAVE — replace the draft's picked orders / ticks / makes wholesale (the app autosaves on change).
-- Every id is filtered to the caller's own, so a bad payload cannot smuggle in someone else's row.
-- ════════════════════════════════════════════════════════════════════════════════════════════
create or replace function public.production_plan_save(
  p_id uuid, p_order_ids uuid[], p_lines jsonb, p_makes jsonb)
 returns void
 language plpgsql security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_stk uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if not exists (select 1 from production_plans where id = p_id and stockist_id = v_stk) then
    raise exception 'That plan is not yours';
  end if;

  delete from production_plan_orders where plan_id = p_id;
  insert into production_plan_orders (plan_id, order_id)
  select p_id, o.id from book_orders o
   where o.id = any(coalesce(p_order_ids, '{}')) and o.stockist_id = v_stk;

  delete from production_plan_lines where plan_id = p_id;
  insert into production_plan_lines (plan_id, book_order_line_id, planned_boxes)
  select p_id, (e->>'line_id')::uuid, greatest(coalesce((e->>'planned_boxes')::int, 0), 0)
    from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e
   where exists (select 1 from book_order_lines l join book_orders o on o.id = l.order_id
                  where l.id = (e->>'line_id')::uuid and o.stockist_id = v_stk);

  delete from production_plan_makes where plan_id = p_id;
  insert into production_plan_makes (plan_id, box_id, target_boxes)
  select p_id, (e->>'box_id')::uuid, greatest(coalesce((e->>'target_boxes')::int, 0), 0)
    from jsonb_array_elements(coalesce(p_makes, '[]'::jsonb)) e
   where exists (select 1 from boxes bx join packings pk on pk.id = bx.packing_id
                  join stockist_library lib on lib.id = pk.library_id
                  where bx.id = (e->>'box_id')::uuid and lib.stockist_id = v_stk);

  update production_plans set updated_at = now() where id = p_id;
end $function$;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- LIST / LOAD / DELETE
-- ════════════════════════════════════════════════════════════════════════════════════════════
create or replace function public.my_production_plans()
 returns jsonb language sql stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(row order by row->>'updated_at' desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', p.id, 'name', p.name, 'plan_date', p.plan_date,
      'created_at', p.created_at, 'updated_at', p.updated_at,
      'order_count', (select count(*) from production_plan_orders o where o.plan_id = p.id),
      'box_count', (select coalesce(sum(pl.planned_boxes), 0)
                      from production_plan_lines pl where pl.plan_id = p.id)
    ) as row
    from production_plans p
    where p.stockist_id in (select id from stockists where user_id = auth.uid())
  ) t;
$function$;

create or replace function public.production_plan_load(p_id uuid)
 returns jsonb language sql stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  select jsonb_build_object(
    'id', p.id, 'name', p.name, 'plan_date', p.plan_date,
    'order_ids', coalesce((select jsonb_agg(o.order_id)
                             from production_plan_orders o where o.plan_id = p.id), '[]'::jsonb),
    'lines', coalesce((select jsonb_agg(jsonb_build_object(
                          'line_id', pl.book_order_line_id, 'planned_boxes', pl.planned_boxes))
                         from production_plan_lines pl where pl.plan_id = p.id), '[]'::jsonb),
    'makes', coalesce((select jsonb_agg(jsonb_build_object(
                          'box_id', pm.box_id, 'target_boxes', pm.target_boxes))
                         from production_plan_makes pm where pm.plan_id = p.id), '[]'::jsonb))
    from production_plans p
   where p.id = p_id
     and p.stockist_id in (select id from stockists where user_id = auth.uid());
$function$;

create or replace function public.production_plan_delete(p_id uuid)
 returns void language plpgsql security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_stk uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  delete from production_plans where id = p_id and stockist_id = v_stk;
end $function$;

revoke all on function public.production_plan_create(text, date, uuid[]) from public, anon;
revoke all on function public.production_plan_save(uuid, uuid[], jsonb, jsonb) from public, anon;
revoke all on function public.my_production_plans() from public, anon;
revoke all on function public.production_plan_load(uuid) from public, anon;
revoke all on function public.production_plan_delete(uuid) from public, anon;
grant execute on function public.production_plan_create(text, date, uuid[]) to authenticated;
grant execute on function public.production_plan_save(uuid, uuid[], jsonb, jsonb) to authenticated;
grant execute on function public.my_production_plans() to authenticated;
grant execute on function public.production_plan_load(uuid) to authenticated;
grant execute on function public.production_plan_delete(uuid) to authenticated;
