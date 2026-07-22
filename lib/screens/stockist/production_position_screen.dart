import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/supabase_data_service.dart';

/// 🏭 **PRODUCTION POSITION — the true state of a run.**
///
/// **By design** — the run's grade split: Program · Premium made · Standard made
/// · Left (progress is premium only; the gap isn't enforced).
///
/// **By order** — where he SENDS ready material to *Order from stock*: per booked
/// line, Ticked · Make · Godown(F_Stock) · Made · **Ready** (= min(ticked−sent,
/// F_Stock)). Sending reserves it from F_Stock into a held Ready order — partial
/// by editing the qty; F_Stock is a shared pool, so a shared design is flagged.
/// (docs/PRODUCTION_REDESIGN_PLAN.md §Phase 3 · order_from_stock artifact)
class ProductionPositionScreen extends StatefulWidget {
  final Map<String, dynamic> run;
  const ProductionPositionScreen({super.key, required this.run});
  @override
  State<ProductionPositionScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);
const _amber = Color(0xFFA96500);
const _green = Color(0xFF2E7D32);
const _red = Color(0xFFC62828);

class _State extends State<ProductionPositionScreen> {
  final _svc = SupabaseDataService();
  bool _loading = true;
  bool _saving = false;
  List<Map<String, dynamic>> _orders = [];
  final _qty = <String, TextEditingController>{}; // line_id -> boxes to send
  final _sharedFStock = <String, int>{}; // design_id shared across orders -> F_Stock

  int _i(Map<String, dynamic> m, String k) => (m[k] as num?)?.toInt() ?? 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _qty.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final orders =
        await _svc.productionPositionOrders((widget.run['id'] ?? '').toString());
    if (!mounted) return;
    // A design is only SHORT — and worth a warning — when it sits in more than
    // one order AND the combined demand (ticked − sent) exceeds its shared
    // F_Stock. If F_Stock covers everyone, there's no conflict, so no warning.
    final count = <String, int>{};
    final demand = <String, int>{};
    final fstockOf = <String, int>{};
    for (final o in orders) {
      for (final raw in (o['lines'] as List?) ?? const []) {
        final l = Map<String, dynamic>.from(raw as Map);
        final d = (l['design_id'] ?? '').toString();
        if (d.isEmpty) continue;
        count[d] = (count[d] ?? 0) + 1;
        demand[d] =
            (demand[d] ?? 0) + (_i(l, 'ticked') - _i(l, 'sent')).clamp(0, 1 << 30);
        fstockOf[d] = _i(l, 'f_stock');
      }
    }
    _sharedFStock.clear();
    for (final d in count.keys) {
      if ((count[d] ?? 0) > 1 && (demand[d] ?? 0) > (fstockOf[d] ?? 0)) {
        _sharedFStock[d] = fstockOf[d] ?? 0;
      }
    }
    // Fresh qty controllers, each defaulting to the line's ready.
    for (final c in _qty.values) {
      c.dispose();
    }
    _qty.clear();
    for (final o in orders) {
      for (final raw in (o['lines'] as List?) ?? const []) {
        final l = Map<String, dynamic>.from(raw as Map);
        final ready = _i(l, 'ready');
        _qty[(l['line_id']).toString()] =
            TextEditingController(text: ready == 0 ? '' : '$ready');
      }
    }
    setState(() {
      _orders = orders;
      _loading = false;
    });
  }

  Future<void> _send(List<Map<String, dynamic>> lines) async {
    final payload = <Map<String, dynamic>>[];
    for (final l in lines) {
      final id = (l['line_id']).toString();
      final q = int.tryParse(_qty[id]?.text.trim() ?? '') ?? 0;
      if (q > 0) payload.add({'line_id': id, 'boxes': q});
    }
    if (payload.isEmpty) {
      _snack('Nothing to send.', _red);
      return;
    }
    setState(() => _saving = true);
    try {
      final res = await _svc.bookOrderSendToStock(payload);
      final sent = _i(res, 'sent');
      final token = (res['token'] ?? '').toString();
      await _load();
      if (mounted) {
        _snack(
            sent > 0
                ? '$sent boxes reserved → Ready order ${token.isEmpty ? '' : '($token)'}'
                : 'Nothing sent — no free stock available.',
            sent > 0 ? _green : _amber);
      }
    } catch (e) {
      if (mounted) _snack('$e', _red);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String m, [Color c = _navy]) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c));

  @override
  Widget build(BuildContext context) {
    final boxes = [
      for (final b in (widget.run['boxes'] as List?) ?? const [])
        Map<String, dynamic>.from(b as Map)
    ];
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: Text('Position · ${widget.run['name'] ?? ''}'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
              children: [
                _sectionTitle('By design — the run\'s totals'),
                for (final b in boxes) _designCard(b),
                const SizedBox(height: 16),
                _sectionTitle('By order — send ready material from here'),
                if (_orders.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('No booked orders in this run.',
                        style: TextStyle(color: Colors.grey.shade500)),
                  )
                else
                  for (final o in _orders) _orderCard(o),
              ],
            ),
    );
  }

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 4, 2, 8),
        child: Text(s.toUpperCase(),
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
                color: Colors.grey.shade600)),
      );

  Widget _designCard(Map<String, dynamic> b) {
    final program = _i(b, 'target');
    final prem = _i(b, 'premium_made');
    final std = _i(b, 'standard_made');
    final left = (program - prem).clamp(0, 1 << 30);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${b['cover_word']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
          Text('${b['brand']} · ${b['surface']} · ${b['size']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          const SizedBox(height: 10),
          Wrap(spacing: 20, runSpacing: 8, children: [
            _fig('Program', program, Colors.grey.shade700),
            _fig('Premium made', prem, _green),
            _fig('Standard made', std, _navy),
            _fig('Left', left, _amber),
          ]),
        ]),
      ),
    );
  }

  Widget _orderCard(Map<String, dynamic> o) {
    final lines = [
      for (final l in (o['lines'] as List?) ?? const [])
        Map<String, dynamic>.from(l as Map)
    ];
    final anyReady = lines.any((l) => _i(l, 'ready') > 0);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.person_outline, size: 16, color: _navy),
              const SizedBox(width: 6),
              Expanded(
                child: Text('${o['customer']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 14)),
              ),
              Text('${o['token']}',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            ]),
            const SizedBox(height: 4),
            for (final l in lines) _lineRow(l),
            if (anyReady)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: FilledButton.icon(
                    onPressed: _saving ? null : () => _send(lines),
                    icon: const Icon(Icons.playlist_add_check, size: 18),
                    label: const Text('Send all ready'),
                    style: FilledButton.styleFrom(backgroundColor: _green),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _lineRow(Map<String, dynamic> l) {
    final lineId = (l['line_id']).toString();
    final designId = (l['design_id'] ?? '').toString();
    final ready = _i(l, 'ready');
    final shared = _sharedFStock.containsKey(designId);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${l['cover_word']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          Text('${l['brand']} · ${l['surface']} · ${l['size']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600)),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: Wrap(spacing: 14, runSpacing: 4, children: [
                _mini('Ticked', _i(l, 'ticked'), Colors.grey.shade700),
                _mini('Make', _i(l, 'make'), _navy),
                _mini('Godown', _i(l, 'f_stock'), _amber),
                _mini('Made', _i(l, 'made'), _green),
                _mini('Ready', ready, ready > 0 ? _green : Colors.grey.shade500),
              ]),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 58,
              child: TextField(
                controller: _qty[lineId],
                enabled: ready > 0,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                    hintText: '0', isDense: true, border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 6),
            FilledButton.tonal(
              onPressed: (_saving || ready == 0) ? null : () => _send([l]),
              style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12)),
              child: const Text('Send', style: TextStyle(fontSize: 12)),
            ),
          ]),
          if (shared)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                  '⚠ Shared stock — F_Stock ${_sharedFStock[designId]} covers this design across orders; sending one reduces the others.',
                  style: const TextStyle(fontSize: 10.5, color: _amber)),
            ),
        ],
      ),
    );
  }

  Widget _mini(String label, int n, Color c) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$n',
              style:
                  TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: c)),
          Text(label,
              style: TextStyle(fontSize: 9, color: Colors.grey.shade600)),
        ],
      );

  Widget _fig(String label, int n, Color c) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$n',
              style:
                  TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: c)),
          Text(label, style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
        ],
      );
}
