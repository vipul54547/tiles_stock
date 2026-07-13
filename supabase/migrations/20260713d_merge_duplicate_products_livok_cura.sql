-- Collapse the duplicate PRODUCTS at livok + cura (applied to prod 2026-07-13).
--
-- Both stockists are surface_mode = 'in_name': the stamped name alone identifies ONE product.
-- So `3209` existing twice was wrong. It happened because the surface-identity split (CHAPTER 2a)
-- spawned a sibling product wherever the STOCK rows claimed a different surface — and those
-- surfaces came from the surface_aliases pollution (Carvingendless, Marblerandom, ... force-mapped
-- onto canonicals). The split faithfully propagated bad data.
--
-- ⚠️ NOT a delete — a MERGE. See [[feedback_check_fk_ondelete_before_deleting]]:
--   * designs.library_id is ON DELETE **SET NULL** — deleting the sibling product would have
--     silently orphaned 318 boxes of live stock instead of erroring.
--   * stock_in / dispatches / inquiry_items / my_choices all CASCADE off designs.id — deleting the
--     sibling HOLDINGS would have destroyed their history.
-- So: carry the history across, add the quantities into the surviving holding, drop the emptied
-- sibling holding, then delete the sibling product.
--
-- inquiry_items is UNIQUE (inquiry_id, design_id) — one real inquiry named BOTH 3209 P.Glossy and
-- 3209 Carving as separate lines, so those two fold into one line with the quantities summed.
--
-- Result (verified on live data): 935 -> 930 products, 913 boxes preserved exactly,
-- 10 holdings merged, 101 stock_in + 26 dispatches kept, inquiry qty 1359 unchanged.
--
-- ❗ famous ceramic is DELIBERATELY excluded. It is surface_mode = 'attribute': one stamped box name
-- legitimately covers several surfaces, so its `1001` as MATTE/Grenul/LUSTRA is CORRECT data.
-- Never collapse duplicates for an 'attribute' stockist.

do $$
declare
  v_box_before  bigint; v_box_after  bigint;
  v_si_before   bigint; v_si_after   bigint;
  v_dp_before   bigint; v_dp_after   bigint;
  v_ii_before   bigint; v_ii_after   bigint;
  v_prod_before int;    v_prod_after int;
  v_iiq_before  bigint; v_iiq_after  bigint;   -- inquiry QUANTITY, not just row count
  v_merged int; v_repointed int; v_dna int; v_killed int;
  v_ii_folded int := 0;
  v_orphan int; v_dup int; v_dup_other int;
begin
  -- ---- the groups: keep the OLDEST product of each (stockist, name, size) ----
  create temp table _pair on commit drop as
  with g as (
    select l.id, l.stockist_id, l.surface_type, l.surface_label,
           first_value(l.id) over (
             partition by l.stockist_id, lower(l.master_design_name), l.size
             order by l.created_at) as keep_id
      from stockist_library l
     where l.stockist_id in ('8a961626-ae3f-44d0-b495-0f4f7a078fb0',
                             'c8efecc1-c3c3-4487-9fc5-05d7e8877f0f')
       and exists (select 1 from stockist_library x
                    where x.stockist_id = l.stockist_id
                      and lower(x.master_design_name) = lower(l.master_design_name)
                      and x.size = l.size and x.id <> l.id)
  )
  select id as sib_id, keep_id from g where id <> keep_id;

  -- ---- BEFORE ----
  select coalesce(sum(d.box_quantity),0) into v_box_before
    from designs d
   where d.library_id in (select sib_id from _pair)
      or d.library_id in (select keep_id from _pair);
  select count(*) into v_si_before from stock_in;
  select count(*) into v_dp_before from dispatches;
  select count(*) into v_ii_before from inquiry_items;
  select coalesce(sum(quantity),0) into v_iiq_before from inquiry_items;
  select count(*) into v_prod_before from stockist_library;

  -- ---- map each sibling holding onto the keep's holding of the SAME (brand, quality) ----
  create temp table _hmap on commit drop as
  select ds.id  as sib_h,
         dk.id  as keep_h,
         ds.box_quantity     as sib_boxes,
         ds.control_quantity as sib_ctrl,
         p.keep_id
    from _pair p
    join designs ds on ds.library_id = p.sib_id
    left join designs dk on dk.library_id = p.keep_id
                        and dk.brand_id is not distinct from ds.brand_id
                        and dk.quality  is not distinct from ds.quality;

  -- ---- 1. carry the history across (these CASCADE off designs.id — never let them die) ----
  -- 1a. keyed only on id: a plain re-point is safe.
  update stock_in          t set design_id = m.keep_h from _hmap m where t.design_id = m.sib_h and m.keep_h is not null;
  update dispatches        t set design_id = m.keep_h from _hmap m where t.design_id = m.sib_h and m.keep_h is not null;
  update stock_adjustments t set design_id = m.keep_h from _hmap m where t.design_id = m.sib_h and m.keep_h is not null;

  -- 1b. inquiry_items is UNIQUE (inquiry_id, design_id). One inquiry can name BOTH the keep and the
  --     sibling as separate lines — after the merge they are one line, so ADD the quantities in.
  update inquiry_items k
     set quantity       = k.quantity       + agg.q,
         dispatched_qty = k.dispatched_qty + agg.d,
         held_qty       = k.held_qty       + agg.h
    from (select s.inquiry_id, m.keep_h,
                 sum(s.quantity) q, sum(s.dispatched_qty) d, sum(s.held_qty) h
            from inquiry_items s
            join _hmap m on m.sib_h = s.design_id and m.keep_h is not null
           where exists (select 1 from inquiry_items e
                          where e.inquiry_id = s.inquiry_id and e.design_id = m.keep_h)
           group by s.inquiry_id, m.keep_h) agg
   where k.inquiry_id = agg.inquiry_id and k.design_id = agg.keep_h;
  get diagnostics v_ii_folded = row_count;

  delete from inquiry_items s
   using _hmap m
   where s.design_id = m.sib_h and m.keep_h is not null
     and exists (select 1 from inquiry_items e
                  where e.inquiry_id = s.inquiry_id and e.design_id = m.keep_h);

  update inquiry_items t set design_id = m.keep_h
    from _hmap m where t.design_id = m.sib_h and m.keep_h is not null;

  -- 1c. my_choices is PK (end_user_id, design_id) — same story, but a choice has no quantity to
  --     fold: if the buyer already picked the keep, the sibling pick is a duplicate. Drop it.
  delete from my_choices s
   using _hmap m
   where s.design_id = m.sib_h and m.keep_h is not null
     and exists (select 1 from my_choices e
                  where e.end_user_id = s.end_user_id and e.design_id = m.keep_h);

  update my_choices t set design_id = m.keep_h
    from _hmap m where t.design_id = m.sib_h and m.keep_h is not null;

  -- ---- 2. add the sibling's quantities into the keep holding ----
  update designs d
     set box_quantity     = d.box_quantity     + agg.boxes,
         control_quantity = d.control_quantity + agg.ctrl,
         status           = case when d.box_quantity + agg.boxes > 0 and d.status = 'out_of_stock'
                                 then 'active' else d.status end,
         updated_at       = now()
    from (select keep_h, sum(sib_boxes) boxes, sum(sib_ctrl) ctrl
            from _hmap where keep_h is not null group by keep_h) agg
   where d.id = agg.keep_h;

  -- ---- 3. the merged sibling holdings are now empty shells: drop them ----
  delete from designs d using _hmap m where d.id = m.sib_h and m.keep_h is not null;
  get diagnostics v_merged = row_count;

  -- ---- 4. any sibling holding with NO counterpart simply moves over, adopting the keep's surface ----
  update designs d
     set library_id    = k.id,
         surface_type  = k.surface_type,
         surface_label = k.surface_label,
         updated_at    = now()
    from _hmap m join stockist_library k on k.id = m.keep_id
   where d.id = m.sib_h and m.keep_h is null;
  get diagnostics v_repointed = row_count;

  -- ---- 5. union the sibling's DNA tags onto the keep ----
  insert into library_dna (library_id, value_id)
  select distinct p.keep_id, x.value_id
    from _pair p join library_dna x on x.library_id = p.sib_id
   where not exists (select 1 from library_dna y
                      where y.library_id = p.keep_id and y.value_id = x.value_id);
  get diagnostics v_dna = row_count;

  -- ---- 6. the sibling PRODUCTS are now unreferenced by any holding: delete ----
  delete from stockist_library l where l.id in (select sib_id from _pair);
  get diagnostics v_killed = row_count;

  -- ---- AFTER ----
  select coalesce(sum(d.box_quantity),0) into v_box_after
    from designs d where d.library_id in (select keep_id from _pair);
  select count(*) into v_si_after from stock_in;
  select count(*) into v_dp_after from dispatches;
  select count(*) into v_ii_after from inquiry_items;
  select coalesce(sum(quantity),0) into v_iiq_after from inquiry_items;
  select count(*) into v_prod_after from stockist_library;

  -- ---- GUARDS: refuse to commit if anything was lost ----
  if v_box_after <> v_box_before then
    raise exception 'ABORT: boxes changed % -> %', v_box_before, v_box_after; end if;
  if v_si_after <> v_si_before then
    raise exception 'ABORT: stock_in rows lost % -> %', v_si_before, v_si_after; end if;
  if v_dp_after <> v_dp_before then
    raise exception 'ABORT: dispatch rows lost % -> %', v_dp_before, v_dp_after; end if;
  -- folded lines legitimately disappear as ROWS, but their quantity must survive.
  if v_ii_after <> v_ii_before - v_ii_folded then
    raise exception 'ABORT: inquiry rows lost % -> % (folded %)', v_ii_before, v_ii_after, v_ii_folded; end if;
  if v_iiq_after <> v_iiq_before then
    raise exception 'ABORT: inquiry QUANTITY changed % -> %', v_iiq_before, v_iiq_after; end if;

  select count(*) into v_orphan from designs where library_id is null;
  if v_orphan > 0 then raise exception 'ABORT: % orphan holding(s)', v_orphan; end if;

  -- scoped to the two stockists this job covers; other stockists' dups are a separate decision.
  select count(*) into v_dup from (
    select 1 from stockist_library
     where stockist_id in ('8a961626-ae3f-44d0-b495-0f4f7a078fb0',
                           'c8efecc1-c3c3-4487-9fc5-05d7e8877f0f')
     group by stockist_id, lower(master_design_name), size having count(*) > 1) t;
  if v_dup > 0 then raise exception 'ABORT: % duplicate group(s) remain in livok/cura', v_dup; end if;

  select count(*) into v_dup_other from (
    select 1 from stockist_library
     where stockist_id not in ('8a961626-ae3f-44d0-b495-0f4f7a078fb0',
                               'c8efecc1-c3c3-4487-9fc5-05d7e8877f0f')
     group by stockist_id, lower(master_design_name), size having count(*) > 1) t;

  raise notice 'RESULT >> COMMITTED | products %->% (killed %) | boxes % PRESERVED | holdings merged %, repointed % | dna added % | stock_in % dispatch % kept | inquiry rows %->% (folded %), qty % PRESERVED | dup groups livok/cura now % | OTHER stockists still have % dup group(s)',
    v_prod_before, v_prod_after, v_killed, v_box_after, v_merged, v_repointed, v_dna,
    v_si_after, v_dp_after, v_ii_before, v_ii_after, v_ii_folded, v_iiq_after, v_dup, v_dup_other;
end $$;
