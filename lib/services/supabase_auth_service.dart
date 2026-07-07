import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show UserAttributes, OtpType;
import '../main.dart';
import '../models/choice_state.dart';
import '../utils/device_id.dart';
import 'supabase_data_service.dart';

enum UserRole { admin, stockist, endUser }

/// The single super admin (final authority). Only this account can create or
/// manage sub-admins, and it can never be deactivated. Kept lowercase for
/// case-insensitive comparison.
const String kSuperAdminEmail = 'vipul54547@gmail.com';

/// True when the currently signed-in user is the super admin.
bool get isSuperAdmin =>
    (supabase.auth.currentUser?.email ?? '').toLowerCase() == kSuperAdminEmail;

/// True for an anonymous "browse as guest" session. Guests can browse designs
/// but cannot inquire, see stockist IDs/contacts, or create groups.
bool get isGuest => supabase.auth.currentUser?.isAnonymous ?? false;

/// Days since the current session was created — drives the guest-trial's
/// ~1-month "create your login" prompt. Null when unknown.
int? get sessionAgeDays {
  final c = supabase.auth.currentUser?.createdAt;
  final d = c == null ? null : DateTime.tryParse(c);
  return d == null ? null : DateTime.now().difference(d).inDays;
}

class SupabaseAuthService {
  UserRole? _role;
  UserRole? get currentRole => _role;

  Future<UserRole?> login(String email, String password) async {
    final res = await supabase.auth.signInWithPassword(
      email: email,
      password: password,
    );
    if (res.user == null) throw 'No user returned from sign-in';
    final role = await _loadProfile(res.user!.id);
    await _enforceDeviceLimit(); // signs out + throws if over the device limit
    await _loadAppSettings();
    return role;
  }

  /// Anonymous "browse as guest" sign-in. No profile/end_user row exists for
  /// guests — they're treated as a limited end user.
  Future<UserRole> loginAsGuest() async {
    await supabase.auth.signInAnonymously();
    _role = UserRole.endUser;
    await _loadGuestIdentity();
    await _loadAppSettings();
    return UserRole.endUser;
  }

  // Guest-trial: a guest gets a lightweight end_user identity so they can SAVE
  // suppliers during the free trial (browse + save only; inquiring/ordering
  // triggers the convert prompt). Converting to a permanent phone login later
  // keeps the same user_id, so their saved suppliers carry over.
  Future<void> _loadGuestIdentity() async {
    try {
      final id = await supabase.rpc('ensure_guest_end_user');
      currentEndUserId = (id ?? '').toString();
      currentEndUserCanClaimPrivate = true;
    } catch (_) {
      currentEndUserId = '';
      currentEndUserCanClaimPrivate = false;
    }
  }

  // Called on app start to restore an existing session
  Future<UserRole?> checkExistingSession() async {
    // Load the global public-market flag on every cold start, even with no
    // session, so the login screen (e.g. the "Browse as guest" option) can
    // reflect whether the public market is live.
    await _loadAppSettings();
    final user = supabase.auth.currentUser;
    if (user == null) return null;
    if (user.isAnonymous) {
      _role = UserRole.endUser; // restored guest session
      await _loadGuestIdentity();
      await _loadAppSettings();
      return UserRole.endUser;
    }
    try {
      final role = await _loadProfile(user.id);
      await _enforceDeviceLimit(); // blocked restore → throws → treated as logged out
      await _loadAppSettings();
      return role;
    } catch (_) {
      return null;
    }
  }

  /// Message thrown (and surfaced on the login screen) when a deactivated user
  /// tries to sign in. They are signed back out before this is thrown.
  static const deactivatedMessage =
      'Your account has been deactivated. Please contact the administrator.';

  Future<UserRole?> _loadProfile(String userId) async {
    final String roleStr;
    final dynamic adminActive;
    try {
      final profile = await supabase
          .from('profiles')
          .select('role, is_active')
          .eq('id', userId)
          .single();
      roleStr = profile['role'] as String;
      adminActive = profile['is_active'];
    } catch (e) {
      throw 'Profile load failed: $e';
    }

    if (roleStr == 'admin') {
      // The super admin is never blocked; a deactivated sub-admin is.
      if (!isSuperAdmin) await _ensureActive(adminActive);
      _role = UserRole.admin;
      return _role;
    }

    if (roleStr == 'stockist') {
      final stockist = await supabase
          .from('stockists')
          .select('id, sequential_id, is_active, business_type')
          .eq('user_id', userId)
          .single();
      await _ensureActive(stockist['is_active']);
      currentStockistId   = stockist['sequential_id'] as String;
      currentStockistUUID = stockist['id']            as String;
      currentStockistBusinessType  =
          (stockist['business_type'] as String?) ?? 'M';
      _role = UserRole.stockist;
      return _role;
    }

    final eu = await supabase
        .from('end_users')
        .select('id, is_active, can_claim_private')
        .eq('user_id', userId)
        .single();
    await _ensureActive(eu['is_active']);
    currentEndUserId = eu['id'] as String;
    currentEndUserCanClaimPrivate = eu['can_claim_private'] as bool? ?? false;
    _role = UserRole.endUser;
    return _role;
  }

  // Blocks a deactivated account: sign back out and throw the friendly message.
  Future<void> _ensureActive(dynamic isActive) async {
    if (isActive == false) {
      await supabase.auth.signOut();
      throw deactivatedMessage;
    }
  }

  /// Message surfaced on the login screen when a user is already signed in on
  /// the maximum number of devices their admin allows.
  static const deviceLimitMessage =
      'This login is already active on the maximum number of devices allowed. '
      'Log out on another device, or ask the administrator to reset your devices.';

  String _deviceLabel() {
    if (kIsWeb) return 'Web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'Android';
      case TargetPlatform.iOS:
        return 'iOS';
      case TargetPlatform.windows:
        return 'Windows';
      case TargetPlatform.macOS:
        return 'macOS';
      case TargetPlatform.linux:
        return 'Linux';
      default:
        return 'Other';
    }
  }

  /// Registers this install as an active device and enforces the per-user cap.
  /// On 'blocked' it signs the user back out and throws [deviceLimitMessage].
  /// Guests are never limited.
  Future<void> _enforceDeviceLimit() async {
    if (isGuest) return;
    try {
      final deviceId = await DeviceId.get();
      final result = await supabase.rpc('register_device',
          params: {'p_device_id': deviceId, 'p_label': _deviceLabel()});
      if (result == 'blocked') {
        await supabase.auth.signOut();
        throw deviceLimitMessage;
      }
    } on String {
      rethrow; // the deviceLimitMessage above
    } catch (_) {
      // Never lock a user out on a transient RPC/network error — allow the
      // login through rather than failing closed on infrastructure hiccups.
    }
  }

  /// Loads global, user-independent app settings into session state. Currently
  /// just the super-admin "go live" switch ([publicMarketLive]). Never throws —
  /// falls back to the safe private-first default (false) on any error.
  Future<void> _loadAppSettings() async {
    try {
      publicMarketLive = await SupabaseDataService().getPublicMarketEnabled();
    } catch (_) {
      publicMarketLive = false;
    }
  }

  /// Deep link the password-reset email redirects back to. The matching scheme
  /// is registered in AndroidManifest.xml and must be added to the Supabase
  /// dashboard's "Redirect URLs" allow-list (Authentication → URL Configuration).
  static const passwordResetRedirect = 'tilesstock://reset-password-callback';

  /// Sends a password-reset email via Supabase Auth. The user gets a link that
  /// reopens the app (via [passwordResetRedirect]) so they can set a new
  /// password. Throws on failure so the UI can surface it.
  Future<void> sendPasswordReset(String email) async {
    await supabase.auth.resetPasswordForEmail(
      email.trim(),
      redirectTo: passwordResetRedirect,
    );
  }

  // ── Guest-trial: convert a guest to a permanent phone login (OTP) ──────────
  // Sends a phone-change OTP. Upgrades the anonymous account → permanent on
  // verify, keeping the SAME user_id so saved suppliers carry over. Throws a
  // friendly message if phone auth isn't wired yet (no SMS provider configured).
  Future<void> sendConvertOtp(String phoneE164) async {
    try {
      await supabase.auth.updateUser(UserAttributes(phone: phoneE164));
    } catch (e) {
      throw _otpError(e);
    }
  }

  /// Verifies the OTP (finishing guest→permanent) then promotes the guest
  /// end_user row to a real member. isGuest auto-flips false once the phone is
  /// linked; currentEndUserId is unchanged (same end_user row).
  Future<void> verifyConvertOtp(
      String phoneE164, String code, String company) async {
    try {
      await supabase.auth.verifyOTP(
          phone: phoneE164, token: code, type: OtpType.phoneChange);
    } catch (e) {
      throw _otpError(e);
    }
    await supabase.rpc('promote_guest_end_user',
        params: {'p_company': company, 'p_phone': phoneE164});
  }

  String _otpError(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('provider') ||
        s.contains('not enabled') ||
        s.contains('unsupported') ||
        s.contains('sms') ||
        s.contains('disabled')) {
      return 'Phone login isn\'t available yet. Please try again later or '
          'tap "Need help?" to reach us on WhatsApp.';
    }
    return e.toString().replaceAll('AuthException:', '').trim();
  }

  Future<void> logout() async {
    // Free this device's slot so the user can sign in elsewhere.
    try {
      final deviceId = await DeviceId.get();
      await supabase.rpc('unregister_device', params: {'p_device_id': deviceId});
    } catch (_) {}
    await supabase.auth.signOut();
    _clearSession();
  }

  /// Permanently deletes the signed-in user's OWN account and all their data
  /// (App Store requirement 5.1.1(v)). Calls the SECURITY DEFINER
  /// `delete_my_account` RPC, which only ever acts on the caller's auth.uid().
  /// Throws on failure so the UI can surface it. Works for buyers, guests and
  /// stockists; admin accounts are rejected server-side.
  Future<void> deleteAccount() async {
    // Best-effort: release this device slot before the user row disappears.
    try {
      final deviceId = await DeviceId.get();
      await supabase.rpc('unregister_device', params: {'p_device_id': deviceId});
    } catch (_) {}
    await supabase.rpc('delete_my_account');
    await supabase.auth.signOut();
    _clearSession();
  }

  void _clearSession() {
    _role = null;
    currentStockistId   = '';
    currentStockistUUID = '';
    currentStockistDisplayName = '';
    currentStockistBusinessType = 'M';
    currentEndUserId    = '';
    currentEndUserCanClaimPrivate = false;
    publicMarketLive = false;
    myChoiceQuantities.clear();
  }

  Future<String?> registerEndUser({
    required String email,
    required String password,
    required String companyName,
    required String contactPerson,
    required String phone,
    String countryCode = '+91',
    required String city,
    String? gstNumber,
  }) async {
    try {
      final res = await supabase.auth.signUp(email: email, password: password);
      if (res.user == null) return null;

      final userId = res.user!.id;

      await supabase.from('profiles').insert({'id': userId, 'role': 'end_user'});

      final eu = await supabase.from('end_users').insert({
        'user_id':        userId,
        'company_name':   companyName,
        'contact_person': contactPerson,
        'phone':          phone,
        'country_code':   countryCode,
        'city':           city,
        'gst_number':     gstNumber,
      }).select().single();

      currentEndUserId = eu['id'] as String;
      return eu['id'];
    } catch (_) {
      return null;
    }
  }
}
