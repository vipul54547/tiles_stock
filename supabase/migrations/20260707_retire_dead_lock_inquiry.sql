-- Retire the dead "Confirm" path. lock_inquiry / unlock_inquiry are not called
-- by the app — the stockist accept/hold flow uses hold_order / unhold_order,
-- which (as of 20260707_order_flow_simplify_gates_hold_dispatch) also materialize
-- the buyer's basket into inquiry_items. Removing the duplicate leaves a single
-- accept/hold path (no "two way"). Applied to buxjebeeiwyrsakeucyk 2026-07-07.
drop function if exists public.unlock_inquiry(uuid);
drop function if exists public.lock_inquiry(uuid, integer);
