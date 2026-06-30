-- ── Order/Dispatch redesign · Phase A — data model ───────────────────────────
-- One inquiries table for all orders. end_user_id becomes optional (web/walk-in/
-- stockist orders have no app user). Add a stockist-editable free-text customer
-- hint (no profile, no stored contact) and a per-inquiry connection code
-- C-<unique><DDMM> shared in WhatsApp. (project_dispatch_order_redesign)

-- 1. end_user_id optional (app order has it; web/stockist orders don't).
alter table public.inquiries alter column end_user_id drop not null;

-- 2. Free-text customer hint the stockist writes (who the order is for).
alter table public.inquiries add column if not exists customer_hint text;

-- 3. Connection code: C- + a globally-unique sequence number + DDMM (date only,
--    no year/time). Sequence guarantees uniqueness; DDMM is informational.
create sequence if not exists public.connection_code_seq start 1001;

alter table public.inquiries
  add column if not exists connection_code text;

-- Backfill existing rows using each order's own creation date for the DDMM.
update public.inquiries
set connection_code = 'C-' || nextval('public.connection_code_seq')
                          || to_char(coalesce(created_at, now()), 'DDMM')
where connection_code is null;

-- New rows auto-generate it (DDMM from the insert moment).
alter table public.inquiries
  alter column connection_code
  set default ('C-' || nextval('public.connection_code_seq') || to_char(now(), 'DDMM'));

-- Enforce uniqueness (the sequence already makes it unique; this guards it).
create unique index if not exists inquiries_connection_code_uidx
  on public.inquiries (connection_code);

-- 4. Stockist edits the customer hint on their own order. SECURITY DEFINER +
--    ownership check (bypasses RLS safely).
create or replace function public.set_inquiry_hint(p_id uuid, p_hint text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_ok int;
begin
  update public.inquiries i
  set customer_hint = nullif(btrim(coalesce(p_hint, '')), ''),
      updated_at = now()
  where i.id = p_id
    and exists (select 1 from public.stockists s
                where s.id = i.stockist_id and s.user_id = auth.uid());
  get diagnostics v_ok = row_count;
  if v_ok = 0 then raise exception 'Order not found'; end if;
end;
$function$;
