import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, LengthLimitingTextInputFormatter;
import 'package:go_router/go_router.dart';
import '../services/supabase_data_service.dart';
import '../utils/india_geo.dart';
import '../widgets/phone_field.dart';
import '../widgets/save_bar.dart';
import '../widgets/unsaved_changes.dart';
import '../widgets/powered_by_tiles_stock.dart';

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
  final _pincodeCtrl = TextEditingController();
  final _cityCtrl    = TextEditingController();
  final _gstCtrl     = TextEditingController();
  final _passCtrl    = TextEditingController();

  List<String> _states = [];
  List<String> _districts = [];
  String _state = '';
  String _district = '';

  bool _loading = false;
  bool _pinLooking = false;
  bool _dirty   = false;

  @override
  void initState() {
    super.initState();
    IndiaGeo.states().then((s) {
      if (mounted) setState(() => _states = s);
    });
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  @override
  void dispose() {
    _companyCtrl.dispose();
    _contactCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    _pincodeCtrl.dispose();
    _cityCtrl.dispose();
    _gstCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _snack(String m, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(m), backgroundColor: error ? Colors.red : null));
  }

  Future<void> _onStateChanged(String? s) async {
    if (s == null) return;
    final d = await IndiaGeo.districts(s);
    setState(() {
      _dirty = true;
      _state = s;
      _districts = d;
      if (!d.contains(_district)) _district = '';
    });
  }

  Future<void> _lookupPincode() async {
    final pin = _pincodeCtrl.text.trim();
    if (pin.length != 6) {
      _snack('Enter a 6-digit pincode first.', error: true);
      return;
    }
    setState(() => _pinLooking = true);
    final r = await IndiaGeo.lookupPincode(pin);
    if (!mounted) return;
    setState(() => _pinLooking = false);
    if (r == null) {
      _snack('Couldn\'t find that pincode — pick state & district manually.',
          error: true);
      return;
    }
    final districts = await IndiaGeo.districts(r.state);
    if (!mounted) return;
    setState(() {
      _dirty = true;
      _state = r.state;
      _districts = districts;
      _district = r.district;
      if (_cityCtrl.text.trim().isEmpty) _cityCtrl.text = r.city;
    });
    _snack('Filled ${r.district}, ${r.state}.');
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
        state:         _state,
        district:      _district,
        pincode:       _pincodeCtrl.text.trim(),
      );
      if (!mounted) return;
      setState(() { _loading = false; _dirty = false; }); // submitted
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
      bottomNavigationBar: SaveBar(
        label: 'Create Account',
        icon: Icons.person_add_alt_1,
        onPressed: _register,
        saving: _loading,
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
            _pincodeRow(),
            const SizedBox(height: 16),
            _stateDistrictRow(),
            const SizedBox(height: 16),
            _field(_cityCtrl,    'City',             Icons.location_city_outlined, required: true),
            _field(_gstCtrl,     'GST Number',      Icons.receipt_outlined),
            _field(_passCtrl,    'Password',         Icons.lock_outline,         required: true, obscure: true),
            const SizedBox(height: 12),
            const Center(child: PoweredByTilesStock()),
          ],
        ),
      ),
      ),
    );
  }

  // Pincode + Auto-fill (state/district/city) — same convenience as the profile.
  Widget _pincodeRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextFormField(
            controller: _pincodeCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            decoration: const InputDecoration(
              labelText: 'Pincode',
              helperText: 'Fills state, district & city',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.pin_drop_outlined),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          height: 58,
          child: OutlinedButton(
            onPressed: (_loading || _pinLooking) ? null : _lookupPincode,
            child: _pinLooking
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Auto-fill'),
          ),
        ),
      ],
    );
  }

  Widget _stateDistrictRow() {
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _state.isEmpty ? null : _state,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'State',
              border: OutlineInputBorder(),
            ),
            hint: const Text('Select'),
            items: _withValue(_states, _state)
                .map((s) => DropdownMenuItem(
                    value: s,
                    child: Text(s, overflow: TextOverflow.ellipsis, maxLines: 1)))
                .toList(),
            onChanged: _onStateChanged,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _district.isEmpty ? null : _district,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'District',
              border: OutlineInputBorder(),
            ),
            hint: const Text('Select'),
            items: _withValue(_districts, _district)
                .map((s) => DropdownMenuItem(
                    value: s,
                    child: Text(s, overflow: TextOverflow.ellipsis, maxLines: 1)))
                .toList(),
            onChanged: _state.isEmpty
                ? null
                : (v) => setState(() {
                      _dirty = true;
                      _district = v ?? '';
                    }),
          ),
        ),
      ],
    );
  }

  // Dropdown items must always contain the current value (avoids an assert).
  List<String> _withValue(List<String> list, String value) {
    if (value.isEmpty || list.contains(value)) return list;
    return [value, ...list];
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
