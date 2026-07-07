-- Self-service buyer profile edit: lets the logged-in end user update their own
-- end_users row (company, contact, phone, city, GST). Auth-scoped via auth.uid()
-- so a buyer can only ever touch their own row. Mirrors stockist_update_profile.
-- Applied to project buxjebeeiwyrsakeucyk 2026-07-07.
create or replace function public.end_user_update_profile(
  p_company      text,
  p_contact      text,
  p_phone        text,
  p_country_code text,
  p_city         text,
  p_gst          text
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update end_users set
    -- Company is the buyer's identity to suppliers — never blank it out.
    company_name   = coalesce(nullif(btrim(p_company), ''), company_name),
    contact_person = nullif(btrim(p_contact), ''),
    phone          = nullif(btrim(p_phone), ''),
    country_code   = coalesce(nullif(btrim(p_country_code), ''), country_code),
    city           = nullif(btrim(p_city), ''),
    gst_number     = nullif(btrim(p_gst), '')
  where user_id = auth.uid();

  if not found then
    raise exception 'No buyer profile for the current user';
  end if;
end;
$$;

revoke execute on function public.end_user_update_profile(text,text,text,text,text,text) from public;
grant  execute on function public.end_user_update_profile(text,text,text,text,text,text) to authenticated;
