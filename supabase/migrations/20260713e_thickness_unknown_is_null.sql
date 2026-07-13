-- Thickness: UNKNOWN is NULL, never 0.
--
-- A tile is never 0 mm thick. 445 of 930 products carried thickness_mm = 0 — 17 of them in stock
-- and visible to buyers as a "0 mm" tile. The cause was two-fold and both halves must go:
--
--   1. stockist_library.thickness_mm was NOT NULL DEFAULT 0, so the column could not express
--      "we don't know yet" at all.
--   2. _trg_rederive_thickness therefore had to squash the honest answer:
--          v_new := coalesce(_derive_thickness(v_lib), 0);
--      _derive_thickness ALREADY returns null correctly ("no box spec yet -> no thickness yet").
--      The coalesce threw that away and wrote a lie.
--
-- thickness_band is generated as CASE WHEN thickness_mm > 0 ... ELSE NULL, so it already treats 0
-- as unknown and needs no change — it just never got a null to work with.
--
-- Re-deriving honestly was measured against live data first: 445 zeros -> NULL, and all 485
-- real values reproduce unchanged (0 would flip to null, 0 would move).

-- 1. let the column say "unknown".
alter table stockist_library
  alter column thickness_mm drop not null,
  alter column thickness_mm drop default;

-- 2. stop the trigger lying. _derive_thickness is already right; just store what it says.
create or replace function public._trg_rederive_thickness()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_row jsonb; v_lib uuid; v_new numeric;
begin
  -- to_jsonb() works on ANY rowtype, so this function stays honest on both of its tables.
  if tg_op = 'DELETE' then v_row := to_jsonb(old); else v_row := to_jsonb(new); end if;

  v_lib := case tg_table_name
             when 'stockist_library_brand_names' then v_row->>'library_id'
             else                                     v_row->>'id'
           end::uuid;

  if v_lib is null then return coalesce(new, old); end if;

  -- No coalesce: a product with no box spec has an UNKNOWN thickness, not a zero one.
  v_new := _derive_thickness(v_lib);

  update stockist_library
     set thickness_mm = v_new,
         updated_at   = now()
   where id = v_lib
     and thickness_mm is distinct from v_new;

  return coalesce(new, old);
end; $function$;

-- 3. backfill: every stored 0 was really "unknown".
update stockist_library
   set thickness_mm = null
 where thickness_mm = 0;

-- 4. guard: a 0 must never exist again, and nothing real may have been lost.
do $$
declare v_zero int; v_lost int;
begin
  select count(*) into v_zero from stockist_library where thickness_mm = 0;
  if v_zero > 0 then
    raise exception 'thickness fix failed: % row(s) still 0', v_zero;
  end if;

  -- anything with a real box spec must still carry a real thickness.
  select count(*) into v_lost
    from stockist_library l
   where l.thickness_mm is null
     and exists (select 1 from stockist_library_brand_names b
                  where b.library_id = l.id
                    and coalesce(b.pieces_per_box,0) > 0
                    and coalesce(b.box_weight_kg,0) > 0);
  if v_lost > 0 then
    raise exception 'thickness fix failed: % product(s) with a box spec lost their thickness', v_lost;
  end if;
end $$;
