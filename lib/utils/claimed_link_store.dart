import 'package:shared_preferences/shared_preferences.dart';

/// Remembers which supplier `/s/` tokens the buyer has already **claimed** or
/// **dismissed**, persisted across app restarts.
///
/// The "You copied a supplier link — add it?" clipboard nudge should not
/// re-appear for a link the buyer has already added (via the banner, the paste
/// dialog, or a deep-link tap) or explicitly waved away — even though the link
/// often stays sitting on the clipboard long after. A share token is not the
/// same as the catalog id we hold in memory, and the in-memory dismissed set
/// resets every launch, so we key off the raw token here and store it.
class ClaimedLinkStore {
  static const _claimedKey = 'claimed_share_tokens';
  static const _dismissedKey = 'dismissed_clipboard_tokens';

  static Future<void> _add(String key, String token) async {
    final t = token.trim();
    if (t.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final set = (prefs.getStringList(key) ?? const <String>[]).toSet()..add(t);
    await prefs.setStringList(key, set.toList());
  }

  /// Record a token the buyer just claimed (any add path).
  static Future<void> addClaimed(String token) => _add(_claimedKey, token);

  /// Record a token the buyer dismissed from the clipboard nudge.
  static Future<void> addDismissed(String token) => _add(_dismissedKey, token);

  /// True when this token was already claimed OR dismissed → suppress the nudge.
  static Future<bool> isKnown(String token) async {
    final t = token.trim();
    if (t.isEmpty) return true;
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_claimedKey) ?? const []).contains(t) ||
        (prefs.getStringList(_dismissedKey) ?? const []).contains(t);
  }
}
