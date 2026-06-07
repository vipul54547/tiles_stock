import '../main.dart';
import '../models/choice_state.dart';

enum UserRole { admin, stockist, endUser }

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

  // Called on app start to restore an existing session
  Future<UserRole?> checkExistingSession() async {
    final user = supabase.auth.currentUser;
    if (user == null) return null;
    try {
      return await _loadProfile(user.id);
    } catch (_) {
      return null;
    }
  }

  Future<UserRole?> _loadProfile(String userId) async {
    try {
      final profile = await supabase
          .from('profiles')
          .select('role')
          .eq('id', userId)
          .single();

      final roleStr = profile['role'] as String;

      if (roleStr == 'admin') {
        _role = UserRole.admin;
      } else if (roleStr == 'stockist') {
        _role = UserRole.stockist;
        final stockist = await supabase
            .from('stockists')
            .select('id, sequential_id')
            .eq('user_id', userId)
            .single();
        currentStockistId   = stockist['sequential_id'] as String;
        currentStockistUUID = stockist['id']            as String;
      } else {
        _role = UserRole.endUser;
        final eu = await supabase
            .from('end_users')
            .select('id')
            .eq('user_id', userId)
            .single();
        currentEndUserId = eu['id'] as String;
      }
      return _role;
    } catch (e) {
      throw 'Profile load failed: $e';
    }
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
