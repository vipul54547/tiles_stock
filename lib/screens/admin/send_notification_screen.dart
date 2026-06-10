import 'package:flutter/material.dart';
import '../../models/stockist.dart';
import '../../models/end_user.dart';
import '../../services/supabase_data_service.dart';
import '../../widgets/save_bar.dart';
import '../../widgets/unsaved_changes.dart';

/// Admin composes a notification and picks recipients — specific stockists
/// and/or end users, or everyone of a role.
class SendNotificationScreen extends StatefulWidget {
  const SendNotificationScreen({super.key});
  @override
  State<SendNotificationScreen> createState() => _State();
}

class _State extends State<SendNotificationScreen> {
  final _svc = SupabaseDataService();
  final _titleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();

  List<Stockist> _stockists = [];
  List<EndUser> _endUsers = [];
  final Set<String> _pickedStockists = {}; // sequential ids
  final Set<String> _pickedEndUsers = {};  // row uuids
  bool _allStockists = false;
  bool _allEndUsers = false;

  int _tab = 0; // 0 = stockists, 1 = end users
  bool _loading = true;
  bool _sending = false;
  bool _dirty = false;

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  @override
  void initState() {
    super.initState();
    _titleCtrl.addListener(_markDirty);
    _bodyCtrl.addListener(_markDirty);
    _load();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final res = await Future.wait([
      _svc.getAllStockists(activeOnly: true),
      _svc.getAllEndUsers(activeOnly: true),
    ]);
    if (!mounted) return;
    setState(() {
      _stockists = res[0] as List<Stockist>;
      _endUsers = res[1] as List<EndUser>;
      _loading = false;
    });
  }

  int get _recipientCount {
    final s = _allStockists ? _stockists.length : _pickedStockists.length;
    final e = _allEndUsers ? _endUsers.length : _pickedEndUsers.length;
    return s + e;
  }

  Future<void> _send() async {
    if (_titleCtrl.text.trim().isEmpty) {
      _snack('Enter a title', Colors.red);
      return;
    }
    if (_recipientCount == 0) {
      _snack('Pick at least one recipient', Colors.red);
      return;
    }
    setState(() => _sending = true);
    try {
      await _svc.adminSendNotification(
        title: _titleCtrl.text.trim(),
        body: _bodyCtrl.text.trim(),
        stockistSeqIds: _allStockists ? null : _pickedStockists.toList(),
        endUserIds: _allEndUsers ? null : _pickedEndUsers.toList(),
        allStockists: _allStockists,
        allEndUsers: _allEndUsers,
      );
      if (!mounted) return;
      _dirty = false; // sent → allow pop through the exit guard
      _snack('Notification sent to $_recipientCount recipient(s).',
          const Color(0xFF2E7D32));
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      _snack('Failed to send: $e', Colors.red);
    }
  }

  void _snack(String m, Color c) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), backgroundColor: c));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send Notification')),
      bottomNavigationBar: _loading
          ? null
          : SaveBar(
              label: 'Send to $_recipientCount recipient(s)',
              icon: Icons.send,
              onPressed: _send,
              saving: _sending,
              dirty: _dirty,
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : UnsavedChangesGuard(
              isDirty: _dirty,
              child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      TextField(
                        controller: _titleCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Title',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _bodyCtrl,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Message (optional)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                ),
                _tabBar(),
                Expanded(child: _tab == 0 ? _stockistList() : _endUserList()),
              ],
            ),
            ),
    );
  }

  Widget _tabBar() {
    Widget chip(String label, int i, int count) {
      final sel = _tab == i;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _tab = i),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                    color: sel ? const Color(0xFF1B4F72) : Colors.transparent,
                    width: 2),
              ),
            ),
            child: Text('$label ($count)',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: sel ? const Color(0xFF1B4F72) : Colors.grey)),
          ),
        ),
      );
    }

    return Row(children: [
      chip('Stockists', 0,
          _allStockists ? _stockists.length : _pickedStockists.length),
      chip('End Users', 1,
          _allEndUsers ? _endUsers.length : _pickedEndUsers.length),
    ]);
  }

  Widget _stockistList() {
    return Column(
      children: [
        SwitchListTile(
          title: const Text('All stockists'),
          value: _allStockists,
          activeThumbColor: const Color(0xFF1B4F72),
          onChanged: (v) => setState(() { _allStockists = v; _dirty = true; }),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: _stockists.map((s) {
              return CheckboxListTile(
                dense: true,
                enabled: !_allStockists,
                value: _allStockists || _pickedStockists.contains(s.id),
                title: Text(s.name),
                subtitle: Text('ID: ${s.id}'),
                onChanged: (v) => setState(() {
                  _dirty = true;
                  if (v == true) {
                    _pickedStockists.add(s.id);
                  } else {
                    _pickedStockists.remove(s.id);
                  }
                }),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _endUserList() {
    return Column(
      children: [
        SwitchListTile(
          title: const Text('All end users'),
          value: _allEndUsers,
          activeThumbColor: const Color(0xFF1B4F72),
          onChanged: (v) => setState(() { _allEndUsers = v; _dirty = true; }),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: _endUsers.map((e) {
              return CheckboxListTile(
                dense: true,
                enabled: !_allEndUsers,
                value: _allEndUsers || _pickedEndUsers.contains(e.uuid),
                title: Text(e.companyName),
                subtitle: Text('ID: ${e.id}'),
                onChanged: (v) => setState(() {
                  _dirty = true;
                  if (v == true) {
                    _pickedEndUsers.add(e.uuid);
                  } else {
                    _pickedEndUsers.remove(e.uuid);
                  }
                }),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}
