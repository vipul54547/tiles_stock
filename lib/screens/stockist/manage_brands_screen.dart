import 'package:flutter/material.dart';
import '../../models/brand.dart';
import '../../services/supabase_data_service.dart';

/// Stockist's brands (multi-brand). A manufacturer can run several brands; each
/// brand is a parent of its own stock catalogue(s) — own design names + stock.
/// How many brands they may create is admin-controlled (the server enforces the
/// brand limit; trying to exceed it returns a clear message).
class ManageBrandsScreen extends StatefulWidget {
  const ManageBrandsScreen({super.key});
  @override
  State<ManageBrandsScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);

class _State extends State<ManageBrandsScreen> {
  final _data = SupabaseDataService();
  List<Brand> _brands = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await _data.getMyBrands();
    if (!mounted) return;
    setState(() {
      _brands = list;
      _loading = false;
    });
  }

  Future<void> _addBrand() async {
    final name = await _nameDialog('Add a brand',
        'Each brand has its own stock catalogue, design names and stock.');
    if (name == null || name.trim().isEmpty) return;
    try {
      await _data.createBrand(name.trim());
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Brand "$name" added.'),
          backgroundColor: const Color(0xFF2E7D32)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _rename(Brand b) async {
    final name = await _nameDialog('Rename brand', null, initial: b.name);
    if (name == null || name.trim().isEmpty || name.trim() == b.name) return;
    try {
      await _data.renameBrand(b.id, name.trim());
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e'), backgroundColor: Colors.red));
    }
  }

  Future<String?> _nameDialog(String title, String? hint, {String? initial}) {
    final ctrl = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hint != null) ...[
              Text(hint, style: const TextStyle(fontSize: 12.5)),
              const SizedBox(height: 10),
            ],
            TextField(
              controller: ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                  labelText: 'Brand name', border: OutlineInputBorder()),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('Save')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Brands')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addBrand,
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add brand'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'Brands let you sell the same stock under different names with '
                    'separate stock lists. How many you can add is set by the admin.',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ),
                Expanded(
                  child: _brands.isEmpty
                      ? const Center(
                          child: Text('No brands yet',
                              style: TextStyle(color: Colors.grey)))
                      : ListView.separated(
                          padding: EdgeInsets.fromLTRB(12, 8, 12,
                              12 + MediaQuery.viewPaddingOf(context).bottom),
                          itemCount: _brands.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 6),
                          itemBuilder: (_, i) => _brandTile(_brands[i]),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _brandTile(Brand b) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: const Color(0xFF6A1B9A).withValues(alpha: 0.1),
              child: const Icon(Icons.sell_outlined,
                  size: 18, color: Color(0xFF6A1B9A)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(b.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14)),
                  Text(
                      '${b.catalogCount} stock catalogue${b.catalogCount == 1 ? '' : 's'}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 20),
              tooltip: 'Rename',
              onPressed: () => _rename(b),
            ),
          ],
        ),
      );
}
