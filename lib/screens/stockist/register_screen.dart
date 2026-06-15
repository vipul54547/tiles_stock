import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../widgets/save_bar.dart';
import '../../widgets/unsaved_changes.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _companyCtrl = TextEditingController();
  final _contactCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _gstCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _dirty = false;

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      setState(() => _dirty = false);
      context.go('/stockist/dashboard');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: SaveBar(
        label: 'Create Account',
        icon: Icons.person_add_alt_1,
        onPressed: _submit,
        dirty: _dirty,
      ),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: const Text('Company Registration'),
      ),
      body: UnsavedChangesGuard(
        isDirty: _dirty,
        child: Form(
        key: _formKey,
        onChanged: _markDirty,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _field(_companyCtrl, 'Company Name', Icons.business, required: true),
            _field(_contactCtrl, 'Contact Person', Icons.person_outline, required: true),
            _field(_emailCtrl, 'Email', Icons.email_outlined, required: true),
            _field(_phoneCtrl, 'WhatsApp Number', Icons.phone_outlined, required: true),
            _field(_cityCtrl, 'City', Icons.location_city_outlined, required: true),
            _field(_gstCtrl, 'GST Number', Icons.receipt_outlined),
            _field(_passCtrl, 'Password', Icons.lock_outline, required: true, obscure: true),
          ],
        ),
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
        validator: required ? (v) => v!.isEmpty ? 'Required' : null : null,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          prefixIcon: Icon(icon),
        ),
      ),
    );
  }
}
