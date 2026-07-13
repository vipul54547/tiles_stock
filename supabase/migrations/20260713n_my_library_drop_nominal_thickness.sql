-- 🔴 HOTFIX: the Design Library was BROKEN for every stockist.
--
-- 20260713l dropped stockist_library.nominal_thickness_mm, but my_library() still selected it, so
-- the RPC raised 42703 and the Library screen came back empty for everyone.
--
-- ⚠️ The lesson, again: DROPPING a column is exactly as breaking as adding one. Postgres does NOT
-- check function bodies when a column goes — plpgsql/SQL bodies are stored as TEXT and only fail at
-- CALL time. Enumerate every function that names the column BEFORE dropping it:
--     select proname from pg_proc where position('<column>' in prosrc) > 0;
-- (feedback_find_every_writer_before_fixing — it applies to READERS too, not just writers.)

create or replace function public.my_library()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_stk uuid;
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists have a library'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id,
      'brand_id', m.brand_id,
      'brand_name', coalesce((select b.name from brands b where b.id = m.brand_id), ''),
      'size', m.size,
      'master_design_name', m.master_design_name,
      'image_url', m.image_url,
      'surface_type', m.surface_type,
      'surface_label', m.surface_label,
      'stock_type', m.stock_type,
      'tile_type', m.tile_type,
      'pieces_per_box', (select a.pieces_per_box from stockist_library_brand_names a
                          where a.library_id = m.id and coalesce(a.pieces_per_box,0) > 0
                          order by a.created_at limit 1),
      'box_weight_kg',  (select a.box_weight_kg from stockist_library_brand_names a
                          where a.library_id = m.id and coalesce(a.box_weight_kg,0) > 0
                          order by a.created_at limit 1),
      -- DERIVED from the BOX by trigger. There is no declared thickness and no picker: the band
      -- this falls in (thickness_band) is what the identity key uses.
      'thickness_mm', m.thickness_mm,
      'colour', m.colour,
      'finish_label', m.finish_label,
      -- an alias IS a box: name + how that brand packs it
      'aliases', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'brand_id', a.brand_id,
                 'name', a.brand_design_name,
                 'pieces_per_box', a.pieces_per_box,
                 'box_weight_kg', a.box_weight_kg))
        from stockist_library_brand_names a where a.library_id = m.id), '[]'::jsonb)
    ) order by m.master_design_name, m.size)
    from stockist_library m where m.stockist_id = v_stk
  ), '[]'::jsonb);
end; $function$;
