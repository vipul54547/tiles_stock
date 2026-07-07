import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show
        TextInputFormatter,
        FilteringTextInputFormatter,
        LengthLimitingTextInputFormatter;

import '../../services/supabase_data_service.dart';
import '../../utils/account_actions.dart';
import '../../utils/india_geo.dart';

/// Self-service BUYER profile — the buyer's own identity that suppliers see when
/// they claim a link or receive an order (company, contact, phone, structured
/// address, GST). Mirrors the stockist profile, including the pincode →
/// state/district/city auto-fill. Fields save through the auth-scoped
/// `end_user_update_profile` RPC. Account deletion lives here too (danger zone).
class MyProfileScreen extends StatefulWidget {
  const MyProfileScreen({super.key});

  @override
  State<MyProfileScreen> createState() => _MyProfileScreenState();
}

class _MyProfileScreenState extends State<MyProfileScreen> {
  static const Color _navy = Color(0xFF1B4F72);
  final _data = SupabaseDataService();

  final _company = TextEditingController();
  final _contact = TextEditingController();
  final _phone = TextEditingController();
  final _country = TextEditingController(text: '+91');
  final _pincode = TextEditingController();
  final _city = TextEditingController();
  final _gst = TextEditingController();

  List<String> _states = [];
  List<String> _districts = [];
  String _state = '';
  String _district = '';

  bool _loading = true;
  bool _busy = false;
  bool _pinLooking = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _company.dispose();
    _contact.dispose();
    _phone.dispose();
    _country.dispose();
    _pincode.dispose();
    _city.dispose();
    _gst.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final states = await IndiaGeo.states();
    final p = await _data.getMyEndUserProfile();
    _states = states;
    if (p != null) {
      _company.text = (p['company_name'] ?? '').toString();
      _contact.text = (p['contact_person'] ?? '').toString();
      _phone.text = (p['phone'] ?? '').toString();
      final cc = (p['country_code'] ?? '').toString();
      if (cc.isNotEmpty) _country.text = cc;
      _pincode.text = (p['pincode'] ?? '').toString();
      _city.text = (p['city'] ?? '').toString();
      _gst.text = (p['gst_number'] ?? '').toString();
      _state = await IndiaGeo.canonicalState((p['state'] ?? '').toString());
      _district = (p['district'] ?? '').toString();
    }
    if (_state.isNotEmpty) _districts = await IndiaGeo.districts(_state);
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String m, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(m), backgroundColor: error ? Colors.red : null));
  }

  // Dropdown items must always contain the current value — insert an off-list
  // legacy value so Flutter doesn't assert.
  List<String> _withValue(List<String> list, String value) {
    if (value.isEmpty || list.contains(value)) return list;
    return [value, ...list];
  }

  Future<void> _onStateChanged(String? s) async {
    if (s == null) return;
    final d = await IndiaGeo.districts(s);
    setState(() {
      _state = s;
      _districts = d;
      if (!d.contains(_district)) _district = '';
    });
  }

  Future<void> _lookupPincode() async {
    final pin = _pincode.text.trim();
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
      _state = r.state;
      _districts = districts;
      _district = r.district;
      if (_city.text.trim().isEmpty) _city.text = r.city;
    });
    _snack('Filled ${r.district}, ${r.state}.');
  }

  Future<void> _save() async {
    if (_company.text.trim().isEmpty) {
      _snack('Business name is required.', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await _data.updateMyEndUserProfile(
        company: _company.text.trim(),
        contact: _contact.text.trim(),
        phone: _phone.text.trim(),
        countryCode: _country.text.trim(),
        city: _city.text.trim(),
        gst: _gst.text.trim(),
        state: _state,
        district: _district,
        pincode: _pincode.text.trim(),
      );
      if (!mounted) return;
      _snack('Profile saved.');
      Navigator.pop(context, true);
    } catch (e) {
      _snack('Save failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('My Profile'),
        actions: [
          if (!_loading)
            TextButton(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? 'Saving…' : 'Save',
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                _label('Business name'),
                _text(_company, hint: 'e.g. Sharma Tiles & Sanitary'),
                const SizedBox(height: 18),
                _label('Contact person'),
                _text(_contact, hint: 'e.g. Ramesh Sharma'),
                const SizedBox(height: 18),
                _label('Phone'),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 78,
                      child: _text(_country,
                          hint: '+91', keyboard: TextInputType.phone),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _text(_phone,
                          hint: '10-digit number',
                          keyboard: TextInputType.phone),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _addressBlock(),
                const SizedBox(height: 18),
                _label('GST number (optional)'),
                _text(_gst, hint: 'e.g. 24ABCDE1234F1Z5'),
                const SizedBox(height: 36),
                _dangerZone(),
              ],
            ),
    );
  }

  Widget _addressBlock() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Pincode', trailing: 'fills state, district & city'),
        Row(
          children: [
            Expanded(
              child: _text(
                _pincode,
                hint: '6 digits',
                keyboard: TextInputType.number,
                formatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: (_busy || _pinLooking) ? null : _lookupPincode,
              child: _pinLooking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Auto-fill'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label('State'),
                  _dropdown(
                    value: _state,
                    items: _withValue(_states, _state),
                    hint: 'Select state',
                    onChanged: _busy ? null : _onStateChanged,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label('District'),
                  _dropdown(
                    value: _district,
                    items: _withValue(_districts, _district),
                    hint: 'Select district',
                    onChanged: (_busy || _state.isEmpty)
                        ? null
                        : (v) => setState(() => _district = v ?? ''),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _label('City / area', trailing: 'editable'),
        _text(_city, hint: 'e.g. Morbi'),
      ],
    );
  }

  Widget _label(String t, {String? trailing}) => Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(t,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: _navy)),
            if (trailing != null) ...[
              const SizedBox(width: 6),
              Text(trailing,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ],
          ],
        ),
      );

  Widget _text(TextEditingController c,
      {String? hint,
      TextInputType? keyboard,
      List<TextInputFormatter>? formatters}) {
    return TextField(
      controller: c,
      keyboardType: keyboard,
      inputFormatters: formatters,
      decoration: InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: Colors.white,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
      ),
    );
  }

  Widget _dropdown({
    required String value,
    required List<String> items,
    required String hint,
    required ValueChanged<String?>? onChanged,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: value.isEmpty ? null : value,
      isExpanded: true,
      hint: Text(hint, style: const TextStyle(fontSize: 13)),
      items: items
          .map((s) => DropdownMenuItem(
                value: s,
                child:
                    Text(s, overflow: TextOverflow.ellipsis, maxLines: 1),
              ))
          .toList(),
      onChanged: onChanged,
      decoration: InputDecoration(
        filled: true,
        fillColor: Colors.white,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
      ),
    );
  }

  // Danger zone — account deletion lives in the profile (not the toolbar).
  Widget _dangerZone() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Danger zone',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.red.shade700)),
          const SizedBox(height: 4),
          Text(
            'Permanently delete your account and all your data (profile, saved '
            'suppliers, stock lists, groups). This cannot be undone.',
            style: TextStyle(fontSize: 12, color: Colors.red.shade700),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => confirmDeleteAccount(context),
              icon: const Icon(Icons.delete_forever, size: 18),
              label: const Text('Delete account'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red.shade700,
                side: BorderSide(color: Colors.red.shade400),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
