-- Buyer's basket vs. reality: what they want, and what is actually free NOW.
--
-- A buyer can add designs to My Choice and send the order weeks later.
-- send_order_to_stockist copies the basket straight into inquiry_items with NO
-- stock check, so a stale basket becomes a wrong inquiry.
--
-- This RPC gives the buyer app the truth for each basket line so it can show
-- "You want 50 · Available 20" in the basket, and gate the Send button.
--
-- Reads `designs` DIRECTLY, not market_designs, ON PURPOSE: a design with zero
-- free stock drops OUT of market_designs (its WHERE filters free > 0), so a
-- basket line for it would silently VANISH instead of saying "out of stock".
-- The whole point is to report those lines, so the source must be the base table.
--
-- free stock = max(0, P - C - H)  (the F_Stock model)
--   P = box_quantity, C = control_quantity (hidden reserve),
--   H = held_of(id) = boxes booked by other buyers' locked/dispatching orders.
--
-- status:
--   'ok'      wanted <= available
--   'reduced' 0 < available < wanted
--   'out'     available = 0
-- (No 'gone': my_choices has an FK to designs, so a deleted design takes its
-- basket rows with it — that state is not reachable.)
--
-- p_stockist_key null = every line in the basket (one call to paint the whole
-- screen); pass a key to check just the group being sent. The key is
-- stockists.sequential_id — the same masked key send_order_to_stockist takes.
--
-- Naming: buyer-facing RPCs in this schema are unprefixed (send_order_to_stockist,
-- reorder_remaining, fulfill_choice). admin_*/my_*/public_* are admin / signed-in
-- stockist / anonymous respectively, and none of those is this audience.
-- (docs/BUYER_ORDER_AVAILABILITY_PLAN.md)

CREATE OR REPLACE FUNCTION public.choices_availability(p_stockist_key text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'design_id',     d.id,
      'stockist_key',  s.sequential_id,
      'name',          d.name,
      'size',          d.size,
      'quality',       d.quality,
      'surface_type',  d.surface_type,
      'surface_label', d.surface_label,
      'image_url',     coalesce(lib.image_url, ''),
      'wanted',        mc.quantity,
      'available',     f.free,
      'status',        case
                         when f.free = 0           then 'out'
                         when f.free < mc.quantity then 'reduced'
                         else 'ok'
                       end
    ) order by d.name), '[]'::jsonb)
  from my_choices mc
  join end_users e on e.id = mc.end_user_id
  join designs   d on d.id = mc.design_id
  join stockists s on s.id = d.stockist_id
  left join stockist_library lib on lib.id = d.library_id
  cross join lateral (
    select greatest(0, d.box_quantity - d.control_quantity - held_of(d.id))::int as free
  ) f
  where e.user_id = auth.uid()
    and (p_stockist_key is null or s.sequential_id = p_stockist_key);
$function$;

-- Buyers are signed in (guests are gated out of ordering). Revoke from PUBLIC,
-- not just anon — a PUBLIC grant is inherited by every role.
REVOKE ALL ON FUNCTION public.choices_availability(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.choices_availability(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.choices_availability(text) TO authenticated, service_role;
