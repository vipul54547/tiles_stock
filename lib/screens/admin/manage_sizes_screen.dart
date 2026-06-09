import 'package:flutter/material.dart';
import '../../models/tile_size.dart';
import '../../services/supabase_data_service.dart';

/// Admin master list of tile sizes — add / rename / hide / delete / reorder.
/// The order here drives the size pickers (add/upload) and the buyer filters.
class ManageSizesScreen extends StatefulWidget {
  const ManageSizesScreen({super.key});
  @override
  State<ManageSizesScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);

class _State extends State<ManageSizesScreen> {
  final _data = SupabaseDataService();
  List<TileSize> _items = [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await _data.getTileSizes();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex--;
    final item = _items.removeAt(oldIndex);
    _items.insert(newIndex, item);
    setState(() {});
    await _run(() => _data.reorderTileSizes(_items.map((s) => s.id).toList()));
  }

  Future<void> _addDialog() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add size'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Size (e.g. 800x1600 mm)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Add')),
        ],
      ),
    );
    if (ok == true) await _run(() => _data.addTileSize(ctrl.text));
  }

  Future<void> _renameDialog(TileSize s) async {
    final ctrl = TextEditingController(text: s.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename size'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
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
    if (ok == true) await _run(() => _data.renameTileSize(s.id, ctrl.text));
  }

  Future<void> _confirmDelete(TileSize s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete size?'),
        content: Text('Delete "${s.name}"? Designs already using it keep their '
            'size, but it won\'t be selectable.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true) await _run(() => _data.deleteTileSize(s.id));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Sizes')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _addDialog,
        backgroundColor: _navy,
        icon: const Icon(Icons.add),
        label: const Text('Add size'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'Drag to reorder; hide to keep a size out of pickers/filters '
                    'without deleting it. Order here is the display order.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
                    itemCount: _items.length,
                    onReorder: _onReorder,
                    itemBuilder: (_, i) =>
                        _tile(_items[i], i, key: ValueKey(_items[i].id)),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _tile(TileSize s, int index, {required Key key}) {
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
                SizedBox(
                  width: 24,
                  child: Text('${index + 1}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, color: _navy)),
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
                onChanged:
                    _busy ? null : (v) => _run(() => _data.setTileSizeActive(s.id, v)),
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
}
