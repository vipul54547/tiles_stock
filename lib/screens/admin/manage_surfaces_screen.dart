import 'package:flutter/material.dart';
import '../../models/surface_type.dart';
import '../../services/supabase_data_service.dart';

/// Admin master list of tile finishes (surface types). Add / rename / hide /
/// reorder / delete. The protected 'None' fallback is shown locked at the
/// bottom. Stockists align their PDF surface words to whatever lives here.
class ManageSurfacesScreen extends StatefulWidget {
  const ManageSurfacesScreen({super.key});

  @override
  State<ManageSurfacesScreen> createState() => _ManageSurfacesScreenState();
}

class _ManageSurfacesScreenState extends State<ManageSurfacesScreen> {
  static const _navy = Color(0xFF1B4F72);

  final _data = SupabaseDataService();

  List<SurfaceType> _items = [];   // non-system, ordered
  SurfaceType? _system;            // the 'None' fallback
  bool _loading = true;
  bool _busy = false;              // a write is in flight
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
      final all = await _data.getSurfaceTypes();
      setState(() {
        _items   = all.where((s) => !s.isSystem).toList();
        _system  = all.where((s) => s.isSystem).cast<SurfaceType?>().firstOrNull;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error   = e.toString();
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

  /// Runs a write, then reloads. Disables the UI while in flight and surfaces
  /// any error as a red SnackBar.
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
    final name = await _nameDialog(title: 'Add Finish');
    if (name == null) return;
    await _run(() => _data.addSurfaceType(name), ok: 'Finish added.');
  }

  Future<void> _renameDialog(SurfaceType s) async {
    final name = await _nameDialog(title: 'Rename Finish', initial: s.name);
    if (name == null || name.trim() == s.name) return;
    await _run(() => _data.renameSurfaceType(s.id, name), ok: 'Renamed.');
  }

  Future<void> _confirmDelete(SurfaceType s) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${s.name}"?'),
        content: const Text(
            'This finish will be removed from the list. Designs that already '
            'use it keep their value. You can only delete finishes no design '
            'is using.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await _run(() => _data.deleteSurfaceType(s), ok: 'Deleted.');
  }

  Future<String?> _nameDialog({required String title, String? initial}) {
    final ctrl = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Finish name',
            hintText: 'e.g. Glossy, Carving, Sugar',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
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

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    setState(() {
      final moved = _items.removeAt(oldIndex);
      _items.insert(newIndex, moved);
    });
    await _run(() => _data.reorderSurfaceTypes(_items.map((s) => s.id).toList()));
  }

  // ── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Finishes'),
        actions: [
          IconButton(
            tooltip: 'Add finish',
            icon: const Icon(Icons.add),
            onPressed: _busy ? null : _addDialog,
          ),
        ],
      ),
      body: _buildBody(),
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
              Text('Could not load finishes:\n$_error',
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              ElevatedButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          color: _navy.withValues(alpha: 0.06),
          child: const Text(
            'These finishes are the master list. Stockists align their PDF '
            'surface words to them. Drag to reorder; hide a finish to keep it '
            'out of pickers without deleting it.',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            itemCount: _items.length,
            onReorder: _onReorder,
            buildDefaultDragHandles: false,
            itemBuilder: (_, i) => _tile(_items[i], i, key: ValueKey(_items[i].id)),
          ),
        ),
        if (_system != null) _systemTile(_system!),
      ],
    );
  }

  Widget _tile(SurfaceType s, int index, {required Key key}) {
    return Card(
      key: key,
      margin: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: s.isActive ? 1 : 0.5,
        child: ListTile(
          leading: ReorderableDragStartListener(
            index: index,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 24,
                  alignment: Alignment.center,
                  child: Text('${index + 1}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1B4F72))),
                ),
                const Icon(Icons.drag_handle, color: Colors.grey),
              ],
            ),
          ),
          title: Text(s.name,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(s.isActive ? 'Visible' : 'Hidden',
              style: TextStyle(
                  fontSize: 11,
                  color: s.isActive ? const Color(0xFF2E7D32) : Colors.grey)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(
                value: s.isActive,
                activeThumbColor: _navy,
                onChanged: _busy
                    ? null
                    : (v) => _run(() => _data.setSurfaceActive(s.id, v)),
              ),
              IconButton(
                tooltip: 'Rename',
                icon: const Icon(Icons.edit_outlined, size: 20),
                onPressed: _busy ? null : () => _renameDialog(s),
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline,
                    size: 20, color: Colors.red),
                onPressed: _busy ? null : () => _confirmDelete(s),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _systemTile(SurfaceType s) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, size: 18, color: Colors.grey),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, color: Colors.black87)),
                const Text('Fallback for unrecognised finishes — always present',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
