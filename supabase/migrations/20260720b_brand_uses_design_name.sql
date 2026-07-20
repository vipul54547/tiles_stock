-- 20260720b — "Cover word = the default brand's design name", declared per brand.
--
-- 🎁 The word stamped on a BOX (`cover_name_set` → `brand_design_name`) is the FACTORY's word, and
-- it is HIS to give — it must never be guessed. But a stockist often has several brands that print
-- the SAME word: only some brands mint their own code (`601001`), the rest just carry the design's
-- own name. Retyping it per brand is pure friction, so let him DECLARE it once, per brand.
--
-- `brands.uses_design_name` = "this brand prints the same design name as the default brand".
-- It is a PREFILL ONLY: the New Design covers section fills a BLANK cover field, and he can always
-- type over it. Nothing here writes a cover name on its own.
--
-- Fill order (screens/stockist/new_design_screen.dart):
--   1. the DEFAULT brand's cover word for THIS design  (what he typed for FAMOUS)
--   2. failing that, the ARTWORK's own name             (print_master.print_name)
--
-- ⚠️ This is NOT the folder/PDF import defaulting a cover name from a filename — that stays banned
-- (a filename is his word for the ARTWORK, and passing it off as a factory's box label is a
-- forgery). The difference is that here HE declared it, per brand, with the box in front of him.

alter table public.brands
  add column if not exists uses_design_name boolean not null default false;

comment on column public.brands.uses_design_name is
  'This brand prints the same design name as the default brand. Prefills the cover word in New '
  'Design (blank fields only, always editable). Never writes a cover name by itself.';

-- The writer. Mirrors stockist_set_brand_hidden: your own brand only. The DEFAULT brand may carry
-- it too — it is the one every other brand copies from, but it is also just a brand.
create or replace function public.stockist_set_brand_uses_design_name(
  p_brand_id uuid, p_on boolean)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_stk uuid;
begin
  select b.stockist_id into v_stk
  from brands b join stockists s on s.id = b.stockist_id
  where b.id = p_brand_id and s.user_id = auth.uid();
  if v_stk is null then raise exception 'Not your brand'; end if;
  update brands set uses_design_name = coalesce(p_on, false) where id = p_brand_id;
end; $function$;

revoke all on function public.stockist_set_brand_uses_design_name(uuid, boolean) from public, anon;
grant execute on function public.stockist_set_brand_uses_design_name(uuid, boolean) to authenticated;

-- The reader: carry the flag out to the app.
create or replace function public.my_brands()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', b.id, 'name', b.name, 'logo_url', b.logo_url,
           'sort_order', b.sort_order, 'is_active', b.is_active,
           'is_default', b.is_default, 'status', b.status,
           'hidden_by_stockist', b.hidden_by_stockist,
           'delete_scheduled_at', b.delete_scheduled_at,
           'uses_design_name', b.uses_design_name,
           'catalog_count', (select count(*) from stock_catalogs c where c.brand_id = b.id))
         order by b.sort_order, b.created_at), '[]'::jsonb)
  from brands b
  where b.stockist_id in (select id from stockists where user_id = auth.uid())
    and b.status <> 'off';
$function$;
