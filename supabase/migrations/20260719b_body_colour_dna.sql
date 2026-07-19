-- ═══ BODY COLOUR — a free-text DNA word, but only for a THROUGH-BODY tile ═════════════════════
--
-- His words: "now i need body colour free text like series when stockist select Full Body or
-- Colour Body."
--
-- A Full Body / Colour Body tile is coloured all the way THROUGH — the body itself has a colour
-- (red, white, grey biscuit). A glazed tile (PGVT & GVT, Porcelain, Ceramic) does not: the colour
-- is only the printed face. So Body Colour is a real attribute for exactly two bodies and nonsense
-- for the rest.
--
-- It is a free-text DNA attribute **exactly like Series** (scope=product, own-word reuse), so it
-- rides every existing rail: `dna_set_design_text` to save, `dna_catalog` to read, My Words. It is
-- NOT identity (two Full Body tiles that differ only by body colour are the same product) and NOT a
-- buyer facet yet (`show_in_facets=false` → `public_dna_catalog` already excludes it).
--
-- 🔑 THE GATE. A DNA attribute normally shows for every product. Body Colour must show only for the
-- bodies it means something for. `tile_type_gate` = the list of tile_types this attribute applies
-- to; NULL means "all bodies" (every existing attribute). Data-driven, so the app never hardcodes
-- an attribute name.

-- ── 1. the gate column ──────────────────────────────────────────────────────────────────────
alter table dna_attributes add column if not exists tile_type_gate text[];
comment on column dna_attributes.tile_type_gate is
  'When set, this attribute applies ONLY to these tile_types (bodies) — e.g. Body Colour is for '
  '{Full Body, Colour Body} only. NULL = every body. Data-driven so the app never names an '
  'attribute to gate it.';

-- ── 2. the Body Colour attribute — a twin of Series, gated ──────────────────────────────────
insert into dna_attributes
  (name, scope, is_multi, is_free_text, show_in_facets, allow_mapping, free_text_detail,
   sort_order, is_active, tile_type_gate)
select 'Body Colour', 'product', false, true, false, true, false, 10, true,
       array['Full Body','Colour Body']
where not exists (select 1 from dna_attributes where name = 'Body Colour');

-- ── 3. dna_catalog now carries the gate (stockist editor + the inline field read it) ────────
-- Identical to the live body except for the new 'tile_type_gate' key. public_dna_catalog is left
-- alone: Body Colour is free-text with no facet, so it is already excluded there.
create or replace function public.dna_catalog()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  with me as (select id from stockists where user_id = auth.uid())
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', a.id, 'name', a.name, 'is_multi', a.is_multi,
      'is_free_text', a.is_free_text, 'sort_order', a.sort_order,
      'show_in_facets', a.show_in_facets, 'allow_mapping', a.allow_mapping,
      'parent_attribute_id', a.parent_attribute_id, 'free_text_detail', a.free_text_detail,
      'scope', a.scope, 'tile_type_gate', a.tile_type_gate,
      'values', coalesce((
        select jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name, 'parent_value_id', v.parent_value_id)
                         order by v.sort_order, lower(v.name))
        from dna_values v
        where v.attribute_id = a.id and v.is_active
          and (v.stockist_id is null or v.stockist_id = (select id from me))), '[]'::jsonb)
    ) order by a.sort_order
  ), '[]'::jsonb)
  from dna_attributes a where a.is_active;
$function$;

-- ── 4. self-check (raise only on FAILURE) ───────────────────────────────────────────────────
do $$
declare v_gate text[];
begin
  select tile_type_gate into v_gate from dna_attributes where name = 'Body Colour';
  if v_gate is null or not (v_gate @> array['Full Body','Colour Body']) then
    raise exception 'FAILED: Body Colour gate is % (expected Full Body + Colour Body)', v_gate;
  end if;
  raise notice 'OK: Body Colour DNA attribute gated to %', v_gate;
end $$;
