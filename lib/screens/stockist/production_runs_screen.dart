import 'package:flutter/material.dart';

import '../../services/supabase_data_service.dart';

/// 🏭 **RUNS & HISTORY.**
///
/// *Runs* — what has been taken into production and what has actually come off the line. Declaring
/// output here is the moment material becomes **stock**.
///
/// *History* — 📜 **which design went into production for which buyer, and when.** The question he
/// named at the very start of the whole feature.
///
/// 🔑 Output settles the lines **ticked into this run first** (⭐urgent, then oldest), because the
/// tick was his decision about who the run was for. Surplus then goes to other open demand for the
/// same cover, and only what is left lands in free stock.
/// 🚫 **Standard is never allocated** — planning is premium; standard is a by-product.
/// (docs/PRODUCTION_PLANNING_PLAN.md)
class ProductionRunsScreen extends StatefulWidget {
  const ProductionRunsScreen({super.key});

  @override
  State<ProductionRunsScreen> createState() => _ProductionRunsScreenState();
}

const _navy = Color(0xFF1B4F72);
const _purple = Color(0xFF6A1B9A);
const _green = Color(0xFF2E7D32);
const _amber = Color(0xFFA96500);

class _ProductionRunsScreenState extends State<ProductionRunsScreen>
    with SingleTickerProviderStateMixin {
  final _data = SupabaseDataService();
  late final TabController _tabs = TabController(length: 2, vsync: this);

  bool _loading = true;
  List<Map<String, dynamic>> _runs = [];
  List<Map<String, dynamic>> _history = [];
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final runs = await _data.myProductionRuns();
    final hist = await _data.myProductionHistory();
    if (!mounted) return;
    setState(() {
      _runs = runs;
      _history = hist;
      _loading = false;
    });
  }

  void _snack(String m, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(m), backgroundColor: error ? Colors.red : _green));
  }

  int _i(Map m, String k) => (m[k] as num?)?.toInt() ?? 0;

  String _date(String? iso) {
    final d = DateTime.tryParse(iso ?? '')?.toLocal();
    if (d == null) return '';
    const mo = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day} ${mo[d.month - 1]}';
  }

  // ── declare output ──────────────────────────────────────────────────────────────────────────
  Future<void> _declare(Map<String, dynamic> run, Map<String, dynamic> b) async {
    final target = _i(b, 'target'), made = _i(b, 'made');
    final ctl = TextEditingController(
        text: '${(target - made).clamp(0, 1 << 30)}');
    var quality = 'Premium';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
            title: const Text('Material came off the line'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${b['cover_word']}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 14)),
                  Text('${b['brand']} · ${b['surface']} · ${b['size']}',
                      style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
                  const SizedBox(height: 2),
                  Text('planned $target · made $made so far',
                      style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
                ]),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: ctl,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Boxes made', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: quality,
                decoration: const InputDecoration(
                    labelText: 'Grade', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'Premium', child: Text('Premium')),
                  DropdownMenuItem(value: 'Standard', child: Text('Standard — by-product')),
                ],
                onChanged: (v) => setD(() => quality = v ?? 'Premium'),
              ),
              const SizedBox(height: 8),
              Text(
                  quality == 'Premium'
                      ? 'Premium settles this run\'s customers first, then any other open order for this cover.'
                      : 'Standard is a by-product — it goes to free stock and settles nobody\'s order.',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: _green),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Add to stock')),
            ],
          )),
    );
    if (ok != true) return;
    final n = int.tryParse(ctl.text.trim()) ?? 0;
    if (n <= 0) {
      _snack('How many boxes came off the line?', error: true);
      return;
    }
    try {
      final res = await _data.productionDeclareOutput(
          runId: (run['id'] ?? '').toString(),
          boxId: (b['box_id'] ?? '').toString(),
          boxes: n,
          quality: quality);
      await _load();
      final parts = <String>[
        if (_i(res, 'to_this_run') > 0) '${res['to_this_run']} to this run',
        if (_i(res, 'to_other_orders') > 0) '${res['to_other_orders']} to other orders',
        if (_i(res, 'to_free_stock') > 0) '${res['to_free_stock']} to free stock',
      ];
      _snack('$n boxes added — ${parts.join(', ')}.'
          '${_i(res, 'orders_closed') > 0 ? '  ${res['orders_closed']} order(s) closed.' : ''}');
    } catch (e) {
      _snack('$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: const Text('Production'),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh), tooltip: 'Refresh', onPressed: _load),
        ],
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: const [Tab(text: 'RUNS'), Tab(text: 'HISTORY')],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabs, children: [_runsTab(), _historyTab()]),
    );
  }

  Widget _runsTab() {
    if (_runs.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text(
              'No production runs yet. Plan one from the Production planning screen.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey)),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 24),
      itemCount: _runs.length,
      itemBuilder: (_, i) => _runCard(_runs[i]),
    );
  }

  Widget _runCard(Map<String, dynamic> r) {
    final boxes = [
      for (final b in (r['boxes'] as List?) ?? const [])
        Map<String, dynamic>.from(b as Map)
    ];
    final target = _i(r, 'target_boxes'), made = _i(r, 'made_boxes');
    final customers =
        [for (final c in (r['customers'] as List?) ?? const []) c.toString()];
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('${r['name']}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 14.5)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                  color: made >= target
                      ? const Color(0xFFE6F2E7)
                      : const Color(0xFFF3E8F8),
                  borderRadius: BorderRadius.circular(20)),
              child: Text(made >= target ? 'complete' : '${r['status']}',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: made >= target ? _green : _purple)),
            ),
          ]),
          Text(
              [
                _date((r['created_at'] ?? '').toString()),
                if (customers.isNotEmpty) customers.join(', '),
                if ((r['note'] ?? '').toString().trim().isNotEmpty) '${r['note']}',
              ].join('  ·  '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
          const SizedBox(height: 8),
          Row(children: [
            _fig('Planned', target, Colors.grey.shade700),
            const SizedBox(width: 18),
            _fig('Made', made, _green),
            const SizedBox(width: 18),
            _fig('Left', (target - made).clamp(0, 1 << 30), _amber),
          ]),
          const Divider(height: 18),
          for (final b in boxes) _boxRow(r, b),
        ]),
      ),
    );
  }

  Widget _boxRow(Map<String, dynamic> run, Map<String, dynamic> b) {
    final t = _i(b, 'target'), m = _i(b, 'made');
    final done = m >= t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${b['cover_word']}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 12.5)),
            Text('${b['brand']} · ${b['surface']} · ${b['size']}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600)),
          ]),
        ),
        Text('$m / $t',
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: done ? _green : _amber)),
        const SizedBox(width: 8),
        FilledButton.tonal(
          style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12)),
          onPressed: () => _declare(run, b),
          child: Text(done ? 'Add more' : 'Made', style: const TextStyle(fontSize: 12)),
        ),
      ]),
    );
  }

  Widget _fig(String label, int n, Color c) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$n',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: c)),
        Text(label, style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
      ]);

  // ── 📜 which design, for which buyer, when ──────────────────────────────────────────────────
  Widget _historyTab() {
    final q = _q.trim().toLowerCase();
    final rows = _history.where((h) {
      if (q.isEmpty) return true;
      return [h['customer'], h['design_name'], h['brand'], h['run_name'], h['order_token']]
          .map((x) => (x ?? '').toString().toLowerCase())
          .any((s) => s.contains(q));
    }).toList();

    return Column(children: [
      Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: TextField(
          onChanged: (v) => setState(() => _q = v),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 20),
            hintText: 'Search buyer, design, run…',
            filled: true,
            fillColor: const Color(0xFFF4F6F8),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none),
          ),
        ),
      ),
      Expanded(
        child: rows.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(28),
                  child: Text(
                      'Nothing has gone into production yet.\nOnce it does, this is where you see which design was made for which buyer.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey)),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 24),
                itemCount: rows.length,
                itemBuilder: (_, i) => _histCard(rows[i]),
              ),
      ),
    ]);
  }

  Widget _histCard(Map<String, dynamic> h) {
    final planned = _i(h, 'planned_boxes');
    final ordered = _i(h, 'ordered_boxes');
    final made = _i(h, 'produced_boxes');
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (h['urgent'] == true)
              const Padding(
                padding: EdgeInsets.only(right: 5),
                child: Icon(Icons.star, size: 15, color: Colors.amber),
              ),
            Expanded(
              child: Text('${h['design_name']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 13.5)),
            ),
            Text(_date((h['taken_at'] ?? '').toString()),
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ]),
          Text('${h['brand']} · ${h['surface']} · ${h['size']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          const SizedBox(height: 6),
          // for WHICH BUYER — the whole point of this screen
          Row(children: [
            const Icon(Icons.person_outline, size: 15, color: _navy),
            const SizedBox(width: 5),
            Expanded(
              child: Text('${h['customer']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w700)),
            ),
            Text('${h['order_token']}  ·  ${h['run_name']}',
                style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500)),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            _fig('Ordered', ordered, Colors.grey.shade700),
            const SizedBox(width: 18),
            _fig('Planned', planned, _purple),
            const SizedBox(width: 18),
            _fig('Made', made, _green),
          ]),
        ]),
      ),
    );
  }
}
