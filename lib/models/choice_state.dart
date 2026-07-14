// Global session-level state

import '../utils/business_types.dart';

// My Choice: designId → quantity (boxes) the buyer wants
final Map<String, int> myChoiceQuantities = {};

// Logged-in stockist — both are set together after login
String currentStockistId   = '';  // sequential_id e.g. '001' (display use)
String currentStockistUUID = '';  // Supabase UUID  (DB query use)
// The logged-in stockist's own anonymity, so OUTGOING share messages use the
// masked trade name instead of the real/default-brand name. Loaded at login.
//
// Effective anonymity is GATED by [publicMarketLive]: anonymity only exists to
// hide a brand from strangers in the public marketplace. While the market is
// dormant (private-first runway), buyers reach a stockist only via a link the
// stockist sent them — they already know who it is — so masking the name is
// pointless and confusing. So when the market is off, nobody is anonymous,
// regardless of the stored per-stockist flag. One switch gates both (see the
// design note on [publicMarketLive]). The setter stores the raw DB value; the
// getter applies the gate at read time, so it can never go stale on load order.
// Anonymity removed 2026-07-07 — real names everywhere. currentStockistDisplayName
// kept only as a harmless empty holder for legacy resets.
String currentStockistDisplayName = '';

/// The logged-in stockist's business / actor type: 'M' (Manufacturer/Author),
/// 'T' (Trader) or 'W' (Wholesaler). Loaded at login. Drives which upload path
/// the stockist gets — authors get the structured PDF flow, importers (T/W) get
/// the external-supplier mapping importer. See lib/utils/business_types.dart.
String currentStockistBusinessType = 'M';

/// True when the logged-in stockist is a Trader/Wholesaler (importer).
bool get currentStockistIsImporter =>
    isImporterType(currentStockistBusinessType);

/// How this stockist's BOXES ARE STAMPED — 'attribute' or 'in_name'. Loaded at login.
///
/// It describes the physical box, nothing else:
///   * 'attribute' — the stamp carries the design name AND the surface as two separate
///     fields (e.g. famous ceramic: `ANT BIANCO | GLOSSY`). One stamped name therefore
///     covers several surfaces, so **stock entry must ask which surface** — that question
///     is really "which product". These stockists are RARE.
///   * 'in_name'  — the stamp carries the name only. The name alone already identifies one
///     product: they make a single surface, or they encode it in the number range
///     (10001-19999 = Glossy, 20001-29999 = Matt). **Stock entry must NOT ask** — the
///     product already knows its surface and the stock inherits it.
///
/// It has NO influence on identity. (Surface is always part of the product key.)
String currentStockistSurfaceMode = 'in_name';

/// 🚫 **DEAD — nothing reads this, and nothing should.** Add Stock no longer asks for a surface
/// from anyone. It used to, for an `attribute` stockist, because the design picker showed only the
/// PRINT's name (`1001`) and could not tell that print's several pieces apart — so the surface
/// dropdown was really asking **which product**. The picker now names the PIECE (`1001 — MATTE`),
/// so the question is answered at the point of choosing, and asking it twice let the two answers
/// DISAGREE: the surface silently moved the stock to a different product, and could even MINT one.
///
/// The stock inherits the piece's surface. Surface is still product identity — the question just
/// belongs in the Library, where a product is made, not at the stock counter.
/// (20260714c_stock_add_holding_never_creates_a_product)
@Deprecated('Add Stock never asks for a surface. The piece already knows it.')
bool get currentStockistAsksSurface =>
    currentStockistSurfaceMode == 'attribute';

/// The logged-in stockist has opted into saving customers on dispatch/order
/// (admin-set `customers_enabled`). Loaded at login. Gates the Customers entry
/// + history screens. (project_customer_history)
bool currentStockistCustomersEnabled = false;

// Logged-in end user
String currentEndUserId = '';  // Supabase UUID
// Admin-set: may this buyer add (claim) catalog links? Drives whether the
// Public/Private/Both market tabs and the add-link button are shown at all.
// Guests and not-permitted buyers stay false → silent public-only mode.
bool currentEndUserCanClaimPrivate = false;

// Super-admin "go live" switch (app_settings.public_market_enabled). While false
// (the ~1yr private-first runway) the public market AND stockist anonymity stay
// dormant — every public/anonymity control is hidden. Loaded once at startup/login.
bool publicMarketLive = false;

// Set by the share-link handler when a buyer opened a supplier's /s/ link and we
// auto-added it to My Suppliers. The My Suppliers screen reads it once (on next
// build) to show the "supplier added" confirmation, then clears it.
String? pendingSupplierAdded;

// Buyer search mode shared across all buyer screens for the session:
// true  = SMART (synonym/multi-language expansion, e.g. bianco = white),
// false = NORMAL (plain literal text match). Toggled from the search bar.
bool smartSearch = true;

// Test accounts for development (email → sequential_id)
const Map<String, String> stockistTestAccounts = {
  'krishna@test.com': '002',
  'silver@test.com':  '018',
  'metro@test.com':   '015',
};
