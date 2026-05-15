// Global session-level state for My Choice feature.
// designId → quantity (boxes) the user wants to order.
final Map<String, int> myChoiceQuantities = {};

// Stockist ID of the currently logged-in stockist user.
String currentStockistId = '001';

// email → stockist ID mapping for test accounts.
const Map<String, String> stockistTestAccounts = {
  'krishna@test.com': '002',
  'silver@test.com':  '018',
  'metro@test.com':   '015',
};
