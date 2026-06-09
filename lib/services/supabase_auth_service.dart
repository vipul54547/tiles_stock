import '../main.dart';
import '../models/choice_state.dart';

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

class SupabaseAuthService {
  UserRole? _role;
  UserRole? get currentRole => _role;

  Future<UserRole?> login(String email, String password) async {
    final res = await supabase.auth.signInWithPassword(
      email: email,
      password: password,
    );
    if (res.user == null) throw 'No user returned from sign-in';
    return _loadProfile(res.user!.id);
  }

  /// Anonymous "browse as guest" sign-in. No profile/end_user row exists for
  /// guests — they're treated as a limited end user.
  Future<UserRole> loginAsGuest() async {
    await supabase.auth.signInAnonymously();
    _role = UserRole.endUser;
    currentEndUserId = '';
    return UserRole.endUser;
  }

  // Called on app start to restore an existing session
  Future<UserRole?> checkExistingSession() async {
    final user = supabase.auth.currentUser;
    if (user == null) return null;
    if (user.isAnonymous) {
      _role = UserRole.endUser; // restored guest session
      currentEndUserId = '';
      return UserRole.endUser;
    }
    try {
      return await _loadProfile(user.id);
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
          .select('id, sequential_id, is_active')
          .eq('user_id', userId)
          .single();
      await _ensureActive(stockist['is_active']);
      currentStockistId   = stockist['sequential_id'] as String;
      currentStockistUUID = stockist['id']            as String;
      _role = UserRole.stockist;
      return _role;
    }

    final eu = await supabase
        .from('end_users')
        .select('id, is_active')
        .eq('user_id', userId)
        .single();
    await _ensureActive(eu['is_active']);
    currentEndUserId = eu['id'] as String;
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

  Future<void> logout() async {
    await supabase.auth.signOut();
    _role = null;
    currentStockistId   = '';
    currentStockistUUID = '';
    currentEndUserId    = '';
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
