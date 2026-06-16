import 'package:flutter/material.dart';
import '../../services/supabase_data_service.dart';

/// Admin: per-brand stock-list limit for one stockist. Each brand has its own
/// "how many stock lists" number (default 1); raising it auto-creates the missing
/// lists in that brand. Reached from the stockist edit form. (project_stockist_library /
/// per_brand_stock_list_limit)
class StockistBrandListsScreen extends StatefulWidget {
  final String seq; // stockist sequential id
  final String stockistName;
  const StockistBrandListsScreen(
      {super.key, required this.seq, required this.stockistName});
  @override
  State<StockistBrandListsScreen> createState() => _State();
}

class _State extends State<StockistBrandListsScreen> {
  final _data = SupabaseDataService();
  List<Map<String, dynamic>> _brands = [];
  // brand id -> the limit currently shown in the stepper (edited value).
  final Map<String, int> _limit = {};
  bool _loading = true;
  bool _saving = false;

  static const Color _navy = Color(0xFF1B4F72);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final brands = await _data.adminStockistBrands(widget.seq);
    if (!mounted) return;
    _limit.clear();
    for (final b in brands) {
      final id = (b['id'] ?? '').toString();
      // Never below what already exists (we don't delete lists).
      final count = (b['list_count'] as num?)?.toInt() ?? 0;
      final lim = (b['stock_list_limit'] as num?)?.toInt() ?? 1;
      _limit[id] = lim < count ? count : lim;
    }
    setState(() {
      _brands = brands;
      _loading = false;
    });
  }

  int _minFor(Map<String, dynamic> b) {
    final count = (b['list_count'] as num?)?.toInt() ?? 0;
    return count < 1 ? 1 : count; // can hold/raise, never reduce below existing
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      for (final b in _brands) {
        final id = (b['id'] ?? '').toString();
        final orig = (b['stock_list_limit'] as num?)?.toInt() ?? 1;
        final now = _limit[id] ?? orig;
        if (now != orig) {
          await _data.setBrandStockListLimit(id, now);
        }
      }
      if (!mounted) return;
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Stock-list limits saved.'),
          backgroundColor: Color(0xFF2E7D32)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().replaceAll('PostgrestException:', '').trim()),
          backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(title: Text('${widget.stockistName} — Brands & Lists')),
      bottomNavigationBar: _brands.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                      backgroundColor: _navy,
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Save limits'),
                ),
              ),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _brands.isEmpty
              ? _empty()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                      child: Text(
                          'Set how many stock lists each brand can have. The lists '
                          'are created automatically; the stockist just renames them. '
                          'You can raise a limit but not reduce below the lists that '
                          'already exist.',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600)),
                    ),
                    ..._brands.map(_brandCard),
                  ],
                ),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.sell_outlined, size: 60, color: Colors.grey.shade300),
              const SizedBox(height: 12),
              Text('No brands yet',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.grey.shade600)),
              const SizedBox(height: 4),
              Text(
                  'Set the Brands count on the stockist and save first — the '
                  'brands appear here afterwards.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
            ],
          ),
        ),
      );

  Widget _brandCard(Map<String, dynamic> b) {
    final id = (b['id'] ?? '').toString();
    final isDefault = b['is_default'] == true;
    final names = ((b['list_names'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    final min = _minFor(b);
    final value = _limit[id] ?? min;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sell, size: 18, color: _navy),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(b['name']?.toString() ?? '',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: _navy)),
                ),
                if (isDefault)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text('default',
                        style: TextStyle(fontSize: 11, color: Colors.black54)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Stock lists',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const Spacer(),
                _stepBtn(Icons.remove, value > min,
                    () => setState(() => _limit[id] = value - 1)),
                SizedBox(
                  width: 40,
                  child: Text('$value',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                _stepBtn(Icons.add, true,
                    () => setState(() => _limit[id] = value + 1)),
              ],
            ),
            if (names.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(names.join(' · '),
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _stepBtn(IconData icon, bool enabled, VoidCallback onTap) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: enabled ? _navy.withValues(alpha: 0.1) : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon,
            size: 20, color: enabled ? _navy : Colors.grey.shade400),
      ),
    );
  }
}
