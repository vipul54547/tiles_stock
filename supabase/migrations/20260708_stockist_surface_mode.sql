-- Where the surface convention lives (project_per_brand_surface_mode, corrected).
--
-- The library stores the PRINT ("Satva White" = one artwork file). The glaze is
-- chosen when the tile is made, i.e. when stock is added — which is why
-- stock_add_holding() keys a holding on (library_id, brand_id, quality,
-- surface_type). surface_mode only decides whether we ASK for the glaze.
--
-- Whose convention is it? The FACTORY's:
--   * M  = the stockist IS the factory. Its brands are just alternate NAMES for
--          the same print (stockist_library_brand_names is N:M), so a per-brand
--          flag has no well-defined answer for one print. One setting per
--          stockist.  → stockists.surface_mode
--   * T/W = each carried brand IS a different factory, and stockist_library
--          .brand_id makes master↔brand 1:1. Per-brand is correct.
--          → brands.surface_mode (already exists, unchanged)
alter table public.stockists
  add column if not exists surface_mode text not null default 'in_name'
    check (surface_mode in ('attribute', 'in_name'));

-- Admin sets an M stockist's surface convention. Mirrors admin_set_stockist_td.
create or replace function public.admin_set_stockist_surface_mode(p_seq text, p_mode text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
begin
  if current_user_role() <> 'admin' then
    raise exception 'admin only';
  end if;
  if p_mode not in ('attribute', 'in_name') then
    raise exception 'Invalid surface mode';
  end if;
  update public.stockists set surface_mode = p_mode where sequential_id = p_seq;
end;
$function$;

revoke execute on function public.admin_set_stockist_surface_mode(text, text) from public;
grant  execute on function public.admin_set_stockist_surface_mode(text, text) to authenticated;

-- NOTE: stockist_library.surface_type is deliberately left ALONE. 400 of 773
-- prints carry a real surface put there by the PDF/Excel importers, and
-- add_edit_stock_screen / add_stock_batch_screen still read it as the default
-- glaze for a new holding. Clearing it would silently downgrade those to 'None'.
-- The print no longer *displays* a surface and never *requires* one; the column
-- survives as an import-supplied default until the importers are reworked to
-- write the glaze onto the holding directly.
