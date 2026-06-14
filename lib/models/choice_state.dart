// Global session-level state

// My Choice: designId → quantity (boxes) the buyer wants
final Map<String, int> myChoiceQuantities = {};

// Logged-in stockist — both are set together after login
String currentStockistId   = '';  // sequential_id e.g. '001' (display use)
String currentStockistUUID = '';  // Supabase UUID  (DB query use)

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
