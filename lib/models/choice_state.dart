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
