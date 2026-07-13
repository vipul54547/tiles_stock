-- ❌ REVERT of my own mistake: there must be NO thickness picker.
--
-- Thickness is DERIVED — `box_weight / (pieces × area × density)` — and that is the ONLY way it can
-- be known. A stockist reads pieces and weight off the box; they do NOT know "8.5–9.0 mm". Asking
-- them to pick it invites a guess into the identity key, which is the exact thing we are trying to
-- prevent. **The BOX is the source of truth for thickness.**
--
-- I kept a picker because I worried that a derived value in the identity key means editing a box
-- weight silently changes WHICH PRODUCT it is. That is the CORRECT behaviour, not a bug: if the
-- weight changes, either the tile really is different, or the weight was wrong. Both must move the
-- product. A declared value would simply have let a wrong one persist.
--
-- So: `nominal_thickness_mm` and `thickness_options` are DELETED, and the identity key uses
-- `thickness_band` — the GENERATED 0.5 mm band (4.0–4.5 … 19.5–20.0) that already follows
-- `thickness_mm`, which the trigger already derives from the BOX. No new column, no second source
-- of truth, nothing for a human to get wrong.

-- 1. the key must not reference the column we are about to drop
drop index if exists stockist_library_uniq;

alter table stockist_library drop column if exists nominal_thickness_mm;
drop function if exists public._nominal_thickness(numeric);
drop table if exists thickness_options;

-- 2. the BAND is the declarable unit: 4.0–4.5 … 19.5–20.0. Outside 4–20 mm is not a tile — it is a
--    bad box weight — so it bands to NULL rather than inventing a 3.0 or 25.0 band.
alter table stockist_library drop column thickness_band;

alter table stockist_library
  add column thickness_band numeric(4,1)
  generated always as (
    case when thickness_mm >= 4 and thickness_mm < 20
         then floor(thickness_mm / 0.5) * 0.5
         else null
    end
  ) stored;

comment on column stockist_library.thickness_band is
  'The 0.5 mm BAND the derived thickness falls in (4.0–4.5 … 19.5–20.0), as the band''s LOW EDGE. '
  'PART OF PRODUCT IDENTITY. Generated from thickness_mm, which the trigger derives from the BOX — '
  'so it is never typed and can never be guessed. NULL until the product has a box spec, or when '
  'the derived figure lands outside 4–20 mm (a bad box weight, not a thin tile).';

-- 3. identity = print + size + surface + body + the DERIVED thickness band.
--    NULLS NOT DISTINCT: a product with no box yet has no band, and two such products of the same
--    print/size/surface/body must still COLLIDE rather than quietly duplicate.
create unique index stockist_library_uniq
    on stockist_library (stockist_id, lower(master_design_name), size,
                         surface_type, tile_type, thickness_band)
       nulls not distinct;

-- 4. a box edit can now move a product's identity — and could land it on top of another product.
--    Postgres would throw a raw 23505 naming an index. Say what actually happened instead.
create or replace function public.library_set_box(
  p_library_id uuid, p_brand_id uuid,
  p_pieces integer default null, p_weight numeric default null)
returns numeric
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can edit the library'; end if;
  if not exists (select 1 from stockist_library
                  where id = p_library_id and stockist_id = v_stk) then
    raise exception 'Design not found';
  end if;
  if p_pieces is not null and p_pieces <= 0 then
    raise exception 'Pieces per box must be more than 0';
  end if;
  if p_weight is not null and p_weight <= 0 then
    raise exception 'Box weight must be more than 0';
  end if;

  insert into stockist_library_brand_names (library_id, brand_id, brand_design_name,
                                            pieces_per_box, box_weight_kg)
  select p_library_id, p_brand_id, l.master_design_name, p_pieces, p_weight
    from stockist_library l where l.id = p_library_id
  on conflict (library_id, brand_id) do update
    set pieces_per_box = coalesce(excluded.pieces_per_box, stockist_library_brand_names.pieces_per_box),
        box_weight_kg  = coalesce(excluded.box_weight_kg,  stockist_library_brand_names.box_weight_kg);

  -- the trigger has already re-derived thickness_mm, and thickness_band followed it
  return (select thickness_mm from stockist_library where id = p_library_id);
exception
  when unique_violation then
    raise exception 'This box weight puts the tile in a different thickness band, and you already '
                    'have that exact design at that thickness. Check the weight and pieces.';
end; $function$;
