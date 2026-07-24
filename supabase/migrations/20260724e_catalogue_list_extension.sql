-- 20260724e — 🖼️ MEDIA PORTFOLIO, P1 slice 3b: catalogue_list = stock_list + a kind flag.
--
-- DDPI #13/#15/#21: a PORTFOLIO LIST is structurally the same row as a STOCK LIST — same table
-- (`stock_catalogs`), same banner / share-link / Permanent-Temporary machinery — only the FILTER and
-- the buyer view differ (stock-blind, design-centric). So we add:
--   • kind              — 'stock' (default, every existing row) | 'portfolio'.
--   • catalogue_brand_id — the ONE mandatory brand a portfolio is scoped to + displayed under
--                          (#11/#15). A stock list leaves it null (it may span brands via filter_brand_ids).
--   • filter_spaces[]    — the mockup/360 room tag facet (#8/#13).
--   • filter_dna[]       — the full DNA facet set (#13); dna_values ids, read via _dna_of_library.
-- Portfolio DROPS the stock facets (quality · stock-type · box range) — they stay null on these rows.
--
-- Writer: a SEPARATE `catalogue_save` (not an overload of stock_list_save — the arg lists differ and
-- adding params to the shipped signature is the 42725 overload trap). Reader: none needed — the
-- stockist's own list read is `getCatalogs` (a plain table select), so the new columns ride for free;
-- the Dart StockCatalog model just parses them. The buyer catalogue read (brand-scoped, media-joined)
-- is deferred to when the catalogue screens exist — it will reuse public_portfolio for media.

-- ── schema ──────────────────────────────────────────────────────────────────────────────────────
alter table public.stock_catalogs
  add column if not exists kind text not null default 'stock',
  add column if not exists catalogue_brand_id uuid references public.brands(id) on delete set null,
  add column if not exists filter_spaces text[] not null default '{}',
  add column if not exists filter_dna uuid[] not null default '{}';

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'stock_catalogs_kind_chk') then
    alter table public.stock_catalogs
      add constraint stock_catalogs_kind_chk check (kind in ('stock','portfolio'));
  end if;
end $$;

-- ── writer ──────────────────────────────────────────────────────────────────────────────────────
-- Create ([p_id] null) or edit a PORTFOLIO catalogue. Mirrors stock_list_save's limit + name-unique
-- gate, but forces kind='portfolio', requires ONE brand, and stores the catalogue facet set.
create or replace function public.catalogue_save(
  p_id uuid,
  p_name text,
  p_brand_id uuid,
  p_description text default '',
  p_list_type text default 'permanent',
  p_filter_surfaces text[] default '{}',
  p_filter_sizes text[] default '{}',
  p_filter_tile_types text[] default '{}',
  p_filter_spaces text[] default '{}',
  p_filter_dna uuid[] default '{}')
 returns uuid
 language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_stk uuid; v_limit int; v_count int; v_order int; v_id uuid;
  v_name text := trim(coalesce(p_name, ''));
  v_desc text := nullif(trim(coalesce(p_description, '')), '');
  v_type text := case when coalesce(btrim(p_list_type),'') = 'temporary' then 'temporary' else 'permanent' end;
begin
  select id, coalesce(stock_list_limit, 3) into v_stk, v_limit from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can manage catalogues'; end if;
  if v_name = '' then raise exception 'Catalogue name cannot be empty'; end if;
  -- A catalogue is always ONE brand — it scopes the designs and names them under that brand's cover.
  if p_brand_id is null then raise exception 'A catalogue must be under one brand'; end if;
  if not exists (select 1 from brands where id = p_brand_id and stockist_id = v_stk) then
    raise exception 'That brand is not yours'; end if;

  if p_id is null then
    -- lists share one per-stockist pool (both kinds are brand_id-null Link Lists)
    select count(*) into v_count from stock_catalogs
      where stockist_id = v_stk and brand_id is null and is_active;
    if v_count >= v_limit then
      raise exception 'List limit reached (%). Ask the admin to allow more.', v_limit; end if;
    if exists (select 1 from stock_catalogs
               where stockist_id = v_stk and kind = 'portfolio' and is_active and lower(name) = lower(v_name)) then
      raise exception 'You already have a catalogue with that name'; end if;
    select coalesce(max(sort_order), 0) + 10 into v_order from stock_catalogs where stockist_id = v_stk;
    insert into stock_catalogs
      (stockist_id, brand_id, kind, catalogue_brand_id, name, description, visibility,
       show_in_marketplace, sort_order, list_type,
       filter_surfaces, filter_sizes, filter_tile_types, filter_spaces, filter_dna)
    values (v_stk, null, 'portfolio', p_brand_id, v_name, v_desc, 'private',
            false, v_order, v_type,
            coalesce(p_filter_surfaces,'{}'), coalesce(p_filter_sizes,'{}'),
            coalesce(p_filter_tile_types,'{}'), coalesce(p_filter_spaces,'{}'),
            coalesce(p_filter_dna,'{}'))
    returning id into v_id;
    return v_id;
  else
    update stock_catalogs set
      name = v_name, description = v_desc, list_type = v_type,
      catalogue_brand_id = p_brand_id,
      filter_surfaces   = coalesce(p_filter_surfaces,'{}'),
      filter_sizes      = coalesce(p_filter_sizes,'{}'),
      filter_tile_types = coalesce(p_filter_tile_types,'{}'),
      filter_spaces     = coalesce(p_filter_spaces,'{}'),
      filter_dna        = coalesce(p_filter_dna,'{}')
    where id = p_id and stockist_id = v_stk and kind = 'portfolio';
    if not found then raise exception 'Catalogue not found'; end if;
    return p_id;
  end if;
end; $function$;
