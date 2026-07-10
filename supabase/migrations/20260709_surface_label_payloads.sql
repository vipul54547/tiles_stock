-- Expose surface_label to buyer/stockist payloads: the market_designs view, and
-- my_stock / my_library RPCs. (project_per_brand_surface_mode)

create or replace view public.market_designs as
 SELECT d.id, d.name, d.size, d.surface_type, d.quality, lib.colour,
    effective_stock_type(lib.stock_type, d.quality) AS stock_type,
    GREATEST(0, (d.box_quantity - d.control_quantity)) AS box_quantity,
    lib.pieces_per_box, (lib.box_weight_kg)::numeric(8,2) AS box_weight_kg,
    (lib.thickness_mm)::numeric(6,2) AS thickness_mm,
    CASE WHEN (NULLIF(btrim(COALESCE(lib.image_url, ''::text)), ''::text) IS NOT NULL)
         THEN ARRAY[lib.image_url] ELSE '{}'::text[] END AS face_image_urls,
    d.status, d.created_at, d.updated_at, lib.finish_label, lib.tile_type,
    NULL::uuid AS catalog_id, s.priority AS stockist_priority,
    s.sequential_id AS stockist_key, s.name AS stockist_display_name,
    s.city AS stockist_city, br.name AS brand_name, d.library_id,
    _family_effective_key(d.library_id) AS family_key,
    d.surface_label
   FROM (((designs d
     JOIN stockists s ON ((s.id = d.stockist_id)))
     LEFT JOIN stockist_library lib ON ((lib.id = d.library_id)))
     LEFT JOIN brands br ON ((br.id = lib.brand_id)))
  WHERE ((s.is_active = true) AND (s.is_listed = true) AND (d.status <> 'out_of_stock'::text)
    AND ((d.box_quantity - d.control_quantity) > 0)
    AND (EXISTS ( SELECT 1 FROM (catalog_designs cd
             JOIN stock_catalogs c ON ((c.id = cd.catalog_id)))
          WHERE ((cd.library_id = d.library_id) AND (c.stockist_id = d.stockist_id)
            AND (c.visibility = 'public'::text) AND (c.show_in_marketplace = true)
            AND (c.is_active = true)))));

-- my_stock + my_library also carry surface_label. Their full bodies live in
-- 20260710_surface_label_my_stock_library_catalog.sql, which backfills the RPCs
-- that were applied straight to the live database and never written down here.
