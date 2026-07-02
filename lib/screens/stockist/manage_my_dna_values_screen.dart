import 'package:flutter/material.dart';
import '../../services/supabase_data_service.dart';

/// Manage a stockist's OWN private values for one single-select free-text DNA
/// attribute (e.g. Series). Rename or delete; deleting removes the tag from
/// every design that carries it (server-side cascade). Generic by attribute
/// so any future attribute of this shape (own naming, no admin mapping)
/// reuses the same screen.
class ManageMyDnaValuesScreen extends StatefulWidget {
  final String attributeId;
  final String attributeName;
  const ManageMyDnaValuesScreen(
      {super.key, required this.attributeId, required this.attributeName});

  @override
  State<ManageMyDnaValuesScreen> createState() =>
      _ManageMyDnaValuesScreenState();
}

class _ManageMyDnaValuesScreenState extends State<ManageMyDnaValuesScreen> {
  static const _navy = Color(0xFF1B4F72);
  final _data = SupabaseDataService();

  List<Map<String, dynamic>> _values = [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final values = await _data.dnaMyValuesWithUsage(widget.attributeId);
    if (!mounted) return;
    setState(() {
      _values = values;
      _loading = false;
    });
  }

  Future<void> _rename(Map<String, dynamic> v) async {
    final ctrl = TextEditingController(text: v['name'] as String? ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Rename ${widget.attributeName}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(isDense: true),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == v['name']) return;
    setState(() => _busy = true);
    try {
      await _data.dnaRenameMyValue(v['id'] as String, name);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not rename: $e'),
            backgroundColor: Colors.red.shade700));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Map<String, dynamic> v) async {
    final count = (v['design_count'] as num?)?.toInt() ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${v['name']}"?'),
        content: Text(count > 0
            ? 'Used on $count design${count == 1 ? '' : 's'} — deleting '
                'removes it from all of them.'
            : 'This ${widget.attributeName.toLowerCase()} is not used on any '
                'design yet.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await _data.dnaDeleteMyValue(v['id'] as String);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not delete: $e'),
            backgroundColor: Colors.red.shade700));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Manage ${widget.attributeName}'),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                  child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _values.isEmpty
              ? Center(
                  child: Text(
                    'You haven\'t created any ${widget.attributeName.toLowerCase()} yet.',
                    style: const TextStyle(color: Colors.black54),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: _values.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (_, i) {
                    final v = _values[i];
                    final count = (v['design_count'] as num?)?.toInt() ?? 0;
                    return Card(
                      margin: EdgeInsets.zero,
                      child: ListTile(
                        title: Text(v['name'] as String? ?? '',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                            '$count design${count == 1 ? '' : 's'}',
                            style: const TextStyle(fontSize: 11.5)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined,
                                  color: _navy, size: 20),
                              tooltip: 'Rename',
                              onPressed: _busy ? null : () => _rename(v),
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline,
                                  color: Colors.red.shade700, size: 20),
                              tooltip: 'Delete',
                              onPressed: _busy ? null : () => _delete(v),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
