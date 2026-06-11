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

  Future<void> _editOrderDialog(TileSize s) async {
    final ctrl = TextEditingController(text: '${s.sortOrder}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Order — ${s.name}'),
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
    await _run(() => _data.setTileSizeOrder(s.id, n));
  }

  // Splits the comma-separated aliases field into a clean list.
  List<String> _parseAliases(String raw) => raw
      .split(RegExp(r'[,\n]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  Future<void> _addDialog() async {
    final nameCtrl = TextEditingController();
    final aliasCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add size'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Size (e.g. 800x1600 mm)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: aliasCtrl,
              decoration: const InputDecoration(
                labelText: 'Aliases (inch/feet) — comma separated',
                hintText: '32x64, 2.5x5',
                helperText: 'Either orientation is matched automatically.',
                border: OutlineInputBorder(),
              ),
            ),
          ],
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
    if (ok == true) {
      await _run(() => _data.addTileSize(nameCtrl.text,
          aliases: _parseAliases(aliasCtrl.text)));
    }
  }

  Future<void> _renameDialog(TileSize s) async {
    final nameCtrl = TextEditingController(text: s.name);
    final aliasCtrl = TextEditingController(text: s.aliases.join(', '));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit size'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Size name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: aliasCtrl,
              decoration: const InputDecoration(
                labelText: 'Aliases (inch/feet) — comma separated',
                hintText: '32x64, 2.5x5',
                helperText: 'Either orientation is matched automatically.',
                border: OutlineInputBorder(),
              ),
            ),
          ],
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
    if (ok == true) {
      await _run(() async {
        if (nameCtrl.text.trim() != s.name) {
          await _data.renameTileSize(s.id, nameCtrl.text);
        }
        await _data.setTileSizeAliases(s.id, _parseAliases(aliasCtrl.text));
      });
    }
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
                    'Tap the order number to change a size\'s position (lower '
                    'shows first). Hide to keep it out of pickers/filters.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
                    itemCount: _items.length,
                    itemBuilder: (_, i) => _tile(_items[i], i),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _tile(TileSize s, int index) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: s.isActive ? 1 : 0.5,
        child: ListTile(
          leading: InkWell(
            onTap: _busy ? null : () => _editOrderDialog(s),
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
                  Text('${s.sortOrder}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, color: _navy)),
                  const Icon(Icons.edit, size: 11, color: _navy),
                ],
              ),
            ),
          ),
          title: Text(s.name,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.isActive ? 'Visible' : 'Hidden',
                  style: TextStyle(
                      fontSize: 11,
                      color:
                          s.isActive ? const Color(0xFF2E7D32) : Colors.grey)),
              if (s.aliases.isNotEmpty)
                Text('also: ${s.aliases.join(', ')}',
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey.shade600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
            ],
          ),
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
