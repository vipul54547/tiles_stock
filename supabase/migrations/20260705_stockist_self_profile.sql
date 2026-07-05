-- Self-service stockist profile (project: stockist profile + share-card identity).
--
-- Until now a stockist could only SELECT their own row (policy stockists_read_own);
-- all edits went through admin_* RPCs. This adds a locked-down self-service RPC so
-- the stockist can maintain their own public identity (logo, name, brand colour,
-- tagline, and a structured pincode → state / district / city address).
--
-- State + district are stored BOTH as display text and as URL slugs so future SEO
-- landing pages (/tiles/<state_slug>/<district_slug>/) have a stable key. The
-- Flutter dropdowns supply canonical state/district values; the pincode autofill
-- (India Post API) pre-selects them. No table-level CHECK is added so existing
-- (possibly messy) rows are not rejected — the dropdown enforces cleanliness going
-- forward and the slug normalises whatever is stored.

-- 1. New identity/address columns.
alter table public.stockists
  add column if not exists pincode        text,
  add column if not exists district       text,
  add column if not exists state_slug     text,
  add column if not exists district_slug  text;

-- 2. Slug helper: lowercase, collapse any run of non-alphanumerics to a single
--    dash, trim leading/trailing dashes. Empty/na input → NULL (no dead slug).
create or replace function public.slugify(p_text text)
 returns text
 language sql
 immutable
as $function$
  select nullif(
           trim(both '-' from
             regexp_replace(lower(coalesce(p_text, '')), '[^a-z0-9]+', '-', 'g')),
           '');
$function$;

-- 3. Self-service profile update — the ONLY write path a stockist has to their own
--    row. Runs as definer but is hard-scoped to auth.uid(), so a stockist can only
--    ever touch their own record. Blank name/brand_color are ignored (never blanks
--    a required-ish field); logo/tagline CAN be cleared by passing ''.
create or replace function public.stockist_update_profile(
  p_name        text,
  p_logo_url    text,
  p_brand_color text,
  p_tagline     text,
  p_pincode     text,
  p_state       text,
  p_district    text,
  p_city        text
) returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_sid uuid;
begin
  select id into v_sid from public.stockists where user_id = auth.uid();
  if v_sid is null then
    raise exception 'Not a stockist account';
  end if;

  update public.stockists set
    name          = coalesce(nullif(btrim(p_name), ''), name),
    logo_url      = coalesce(p_logo_url, logo_url),
    brand_color   = coalesce(nullif(btrim(p_brand_color), ''), brand_color),
    tagline       = coalesce(p_tagline, tagline),
    pincode       = nullif(btrim(p_pincode), ''),
    state         = nullif(btrim(p_state), ''),
    district      = nullif(btrim(p_district), ''),
    city          = nullif(btrim(p_city), ''),
    state_slug    = public.slugify(p_state),
    district_slug = public.slugify(p_district)
  where id = v_sid;
end;
$function$;

revoke execute on function public.stockist_update_profile(text,text,text,text,text,text,text,text) from public;
grant  execute on function public.stockist_update_profile(text,text,text,text,text,text,text,text) to authenticated;

-- 4. Backfill state_slug for existing rows (district_slug stays NULL until a
--    stockist saves a district via the new screen).
update public.stockists
   set state_slug = public.slugify(state)
 where state is not null and state_slug is null;
