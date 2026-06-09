import 'package:flutter/material.dart';
import '../../models/end_user.dart';
import '../../services/supabase_data_service.dart';
import '../../widgets/phone_field.dart';
import 'excel_import_screen.dart';

// Admin screen to view end users (companies) and add a single new one. The
// unique ID (01A, 02A … 01B) is generated automatically by the backend.
class ManageEndUsersScreen extends StatefulWidget {
  const ManageEndUsersScreen({super.key});
  @override
  State<ManageEndUsersScreen> createState() => _ManageEndUsersScreenState();
}

class _ManageEndUsersScreenState extends State<ManageEndUsersScreen> {
  final _dataSvc = SupabaseDataService();

  List<EndUser> _users = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await _dataSvc.getAllEndUsers(activeOnly: false);
    if (!mounted) return;
    setState(() {
      _users = list;
      _loading = false;
    });
  }

  Future<void> _toggleActive(EndUser u, bool active) async {
    final ok = await _dataSvc.setEndUserActive(u.uuid, active);
    if (!mounted) return;
    if (ok) {
      _load();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update status.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('End Users'),
        actions: [
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: 'Import from Excel',
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const ExcelImportScreen(role: 'end_user')));
              _load();
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openAddForm,
        backgroundColor: const Color(0xFF1B4F72),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add End User'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _users.isEmpty
              ? const Center(
                  child: Text('No end users yet. Tap "Add End User".',
                      style: TextStyle(color: Colors.grey)))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
                    itemCount: _users.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (_, i) => _userTile(_users[i]),
                  ),
                ),
    );
  }

  Widget _userTile(EndUser u) => Opacity(
        opacity: u.isActive ? 1 : 0.55,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: const Color(0xFF6A1B9A).withValues(alpha: 0.1),
                child: Text(u.id,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF6A1B9A))),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(u.companyName,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 14),
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (u.endUserType.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: const Color(0xFF6A1B9A)
                                  .withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(u.endUserType,
                                style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF6A1B9A))),
                          ),
                        ],
                      ],
                    ),
                    if (u.email.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(u.email,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF1B4F72)),
                          overflow: TextOverflow.ellipsis),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (u.contactPerson.isNotEmpty) u.contactPerson,
                        if (u.city.isNotEmpty) u.city,
                        if (u.phone.isNotEmpty) u.phone,
                      ].join('  ·  '),
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Switch(
                value: u.isActive,
                onChanged: (v) => _toggleActive(u, v),
                activeThumbColor: const Color(0xFF2E7D32),
              ),
            ],
          ),
        ),
      );

  Future<void> _openAddForm() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => const _AddEndUserSheet(),
    );
    if (created == true) _load();
  }
}

// ── Add-end-user bottom sheet ────────────────────────────────────────────────
class _AddEndUserSheet extends StatefulWidget {
  const _AddEndUserSheet();
  @override
  State<_AddEndUserSheet> createState() => _AddEndUserSheetState();
}

class _AddEndUserSheetState extends State<_AddEndUserSheet> {
  final _dataSvc = SupabaseDataService();
  final _formKey = GlobalKey<FormState>();

  final _company  = TextEditingController();
  final _email    = TextEditingController();
  final _password = TextEditingController();
  final _contact  = TextEditingController();
  final _phone    = TextEditingController();
  final _code     = TextEditingController(text: '+91');
  final _city     = TextEditingController();
  final _gst      = TextEditingController();
  final _type     = TextEditingController();
  final _priority = TextEditingController(text: '0.00');

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [
      _company, _email, _password, _contact, _phone, _code, _city, _gst,
      _type, _priority
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _saving = true; _error = null; });
    try {
      final id = await _dataSvc.addEndUser(
        companyName:   _company.text.trim(),
        email:         _email.text.trim(),
        password:      _password.text,
        contactPerson: _contact.text.trim(),
        phone:         _phone.text.trim(),
        countryCode:   _code.text.trim().isEmpty ? '+91' : _code.text.trim(),
        city:          _city.text.trim(),
        gstNumber:     _gst.text.trim(),
        endUserType:   _type.text.trim(),
        priority:      double.tryParse(_priority.text.trim()) ?? 0,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('End user created${id.isNotEmpty ? ' · ID $id' : ''}.'),
        backgroundColor: const Color(0xFF2E7D32),
      ));
    } catch (e) {
      setState(() {
        _saving = false;
        _error = e.toString().replaceAll('PostgrestException:', '').trim();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + bottom),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const Text('Add End User',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              const SizedBox(height: 2),
              Text('The ID is generated automatically (e.g. 01A).',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              const SizedBox(height: 14),

              _field(_company, 'Company name *', required: true),
              _field(_email, 'Email *',
                  keyboard: TextInputType.emailAddress,
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return 'Email is required';
                    if (!t.contains('@')) return 'Invalid email';
                    return null;
                  }),
              _field(_password, 'Password *',
                  validator: (v) =>
                      (v ?? '').length < 6 ? 'Min 6 characters' : null),
              _field(_contact, 'Contact person'),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: PhoneField(
                    codeController: _code,
                    phoneController: _phone,
                    label: 'Phone'),
              ),
              _field(_city, 'City'),
              _field(_gst, 'GST number (optional)'),
              _field(_type, 'End user type (optional)',
                  hint: 'e.g. Gold, Platinum, Silver'),
              _field(_priority, 'Priority (0.00)',
                  keyboard: const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return null;
                    return double.tryParse(t) == null ? 'Enter a number' : null;
                  }),

              if (_error != null) ...[
                const SizedBox(height: 6),
                Text(_error!,
                    style: const TextStyle(color: Colors.red, fontSize: 12)),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1B4F72),
                      foregroundColor: Colors.white),
                  child: _saving
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : const Text('Create End User',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController c,
    String label, {
    bool required = false,
    TextInputType? keyboard,
    String? hint,
    String? Function(String?)? validator,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextFormField(
          controller: c,
          keyboardType: keyboard,
          obscureText: label.startsWith('Password'),
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          validator: validator ??
              (required
                  ? (v) => (v ?? '').trim().isEmpty ? '$label required' : null
                  : null),
        ),
      );
}
