import 'package:flutter/material.dart';
import '../../services/supabase_data_service.dart';

// Super-admin-only screen: create and manage sub-admins. Sub-admins have all
// admin powers EXCEPT creating/managing admins (this screen is hidden for them).
// The super admin row has no toggle — it can never be deactivated.
class ManageAdminsScreen extends StatefulWidget {
  const ManageAdminsScreen({super.key});
  @override
  State<ManageAdminsScreen> createState() => _ManageAdminsScreenState();
}

class _ManageAdminsScreenState extends State<ManageAdminsScreen> {
  final _dataSvc = SupabaseDataService();
  List<Map<String, dynamic>> _admins = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await _dataSvc.getAllAdmins();
    if (!mounted) return;
    setState(() { _admins = list; _loading = false; });
  }

  Future<void> _toggleActive(Map<String, dynamic> a, bool active) async {
    final ok = await _dataSvc.setAdminActive(a['id'] as String, active);
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
        title: const Text('Manage Admins'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openAddForm,
        backgroundColor: const Color(0xFF6A1B9A),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.admin_panel_settings),
        label: const Text('Add Sub-admin'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _admins.isEmpty
              ? const Center(
                  child: Text('No admins found.',
                      style: TextStyle(color: Colors.grey)))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
                    itemCount: _admins.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (_, i) => _adminTile(_admins[i]),
                  ),
                ),
    );
  }

  Widget _adminTile(Map<String, dynamic> a) {
    final isSuper = a['is_super'] == true;
    final active = a['is_active'] == true;
    return Opacity(
      opacity: (active || isSuper) ? 1 : 0.55,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
              child: const Icon(Icons.person, color: Color(0xFF6A1B9A), size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(a['email']?.toString() ?? '',
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14),
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(isSuper ? 'Super admin' : (active ? 'Sub-admin' : 'Sub-admin · inactive'),
                      style: TextStyle(
                          fontSize: 12,
                          color: isSuper
                              ? const Color(0xFF6A1B9A)
                              : Colors.grey.shade600,
                          fontWeight:
                              isSuper ? FontWeight.bold : FontWeight.normal)),
                ],
              ),
            ),
            if (isSuper)
              const Icon(Icons.verified, color: Color(0xFF6A1B9A), size: 20)
            else
              Switch(
                value: active,
                onChanged: (v) => _toggleActive(a, v),
                activeThumbColor: const Color(0xFF2E7D32),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openAddForm() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => const _AddAdminSheet(),
    );
    if (created == true) _load();
  }
}

class _AddAdminSheet extends StatefulWidget {
  const _AddAdminSheet();
  @override
  State<_AddAdminSheet> createState() => _AddAdminSheetState();
}

class _AddAdminSheetState extends State<_AddAdminSheet> {
  final _dataSvc = SupabaseDataService();
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _saving = true; _error = null; });
    try {
      final email = await _dataSvc.addAdmin(
          email: _email.text.trim(), password: _password.text);
      if (!mounted) return;
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Sub-admin created${email.isNotEmpty ? ' · $email' : ''}.'),
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
    final mq = MediaQuery.of(context);
    final bottom = mq.viewInsets.bottom + mq.viewPadding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + bottom),
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
            const Text('Add Sub-admin',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            const SizedBox(height: 2),
            Text('Has full admin access except managing admins.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            const SizedBox(height: 14),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: 'Email *',
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              validator: (v) {
                final t = (v ?? '').trim();
                if (t.isEmpty) return 'Email is required';
                if (!t.contains('@')) return 'Invalid email';
                return null;
              },
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _password,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Password *',
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              validator: (v) => (v ?? '').length < 6 ? 'Min 6 characters' : null,
            ),
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
                    backgroundColor: const Color(0xFF6A1B9A),
                    foregroundColor: Colors.white),
                child: _saving
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Text('Create Sub-admin',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
