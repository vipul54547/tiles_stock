import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/supabase_data_service.dart';
import '../widgets/phone_field.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey     = GlobalKey<FormState>();
  final _companyCtrl = TextEditingController();
  final _contactCtrl = TextEditingController();
  final _emailCtrl   = TextEditingController();
  final _phoneCtrl   = TextEditingController();
  final _codeCtrl    = TextEditingController(text: '+91');
  final _cityCtrl    = TextEditingController();
  final _gstCtrl     = TextEditingController();
  final _passCtrl    = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _companyCtrl.dispose();
    _contactCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    _cityCtrl.dispose();
    _gstCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    try {
      await SupabaseDataService().submitRegistrationRequest(
        email:         _emailCtrl.text.trim(),
        password:      _passCtrl.text,
        companyName:   _companyCtrl.text.trim(),
        contactPerson: _contactCtrl.text.trim(),
        phone:         _phoneCtrl.text.trim(),
        countryCode:   _codeCtrl.text.trim().isEmpty ? '+91' : _codeCtrl.text.trim(),
        city:          _cityCtrl.text.trim(),
        gstNumber:     _gstCtrl.text.trim().isEmpty ? null : _gstCtrl.text.trim(),
      );
      if (!mounted) return;
      setState(() => _loading = false);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Request submitted'),
          content: const Text(
              'Your registration has been sent for approval. Once an admin '
              'approves it, you can log in with this email and password.\n\n'
              'Meanwhile you can keep browsing as a guest.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK')),
          ],
        ),
      );
      if (mounted) context.go('/login');
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$e'.replaceAll('PostgrestException:', '').trim()),
        backgroundColor: Colors.red,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Company Registration'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _field(_companyCtrl, 'Company Name',   Icons.business,             required: true),
            _field(_contactCtrl, 'Contact Person', Icons.person_outline,        required: true),
            _field(_emailCtrl,   'Email',           Icons.email_outlined,        required: true),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: PhoneField(
                codeController: _codeCtrl,
                phoneController: _phoneCtrl,
                icon: Icons.phone_outlined,
                required: true,
              ),
            ),
            _field(_cityCtrl,    'City',             Icons.location_city_outlined, required: true),
            _field(_gstCtrl,     'GST Number',      Icons.receipt_outlined),
            _field(_passCtrl,    'Password',         Icons.lock_outline,         required: true, obscure: true),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _loading ? null : _register,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1B4F72),
                  foregroundColor: Colors.white,
                ),
                child: _loading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text('Create Account', style: TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String label, IconData icon,
      {bool required = false, bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: ctrl,
        obscureText: obscure,
        keyboardType: label.contains('Phone') ? TextInputType.phone : TextInputType.text,
        validator: required ? (v) => v!.trim().isEmpty ? 'Required' : null : null,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          prefixIcon: Icon(icon),
        ),
      ),
    );
  }
}
