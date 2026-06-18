import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/supabase_auth_service.dart';
import '../models/choice_state.dart';
import '../utils/support.dart';
import '../utils/login_history.dart';
import '../widgets/powered_by_tiles_stock.dart';



class LoginScreen extends StatefulWidget {

  const LoginScreen({super.key});

  @override State<LoginScreen> createState() => _LoginScreenState();

}



class _LoginScreenState extends State<LoginScreen> {

  final _emailCtrl = TextEditingController();

  final _passCtrl = TextEditingController();

  bool _loading = false;

  bool _obscurePassword = true;

  // Shown only until the first successful login on this install. New dealers
  // are created by the admin and don't know their credentials yet, so they get
  // a one-tap way to request them. Runway-only — retire once OTP self-service
  // login is live.
  bool _showFirstTimeHelp = false;

  @override
  void initState() {
    super.initState();
    LoginHistory.hasLoggedIn().then((seen) {
      if (mounted && !seen) setState(() => _showFirstTimeHelp = true);
    });
  }

  void _login() async {
    if (_emailCtrl.text.trim().isEmpty || _passCtrl.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter email and password')));
      return;
    }

    setState(() => _loading = true);

    UserRole? role;
    try {
      role = await SupabaseAuthService().login(
        _emailCtrl.text.trim(),
        _passCtrl.text,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$e'),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 8),
      ));
      return;
    }

    if (!mounted) return;
    setState(() => _loading = false);

    if (role == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Invalid email or password'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    // They're in — hide the first-time "Get my login details" helper from now on.
    await LoginHistory.markLoggedIn();
    if (!mounted) return;

    if (role == UserRole.admin) {
      context.go('/admin');
    } else if (role == UserRole.stockist) {
      context.go('/stockist/dashboard');
    } else {
      context.go('/home');
    }
  }

  // Sends a Supabase password-reset email. Pre-fills the address from the email
  // field, lets the user confirm/edit it, then dispatches the reset link.
  void _forgotPassword() async {
    final resetCtrl = TextEditingController(text: _emailCtrl.text.trim());
    final email = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter your email and we\'ll send you a link to reset your '
              'password.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: resetCtrl,
              keyboardType: TextInputType.emailAddress,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Email',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.email_outlined),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, resetCtrl.text.trim()),
            child: const Text('Send link'),
          ),
        ],
      ),
    );

    if (email == null || email.isEmpty) return;

    try {
      await SupabaseAuthService().sendPasswordReset(email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Password-reset link sent to $email. Check your inbox.'),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 6),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not send reset email: $e'),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 6),
      ));
    }
  }

  // Anonymous "browse as guest" — guest-trial: can browse + SAVE suppliers, but
  // inquiring/ordering triggers the convert prompt. Lands on the same My
  // Suppliers home as a real buyer (the guest now has a lightweight identity).
  void _browseAsGuest() async {
    setState(() => _loading = true);
    try {
      await SupabaseAuthService().loginAsGuest();
      if (!mounted) return;
      setState(() => _loading = false);
      context.go('/home');
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Guest browsing unavailable: $e'),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 6),
      ));
    }
  }

  // First-time helper: a dealer who doesn't have their login asks the team for
  // it. Collects who they are, then opens a pre-filled WhatsApp message to the
  // Tiles Stock team (contactSupport also logs the request server-side). Empty
  // fields are simply left out of the message.
  void _requestLoginDetails() async {
    final nameCtrl = TextEditingController();
    final shopCtrl = TextEditingController();
    final cityCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();

    InputDecoration deco(String label) => InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        );

    void disposeAll() {
      nameCtrl.dispose();
      shopCtrl.dispose();
      cityCtrl.dispose();
      phoneCtrl.dispose();
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Get my login details'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Tell us who you are and the Tiles Stock team will send your '
                'login details on WhatsApp.',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: deco('Your name'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: shopCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: deco('Shop / Company'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: cityCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: deco('City'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: deco('WhatsApp number'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.chat_outlined, size: 18),
            label: const Text('Send on WhatsApp'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF25D366),
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
    if (ok != true) {
      disposeAll();
      return;
    }

    final lines = <String>[
      'Hi Tiles Stock team 👋',
      "I want to log in to the Tiles Stock app but I don't have my account "
          'details.',
      '',
      if (nameCtrl.text.trim().isNotEmpty) 'Name: ${nameCtrl.text.trim()}',
      if (shopCtrl.text.trim().isNotEmpty)
        'Shop / Company: ${shopCtrl.text.trim()}',
      if (cityCtrl.text.trim().isNotEmpty) 'City: ${cityCtrl.text.trim()}',
      if (phoneCtrl.text.trim().isNotEmpty)
        'WhatsApp: ${phoneCtrl.text.trim()}',
      '',
      'Please send me my login details. Thank you.',
    ];
    final message = lines.join('\n');
    disposeAll();
    // No `ref` → the WhatsApp text stays clean (no "(Ref: ...)" suffix);
    // contactSupport still logs the full message server-side.
    await contactSupport(message: message);
  }



  @override

  Widget build(BuildContext context) {

    return Scaffold(

      backgroundColor: const Color(0xFFF5F5F5),

      body: SafeArea(

        child: SingleChildScrollView(

          padding: const EdgeInsets.all(24),

          child: Column(

            crossAxisAlignment: CrossAxisAlignment.start,

            children: [

              const SizedBox(height: 40),

              const Icon(Icons.grid_view_rounded, size: 48, color: Color(0xFF1B4F72)),

              const SizedBox(height: 16),

              const Text('Welcome Back',

                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),

              const Text('Sign in to Tiles Stock',

                  style: TextStyle(color: Colors.grey)),

              const SizedBox(height: 40),

              TextField(

                controller: _emailCtrl,

                decoration: const InputDecoration(

                  labelText: 'Email',

                  border: OutlineInputBorder(),

                  prefixIcon: Icon(Icons.email_outlined),

                ),

              ),

              const SizedBox(height: 16),

              TextField(

                controller: _passCtrl,

                obscureText: _obscurePassword,

                onSubmitted: (_) { if (!_loading) _login(); },

                decoration: InputDecoration(

                  labelText: 'Password',

                  border: const OutlineInputBorder(),

                  prefixIcon: const Icon(Icons.lock_outline),

                  suffixIcon: IconButton(

                    icon: Icon(_obscurePassword

                        ? Icons.visibility_outlined

                        : Icons.visibility_off_outlined),

                    tooltip: _obscurePassword ? 'Show password' : 'Hide password',

                    onPressed: () =>

                        setState(() => _obscurePassword = !_obscurePassword),

                  ),

                ),

              ),

              Align(

                alignment: Alignment.centerRight,

                child: TextButton(

                  onPressed: _loading ? null : _forgotPassword,

                  child: const Text('Forgot password?'),

                ),

              ),

              const SizedBox(height: 8),

              SizedBox(

                width: double.infinity,

                height: 50,

                child: ElevatedButton(

                  onPressed: _loading ? null : _login,

                  style: ElevatedButton.styleFrom(

                    backgroundColor: const Color(0xFF1B4F72),

                    foregroundColor: Colors.white,

                  ),

                  child: _loading

                      ? const CircularProgressIndicator(color: Colors.white)

                      : const Text('Login', style: TextStyle(fontSize: 16)),

                ),

              ),

              // First-time helper for dealers who don't yet have their login.
              if (_showFirstTimeHelp) ...[
                const SizedBox(height: 16),
                Card(
                  elevation: 0,
                  color: const Color(0xFFE8F0FE),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: const BorderSide(color: Color(0xFFB6CCF2)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "Don't have your login yet?",
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Get your account details from the Tiles Stock team '
                          'on WhatsApp.',
                          style:
                              TextStyle(color: Colors.black54, fontSize: 13),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed:
                                _loading ? null : _requestLoginDetails,
                            icon: const Icon(Icons.badge_outlined, size: 18),
                            label: const Text('Get my login details'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF25D366),
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 16),

              Center(

                child: TextButton(

                  onPressed: () => context.push('/register'),

                  child: const Text('New company? Register here'),

                ),

              ),

              const SizedBox(height: 4),

              // "Browse as guest" only makes sense once the public market is
              // live; during the private-first runway there's nothing public to
              // browse, so it's hidden (buyers enter via a supplier's link).
              if (publicMarketLive)
                Center(

                  child: OutlinedButton.icon(

                    onPressed: _loading ? null : _browseAsGuest,

                    icon: const Icon(Icons.visibility_outlined, size: 18),

                    label: const Text('Browse as guest'),

                  ),

                ),

              const SizedBox(height: 12),

              Center(
                child: TextButton.icon(
                  onPressed: () => contactSupport(),
                  icon: const Icon(Icons.chat_outlined, size: 18),
                  label: const Text('Need help? Chat on WhatsApp'),
                  style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF25D366)),
                ),
              ),

              const SizedBox(height: 16),

              const Center(child: PoweredByTilesStock()),

            ],



          ),


        ),


      ),

    );

  }

} 