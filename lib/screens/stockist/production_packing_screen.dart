import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/supabase_data_service.dart';

/// 🏭 **PRODUCTION — STEP 3: THE PACKING PLAN.**
///
/// The sheet the packing line actually needs, once a plan has been taken into production: **which
/// cover, how many boxes, how many pieces, and whose order it is for.** Nothing has entered stock
/// yet — the boxes appear in the godown only when he adds the stock (a later step), and the booked
/// orders settle then.
///
/// "For whom" comes from the run's demand (`my_production_history` rows for this run), grouped by
/// cover. (docs/PRODUCTION_REDESIGN_PLAN.md)
class ProductionPackingScreen extends StatefulWidget {
  const ProductionPackingScreen(
      {super.key, required this.runId, required this.runName});

  final String runId;
  final String runName;

  @override
  State<ProductionPackingScreen> createState() =>
      _ProductionPackingScreenState();
}

const _navy = Color(0xFF1B4F72);
const _purple = Color(0xFF6A1B9A);
const _green = Color(0xFF2E7D32);

class _ProductionPackingScreenState extends State<ProductionPackingScreen> {
  final _data = SupabaseDataService();

  bool _loading = true;
  Map<String, dynamic>? _run;

  /// box_id → the buyers (and their planned boxes) that cover is for.
  final Map<String, List<({String who, int qty})>> _whoByBox = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final runs = await _data.myProductionRuns();
    final hist = await _data.myProductionHistory();
    if (!mounted) return;
    setState(() {
      _run = runs.firstWhere(
          (r) => (r['id'] ?? '').toString() == widget.runId,
          orElse: () => <String, dynamic>{});
      _whoByBox.clear();
      for (final h in hist) {
        if ((h['run_id'] ?? '').toString() != widget.runId) continue;
        final box = (h['box_id'] ?? '').toString();
        final who = (h['customer'] ?? '').toString();
        final qty = (h['planned_boxes'] as num?)?.toInt() ?? 0;
        (_whoByBox[box] ??= []).add((who: who, qty: qty));
      }
      _loading = false;
    });
  }

  int _i(Map m, String k) => (m[k] as num?)?.toInt() ?? 0;

  List<Map<String, dynamic>> get _boxes => [
        for (final b in (_run?['boxes'] as List?) ?? const [])
          Map<String, dynamic>.from(b as Map)
      ];

  String _forWhom(String boxId) {
    final list = _whoByBox[boxId] ?? const [];
    if (list.isEmpty) return 'stock';
    return list.map((w) => '${w.who} (${w.qty})').join(' · ');
  }

  void _copy() {
    final boxes = _boxes;
    final buf = StringBuffer('${widget.runName} — packing plan\n');
    for (final b in boxes) {
      final id = (b['box_id'] ?? '').toString();
      final pieces = _i(b, 'pieces');
      final target = _i(b, 'target');
      buf.writeln('\n• ${b['cover_word']}  (${b['brand']} · ${b['surface']} · ${b['size']})');
      buf.writeln('  $target boxes'
          '${pieces > 0 ? ' · ${target * pieces} pieces' : ''}');
      buf.writeln('  for ${_forWhom(id)}');
    }
    Clipboard.setData(ClipboardData(text: buf.toString().trim()));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Packing plan copied.'), backgroundColor: _green));
  }

  @override
  Widget build(BuildContext context) {
    final boxes = _boxes;
    final totBoxes = boxes.fold<int>(0, (s, b) => s + _i(b, 'target'));
    final totPieces = boxes.fold<int>(
        0, (s, b) => s + _i(b, 'target') * (_i(b, 'pieces')));
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: const Text('Packing plan'),
        actions: [
          if (!_loading && boxes.isNotEmpty)
            IconButton(
                icon: const Icon(Icons.copy_all_outlined),
                tooltip: 'Copy',
                onPressed: _copy),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.runName,
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 17)),
                      const SizedBox(height: 2),
                      Text(
                          '${boxes.length} cover(s) · $totBoxes boxes'
                          '${totPieces > 0 ? ' · $totPieces pieces' : ''}',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600)),
                    ]),
              ),
              const Divider(height: 1),
              Expanded(
                child: boxes.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(28),
                          child: Text('This run has no covers to pack.',
                              style: TextStyle(color: Colors.grey)),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(10, 10, 10, 20),
                        children: [
                          for (final b in boxes) _coverRow(b),
                          _note(),
                        ],
                      ),
              ),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                child: Row(children: [
                  const Expanded(
                    child: Text('Orders fully taken have left the planning list.',
                        style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: _navy),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('Done'),
                  ),
                ]),
              ),
            ]),
    );
  }

  Widget _coverRow(Map<String, dynamic> b) {
    final id = (b['box_id'] ?? '').toString();
    final pieces = _i(b, 'pieces');
    final target = _i(b, 'target');
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${b['cover_word']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 13.5)),
                  Text('${b['brand']} · ${b['surface']} · ${b['size']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade600)),
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text('for ${_forWhom(id)}',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade700)),
                  ),
                ]),
          ),
          const SizedBox(width: 10),
          _fig('$target', 'boxes', _purple),
          if (pieces > 0) ...[
            const SizedBox(width: 14),
            _fig('${target * pieces}', 'pieces', _navy),
          ],
        ]),
      ),
    );
  }

  Widget _fig(String n, String label, Color c) => Column(children: [
        Text(n,
            style:
                TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: c)),
        Text(label, style: TextStyle(fontSize: 9, color: Colors.grey.shade500)),
      ]);

  Widget _note() => Container(
        margin: const EdgeInsets.fromLTRB(2, 8, 2, 0),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: const Color(0xFFE7EEF4),
            borderRadius: BorderRadius.circular(9)),
        child: const Text(
            'This is the sheet the packing line needs: which cover, how many boxes, and whose order '
            'it is for. Nothing has entered stock yet — the boxes appear in the godown when you add '
            'the stock, and the booked orders settle themselves at that moment.',
            style: TextStyle(fontSize: 12, height: 1.45, color: Color(0xFF12212D))),
      );
}
