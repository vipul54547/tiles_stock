import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../services/supabase_auth_service.dart';
import '../utils/support.dart';
import '../widgets/phone_field.dart';

/// Guest-trial conversion: a guest creates a permanent login with their phone
/// number + OTP. Upgrades the anonymous account in place, so their saved
/// suppliers carry over. project_buyer_onboarding_funnel Increment 2.
///
/// Works the moment an SMS provider is wired into Supabase; until then "Send
/// code" surfaces a friendly "not available yet" message and the guest keeps
/// using the app.
class CreateLoginScreen extends StatefulWidget {
  const CreateLoginScreen({super.key});
  @override
  State<CreateLoginScreen> createState() => _State();
}

class _State extends State<CreateLoginScreen> {
  final _auth = SupabaseAuthService();
  final _company = TextEditingController();
  final _code = TextEditingController(text: '+91');
  final _phone = TextEditingController();
  final _otp = TextEditingController();

  bool _codeSent = false;
  bool _loading = false;
  String? _error;

  String get _phoneE164 =>
      '${_code.text.trim()}${_phone.text.trim()}'.replaceAll(' ', '');

  @override
  void dispose() {
    _company.dispose();
    _code.dispose();
    _phone.dispose();
    _otp.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    if (_phone.text.trim().length < 7) {
      setState(() => _error = 'Enter a valid mobile number.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _auth.sendConvertOtp(_phoneE164);
      if (!mounted) return;
      setState(() {
        _codeSent = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _verify() async {
    if (_otp.text.trim().length < 4) {
      setState(() => _error = 'Enter the code from the SMS.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _auth.verifyConvertOtp(
          _phoneE164, _otp.text.trim(), _company.text.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Login created — your suppliers are saved to you.'),
          backgroundColor: Color(0xFF2E7D32)));
      context.go('/home');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create your login')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 8),
          const Icon(Icons.verified_user_outlined,
              size: 48, color: Color(0xFF1B4F72)),
          const SizedBox(height: 12),
          const Text('Keep your suppliers — for free',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
              'Create a login with your mobile number so your saved suppliers '
              'stay with you on any phone. It only takes a moment.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
          const SizedBox(height: 24),
          if (!_codeSent) ...[
            TextField(
              controller: _company,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Company / shop name (optional)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.business_outlined),
              ),
            ),
            const SizedBox(height: 14),
            PhoneField(
              codeController: _code,
              phoneController: _phone,
              icon: Icons.phone_outlined,
              required: true,
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: _loading ? null : _sendCode,
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1B4F72),
                    foregroundColor: Colors.white),
                child: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Text('Send code', style: TextStyle(fontSize: 16)),
              ),
            ),
          ] else ...[
            Text('Enter the code sent to $_phoneE164',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            TextField(
              controller: _otp,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'Verification code',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.sms_outlined),
                counterText: '',
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: _loading ? null : _verify,
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2E7D32),
                    foregroundColor: Colors.white),
                child: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Text('Verify & create login',
                        style: TextStyle(fontSize: 16)),
              ),
            ),
            TextButton(
              onPressed: _loading ? null : () => setState(() => _codeSent = false),
              child: const Text('Change number'),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
          ],
          const SizedBox(height: 24),
          Center(
            child: TextButton.icon(
              onPressed: () => contactSupport(),
              icon: const Icon(Icons.chat_outlined, size: 18),
              label: const Text('Need help? Chat on WhatsApp'),
              style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF25D366)),
            ),
          ),
        ],
      ),
    );
  }
}
