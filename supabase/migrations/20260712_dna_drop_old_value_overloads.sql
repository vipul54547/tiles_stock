-- Phase 1 added parent-value params to admin_dna_add_value / admin_dna_update_value
-- as NEW signatures (different arity ⇒ CREATE OR REPLACE left the old ones behind).
-- Drop the superseded overloads so a 2-/3-arg call is never ambiguous. The app
-- always sends the parent-value param by name, so it is unaffected.
drop function if exists admin_dna_add_value(uuid, text);
drop function if exists admin_dna_update_value(uuid, text, boolean);
