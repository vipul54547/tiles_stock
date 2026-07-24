-- 20260724k — 🖼️ MEDIA PORTFOLIO, P2: storage bucket for 360 Pano2VR bundles.
--
-- A 360 is a Pano2VR static export (index.html + pano.xml + pano2vr_player.js + tiles/ ~1600 jpgs,
-- ~47 MB) — too many files / too big for Cloudinary, so it's hosted as a folder in Supabase Storage.
-- The stockist uploads the whole folder (Windows) under `<stockist_id>/<asset_id>/…`; the media_asset
-- stores the public index.html URL; the buyer /s/ page embeds it in an <iframe>.
--
-- Public bucket → the login-free /s/ page serves the bundle without auth. Writes are authenticated
-- (a stockist uploads their own; media gating/quota is enforced by media_add, not storage).

insert into storage.buckets (id, name, public)
values ('portfolio-360', 'portfolio-360', true)
on conflict (id) do nothing;

drop policy if exists "portfolio_360_read" on storage.objects;
create policy "portfolio_360_read" on storage.objects
  for select to public using (bucket_id = 'portfolio-360');

drop policy if exists "portfolio_360_write" on storage.objects;
create policy "portfolio_360_write" on storage.objects
  for all to authenticated
  using (bucket_id = 'portfolio-360')
  with check (bucket_id = 'portfolio-360');
