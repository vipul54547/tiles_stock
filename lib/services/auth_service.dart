enum UserRole { admin, stockist, endUser }



abstract class AuthService {

  Future<UserRole?> login(String email, String password);

  Future<void> logout();

  Future<String?> registerEndUser(Map<String, dynamic> profile);

  UserRole? get currentRole;

  String? get currentUserId;

}



class MockAuthService implements AuthService {

  UserRole? _role;

  String? _userId;



  @override

  UserRole? get currentRole => _role;



  @override

  String? get currentUserId => _userId;



  @override

  Future<UserRole?> login(String email, String password) async {

    await Future.delayed(const Duration(seconds: 1));

    if (email == 'admin@tilesfinders.com') {

      _role = UserRole.admin;

      _userId = 'admin_001';

    } else if (email.contains('stockist')) {

      _role = UserRole.stockist;

      _userId = 'stockist_001';

    } else {

      _role = UserRole.endUser;

      _userId = 'user_001';

    }

    return _role;

  }



  @override

  Future<void> logout() async {

    _role = null;

    _userId = null;

  }



  @override

  Future<String?> registerEndUser(Map<String, dynamic> profile) async {

    await Future.delayed(const Duration(seconds: 1));

    return 'user_new_001';

  }

} 