// Global session-level state

// My Choice: designId → quantity (boxes) the buyer wants
final Map<String, int> myChoiceQuantities = {};

// Logged-in stockist — both are set together after login
String currentStockistId   = '';  // sequential_id e.g. '001' (display use)
String currentStockistUUID = '';  // Supabase UUID  (DB query use)

// Logged-in end user
String currentEndUserId = '';  // Supabase UUID

// Test accounts for development (email → sequential_id)
const Map<String, String> stockistTestAccounts = {
  'krishna@test.com': '002',
  'silver@test.com':  '018',
  'metro@test.com':   '015',
};
