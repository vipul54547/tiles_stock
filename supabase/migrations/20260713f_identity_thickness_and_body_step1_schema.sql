-- CHAPTER 3, STEP 1 of 3 (schema) — thickness + body join PRODUCT IDENTITY.
-- (docs/THICKNESS_AND_BODY_IDENTITY_PLAN.md)
--
-- A 7 mm and a 12 mm tile of the same print/size/surface cover the SAME sq ft but sell at a
-- DIFFERENT rate — they are two products, and the old key silently merged them. Same for body
-- (Ceramic vs Porcelain). Tiles sell BY AREA AT A RATE; weight is freight, not commerce.
--
-- 🔑 Thickness is DECLARED, not derived. The derived value comes from the BOX, and the BOX hangs off
-- the product — a derived value in the identity key would mean that editing a box weight silently
-- changes WHICH PRODUCT it is. `thickness_mm` survives as EVIDENCE (it validates the declaration).

-- ---------------------------------------------------------------- 1. the fixed list
create table if not exists thickness_options (
  mm        numeric(4,1) primary key,
  is_active boolean not null default true,
  sort      int     not null default 0
);

comment on table thickness_options is
  'The fixed list of NOMINAL tile thicknesses a stockist may declare. Nominal, not measured: the '
  'trade says "8 mm", never "8.86 mm". A free number would make 8 and 8.0 different products.';

insert into thickness_options (mm, sort) values
  (5,10),(6,20),(7,30),(8,40),(9,50),(10,60),(12,70),(15,80),(16,90),(18,100),(20,110)
on conflict (mm) do nothing;

-- ⚠️ a new public-schema table silently grants anon INSERT/UPDATE/DELETE. Revoke it here.
revoke all on thickness_options from anon, authenticated;
grant select on thickness_options to anon, authenticated;
alter table thickness_options enable row level security;
drop policy if exists thickness_options_read on thickness_options;
create policy thickness_options_read on thickness_options for select using (true);

-- ---------------------------------------------------------------- 2. the declared column
alter table stockist_library
  add column if not exists nominal_thickness_mm numeric(4,1)
    references thickness_options(mm);

comment on column stockist_library.nominal_thickness_mm is
  'DECLARED nominal thickness — part of PRODUCT IDENTITY. NULL = not yet declared (the 930 rows '
  'that predate CHAPTER 3). Never guessed: a wrong value in the identity key is worse than a blank.';

comment on column stockist_library.thickness_mm is
  'DERIVED from the BOX (weight / (pieces x area x density)). EVIDENCE ONLY — it validates '
  'nominal_thickness_mm and warns on mismatch. It is NOT identity and NOT the truth.';

-- ---------------------------------------------------------------- 3. body becomes mandatory
-- Already 100% populated (Porcelain 702 / PGVT & GVT 141 / Ceramic 87), so this is free.
do $$
declare v_bad int;
begin
  select count(*) into v_bad from stockist_library
   where coalesce(btrim(tile_type),'') = '';
  if v_bad > 0 then
    raise exception 'cannot make tile_type NOT NULL: % product(s) have none', v_bad;
  end if;
end $$;

alter table stockist_library alter column tile_type set not null;

alter table stockist_library drop constraint if exists stockist_library_tile_type_not_blank;
alter table stockist_library add constraint stockist_library_tile_type_not_blank
  check (btrim(tile_type) <> '');

-- ---------------------------------------------------------------- 4. the new identity key
-- Adding columns to a unique key can only SPLIT, never collide, so this cannot fail on live rows.
-- NULLS NOT DISTINCT (PG 17.6) is the point: while nominal_thickness_mm is still NULL on the 930
-- legacy rows, two "unknown thickness" products of the same print/size/surface must STILL COLLIDE
-- rather than quietly duplicate. Without it, NULL <> NULL and the key would stop protecting them.
drop index if exists stockist_library_uniq;

create unique index stockist_library_uniq
    on stockist_library (stockist_id, lower(master_design_name), size,
                         surface_type, tile_type, nominal_thickness_mm)
       nulls not distinct;

-- ---------------------------------------------------------------- guards
do $$
declare v_rows int; v_opts int; v_null_tt int;
begin
  select count(*) into v_rows    from stockist_library;
  select count(*) into v_opts    from thickness_options where is_active;
  select count(*) into v_null_tt from stockist_library where tile_type is null;

  if v_null_tt > 0 then raise exception 'tile_type still null on % row(s)', v_null_tt; end if;
  if v_opts = 0   then raise exception 'thickness_options is empty';                   end if;

  raise notice 'STEP 1 OK >> % products, % thickness options, new key live', v_rows, v_opts;
end $$;
