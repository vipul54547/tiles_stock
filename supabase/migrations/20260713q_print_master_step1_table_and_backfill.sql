-- CHAPTER 4, step 1 — the PRINT_MASTER layer.
--
-- Today `stockist_library` IS the product, and the PRINT is duplicated onto every row:
-- Glossy Ant Bianco and Matt Ant Bianco each carry their OWN copy of the same photo, the same
-- colour and the same DNA — and nothing keeps the copies in sync. A thickness fork copies them
-- again. This factors the print out, so the artwork is stored ONCE.
--
--     PRINT_MASTER    stockist + print_name + size          <- the artwork. A PDF gives exactly this.
--        v
--     PRODUCT         print + surface + body + thickness    <- ONE PIECE of tile
--        v
--     BOX             product x brand                       <- pieces/box, box weight, the STAMP
--        v
--     HOLDING         product x brand x quality             <- the quantity
--
-- 🔑 In a KEY => COMPULSORY. Not in a key => a blank is fine.
--    (stockist, print_name, size) is the print's key. The image and every DNA tag are optional —
--    a PDF knows only name+size+image, so anything else would have to be INVENTED. See the 444
--    products whose body was blanket-guessed as 'Porcelain' and had to be un-guessed today.
--
-- ADDITIVE ONLY. Nothing is dropped here: 38 live functions still read image_url /
-- master_design_name / colour / library_dna, and they all keep working. The readers move in
-- step 2; the columns die in step 3. (Dropping a column out from under a reader is what emptied
-- every stockist's Design Library on 2026-07-13.)

-- ---------------------------------------------------------------- 1. the table
create table if not exists print_master (
  id          uuid primary key default gen_random_uuid(),
  stockist_id uuid not null references stockists(id) on delete cascade,
  print_name  text not null,
  size        text not null,
  image_url   text,                       -- exactly ONE per print. Optional, but chase it.
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint print_master_name_not_blank check (btrim(print_name) <> ''),
  constraint print_master_size_not_blank check (btrim(size) <> '')
);

-- the KEY. Case-insensitive on the name, exactly like stockist_library_uniq.
create unique index if not exists print_master_uniq
  on print_master (stockist_id, lower(print_name), size);
create index if not exists print_master_stk on print_master (stockist_id);

comment on table print_master is
  'The PRINT: the artwork itself (stockist + print_name + size), carrying exactly one image. '
  'A print has no thickness and no weight - you cannot hold it. It becomes a PRODUCT (one piece) '
  'only when a surface, a body and a box are declared. The print is the PORTFOLIO; the product is '
  'the COMMERCE. A print may exist with NO product.';
comment on column print_master.print_name is
  'The STOCKIST''S OWN master word for the artwork. NOT the name on any brand''s box - that is '
  'brand_design_name on the BOX, is free text, and is unrelated (print "MURLI WHITE" is stamped '
  'KARTIK BIANCO / 60200 / DHORO KHIMO by three different brands).';

-- ---------------------------------------------------------------- 2. backfill  (935 -> 929)
-- One print per (stockist, lower(name), size). Verified beforehand on live data:
-- 0 image conflicts, 0 colour conflicts - so there is no "which photo wins?" to resolve.
-- The name's CASING and the created_at are taken from the OLDEST product in the group, so the
-- print inherits the original spelling rather than a fork's.
with grp as (
  select l.stockist_id,
         lower(l.master_design_name) as nm,
         l.size,
         (array_agg(l.master_design_name order by l.created_at, l.id))[1] as print_name,
         max(nullif(btrim(coalesce(l.image_url,'')),''))                  as image_url,
         min(l.created_at)                                                as created_at
    from stockist_library l
   group by l.stockist_id, lower(l.master_design_name), l.size
)
insert into print_master (stockist_id, print_name, size, image_url, created_at)
select stockist_id, print_name, size, image_url, created_at from grp
on conflict do nothing;

-- ---------------------------------------------------------------- 3. point the product at it
alter table stockist_library add column if not exists print_id uuid references print_master(id);

update stockist_library l
   set print_id = p.id
  from print_master p
 where p.stockist_id = l.stockist_id
   and p.size        = l.size
   and lower(p.print_name) = lower(l.master_design_name)
   and l.print_id is null;

create index if not exists stockist_library_print on stockist_library (print_id);

-- Every product MUST belong to a print: the print carries its name and size.
alter table stockist_library alter column print_id set not null;

comment on column stockist_library.print_id is
  'The PRINT this piece is printed from. The print owns the name, the size and the image. '
  'master_design_name / size / image_url / colour on this table are LEGACY and are dropped in '
  'step 3 once all 38 reader functions have moved.';

-- ---------------------------------------------------------------- 4. DNA that belongs to the PRINT
-- The DNA splits across the boundary, and NEITHER CASCADE IS CUT:
--   PRINT   : Look Type -> Natural Name, Print Type, Design Joint, Colour(multi)
--   PRODUCT : Punch -> Punch Type, Application, Series, [Behaviour Type, Use Type -> auto later]
-- Antiskid is a property of a MATT tile, not of the artwork. Emboss is relief pressed into the
-- piece, not printed on it. Marble / Carara / Dark / Bookmatch are the same in every surface and
-- every thickness -> they are the artwork.
create table if not exists print_dna (
  print_id uuid not null references print_master(id) on delete cascade,
  value_id uuid not null references dna_values(id)   on delete cascade,
  primary key (print_id, value_id)
);
create index if not exists print_dna_value on print_dna (value_id);

-- move the print-side tags off library_dna (live: Look Type 1 + Natural Name 1 = 2 rows)
insert into print_dna (print_id, value_id)
select distinct l.print_id, ld.value_id
  from library_dna ld
  join stockist_library l on l.id = ld.library_id
  join dna_values     v  on v.id  = ld.value_id
  join dna_attributes a  on a.id  = v.attribute_id
 where a.name in ('Look Type','Natural Name','Print Type','Design Joint','Colour')
on conflict do nothing;

delete from library_dna ld
 using dna_values v, dna_attributes a
 where v.id = ld.value_id and a.id = v.attribute_id
   and a.name in ('Look Type','Natural Name','Print Type','Design Joint','Colour');

-- ---------------------------------------------------------------- 5. lock the new tables down
-- Supabase hands anon/authenticated full DML on every new public table. Revoke it in the SAME
-- migration - all access goes through SECURITY DEFINER RPCs, never direct table reads.
alter table print_master enable row level security;
alter table print_dna    enable row level security;
revoke all on print_master from anon, authenticated;
revoke all on print_dna    from anon, authenticated;

-- ---------------------------------------------------------------- 6. self-check
-- NB: a plain RAISE EXCEPTION here would roll the MIGRATION back too. Raise only on FAILURE.
do $$
declare v_prints int; v_orphan int; v_products int;
begin
  select count(*) into v_prints   from print_master;
  select count(*) into v_products from stockist_library;
  select count(*) into v_orphan   from stockist_library where print_id is null;

  if v_orphan > 0 then
    raise exception 'FAILED: % products have no print', v_orphan;
  end if;
  if v_prints = 0 or v_prints > v_products then
    raise exception 'FAILED: % prints from % products looks wrong', v_prints, v_products;
  end if;
  raise notice 'OK: % products -> % prints', v_products, v_prints;
end $$;
