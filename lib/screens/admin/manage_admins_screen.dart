import 'package:flutter/material.dart';
import '../../models/choice_state.dart';
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
  // Public-market go-live switch (super-admin-only, app-wide).
  bool _publicEnabled = false;
  bool _publicSaving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await _dataSvc.getAllAdmins();
    final pub = await _dataSvc.getPublicMarketEnabled();
    if (!mounted) return;
    setState(() {
      _admins = list;
      _publicEnabled = pub;
      publicMarketLive = pub;
      _loading = false;
    });
  }

  // Flip the single app-wide public-market / anonymity switch. Enabling reveals
  // the public market + anonymity controls everywhere, so confirm first.
  Future<void> _setPublic(bool value) async {
    if (value) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Go live with the public market?'),
          content: const Text(
              'This reveals the public market and stockist anonymity controls '
              'across the whole app for every admin and buyer. Only do this on '
              'launch day. You can turn it back off here.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Go live')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _publicSaving = true);
    try {
      final v = await _dataSvc.setPublicMarketEnabled(value);
      if (!mounted) return;
      setState(() {
        _publicEnabled = v;
        publicMarketLive = v;
        _publicSaving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(v
              ? 'Public market is now LIVE.'
              : 'Public market is OFF (private-first).')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _publicSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red));
    }
  }

  // "Public Market — Go Live" section, shown above the admins list. Its own
  // labelled card so it reads as an app-wide launch setting, not an admin row.
  Widget _goLiveCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: _publicEnabled
            ? const Color(0xFFE8F5E9)
            : const Color(0xFFF3E5F5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: _publicEnabled
                ? const Color(0xFF2E7D32)
                : const Color(0xFF6A1B9A),
            width: 1.2),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.rocket_launch_outlined,
                    size: 18, color: Color(0xFF6A1B9A)),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text('Public Market — Go Live',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 14)),
                ),
                if (_publicSaving)
                  const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else
                  Switch(
                    value: _publicEnabled,
                    activeThumbColor: const Color(0xFF2E7D32),
                    onChanged: _setPublic,
                  ),
              ],
            ),
            Text(
                _publicEnabled
                    ? 'LIVE: public market + stockist anonymity controls are visible app-wide.'
                    : 'OFF (private-first): no public market or anonymity anywhere. '
                        'Buyers still reach stock via the share links they are sent.',
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleActive(Map<String, dynamic> a, bool active) async {
    try {
      await _dataSvc.setAdminActive(a['id'] as String, active);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update status: $e')));
      return;
    }
    if (mounted) _load();
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
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
                children: [
                  _goLiveCard(),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(2, 4, 2, 8),
                    child: Text('Admins',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13)),
                  ),
                  if (_admins.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                          child: Text('No admins found.',
                              style: TextStyle(color: Colors.grey))),
                    )
                  else
                    for (final a in _admins) ...[
                      _adminTile(a),
                      const SizedBox(height: 6),
                    ],
                ],
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
