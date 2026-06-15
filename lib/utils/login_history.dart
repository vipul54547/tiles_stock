import 'package:shared_preferences/shared_preferences.dart';

/// Tracks whether this install has ever completed a successful login.
///
/// Used to show first-time onboarding affordances — e.g. the "Get my login
/// details" helper on the login screen — only until the dealer is in, then
/// hide them. Persists across logout/login on the same install; a reinstall
/// resets it (which is fine — the helper reappears for a genuinely fresh start).
class LoginHistory {
  static const _key = 'has_logged_in_before';

  static Future<bool> hasLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  static Future<void> markLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
  }
}
