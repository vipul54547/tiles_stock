-- Close an anon-reachable hole in two legacy stock RPCs.
--
-- add_stock(design, stockist_id, qty, ...) and dispatch_stock(design,
-- stockist_id, qty, ...) are SECURITY DEFINER, take the stockist id as a plain
-- argument, and perform NO ownership check. Postgres grants EXECUTE to PUBLIC
-- by default and Supabase's anon role inherits it, so with the published anon
-- key anyone could add or dispatch stock for ANY stockist.
--
-- They are dead: the only Dart that called them (StockService.addStock /
-- .dispatchStock) has zero callers. The live paths are add_inventory_batch,
-- dispatch_walkin and dispatch_inquiry, and the still-used adjust_stock is
-- correctly gated by `s.user_id = auth.uid()`.
--
-- Revoke rather than drop: reversible, and keeps the definition around in case
-- a caller is ever reintroduced (with a proper guard). Belt and braces: also
-- revoke from authenticated, since nothing legitimate calls these either.

revoke execute on function public.add_stock(uuid, uuid, integer, text, text, text)
  from anon, authenticated, public;

revoke execute on function public.dispatch_stock(uuid, uuid, integer, text, text)
  from anon, authenticated, public;
