import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/tile_design.dart';
import '../../models/choice_state.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../widgets/save_bar.dart';
import '../../widgets/unsaved_changes.dart';

/// Stockist creates their own order for a (possibly non-app) customer: a
/// free-text customer hint + designs picked from their F_Stock with box
/// quantities. Saves a no-buyer inquiry (source='stockist'). On success pops
/// the new order's `{id, token, connection_code}` so the caller can offer
/// WhatsApp / a link. (project_dispatch_order_redesign · Phase E)
class StockistAddOrderScreen extends StatefulWidget {
  const StockistAddOrderScreen({super.key});
  @override
  State<StockistAddOrderScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);

class _Pick {
  final TileDesign d;
  final TextEditingController ctrl;
  _Pick(this.d, int qty) : ctrl = TextEditingController(text: '$qty');
  int get qty => int.tryParse(ctrl.text.trim()) ?? 0;
}

class _State extends State<StockistAddOrderScreen> {
  final _data = SupabaseDataService();
  final _hintCtrl = TextEditingController();
  final _picks = <String, _Pick>{}; // designId → pick
  List<TileDesign> _stock = [];
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _hintCtrl.dispose();
    for (final p in _picks.values) {
      p.ctrl.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final all = await _data.getDesignsByStockist(currentStockistUUID);
    if (!mounted) return;
    setState(() {
      // Only designs with free stock available (F = P − C − H).
      _stock = all.where((d) => d.fStock > 0).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      _loading = false;
    });
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  int get _totalBoxes =>
      _picks.values.fold(0, (s, p) => s + (p.qty > 0 ? p.qty : 0));

  Future<void> _pickDesigns() async {
    final chosen = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        var q = '';
        final sel = _picks.keys.toSet();
        return StatefulBuilder(
          builder: (ctx, setS) {
            final filtered = q.isEmpty
                ? _stock
                : _stock
                    .where((d) => d.name.toLowerCase().contains(q.toLowerCase()))
                    .toList();
            return SizedBox(
              height: MediaQuery.sizeOf(ctx).height * 0.8,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                    child: TextField(
                      autofocus: true,
                      onChanged: (v) => setS(() => q = v),
                      decoration: InputDecoration(
                        hintText: 'Search F_Stock designs…',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        isDense: true,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                  Expanded(
                    child: filtered.isEmpty
                        ? const Center(
                            child: Text('No free stock to add',
                                style: TextStyle(color: Colors.grey)))
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (_, i) {
                              final d = filtered[i];
                              final on = sel.contains(d.id);
                              return CheckboxListTile(
                                dense: true,
                                value: on,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: Text(d.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                subtitle: Text(
                                    '${d.size.replaceAll(' mm', '')} · ${d.surfaceType} · ${d.fStock} free'),
                                onChanged: (v) => setS(() =>
                                    v == true ? sel.add(d.id) : sel.remove(d.id)),
                              );
                            },
                          ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                      child: SizedBox(
                        width: double.infinity,
                        height: 46,
                        child: ElevatedButton(
                          onPressed: () => Navigator.pop(ctx, sel),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: _navy,
                              foregroundColor: Colors.white),
                          child: Text('Add ${sel.length} design'
                              '${sel.length == 1 ? '' : 's'}'),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    if (chosen == null) return;
    setState(() {
      // Drop unpicked, add newly picked (default qty = full free stock).
      _picks.removeWhere((id, p) {
        if (chosen.contains(id)) return false;
        p.ctrl.dispose();
        return true;
      });
      for (final id in chosen) {
        if (_picks.containsKey(id)) continue;
        final d = _stock.firstWhere((e) => e.id == id);
        _picks[id] = _Pick(d, d.fStock);
      }
      _dirty = true;
    });
  }

  Future<void> _save() async {
    final lines = _picks.values
        .where((p) => p.qty > 0)
        .map((p) => {'design_id': p.d.id, 'quantity': p.qty})
        .toList();
    if (lines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Add at least one design with a quantity.')));
      return;
    }
    setState(() => _saving = true);
    try {
      final res =
          await _data.createStockistOrder(_hintCtrl.text.trim(), lines);
      if (!mounted) return;
      _dirty = false;
      Navigator.pop(context, res); // {id, token, connection_code}
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e'), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    final picks = _picks.values.toList();
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(title: const Text('New Order')),
      bottomNavigationBar: SaveBar(
        label: 'Save Order ($_totalBoxes boxes)',
        icon: Icons.check_circle_outline,
        color: const Color(0xFF2E7D32),
        onPressed: _save,
        saving: _saving,
        dirty: _dirty,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : UnsavedChangesGuard(
              isDirty: _dirty,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                children: [
                  // Customer hint
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: TextField(
                        controller: _hintCtrl,
                        textCapitalization: TextCapitalization.words,
                        maxLength: 80,
                        onChanged: (_) => _markDirty(),
                        decoration: const InputDecoration(
                          labelText: 'Customer name / hint',
                          hintText: 'e.g. Ramesh (walk-in), site at Bopal…',
                          helperText:
                              'Just a note for you — no customer details are stored.',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('Designs from F_Stock',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 14)),
                      const Spacer(),
                      OutlinedButton.icon(
                        onPressed: _pickDesigns,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Select'),
                        style: OutlinedButton.styleFrom(foregroundColor: _navy),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (picks.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                          child: Text('No designs yet — tap Select.',
                              style: TextStyle(color: Colors.grey))),
                    )
                  else
                    ...picks.map(_pickCard),
                ],
              ),
            ),
    );
  }

  Widget _pickCard(_Pick p) {
    final d = p.d;
    final over = p.qty > d.fStock;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: d.faceImageUrls.isEmpty
                  ? Container(
                      width: 52, height: 52,
                      color: Colors.grey.shade100,
                      child: const Icon(Icons.image_not_supported,
                          size: 20, color: Colors.grey))
                  : CachedNetworkImage(
                      imageUrl: CloudinaryService.thumbUrl(
                          d.faceImageUrls.first, width: 200),
                      width: 52, height: 52, fit: BoxFit.cover,
                      placeholder: (_, __) => Container(color: Colors.grey.shade200),
                      errorWidget: (_, __, ___) => Container(color: Colors.grey.shade200)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13)),
                  Text('${d.size.replaceAll(' mm', '')} · ${d.surfaceType}',
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                  const SizedBox(height: 2),
                  Text('${d.fStock} free in stock',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: over ? Colors.red.shade700 : Colors.green.shade700)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 64,
              child: TextField(
                controller: p.ctrl,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                onChanged: (_) {
                  _markDirty();
                  setState(() {});
                },
                decoration: InputDecoration(
                  labelText: 'Boxes',
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
