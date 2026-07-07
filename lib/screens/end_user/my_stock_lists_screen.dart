import 'package:flutter/material.dart';

import '../../models/claimed_catalog.dart';
import '../../services/supabase_data_service.dart';

/// Buyer-facing management of the stock lists they've added (claimed).
///
/// The My Suppliers home groups everything by supplier and only offers an
/// all-or-nothing "Remove supplier". This screen goes one level deeper: it
/// shows every individual stock list the buyer has claimed — grouped by
/// supplier — with the supplier name, per-list design count and date added,
/// and lets them remove a SINGLE list (keeping the supplier's other lists).
///
/// Uses the existing `getMyClaimedCatalogs()` / `unclaimCatalog(catalogId)`
/// service methods — no schema change.
class MyStockListsScreen extends StatefulWidget {
  const MyStockListsScreen({super.key});

  @override
  State<MyStockListsScreen> createState() => _MyStockListsScreenState();
}

class _MyStockListsScreenState extends State<MyStockListsScreen> {
  static const _navy = Color(0xFF1B4F72);
  final _service = SupabaseDataService();

  bool _loading = true;
  List<ClaimedCatalog> _catalogs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final cats = await _service.getMyClaimedCatalogs();
    if (!mounted) return;
    setState(() {
      _catalogs = cats;
      _loading = false;
    });
  }

  // Group the flat claimed list by supplier, preserving order of appearance.
  Map<String, List<ClaimedCatalog>> get _bySupplier {
    final map = <String, List<ClaimedCatalog>>{};
    for (final c in _catalogs) {
      map.putIfAbsent(c.stockistKey, () => []).add(c);
    }
    return map;
  }

  Future<void> _removeList(ClaimedCatalog c) async {
    final label = c.name.isEmpty ? 'this list' : '"${c.name}"';
    final yes = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Remove stock list?'),
        content: Text(
            'Remove $label from ${c.stockistName.isEmpty ? "this supplier" : c.stockistName}? '
            'You will stop seeing its stock. You can add it again with its link.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(dctx, true),
              child:
                  const Text('Remove', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await _service.unclaimCatalog(c.catalogId);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Removed ${c.name.isEmpty ? "list" : c.name}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red));
    }
  }

  String _dateLabel(DateTime? d) {
    if (d == null) return '';
    final l = d.toLocal();
    return 'Added ${l.day}/${l.month}/${l.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Stock Lists'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _catalogs.isEmpty
              ? _empty()
              : _list(),
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.playlist_add_check_circle_outlined,
                size: 56, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              'No stock lists yet',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade700),
            ),
            const SizedBox(height: 6),
            Text(
              'Add a supplier\'s WhatsApp link to see their live stock here.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list() {
    final groups = _bySupplier;
    final keys = groups.keys.toList();
    final totalLists = _catalogs.length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
          child: Text(
            '$totalLists ${totalLists == 1 ? "list" : "lists"} · '
            '${keys.length} ${keys.length == 1 ? "supplier" : "suppliers"}',
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade600),
          ),
        ),
        for (final key in keys) _supplierCard(groups[key]!),
      ],
    );
  }

  Widget _supplierCard(List<ClaimedCatalog> lists) {
    final first = lists.first;
    final supplier =
        first.stockistName.isEmpty ? 'Supplier' : first.stockistName;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Supplier header.
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: BoxDecoration(
              color: _navy.withValues(alpha: 0.06),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: Row(
              children: [
                const Icon(Icons.storefront, size: 18, color: _navy),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    supplier,
                    style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.bold,
                        color: _navy),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _navy.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${lists.length} ${lists.length == 1 ? "list" : "lists"}',
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w700, color: _navy),
                  ),
                ),
              ],
            ),
          ),
          for (int i = 0; i < lists.length; i++) ...[
            if (i > 0) Divider(height: 1, color: Colors.grey.shade200),
            _listRow(lists[i]),
          ],
        ],
      ),
    );
  }

  Widget _listRow(ClaimedCatalog c) {
    final name = c.name.isEmpty ? 'Stock list' : c.name;
    final parts = <String>[
      '${c.designCount} ${c.designCount == 1 ? "design" : "designs"}',
      if (c.brandName.isNotEmpty) c.brandName,
      if (_dateLabel(c.claimedAt).isNotEmpty) _dateLabel(c.claimedAt),
    ];
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(14, 2, 6, 2),
      title: Text(name,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: Text(parts.join(' · '),
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      trailing: IconButton(
        icon: Icon(Icons.delete_outline, color: Colors.red.shade400),
        tooltip: 'Remove list',
        onPressed: () => _removeList(c),
      ),
    );
  }
}
