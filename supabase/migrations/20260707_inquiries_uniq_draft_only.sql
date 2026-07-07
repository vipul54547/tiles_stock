-- Under the My Choice ↔ Order split a buyer can have several orders with one
-- stockist over time (an in-flight sent/dispatching one, past completed ones) AND
-- still start a NEW basket. The old partial unique covered all active statuses
-- (draft/sent/confirmed/locked/dispatching), so an in-flight order blocked a fresh
-- draft (the "can't add designs / My Choice empty" bug). Narrow it to one DRAFT
-- (basket) per (buyer, stockist); every other order state is unconstrained.
drop index if exists public.inquiries_active_uniq;
create unique index inquiries_active_uniq
  on public.inquiries (end_user_id, stockist_id)
  where status = 'draft';
