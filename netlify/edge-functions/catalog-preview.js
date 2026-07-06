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

// ── TilesDesign branding on the share card (B, C, D) ────────────────────────
// Master switch for every "TilesDesign" mention in the link-preview card:
//   B) og:site_name label,  C) "· Powered by TilesDesign" in the description,
//   D) the "— TilesDesign" suffix in the <title>.
// Set to `true` when we launch the marketplace to show TilesDesign branding
// again — that ONE line re-enables all of B/C/D. (Does NOT affect the A image.)
const SHOW_TILESDESIGN_BRANDING = false;

function esc(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// Encode text for a Cloudinary `l_text` layer: URL-encode, then double-encode the
// comma and slash Cloudinary treats as transformation delimiters.
function cxText(s) {
  return encodeURIComponent(String(s ?? '').trim())
    .replace(/%2C/g, '%252C')
    .replace(/%2F/g, '%252F');
}

// A branded fallback share image generated on the fly: the stockist's name (+ city)
// in white on their brand colour. No TilesDesign mark — used when they have neither
// an uploaded banner nor a logo. Base asset `share_card_base` is a plain canvas
// flooded to the brand colour via e_colorize.
// A message banner baked for the share card: the stockist's text-background with
// their heading + message overlaid (darkened for legibility). Returns null if the
// background isn't a Cloudinary URL, so the caller falls back to the raw image.
function messageCard(bgUrl, heading, message, style) {
  const marker = '/image/upload/';
  const i = bgUrl.indexOf(marker);
  if (i < 0) return null;
  const at = i + marker.length;
  const st = style || {};
  // S/M/L → font size; heading kept bigger than the body (matches the app).
  const hSize = { s: 56, m: 70, l: 88 }[st.headingSize] || 70;
  const mSize = { s: 36, m: 44, l: 56 }[st.msgSize] || 44;
  const hex = (v) => {
    const h = String(v || '').replace('#', '').toLowerCase();
    return /^[0-9a-f]{6}$/.test(h) ? h : 'ffffff';
  };
  const hCol = hex(st.headingColor);
  const mCol = hex(st.msgColor);
  // Compound gravity: vertical (top/bottom → north/south) × horizontal (left →
  // west, else centre). y offsets are relative to that gravity edge.
  const vpart = st.valign === 'top' ? 'north' : st.valign === 'bottom' ? 'south' : '';
  const hpart = st.align === 'left' ? 'west' : '';
  const grav =
    'g_' + ([vpart, hpart].filter(Boolean).join('_') || 'center') +
    (hpart ? ',x_80' : '');
  let hY, mY;
  if (st.valign === 'top') { hY = 70; mY = 190; }
  else if (st.valign === 'bottom') { hY = 190; mY = 70; }
  else { hY = -90; mY = 70; }
  const bodyOnlyY =
    st.valign === 'top' ? 90 : st.valign === 'bottom' ? 90 : 0;
  const head = heading
    ? `/l_text:Arial_${hSize}_bold:${cxText(heading)},co_rgb:${hCol},c_fit,w_1040/fl_layer_apply,${grav},y_${hY}`
    : '';
  const body =
    `/l_text:Arial_${mSize}:${cxText(message)},co_rgb:${mCol},c_fit,w_980` +
    `/fl_layer_apply,${grav},y_${heading ? mY : bodyOnlyY}`;
  const t = `c_fill,ar_5:2,w_1200,e_brightness:-45${head}${body}`;
  return bgUrl.slice(0, at) + t + '/' + bgUrl.slice(at);
}

function nameCard(title, city, brandColorHex) {
  const t = cxText(title || 'Tile Catalog');
  const sub = city ? cxText(city) : '';
  const bg = `w_1200,h_630,c_fill,e_colorize,co_rgb:${brandColorHex}`;
  const l1 =
    `l_text:Arial_82_bold:${t},co_white,c_fit,w_1040/fl_layer_apply,g_center,` +
    (sub ? 'y_-36' : 'y_0');
  const l2 = sub
    ? `/l_text:Arial_44:${sub},co_white,c_fit,w_900/fl_layer_apply,g_center,y_78`
    : '';
  return `https://res.cloudinary.com/dt9cifer9/image/upload/${bg}/${l1}${l2}/share_card_base.png`;
}

export default async (request, context) => {
  const url = new URL(request.url);
  const token = (url.pathname.split('/s/')[1] || '').split('/')[0].split('?')[0];
  const appUrl = `${url.origin}/#/s/${encodeURIComponent(token)}`;

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
  const poweredBy = SHOW_TILESDESIGN_BRANDING ? ' · Powered by TilesDesign' : '';
  const description = `${byLine}${taglineBase}${poweredBy}`;
  // Share-card image (slot A) — no TilesDesign anywhere in the chain:
  //   1. the stockist's OWN uploaded banner (overlay=false → genuinely theirs)
  //   2. their logo
  //   3. an auto-generated name-card on their brand colour
  // A generic/pool banner (overlay=true) is deliberately skipped — it isn't the
  // stockist's own art and used to leak TilesDesign branding.
  const brandColorHex = (() => {
    const c = String(stockist.brand_color || '').replace('#', '').trim();
    return /^[0-9a-fA-F]{6}$/.test(c) ? c.toLowerCase() : '1b4f72';
  })();
  const bannerText =
    banner && banner.banner_text ? String(banner.banner_text).trim() : '';
  const bannerHeading =
    banner && banner.banner_heading ? String(banner.banner_heading).trim() : '';
  const ownBanner =
    !overlay && banner && banner.image_url && String(banner.image_url).trim()
      ? String(banner.image_url).trim()
      : '';
  const logo = stockist.logo_url && String(stockist.logo_url).trim();
  // A message banner is baked (text over background); otherwise own banner → logo
  // → auto name-card. No TilesDesign in any branch.
  const msgStyle = banner
    ? {
        headingSize: banner.banner_heading_size,
        headingColor: banner.banner_heading_color,
        msgSize: banner.banner_msg_size,
        msgColor: banner.banner_msg_color,
        align: banner.banner_text_align,
      }
    : {};
  const image =
    (bannerText &&
      ownBanner &&
      messageCard(ownBanner, bannerHeading, bannerText, msgStyle)) ||
    ownBanner ||
    logo ||
    nameCard(name, stockist.city && String(stockist.city).trim(), brandColorHex);

  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(name)}${SHOW_TILESDESIGN_BRANDING ? ' — TilesDesign' : ''}</title>
<meta property="og:type" content="website">
${SHOW_TILESDESIGN_BRANDING ? '<meta property="og:site_name" content="TilesDesign">' : ''}
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
