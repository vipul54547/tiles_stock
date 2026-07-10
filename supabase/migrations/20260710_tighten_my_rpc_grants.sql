-- Narrow the my_* RPCs to `authenticated`. Hygiene, not a fix.
--
-- my_stock, my_library, my_private_designs and my_surface_labels all carry
-- EXECUTE for PUBLIC (and so anon, via the published publishable key). That is
-- NOT a leak: each resolves the caller through auth.uid(), so the anon role
-- gets an exception (my_library: "Only stockists have a library") or an empty
-- result (the other three). Unlike the legacy add_stock / dispatch_stock
-- revoked in 20260710_revoke_legacy_stock_rpcs.sql, which took the stockist id
-- as a plain argument and checked nothing.
--
-- Nothing legitimate calls them as anon: every caller in
-- supabase_data_service.dart runs behind a signed-in session. Guest buyers use
-- Supabase anonymous SIGN-IN, which issues the `authenticated` role, not `anon`
-- -- so they keep working.
--
-- Revoke from PUBLIC too, not just anon: an EXECUTE grant to PUBLIC is
-- inherited by every role, so revoking anon alone would leave the door open.
-- Then re-grant explicitly to the two roles that need it. service_role is kept,
-- as in the other two revoke migrations.
--
-- This supersedes the "Grants" block at the bottom of
-- 20260710_surface_label_my_stock_library_catalog.sql, which reproduced the old
-- anon grants verbatim to keep repo/DB parity at the time it was written. On a
-- clean replay that file runs first and this one narrows it -- end state below.

revoke execute on function public.my_stock()           from anon, public;
revoke execute on function public.my_library()         from anon, public;
revoke execute on function public.my_private_designs() from anon, public;
revoke execute on function public.my_surface_labels()  from anon, public;

grant execute on function public.my_stock()           to authenticated, service_role;
grant execute on function public.my_library()         to authenticated, service_role;
grant execute on function public.my_private_designs() to authenticated, service_role;
grant execute on function public.my_surface_labels()  to authenticated, service_role;
