-- The declared thickness is a 0.5 mm BAND, not a round number: 4.0–4.5 … 19.5–20.0 (32 bands).
--
-- My first seed (5, 6, 7, 8, 9, 10, 12, 15, 16, 18, 20) was a guess at round "nominal" figures and
-- the user corrected it. A band is the better fit for the trade AND for the data: a real tile is
-- 8.86 mm, not 9 mm, and it lands cleanly in 8.5–9.0. Every derived figure we hold falls in exactly
-- one band, so the suggestion becomes exact instead of a rounding.
--
-- STORED VALUE = the band's LOW EDGE (4.0, 4.5, … 19.5). One number per band, so it still keys
-- cleanly and `8` and `8.0` cannot become two products. DISPLAYED as "8.5–9.0 mm".
--
-- Safe to re-seed: nominal_thickness_mm is NULL on all 930 products, so nothing references a row.

comment on table thickness_options is
  'The fixed list of declarable thicknesses, as 0.5 mm BANDS. `mm` is the band''s LOW EDGE — the '
  'band runs [mm, mm+0.5). A real tile is 8.86 mm, not 9 mm, so the band is what can honestly be '
  'declared. One number per band keeps it a clean identity key.';

do $$
declare v_used int;
begin
  select count(*) into v_used from stockist_library where nominal_thickness_mm is not null;
  if v_used > 0 then
    raise exception 're-seed aborted: % product(s) already declare a thickness', v_used;
  end if;
end $$;

delete from thickness_options;

insert into thickness_options (mm, sort)
select (4.0 + 0.5 * g)::numeric(4,1), g
  from generate_series(0, 31) as g;      -- 4.0 … 19.5 → the bands 4.0–4.5 … 19.5–20.0

do $$
declare v_n int; v_lo numeric; v_hi numeric;
begin
  select count(*), min(mm), max(mm) into v_n, v_lo, v_hi from thickness_options where is_active;
  if v_n <> 32 or v_lo <> 4.0 or v_hi <> 19.5 then
    raise exception 'bad seed: % rows, % … %', v_n, v_lo, v_hi;
  end if;
end $$;
