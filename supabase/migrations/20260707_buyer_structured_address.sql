-- Buyer structured address parity with stockists: pincode → state/district/city.
-- Adds state/district/pincode to end_users + registration_requests and threads
-- them through the self-service profile update, the registration request, and
-- the admin approval that creates the end_users row.
-- Applied to project buxjebeeiwyrsakeucyk 2026-07-07.

alter table public.end_users
  add column if not exists state    text,
  add column if not exists district text,
  add column if not exists pincode  text;

alter table public.registration_requests
  add column if not exists state    text,
  add column if not exists district text,
  add column if not exists pincode  text;

-- ── Self-service buyer profile update (extend with address) ──────────────────
drop function if exists public.end_user_update_profile(text,text,text,text,text,text);
create or replace function public.end_user_update_profile(
  p_company      text,
  p_contact      text,
  p_phone        text,
  p_country_code text,
  p_city         text,
  p_gst          text,
  p_state        text default '',
  p_district     text default '',
  p_pincode      text default ''
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update end_users set
    company_name   = coalesce(nullif(btrim(p_company), ''), company_name),
    contact_person = nullif(btrim(p_contact), ''),
    phone          = nullif(btrim(p_phone), ''),
    country_code   = coalesce(nullif(btrim(p_country_code), ''), country_code),
    city           = nullif(btrim(p_city), ''),
    gst_number     = nullif(btrim(p_gst), ''),
    state          = nullif(btrim(p_state), ''),
    district       = nullif(btrim(p_district), ''),
    pincode        = nullif(btrim(p_pincode), '')
  where user_id = auth.uid();
  if not found then
    raise exception 'No buyer profile for the current user';
  end if;
end;
$$;
revoke execute on function public.end_user_update_profile(text,text,text,text,text,text,text,text,text) from public;
grant  execute on function public.end_user_update_profile(text,text,text,text,text,text,text,text,text) to authenticated;

-- ── Registration request (extend with address) ──────────────────────────────
drop function if exists public.submit_registration_request(text,text,text,text,text,text,text,text);
create or replace function public.submit_registration_request(
  p_email text, p_password text, p_company_name text,
  p_contact_person text default ''::text, p_phone text default ''::text,
  p_city text default ''::text, p_gst_number text default null::text,
  p_country_code text default '+91'::text,
  p_state text default ''::text, p_district text default ''::text,
  p_pincode text default ''::text
) returns void
language plpgsql
security definer
set search_path to 'public','extensions','pg_temp'
as $function$
declare v_email text := lower(trim(p_email));
begin
  if v_email = '' or position('@' in v_email) = 0 then
    raise exception 'Invalid email';
  end if;
  if length(p_password) < 6 then
    raise exception 'Password must be at least 6 characters';
  end if;
  if exists (select 1 from auth.users where lower(email) = v_email) then
    raise exception 'An account with this email already exists';
  end if;
  if exists (select 1 from registration_requests where lower(email) = v_email) then
    raise exception 'A registration request for this email is already pending';
  end if;
  insert into registration_requests(
    company_name, contact_person, email, phone, country_code, city,
    gst_number, password_hash, state, district, pincode)
  values (
    trim(p_company_name), trim(p_contact_person), v_email, trim(p_phone),
    coalesce(nullif(trim(coalesce(p_country_code, '')), ''), '+91'),
    trim(p_city), nullif(trim(coalesce(p_gst_number, '')), ''),
    crypt(p_password, gen_salt('bf')),
    nullif(trim(coalesce(p_state, '')), ''),
    nullif(trim(coalesce(p_district, '')), ''),
    nullif(trim(coalesce(p_pincode, '')), ''));

  insert into notifications(recipient_id, type, title, body)
  select p.id, 'registration', 'New registration request',
         v_email || ' has requested to join.'
  from profiles p where p.role = 'admin';
end; $function$;
grant execute on function public.submit_registration_request(text,text,text,text,text,text,text,text,text,text,text) to public;

-- ── Approval → carry address into the new end_users row ──────────────────────
create or replace function public.approve_registration_request(p_id text, p_priority numeric default 0, p_enduser_type text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
declare r registration_requests; v_uid uuid := gen_random_uuid(); v_seq text;
begin
  if current_user_role() <> 'admin' then
    raise exception 'Only admins can approve requests';
  end if;
  select * into r from registration_requests where id = p_id::uuid;
  if not found then raise exception 'Request not found'; end if;
  if exists (select 1 from auth.users where lower(email) = lower(r.email)) then
    delete from registration_requests where id = r.id;
    raise exception 'An account already exists for %', r.email;
  end if;

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    created_at, updated_at, confirmation_token, email_change,
    email_change_token_new, recovery_token
  ) values (
    '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated',
    'authenticated', lower(r.email), r.password_hash, now(), now(), now(),
    '', '', '', '');
  insert into auth.identities (
    id, provider_id, user_id, identity_data, provider,
    last_sign_in_at, created_at, updated_at
  ) values (
    gen_random_uuid(), lower(r.email), v_uid,
    jsonb_build_object('sub', v_uid::text, 'email', lower(r.email)),
    'email', now(), now(), now());
  insert into profiles (id, role) values (v_uid, 'end_user');

  v_seq := next_end_user_seq_id();
  insert into end_users (
    user_id, sequential_id, company_name, contact_person, phone, country_code,
    city, gst_number, priority, enduser_type, state, district, pincode
  ) values (
    v_uid, v_seq, r.company_name, r.contact_person, r.phone, r.country_code,
    r.city, r.gst_number, coalesce(p_priority, 0),
    nullif(trim(coalesce(p_enduser_type, '')), ''),
    r.state, r.district, r.pincode);

  perform _notify(v_uid, 'account', 'Registration approved',
    'Your account has been approved. Welcome to Tiles Stock!', '{}'::jsonb);

  delete from registration_requests where id = r.id;
  return jsonb_build_object('email', r.email, 'sequential_id', v_seq);
end; $function$;
