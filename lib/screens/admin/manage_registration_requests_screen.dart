import 'package:flutter/material.dart';
import '../../services/supabase_data_service.dart';

// Admin screen: review self-registration requests and approve (→ creates the
// end-user account with an auto ID) or reject them.
class ManageRegistrationRequestsScreen extends StatefulWidget {
  const ManageRegistrationRequestsScreen({super.key});
  @override
  State<ManageRegistrationRequestsScreen> createState() =>
      _ManageRegistrationRequestsScreenState();
}

class _ManageRegistrationRequestsScreenState
    extends State<ManageRegistrationRequestsScreen> {
  final _dataSvc = SupabaseDataService();
  List<Map<String, dynamic>> _requests = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await _dataSvc.getRegistrationRequests();
    if (!mounted) return;
    setState(() { _requests = list; _loading = false; });
  }

  Future<void> _reject(Map<String, dynamic> r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject request?'),
        content: Text('Reject and delete the request from '
            '${r['company_name'] ?? r['email']}?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final done = await _dataSvc.rejectRegistrationRequest(r['id'] as String);
    if (!mounted) return;
    if (done) {
      _load();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not reject the request.')));
    }
  }

  Future<void> _approve(Map<String, dynamic> r) async {
    final priorityCtrl = TextEditingController(text: '0.00');
    final typeCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Approve request'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${r['company_name']} · ${r['email']}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('A login + unique ID will be created.',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 14),
            TextField(
              controller: typeCtrl,
              decoration: const InputDecoration(
                labelText: 'End user type (optional)',
                hintText: 'e.g. Gold',
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: priorityCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Priority (0.00)', isDense: true),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32)),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final id = await _dataSvc.approveRegistrationRequest(
        r['id'] as String,
        priority: double.tryParse(priorityCtrl.text.trim()) ?? 0,
        endUserType: typeCtrl.text.trim(),
      );
      if (!mounted) return;
      _load();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Approved${id.isNotEmpty ? ' · ID $id' : ''}.'),
        backgroundColor: const Color(0xFF2E7D32),
      ));
    } catch (e) {
      if (!mounted) return;
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
        title: const Text('Registration Requests'),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _requests.isEmpty
              ? const Center(
                  child: Text('No pending requests.',
                      style: TextStyle(color: Colors.grey)))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: _requests.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _requestCard(_requests[i]),
                  ),
                ),
    );
  }

  Widget _requestCard(Map<String, dynamic> r) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(r['company_name']?.toString() ?? '',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 2),
            Text(r['email']?.toString() ?? '',
                style: const TextStyle(
                    fontSize: 12.5, color: Color(0xFF1B4F72))),
            const SizedBox(height: 4),
            Text(
              [
                if ((r['contact_person'] ?? '').toString().isNotEmpty)
                  r['contact_person'],
                if ((r['phone'] ?? '').toString().isNotEmpty) r['phone'],
                if ((r['city'] ?? '').toString().isNotEmpty) r['city'],
                if ((r['gst_number'] ?? '').toString().isNotEmpty)
                  'GST ${r['gst_number']}',
              ].join('  ·  '),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                    onPressed: () => _reject(r),
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                    child: const Text('Reject')),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () => _approve(r),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D32),
                      foregroundColor: Colors.white),
                  child: const Text('Approve'),
                ),
              ],
            ),
          ],
        ),
      );
}
