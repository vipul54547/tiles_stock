import 'package:flutter/material.dart';
import '../../services/supabase_data_service.dart';

/// Admin: per-brand identity for one stockist — rename, Live/Correction/Off
/// status, and delete. Banners now live on the stock list (set by the stockist),
/// not the brand; the "how many stock lists" allowance is set per-stockist on the
/// stockist edit form. Reached from the stockist edit form. (project_stockist_library)
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
    setState(() {
      _brands = brands;
      _loading = false;
    });
  }

  // + Add brand — dialog pre-filled with the next default name "Brand N".
  Future<void> _addBrand() async {
    final ctrl = TextEditingController(text: 'Brand ${_brands.length + 1}');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add brand'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
              labelText: 'Brand name', border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('Add')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    setState(() => _saving = true);
    try {
      await _data.addBrandForStockist(widget.seq, name.trim());
      await _load();
    } catch (e) {
      _snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _rename(Map<String, dynamic> b) async {
    final ctrl = TextEditingController(text: (b['name'] ?? '').toString());
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename brand'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
              labelText: 'Brand name', border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(ctx, v),
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
    if (name == null || name.trim().isEmpty || name.trim() == b['name']) return;
    setState(() => _saving = true);
    try {
      await _data.renameBrand((b['id'] ?? '').toString(), name.trim());
      if (!mounted) return;
      setState(() => b['name'] = name.trim());
    } catch (e) {
      _snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text('${widget.stockistName} — Brands'),
        actions: [
          IconButton(
            tooltip: 'Add brand',
            icon: const Icon(Icons.add),
            onPressed: _saving ? null : _addBrand,
          ),
        ],
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
                          'Manage each brand\'s name and visibility. Banners are '
                          'set by the stockist on each stock list. The number of '
                          'stock lists is set per-stockist on the stockist edit '
                          'form.',
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
                  'Tap + (top right) to add a brand. The first one is the '
                  'company default.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
            ],
          ),
        ),
      );

  Widget _brandCard(Map<String, dynamic> b) {
    final isDefault = b['is_default'] == true;

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
                IconButton(
                  tooltip: 'Rename brand',
                  icon: const Icon(Icons.edit_outlined, size: 19, color: _navy),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(4),
                  onPressed: _saving ? null : () => _rename(b),
                ),
                if (!isDefault)
                  IconButton(
                    tooltip: 'Delete brand',
                    icon: const Icon(Icons.delete_outline,
                        size: 20, color: Colors.red),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(4),
                    onPressed: _saving ? null : () => _deleteBrand(b),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            _statusControl(b),
          ],
        ),
      ),
    );
  }

  // Live / Correction / Off — the moderation control. Default brand omits "Off".
  Widget _statusControl(Map<String, dynamic> b) {
    final isDefault = b['is_default'] == true;
    var status = (b['status'] ?? 'live').toString();
    if (!['live', 'correction', 'off'].contains(status)) status = 'live';
    if (isDefault && status == 'off') status = 'live';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
            ),
            segments: [
              const ButtonSegment(
                  value: 'live',
                  label: Text('Live'),
                  icon: Icon(Icons.public, size: 15)),
              const ButtonSegment(
                  value: 'correction',
                  label: Text('Correction'),
                  icon: Icon(Icons.build_outlined, size: 15)),
              if (!isDefault)
                const ButtonSegment(
                    value: 'off',
                    label: Text('Off'),
                    icon: Icon(Icons.visibility_off_outlined, size: 15)),
            ],
            selected: {status},
            onSelectionChanged:
                _saving ? null : (sel) => _setStatus(b, sel.first),
          ),
        ),
        const SizedBox(height: 4),
        Text(
            'Live: stockist + buyers · Correction: only the stockist (to fix '
            'images), hidden from buyers'
            '${isDefault ? '' : ' · Off: hidden from everyone'}',
            style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500)),
      ],
    );
  }

  Future<void> _setStatus(Map<String, dynamic> b, String status) async {
    if (status == (b['status'] ?? 'live').toString()) return;
    if (status == 'off') {
      final ok = await _confirm('Turn off brand?',
          'Buyers and the stockist will no longer see "${b['name']}". '
          'You can turn it back on later.');
      if (!ok) return;
    }
    setState(() => _saving = true);
    try {
      await _data.setBrandStatus((b['id'] ?? '').toString(), status);
      if (!mounted) return;
      setState(() => b['status'] = status); // local update, keep stepper edits
    } catch (e) {
      _snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteBrand(Map<String, dynamic> b) async {
    final ok = await _confirm('Delete brand?',
        'Permanently delete "${b['name']}" and its stock lists. This frees a '
        'brand slot and cannot be undone.');
    if (!ok) return;
    setState(() => _saving = true);
    try {
      await _data.deleteBrand((b['id'] ?? '').toString());
      await _load();
    } catch (e) {
      _snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirm')),
        ],
      ),
    );
    return ok ?? false;
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: error ? Colors.red : null));
  }
}
