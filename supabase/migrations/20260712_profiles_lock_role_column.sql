-- Close a privilege escalation: any logged-in user could make themselves an admin.
--
-- FOUND 2026-07-12. All 47 admin_* RPCs DO check the caller's role server-side, via
--   current_user_role() := (select role from profiles where id = auth.uid())
-- so the guard itself is sound. The hole is the table it reads.
--
-- `profiles` is (id, role, is_active). `authenticated` held a table-level UPDATE grant
-- covering `role`, and the RLS policy profiles_update_own was
--   USING (id = auth.uid())  WITH CHECK <null>
-- — and a null WITH CHECK falls back to the USING expression. There is no trigger on the
-- table. So `update profiles set role = 'admin' where id = auth.uid()` succeeded: the row is
-- yours before the write and still yours after it. current_user_role() then honestly answers
-- 'admin', and all 47 RPCs open. profiles_insert_own had the same shape, so a fresh signup
-- could mint itself an admin directly.
--
-- Same hole let a DEACTIVATED user flip is_active back to true and sign in again.
--
-- Verified safe to revoke:
--   * The app NEVER updates profiles. It only reads it (supabase_auth_service.dart:106) and
--     inserts one row at signup with a hardcoded 'end_user' (:323).
--   * All 5 functions that write profiles — admin_delete_end_user, admin_delete_stockist,
--     approve_registration_request, create_user_from_excel, set_admin_active — are
--     SECURITY DEFINER, so they run as the owner and bypass both GRANTs and RLS. Untouched.

begin;

-- 1. Nobody signed in may write their own role/is_active. Grants are checked BEFORE RLS, so
--    this alone closes the escalation. Admin writes keep working (SECURITY DEFINER, above).
revoke update, delete on public.profiles from authenticated, anon;

-- anon could never satisfy `id = auth.uid()` anyway (auth.uid() is null); revoke regardless.
revoke insert on public.profiles from anon;

-- 2. The policy is now unreachable (no UPDATE grant survives). Drop it so the next reader is
--    not misled into thinking self-update is a supported path.
drop policy if exists profiles_update_own on public.profiles;

-- 3. Signup still needs to create its own row — but it may only ever create an end_user.
--    Stockists and admins are created by SECURITY DEFINER RPCs, which bypass this policy.
drop policy if exists profiles_insert_own on public.profiles;
create policy profiles_insert_own on public.profiles
  for insert to authenticated
  with check (id = auth.uid() and role = 'end_user');

commit;

-- Left in place deliberately:
--   profiles_select_own  (id = auth.uid())            — the app reads its own role. Required.
--   profiles_admin_all   (current_user_role()='admin') — now effectively read-only for admins,
--                                                        since no UPDATE/DELETE grant remains.
--                                                        Harmless; admin writes go via RPCs.
