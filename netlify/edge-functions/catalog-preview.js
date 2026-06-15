// Netlify Edge Function: per-stockist link preview for share links.
//
// WhatsApp/Facebook/etc. crawlers fetch the shared URL but cannot read anything
// after a `#`, so the app's hash routes (`/#/s/<token>`) can't be previewed.
// This function runs on the PATH form `/s/<token>`: it looks up the stockist's
// (anonymity-gated) branding and returns HTML with OpenGraph tags so the link
// shows a branded card — then instantly redirects real browsers to the hash app
// (`/#/s/<token>`), which is untouched. Old hash links keep working as before.

const SUPABASE_URL = 'https://buxjebeeiwyrsakeucyk.supabase.co';
const SUPABASE_ANON = 'sb_publishable_6-1LdA_YMfkTvaDA0JwCXg_YuHmcb-x';

function esc(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

export default async (request, context) => {
  const url = new URL(request.url);
  const token = (url.pathname.split('/s/')[1] || '').split('/')[0].split('?')[0];
  const appUrl = `${url.origin}/#/s/${encodeURIComponent(token)}`;
  const fallbackImg = `${url.origin}/tilesdesign-og.png`;

  if (!token) return Response.redirect(`${url.origin}/`, 302);

  let stockist = null;
  let brand = null;
  let banner = null;
  let designCount = 0;
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/public_catalog`, {
      method: 'POST',
      headers: {
        apikey: SUPABASE_ANON,
        Authorization: `Bearer ${SUPABASE_ANON}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ p_token: token }),
    });
    if (res.ok) {
      const data = await res.json();
      stockist = data && data.stockist ? data.stockist : null;
      brand = data && data.brand ? data.brand : null;
      banner = data && data.banner ? data.banner : null;
      designCount = data && Array.isArray(data.designs) ? data.designs.length : 0;
    }
  } catch (_) {
    // fall through to a generic card / redirect
  }

  // Invalid/expired token: just hand off to the app (it shows "not found").
  if (!stockist) {
    return new Response(redirectHtml(appUrl), {
      headers: { 'content-type': 'text/html; charset=utf-8' },
    });
  }

  // overlay=true means the chosen banner is a GENERIC/anonymous image (system
  // overlays a "Welcome to [name]" trust strip). In that case `stockist.name` /
  // `banner.name` are already the (server-gated) masked-or-real name, and we must
  // NOT surface the brand name or tagline — they would leak an anonymous identity.
  // overlay=false means a finished BRANDED image, so brand identity is intended.
  const overlay = !!(banner && banner.overlay === true);
  const brandName = brand && brand.name ? String(brand.name).trim() : '';
  const company = (stockist.name && String(stockist.name).trim()) || 'Tile Catalog';
  const bannerName = banner && banner.name ? String(banner.name).trim() : '';
  const name = overlay ? (bannerName || company) : (brandName || company);
  const taglineBase =
    !overlay && stockist.tagline && String(stockist.tagline).trim()
      ? String(stockist.tagline).trim()
      : `${designCount} tile design${designCount === 1 ? '' : 's'} in stock`;
  const byLine = !overlay && brandName ? `by ${company} · ` : '';
  const description = `${byLine}${taglineBase} · Powered by TilesDesign`;
  // Use the admin-chosen banner (branded image, or the daily-rotated generic one)
  // so the link-preview thumbnail matches the on-page banner. Fall back to brand
  // logo, then stockist logo, then the TilesDesign mark.
  const image =
    (banner && banner.image_url && String(banner.image_url).trim()) ||
    (brand && brand.logo_url) || stockist.logo_url || fallbackImg;

  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(name)} — TilesDesign</title>
<meta property="og:type" content="website">
<meta property="og:site_name" content="TilesDesign">
<meta property="og:title" content="${esc(name)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:image" content="${esc(image)}">
<meta property="og:url" content="${esc(url.href)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${esc(name)}">
<meta name="twitter:description" content="${esc(description)}">
<meta name="twitter:image" content="${esc(image)}">
<meta http-equiv="refresh" content="0; url=${esc(appUrl)}">
<script>location.replace(${JSON.stringify(appUrl)});</script>
</head>
<body style="font-family:sans-serif;text-align:center;padding:40px;color:#1B4F72">
Opening ${esc(name)}…
</body>
</html>`;

  return new Response(html, {
    headers: { 'content-type': 'text/html; charset=utf-8' },
  });
};

function redirectHtml(appUrl) {
  return `<!doctype html><html><head>
<meta http-equiv="refresh" content="0; url=${appUrl}">
<script>location.replace(${JSON.stringify(appUrl)});</script>
</head><body>Redirecting…</body></html>`;
}

export const config = { path: '/s/:token' };
