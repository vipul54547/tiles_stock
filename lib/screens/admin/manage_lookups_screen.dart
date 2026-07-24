import 'package:flutter/material.dart';
import '../../services/supabase_data_service.dart';

/// Admin editor for the generic managed lookup lists (`admin_lookups`) that the
/// media portfolio uses — **Space** (room tag on mockups/360s) and **Placement**
/// (Wall / Floor / Wall & Floor role on a media→tile link). Add · rename · hide ·
/// reorder. Built generic on `list_key` so future tools register their own list
/// and reuse this one editor. (project_media_portfolio_ddpi #18)
///
/// There is no delete — the slug (`value`) is stable and referenced by
/// convention, so a value is HIDDEN (active=false) rather than removed.
class ManageLookupsScreen extends StatefulWidget {
  const ManageLookupsScreen({super.key});

  @override
  State<ManageLookupsScreen> createState() => _ManageLookupsScreenState();
}

/// One editable managed list. Add to this list to expose a new `list_key` here.
class _ListDef {
  final String key;
  final String title;
  final String noun; // singular, for dialogs ("Add Space")
  final String hint; // example values, shown in the add dialog
  const _ListDef(this.key, this.title, this.noun, this.hint);
}

const _lists = <_ListDef>[
  _ListDef('space', 'Space', 'Space',
      'e.g. Living room, Bedroom, Kitchen, Bathroom'),
  _ListDef('placement', 'Placement', 'Placement',
      'e.g. Wall, Floor, Wall & Floor'),
];

class _ManageLookupsScreenState extends State<ManageLookupsScreen> {
  static const _navy = Color(0xFF1B4F72);

  final _data = SupabaseDataService();

  _ListDef _list = _lists.first;
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _data.adminLookupsList(_list.key);
      setState(() {
        _items = rows;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade700 : null,
      duration: Duration(seconds: error ? 5 : 2),
    ));
  }

  Future<void> _run(Future<void> Function() action, {String? ok}) async {
    setState(() => _busy = true);
    try {
      await action();
      if (ok != null) _snack(ok);
      await _load();
    } catch (e) {
      _snack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── actions ────────────────────────────────────────────────────────────────

  Future<void> _addDialog() async {
    final name = await _nameDialog(title: 'Add ${_list.noun}', hint: _list.hint);
    if (name == null || name.trim().isEmpty) return;
    await _run(() => _data.adminLookupAdd(_list.key, name),
        ok: '${_list.noun} added.');
  }

  Future<void> _renameDialog(Map<String, dynamic> row) async {
    final name = await _nameDialog(
        title: 'Rename ${_list.noun}',
        initial: row['label'] as String?,
        hint: _list.hint);
    if (name == null || name.trim() == (row['label'] as String?)) return;
    await _run(() => _data.adminLookupRename(row['id'] as String, name),
        ok: 'Renamed.');
  }

  Future<String?> _nameDialog(
      {required String title, String? initial, String? hint}) {
    final ctrl = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: '${_list.noun} name',
            hintText: hint,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            style: ElevatedButton.styleFrom(
                backgroundColor: _navy, foregroundColor: Colors.white),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _editOrderDialog(Map<String, dynamic> row) async {
    final ctrl = TextEditingController(text: '${row['sort_order']}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Order — ${row['label']}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Order number (lower shows first)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    final n = int.tryParse(ctrl.text.trim());
    if (n == null) return;
    await _run(() => _data.adminLookupSetSort(row['id'] as String, n));
  }

  // ── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Managed Lists'),
        actions: [
          IconButton(
            tooltip: 'Add ${_list.noun}',
            icon: const Icon(Icons.add),
            onPressed: _busy ? null : _addDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            color: _navy.withValues(alpha: 0.06),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Shared pick-lists used across the app. Tap the order number to '
                  'change position (lower shows first); hide a value to keep it '
                  'out of pickers. Values are never deleted, only hidden.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: _list.key,
                  decoration: const InputDecoration(
                    labelText: 'List',
                    isDense: true,
                    border: OutlineInputBorder(),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  items: _lists
                      .map((l) => DropdownMenuItem(
                          value: l.key, child: Text(l.title)))
                      .toList(),
                  onChanged: _busy
                      ? null
                      : (v) {
                          final next =
                              _lists.firstWhere((l) => l.key == v);
                          setState(() => _list = next);
                          _load();
                        },
                ),
              ],
            ),
          ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 40),
              const SizedBox(height: 12),
              Text('Could not load list:\n$_error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              ElevatedButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text('No ${_list.title} values yet. Tap + to add.',
            style: const TextStyle(color: Colors.grey)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      itemCount: _items.length,
      itemBuilder: (_, i) => _tile(_items[i]),
    );
  }

  Widget _tile(Map<String, dynamic> row) {
    final active = row['active'] == true;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: active ? 1 : 0.5,
        child: ListTile(
          leading: InkWell(
            onTap: _busy ? null : () => _editOrderDialog(row),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 44,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: _navy.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${row['sort_order']}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, color: _navy)),
                  const Icon(Icons.edit, size: 11, color: _navy),
                ],
              ),
            ),
          ),
          title: Text(row['label']?.toString() ?? '',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(active ? 'Visible' : 'Hidden',
              style: TextStyle(
                  fontSize: 11,
                  color: active ? const Color(0xFF2E7D32) : Colors.grey)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(
                value: active,
                activeThumbColor: _navy,
                onChanged: _busy
                    ? null
                    : (v) => _run(() =>
                        _data.adminLookupSetActive(row['id'] as String, v)),
              ),
              IconButton(
                tooltip: 'Rename',
                icon: const Icon(Icons.edit_outlined, size: 20),
                onPressed: _busy ? null : () => _renameDialog(row),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
