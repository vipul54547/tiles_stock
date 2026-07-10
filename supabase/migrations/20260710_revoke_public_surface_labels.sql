-- Retire the render-time surface resolver's RPC.
--
-- public_surface_labels() returned each stockist's own word per canonical
-- surface, keyed by sequential_id, so buyer cards could resolve "Sugar" into
-- "Raindrops (Sugar)" at render time. That model is SUPERSEDED: every stock row
-- now carries surface_label (the stockist's word) alongside surface_type (the
-- admin canonical), and cards format it via TileDesign.surfaceCardLabel.
-- See project_per_brand_surface_mode.
--
-- Its only caller was lib/utils/surface_labels.dart, deleted in this change.
-- The RPC is now unreachable from the app but still carries EXECUTE for PUBLIC
-- (hence anon, via the published publishable key).
--
-- Revoke rather than drop, matching 20260710_revoke_legacy_stock_rpcs.sql:
-- reversible, and the definition stays for reference. service_role keeps
-- EXECUTE, as it does there.
--
-- NOT touched: my_surface_labels(), which looks similar but is very much alive
-- -- getMySurfaceLabels() feeds the stock-list "Edit conditions" chips, which
-- label with the stockist's word and store the canonical.

revoke execute on function public.public_surface_labels()
  from anon, authenticated, public;
