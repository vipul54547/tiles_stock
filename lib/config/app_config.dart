class AppConfig {
  static const supabaseUrl = 'https://buxjebeeiwyrsakeucyk.supabase.co';
  static const supabaseAnonKey = 'sb_publishable_6-1LdA_YMfkTvaDA0JwCXg_YuHmcb-x';
  static const cloudinaryCloudName = 'dt9cifer9';
  static const cloudinaryUploadPreset = 'ml_default';
  static const cloudinaryApiKey = '217379279718255';

  /// Base URL of the deployed web catalog. A stockist's private share link is
  /// `$shareBaseUrl/s/<share_token>`. Update this to the real domain once the
  /// Flutter‑Web build is hosted (e.g. https://catalog.yourbrand.com).
  static const shareBaseUrl = 'https://tilesdesign.in';

  // ── App store links (web "download the app" nudge) ────────────────────────
  // The web catalog at [shareBaseUrl] is served to BOTH Android and iOS browser
  // visitors, so the download nudge is platform-aware: Android → Play Store,
  // iOS → App Store, anything else → [storeFallbackUrl]. Fill these in when each
  // store listing goes live; an empty store URL falls back automatically.
  static const androidStoreUrl = ''; // e.g. https://play.google.com/store/apps/details?id=in.tilesdesign.stock
  static const iosStoreUrl     = ''; // e.g. https://apps.apple.com/app/idXXXXXXXXXX
  /// Shown when the visitor's platform has no store link yet (or on desktop).
  static const storeFallbackUrl = shareBaseUrl;

  /// True once at least one real store link exists — gates the download nudge so
  /// it only appears when there's actually somewhere to send people.
  static bool get hasAnyStoreLink =>
      androidStoreUrl.isNotEmpty || iosStoreUrl.isNotEmpty;

  /// Tiles Stock team WhatsApp for buyer "Help" / support — digits only with
  /// country code (no +), opened via wa.me/$supportWhatsApp.
  static const supportWhatsApp = '919726966906';
}
