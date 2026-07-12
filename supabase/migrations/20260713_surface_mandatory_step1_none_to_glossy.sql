-- Surface becomes MANDATORY — step 1 of 3: retire the 'None' placeholder from products.
-- (follows docs/PRODUCT_IDENTITY_MIGRATION_PLAN.md)
--
-- A tile always has a surface. 'None' is not a surface — it is "we don't know yet" wearing
-- a surface's clothes, and because surface is now part of the product key, a 'None' product
-- and a Glossy product of the SAME tile are two rows for one thing. That is a duplicate
-- waiting to happen the moment stock is added.
--
-- USER DECISION 2026-07-13: all current data is test data — convert every 'None' product to
-- Glossy rather than inventing a per-stockist answer.
--
-- Measured on live data first:
--   * 859 products carry 'None'  (933 total = 859 None + 74 real)
--   * ZERO of them have any holdings   -> every one is a placeholder, no stock is disturbed
--   * ZERO collisions: no tile has BOTH a 'None' product and a real-surface product, so
--     nothing merges and nothing violates stockist_library_uniq
--   * ZERO holdings carry 'None' — every holding already has a real canonical surface

do $$
declare v_dupes int;
begin
  -- Refuse if converting would collide on (stockist, lower(name), size, surface_type).
  select count(*) into v_dupes from (
    select 1 from stockist_library l
    where l.surface_type = 'None'
      and exists (select 1 from stockist_library x
                  where x.stockist_id = l.stockist_id
                    and lower(x.master_design_name) = lower(l.master_design_name)
                    and x.size = l.size
                    and x.surface_type = 'Glossy')
  ) t;
  if v_dupes > 0 then
    raise exception 'refusing: % None product(s) would collide with an existing Glossy product',
      v_dupes;
  end if;
end $$;

update stockist_library
   set surface_type = 'Glossy',
       updated_at   = now()
 where surface_type = 'None';

-- Guard: no product may be left without a real surface.
do $$
declare v_left int;
begin
  select count(*) into v_left from stockist_library where surface_type = 'None';
  if v_left > 0 then
    raise exception 'step failed: % product(s) still carry None', v_left;
  end if;
end $$;
