import 'package:flutter/material.dart';
import '../../models/stockist.dart';
import '../../services/supabase_data_service.dart';
import '../../utils/stockist_tiers.dart';

/// Admin controls the order stockists appear to buyers: Tier (Platinum > Gold >
/// Silver > none) → Priority (higher first) → automatic stock-ranking. The list
/// here is shown in that exact order, so position = how buyers see them.
class ListingOrderScreen extends StatefulWidget {
  const ListingOrderScreen({super.key});
  @override
  State<ListingOrderScreen> createState() => _State();
}

class _State extends State<ListingOrderScreen> {
  final _svc = SupabaseDataService();
  List<Stockist> _stockists = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await _svc.getAllStockists(activeOnly: false);
    // Same order buyers see (tier → priority → name as a stable tiebreaker).
    list.sort((a, b) {
      final t = stockistTierRank(b.stockistType)
          .compareTo(stockistTierRank(a.stockistType));
      if (t != 0) return t;
      final p = b.priority.compareTo(a.priority);
      if (p != 0) return p;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    if (!mounted) return;
    setState(() {
      _stockists = list;
      _loading = false;
    });
  }

  Future<void> _edit(Stockist s) async {
    final priorityCtrl =
        TextEditingController(text: s.priority.toStringAsFixed(0));
    String tier = kStockistTiers.contains(s.stockistType) ? s.stockistType : '';

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(s.name, overflow: TextOverflow.ellipsis),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('ID: ${s.id}',
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: tier,
                decoration: const InputDecoration(
                    labelText: 'Tier', border: OutlineInputBorder()),
                items: [
                  const DropdownMenuItem(value: '', child: Text('None')),
                  ...kStockistTiers.map(
                      (t) => DropdownMenuItem(value: t, child: Text(t))),
                ],
                onChanged: (v) => setD(() => tier = v ?? ''),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: priorityCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Priority (higher shows first)',
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
      ),
    );

    if (saved != true) return;
    final priority = double.tryParse(priorityCtrl.text.trim()) ?? 0;
    try {
      await _svc.updateStockistListing(s.id, priority, tier);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red));
    }
  }

  Color _tierColor(String t) {
    switch (t.toLowerCase()) {
      case 'platinum':
        return const Color(0xFF6A1B9A);
      case 'gold':
        return const Color(0xFFF9A825);
      case 'silver':
        return const Color(0xFF607D8B);
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Listing Order')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  color: const Color(0xFF1B4F72).withValues(alpha: 0.06),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: const Text(
                    'Order = Tier (Platinum→Silver) → Priority (high→low). '
                    'Tap a stockist to set its tier & priority.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF1B4F72)),
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: _stockists.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) => _row(i + 1, _stockists[i]),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _row(int pos, Stockist s) {
    final tier = kStockistTiers.contains(s.stockistType) ? s.stockistType : 'None';
    return InkWell(
      onTap: () => _edit(s),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: const Color(0xFF1B4F72).withValues(alpha: 0.1),
              child: Text('$pos',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1B4F72))),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 14),
                      overflow: TextOverflow.ellipsis),
                  Text('ID: ${s.id}',
                      style:
                          const TextStyle(color: Colors.grey, fontSize: 11)),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _tierColor(tier).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(tier,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: _tierColor(tier))),
            ),
            const SizedBox(width: 8),
            Column(
              children: [
                Text(s.priority.toStringAsFixed(0),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14)),
                const Text('priority',
                    style: TextStyle(fontSize: 9, color: Colors.grey)),
              ],
            ),
            const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}
