-- The buyer app was showing stock that is already booked by someone else.
--
-- F_Stock model: free stock = max(0, P - C - H)
--   P = box_quantity, C = control_quantity (hidden reserve), H = held (booked by
--   other buyers' locked/dispatching orders, via held_of()).
--
-- public_catalog (the /s/ link) already computed this correctly:
--   greatest(0, box_quantity - control_quantity - held_of(id))
--
-- market_designs (the buyer APP's marketplace) subtracted control but NOT held:
--   GREATEST(0, box_quantity - control_quantity)
--
-- So a buyer browsing the app could see 100 boxes when 80 were already held for
-- another buyer's order, put 100 in their basket, and send an inquiry for stock
-- that was never available. The wrong inquiry starts at SELECTION time, not at
-- send time -- so the gate at Send (choices_availability, next commit) is not
-- enough on its own. Fix the number the buyer chooses against.
--
-- Same column NAME and type, so no Flutter change: TileDesign.boxQuantity keeps
-- its meaning, "boxes the buyer can actually ask for".
--
-- CREATE OR REPLACE VIEW (not DROP + CREATE): it preserves the anon/authenticated
-- grants and the view's definer-rights behaviour, which is the intentional
-- login-free public read path. (project_fstock_model, project_supabase_security_advisor)
--
-- Consequence, accepted: a design whose stock is FULLY held by one order now has
-- F = 0 and drops out of the marketplace for everyone else. Correct -- there is
-- nothing free to sell -- and public_catalog already behaves this way.
--
-- Perf: held_of() is a per-row lookup on inquiry_items, but idx_inquiry_items_design
-- on (design_id) already exists, and held_of is STABLE. Fine at current size.

CREATE OR REPLACE VIEW public.market_designs AS
 SELECT d.id,
    d.name,
    d.size,
    d.surface_type,
    d.quality,
    lib.colour,
    effective_stock_type(lib.stock_type, d.quality) AS stock_type,
    GREATEST(0, d.box_quantity - d.control_quantity - held_of(d.id)) AS box_quantity,
    lib.pieces_per_box,
    lib.box_weight_kg::numeric(8,2) AS box_weight_kg,
    lib.thickness_mm::numeric(6,2) AS thickness_mm,
        CASE
            WHEN NULLIF(btrim(COALESCE(lib.image_url, ''::text)), ''::text) IS NOT NULL THEN ARRAY[lib.image_url]
            ELSE '{}'::text[]
        END AS face_image_urls,
    d.status,
    d.created_at,
    d.updated_at,
    lib.finish_label,
    lib.tile_type,
    NULL::uuid AS catalog_id,
    s.priority AS stockist_priority,
    s.sequential_id AS stockist_key,
    s.name AS stockist_display_name,
    s.city AS stockist_city,
    br.name AS brand_name,
    d.library_id,
    _family_effective_key(d.library_id) AS family_key,
    d.surface_label
   FROM designs d
     JOIN stockists s ON s.id = d.stockist_id
     LEFT JOIN stockist_library lib ON lib.id = d.library_id
     LEFT JOIN brands br ON br.id = lib.brand_id
  WHERE s.is_active = true
    AND s.is_listed = true
    AND d.status <> 'out_of_stock'::text
    AND (d.box_quantity - d.control_quantity - held_of(d.id)) > 0
    AND (EXISTS ( SELECT 1
           FROM catalog_designs cd
             JOIN stock_catalogs c ON c.id = cd.catalog_id
          WHERE cd.library_id = d.library_id
            AND c.stockist_id = d.stockist_id
            AND c.visibility = 'public'::text
            AND c.show_in_marketplace = true
            AND c.is_active = true));
