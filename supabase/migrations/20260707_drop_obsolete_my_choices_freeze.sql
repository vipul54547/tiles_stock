-- Remove the obsolete my_choices freeze. Under the old model my_choices WAS the
-- order, so a locked order froze the basket. Under the My Choice ↔ Order split,
-- my_choices is a pure pre-send basket (draft only); a locked/dispatching order's
-- lines live in inquiry_items and the basket was cleared on Send. So freezing
-- my_choices now just blocks the buyer from placing a NEW order with a stockist
-- they already have a locked/dispatching order with (reported "add shows empty").
drop trigger if exists zz_my_choices_freeze on public.my_choices;
drop function if exists public.trg_my_choices_freeze();
