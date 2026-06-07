-- ============================================================
-- CREATE ALL TEST ACCOUNTS (run in Supabase SQL Editor)
-- Creates users directly in auth schema — no email needed
-- ============================================================

DO $$
DECLARE
  admin_uid    uuid := 'aec01a0c-13be-4aea-a3d4-19ef261bc8ca'; -- already exists
  stockist_uid uuid := gen_random_uuid();
  enduser_uid  uuid := gen_random_uuid();
BEGIN

  -- ── 1. CONFIRM ADMIN (already created via API, just confirm + add profile) ──
  UPDATE auth.users
  SET email_confirmed_at = NOW(),
      updated_at         = NOW()
  WHERE id = admin_uid
    AND email_confirmed_at IS NULL;

  INSERT INTO profiles (id, role)
  VALUES (admin_uid, 'admin')
  ON CONFLICT (id) DO NOTHING;

  -- ── 2. STOCKIST AUTH USER ────────────────────────────────────────────────────
  INSERT INTO auth.users (
    instance_id,
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    created_at,
    updated_at,
    confirmation_token,
    email_change,
    email_change_token_new,
    recovery_token
  ) VALUES (
    '00000000-0000-0000-0000-000000000000',
    stockist_uid,
    'authenticated',
    'authenticated',
    'stockist1@gmail.com',
    crypt('Test@123', gen_salt('bf')),
    NOW(), NOW(), NOW(),
    '', '', '', ''
  );

  INSERT INTO auth.identities (
    id,
    user_id,
    identity_data,
    provider,
    last_sign_in_at,
    created_at,
    updated_at
  ) VALUES (
    gen_random_uuid(),
    stockist_uid,
    jsonb_build_object('sub', stockist_uid::text, 'email', 'stockist1@gmail.com'),
    'email',
    NOW(), NOW(), NOW()
  );

  -- ── 3. END USER AUTH USER ────────────────────────────────────────────────────
  INSERT INTO auth.users (
    instance_id,
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    created_at,
    updated_at,
    confirmation_token,
    email_change,
    email_change_token_new,
    recovery_token
  ) VALUES (
    '00000000-0000-0000-0000-000000000000',
    enduser_uid,
    'authenticated',
    'authenticated',
    'enduser@tiles.com',
    crypt('Test@123', gen_salt('bf')),
    NOW(), NOW(), NOW(),
    '', '', '', ''
  );

  INSERT INTO auth.identities (
    id,
    user_id,
    identity_data,
    provider,
    last_sign_in_at,
    created_at,
    updated_at
  ) VALUES (
    gen_random_uuid(),
    enduser_uid,
    jsonb_build_object('sub', enduser_uid::text, 'email', 'enduser@tiles.com'),
    'email',
    NOW(), NOW(), NOW()
  );

  -- ── 4. PROFILES ──────────────────────────────────────────────────────────────
  INSERT INTO profiles (id, role) VALUES (stockist_uid, 'stockist');
  INSERT INTO profiles (id, role) VALUES (enduser_uid,  'end_user');

  -- ── 5. STOCKIST RECORD ───────────────────────────────────────────────────────
  INSERT INTO stockists (user_id, sequential_id, name, phone, city, state, address)
  VALUES (
    stockist_uid,
    '001',
    'Test Stockist Co.',
    '9876543210',
    'Morbi',
    'Gujarat',
    'Test Address, GIDC, Morbi - 363641'
  );

  -- ── 6. END USER RECORD ───────────────────────────────────────────────────────
  INSERT INTO end_users (user_id, company_name, contact_person, phone, city, gst_number)
  VALUES (
    enduser_uid,
    'Test Buyer Pvt. Ltd.',
    'Test User',
    '9876543211',
    'Ahmedabad',
    NULL
  );

  RAISE NOTICE 'Admin UUID    : %', admin_uid;
  RAISE NOTICE 'Stockist UUID : %', stockist_uid;
  RAISE NOTICE 'End User UUID : %', enduser_uid;

END $$;
