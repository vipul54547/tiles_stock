-- 20260722a — 🧱 LOT LAYER, L3 (dispatch UI): batch is picked AT ENTRY, not after.
--
-- The dispatch/loading list is the stockist's picking instruction to a supervisor: for each design,
-- WHICH batch, at WHAT location, how many boxes. So the batch is chosen in the entry bar the moment
-- the design is added — one line per (design, batch) — and it prints on the list. To offer batches
-- without a round-trip per design, the screen preloads every one of the stockist's lots in a single
-- call. (docs/LOT_LAYER_PLAN.md · DDPI dispatch redesign 22 Jul)
--
-- Twin of my_holding_lots (one holding) → all of them at once. Only holdings with stock; only real
-- lots (a stockist who tracks neither batch nor location has one NULL lot, returned as such so the
-- caller sees "one lot, nothing to pick").

create or replace function public.my_stock_lots()
 returns jsonb language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
             'holding_id', l.holding_id,
             'lot_id',     l.id,
             'batch',      l.batch,
             'location',   loc.code,
             'box_quantity', l.box_quantity)
           order by l.holding_id, l.created_at), '[]'::jsonb)
  from stock_lots l
  join designs d   on d.id = l.holding_id
  join stockists s on s.id = d.stockist_id
  left join stock_locations loc on loc.id = l.location_id
  where s.user_id = auth.uid()
    and l.box_quantity > 0;
$function$;

revoke all on function public.my_stock_lots() from public, anon;
grant execute on function public.my_stock_lots() to authenticated;
