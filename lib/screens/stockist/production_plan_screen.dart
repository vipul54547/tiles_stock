import 'package:flutter/material.dart';

import '../../services/supabase_data_service.dart';
import 'production_packing_screen.dart';

/// 📝 **A plan in progress.** Named + dated on the Choose-orders page, carried here to be finished.
/// For now it lives only in memory; sub-step 2 gives it server persistence (a real draft you can
/// close the app and return to) — this shape gains an `id` then, nothing else changes.
class PlanDraft {
  PlanDraft({
    required this.name,
    required this.date,
    required this.pickedIds,
    required this.orders,
  });

  final String name;
  final DateTime date;

  /// The booked orders he chose to plan (`book_orders.id`).
  final Set<String> pickedIds;

  /// The open booked-order metadata (from `my_book_orders`) — for the party bar, the pending
  /// warning and the per-order outcome. The picked SET is fixed here; picking happens one page back.
  final List<Map<String, dynamic>> orders;
}

/// 🏭 **PLAN WHAT TO RUN — the factory view of the orders he picked.**
///
/// The demand rolled up by what actually runs: one design ordered by three customers under three
/// covers is one thing to fire. He picked the orders on the page before; here he ticks who each run
/// is for, sets how many boxes to make, and takes it into production.
///
/// 🔑 **THE TICK IS THE DECISION.** A ticked line commits to production; anything left unticked stays
/// pending on that order and comes back next time. ⚠️ **Godown stock is INFORMATION, never netted** —
/// free and total sit side by side; he does his own arithmetic and types what to run.
/// (docs/PRODUCTION_REDESIGN_PLAN.md · docs/PRODUCTION_PLANNING_PLAN.md)
class ProductionPlanScreen extends StatefulWidget {
  const ProductionPlanScreen({super.key, required this.draft});

  final PlanDraft draft;

  @override
  State<ProductionPlanScreen> createState() => _ProductionPlanScreenState();
}

const _navy = Color(0xFF1B4F72);
const _purple = Color(0xFF6A1B9A);
const _green = Color(0xFF2E7D32);
const _amber = Color(0xFFA96500);

const _dims = <({String key, String label})>[
  (key: 'punch', label: 'Punch'),
  (key: 'surface', label: 'Surface'),
  (key: 'tile_type', label: 'Body'),
  (key: 'series', label: 'Series'),
  (key: 'size', label: 'Size'),
  (key: 'brand', label: 'Brand'),
];

class _ProductionPlanScreenState extends State<ProductionPlanScreen> {
  final _data = SupabaseDataService();

  bool _loading = true, _saving = false;
  DateTime? _asOf;
  List<Map<String, dynamic>> _rows = [];

  /// The orders being planned — fixed, chosen one page back.
  Set<String> get _picked => widget.draft.pickedIds;
  List<Map<String, dynamic>> get _orders => widget.draft.orders;

  /// 🔑 The booked lines he has committed. `book_order_line_id`.
  final Set<String> _ticked = {};

  /// box_id → boxes he typed. Absent = follow the ticks.
  final Map<String, int> _plan = {};

  String _groupBy = 'punch';
  bool _urgentOnly = false;
  String _q = '';

  /// The View-plan review toggles between grouping by ORDER (default) and by DESIGN.
  bool _reviewByDesign = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final res = await _data.myProductionDemand();
    if (!mounted) return;
    setState(() {
      _rows = [
        for (final r in (res['rows'] as List?) ?? const [])
          Map<String, dynamic>.from(r as Map)
      ];
      _asOf = DateTime.tryParse((res['as_of'] ?? '').toString())?.toLocal();
      // Picking an order ticks its lines by default — doing nothing is the common case.
      _ticked.clear();
      for (final r in _rows) {
        for (final l in _linesOf(r)) {
          if (_picked.contains(l['order_id']) && _free(l) > 0) {
            _ticked.add(l['line_id']);
          }
        }
      }
      _plan.clear();
      _loading = false;
    });
  }

  void _snack(String m, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(m), backgroundColor: error ? Colors.red : _green));
  }

  int _i(Map m, String k) => (m[k] as num?)?.toInt() ?? 0;
  double _d(Map m, String k) => (m[k] as num?)?.toDouble() ?? 0;

  List<Map<String, dynamic>> _linesOf(Map<String, dynamic> r) => [
        for (final l in (r['lines'] as List?) ?? const [])
          Map<String, dynamic>.from(l as Map)
      ];

  List<Map<String, dynamic>> _mine(Map<String, dynamic> r) =>
      _linesOf(r).where((l) => _picked.contains(l['order_id'])).toList();
  List<Map<String, dynamic>> _others(Map<String, dynamic> r) =>
      _linesOf(r).where((l) => !_picked.contains(l['order_id'])).toList();

  /// Still bookable on a line: ordered − made − already planned into an open run.
  int _free(Map l) =>
      (_i(l, 'remaining') - _i(l, 'planned')).clamp(0, 1 << 30);

  int _tickedQty(Map<String, dynamic> r) => _linesOf(r)
      .where((l) => _ticked.contains(l['line_id']))
      .fold(0, (s, l) => s + _free(l));

  int _planOf(Map<String, dynamic> r) => _plan[r['box_id']] ?? _tickedQty(r);

  String _val(Map<String, dynamic> r, String key) {
    final v = (r[key] ?? '').toString().trim();
    if (v.isNotEmpty) return v;
    return switch (key) {
      'punch' => 'No punch',
      'series' => 'No series',
      'tile_type' => 'Body not set',
      _ => '—',
    };
  }

  /// Only designs that are in the PICKED orders. A design wanted solely by an order he did not pick
  /// is not on this plan at all — the "also wanted" column annotates a row, it never adds one.
  List<Map<String, dynamic>> get _visible {
    final q = _q.trim().toLowerCase();
    return _rows.where((r) {
      if (_mine(r).isEmpty) return false;
      if (_urgentOnly && r['urgent'] != true) return false;
      if (q.isNotEmpty) {
        final hay = [
          r['print_name'], r['cover_word'], r['brand'], r['surface'],
          for (final l in _linesOf(r)) l['customer'],
        ].map((x) => (x ?? '').toString().toLowerCase()).join(' ');
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();
  }

  // ── the tick list ───────────────────────────────────────────────────────────────────────────
  Future<void> _openTickList(Map<String, dynamic> r, bool mine) async {
    final lines = mine ? _mine(r) : _others(r);
    if (lines.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final on = lines.where((l) => _ticked.contains(l['line_id']));
        final onQ = on.fold<int>(0, (s, l) => s + _free(l));
        final allQ = lines.fold<int>(0, (s, l) => s + _free(l));
        final allOn = on.length == lines.length;
        return AlertDialog(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(mine ? 'Tick what goes into production' : 'Also wanted — tick to add it in',
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text('${r['cover_word']} · ${r['brand']}',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
            ],
          ),
          contentPadding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setD(() => setState(() {
                        for (final l in lines) {
                          if (allOn) {
                            _ticked.remove(l['line_id']);
                          } else if (_free(l) > 0) {
                            _ticked.add(l['line_id']);
                          }
                        }
                        _plan.remove(r['box_id']);
                      })),
                  icon: Icon(allOn ? Icons.remove_done : Icons.done_all, size: 17),
                  label: Text(allOn ? 'Untick all' : 'Tick all',
                      style: const TextStyle(fontSize: 12.5)),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final l in lines) _tickRow(l, r, setD),
                  ],
                ),
              ),
              const Divider(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(children: [
                  const Text('Ticked',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5)),
                  const Spacer(),
                  Text('$onQ of $allQ boxes',
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 12.5)),
                ]),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Text(
                    'Unticked lines stay pending on that order and come back next time.',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              ),
            ]),
          ),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
          ],
        );
      }),
    );
    setState(() {});
  }

  Widget _tickRow(Map<String, dynamic> l, Map<String, dynamic> r, StateSetter setD) {
    final free = _free(l);
    final made = _i(l, 'produced');
    final planned = _i(l, 'planned');
    final on = _ticked.contains(l['line_id']);
    return CheckboxListTile(
      value: on,
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      activeColor: _green,
      onChanged: free == 0
          ? null
          : (v) => setD(() => setState(() {
                if (v == true) {
                  _ticked.add(l['line_id']);
                } else {
                  _ticked.remove(l['line_id']);
                }
                _plan.remove(r['box_id']);
              })),
      title: Row(children: [
        if (l['urgent'] == true)
          const Padding(
            padding: EdgeInsets.only(right: 4),
            child: Icon(Icons.star, size: 14, color: Colors.amber),
          ),
        Expanded(
          child: Text('${l['customer']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
        Text('$free',
            style: const TextStyle(
                fontSize: 13.5, fontWeight: FontWeight.w800)),
      ]),
      subtitle: Text(
          [
            '${l['note']}'.trim().isEmpty ? '${l['token']}' : '${l['note']} · ${l['token']}',
            if (made > 0) 'made $made',
            if (planned > 0) 'planned $planned',
          ].join('  ·  '),
          style: TextStyle(
              fontSize: 10.5,
              color: made > 0 ? _green : Colors.grey.shade600)),
    );
  }

  // ── verify → take into production ───────────────────────────────────────────────────────────
  /// What will run: the per-cover Make quantities and the ticked customer lines.
  ({List<Map<String, dynamic>> boxes, List<Map<String, dynamic>> demand}) _collect() {
    final boxes = <Map<String, dynamic>>[];
    final demand = <Map<String, dynamic>>[];
    for (final r in _visible) {
      final p = _planOf(r);
      if (p > 0) boxes.add({'box_id': r['box_id'], 'target_boxes': p});
      for (final l in _linesOf(r)) {
        if (_ticked.contains(l['line_id']) && _free(l) > 0) {
          demand.add({'book_order_line_id': l['line_id'], 'planned_boxes': _free(l)});
        }
      }
    }
    return (boxes: boxes, demand: demand);
  }

  /// 🔒 The safety gate. **Cancel · Verify · Yes** — Verify opens the plan review, Yes commits.
  Future<void> _openVerify() async {
    final c = _collect();
    if (c.demand.isEmpty) {
      _snack('Tick at least one customer line — the run has to know who it is for.',
          error: true);
      return;
    }
    final totalBoxes = c.boxes.fold<int>(0, (s, b) => s + (b['target_boxes'] as int));

    // ⚠️ A part-pending order is legitimate, but a MISSED tick looks identical to a deliberate one.
    final pending = <String, int>{};
    for (final o in _orders) {
      final id = (o['id'] ?? '').toString();
      if (!_picked.contains(id)) continue;
      var left = 0;
      for (final r in _rows) {
        for (final l in _linesOf(r)) {
          if (l['order_id'] == id &&
              _free(l) > 0 &&
              !_ticked.contains(l['line_id'])) {
            left++;
          }
        }
      }
      if (left > 0) pending[(o['customer_name'] ?? o['customer_hint'] ?? o['token']).toString()] = left;
    }

    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Are you sure your plan is verified?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${c.boxes.length} design(s) · $totalBoxes boxes · ${c.demand.length} customer line(s) '
              'will go into a run. Nothing enters stock yet.',
              style: const TextStyle(fontSize: 12.5)),
          const SizedBox(height: 8),
          Text('Not sure? Verify opens the plan so you can check every ticked line first.',
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
          if (pending.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: const Color(0xFFFBEFDC),
                  borderRadius: BorderRadius.circular(8)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('These orders will keep something pending',
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w800, color: _amber)),
                const SizedBox(height: 4),
                for (final e in pending.entries)
                  Text('${e.key} — ${e.value} design(s) not ticked',
                      style: const TextStyle(fontSize: 11.5)),
              ]),
            ),
          ],
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'verify'),
              child: const Text('Verify')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _purple),
              onPressed: () => Navigator.pop(ctx, 'yes'),
              child: const Text('Yes, take in')),
        ],
      ),
    );
    if (choice == 'verify') {
      await _openReview();
    } else if (choice == 'yes') {
      await _commit(c.boxes, c.demand);
    }
  }

  Future<void> _commit(
      List<Map<String, dynamic>> boxes, List<Map<String, dynamic>> demand) async {
    setState(() => _saving = true);
    try {
      final res = await _data.productionTakeIntoRun(
          name: widget.draft.name, boxes: boxes, demand: demand);
      if (!mounted) return;
      // 🔪 Say when an order was SLICED — the remainder is still in Booked orders under the
      // customer's own number, and the part taken now lives under a letter.
      final sliced = (res['slices'] as num?)?.toInt() ?? 0;
      _snack('${res['name']} — ${res['boxes']} boxes for ${res['orders']} order(s).'
          '${sliced > 0 ? '  $sliced order(s) split; the rest stays in Booked orders.' : ''}');
      // ▶ Forward to the packing plan; Choose orders (underneath) reloads via the `true` result.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<bool>(
          builder: (_) => ProductionPackingScreen(
              runId: (res['id'] ?? '').toString(),
              runName: (res['name'] ?? widget.draft.name).toString()),
        ),
        result: true,
      );
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      _snack('$e', error: true);
    }
  }

  // ── 👁 View plan — check the ticked lines, by ORDER or by DESIGN ────────────────────────────
  Future<void> _openReview() async {
    final entries = <({Map<String, dynamic> r, Map<String, dynamic> l})>[];
    for (final r in _rows) {
      for (final l in _linesOf(r)) {
        if (_ticked.contains(l['line_id']) && _free(l) > 0) {
          entries.add((r: r, l: l));
        }
      }
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final total = entries.fold<int>(0, (s, e) => s + _free(e.l));
        Widget body;
        if (entries.isEmpty) {
          body = const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Nothing is ticked yet.', style: TextStyle(color: Colors.grey)));
        } else if (_reviewByDesign) {
          final g = <String, List<({Map<String, dynamic> r, Map<String, dynamic> l})>>{};
          for (final e in entries) {
            g.putIfAbsent((e.r['box_id']).toString(), () => []).add(e);
          }
          body = Column(mainAxisSize: MainAxisSize.min, children: [
            for (final k in g.keys)
              _reviewGroup(
                title: '${g[k]!.first.r['cover_word']}',
                sub: '${g[k]!.first.r['brand']} · ${g[k]!.first.r['surface']} · ${g[k]!.first.r['size']}',
                total: g[k]!.fold<int>(0, (s, e) => s + _free(e.l)),
                lines: [
                  for (final e in g[k]!)
                    (label: '${e.l['customer']}', sub: '${e.l['token']}', qty: _free(e.l))
                ],
              ),
          ]);
        } else {
          final g = <String, List<({Map<String, dynamic> r, Map<String, dynamic> l})>>{};
          for (final e in entries) {
            g.putIfAbsent((e.l['order_id']).toString(), () => []).add(e);
          }
          body = Column(mainAxisSize: MainAxisSize.min, children: [
            for (final k in g.keys)
              _reviewGroup(
                title: '${g[k]!.first.l['customer']}',
                sub: '${g[k]!.first.l['note']} · ${g[k]!.first.l['token']}',
                total: g[k]!.fold<int>(0, (s, e) => s + _free(e.l)),
                lines: [
                  for (final e in g[k]!)
                    (label: '${e.r['cover_word']}', sub: '${e.r['brand']} · ${e.r['surface']}', qty: _free(e.l))
                ],
              ),
          ]);
        }
        return AlertDialog(
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Verify your plan',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text('${entries.length} line(s) ticked · $total boxes',
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
            const SizedBox(height: 8),
            Row(children: [
              const Text('Show ', style: TextStyle(fontSize: 11.5)),
              ChoiceChip(
                  label: const Text('By order'),
                  selected: !_reviewByDesign,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setD(() => _reviewByDesign = false)),
              const SizedBox(width: 6),
              ChoiceChip(
                  label: const Text('By design'),
                  selected: _reviewByDesign,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setD(() => _reviewByDesign = true)),
            ]),
          ]),
          contentPadding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
          content: SizedBox(
              width: 400, child: SingleChildScrollView(child: body)),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
          ],
        );
      }),
    );
  }

  Widget _reviewGroup({
    required String title,
    required String sub,
    required int total,
    required List<({String label, String sub, int qty})> lines,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
                color: const Color(0xFFEDF1F4),
                borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 12.5)),
                      Text(sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10.5, color: Colors.grey.shade600)),
                    ]),
              ),
              Text('$total',
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 14, color: _purple)),
            ]),
          ),
          for (final ln in lines)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
              child: Row(children: [
                Expanded(
                  child: RichText(
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(
                        style: DefaultTextStyle.of(context).style.copyWith(fontSize: 12),
                        children: [
                          TextSpan(text: ln.label),
                          TextSpan(
                              text: '  ${ln.sub}',
                              style: TextStyle(
                                  color: Colors.grey.shade500, fontSize: 10.5)),
                        ]),
                  ),
                ),
                Text('${ln.qty}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 12.5)),
              ]),
            ),
        ]),
      );

  // ── build ───────────────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final rows = _visible;
    final boxes = rows.fold<int>(0, (s, r) => s + _planOf(r));
    final cover = rows.fold<int>(0, (s, r) => s + _tickedQty(r));
    final pieces = rows.fold<int>(0, (s, r) => s + _planOf(r) * _i(r, 'pieces'));

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: const Text('Plan what to run'),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh), tooltip: 'Refresh', onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _partyBar(),
              _totals(rows.length, boxes, cover, pieces),
              _filterBar(),
              const Divider(height: 1),
              Expanded(
                child: rows.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(28),
                          child: Text(
                              _picked.isEmpty
                                  ? 'No orders were carried into this plan.'
                                  : 'No design matches these filters.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.grey)),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 20),
                        children: _groups(rows),
                      ),
              ),
              _actionBar(rows, boxes),
            ]),
    );
  }

  Widget _partyBar() {
    final names = <String>{};
    final notes = <String>[];
    for (final o in _orders) {
      if (!_picked.contains((o['id'] ?? '').toString())) continue;
      final who = (o['customer_name'] ?? '').toString().trim();
      names.add(who.isEmpty ? (o['customer_hint'] ?? '').toString() : who);
      notes.add('${o['customer_hint']} (${o['token']})');
    }
    final d = widget.draft.date;
    final dateStr =
        '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    return Container(
      width: double.infinity,
      color: const Color(0xFFE7EEF4),
      padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(widget.draft.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 16.5, fontWeight: FontWeight.w800, color: _navy)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
                color: const Color(0xFFFBEFDC),
                borderRadius: BorderRadius.circular(20)),
            child: const Text('DRAFT',
                style: TextStyle(
                    fontSize: 9.5, fontWeight: FontWeight.w800, color: _amber)),
          ),
          const SizedBox(width: 8),
          Text(dateStr,
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
        ]),
        const SizedBox(height: 3),
        Text(names.isEmpty ? '—' : names.join('  ·  '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 13.5, fontWeight: FontWeight.w700, color: Colors.black87)),
        if (notes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(notes.join('   ·   '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
          ),
      ]),
    );
  }

  Widget _totals(int n, int boxes, int cover, int pieces) => Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 20, runSpacing: 2, children: [
            _big('$boxes', 'boxes to make', _purple),
            _big('$cover', 'ticked for production', _green),
            _big('$pieces', 'pieces', null),
            _big('$n', n == 1 ? 'design' : 'designs', null),
          ]),
          if (_asOf != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                  'Godown figures as of '
                  '${_asOf!.hour.toString().padLeft(2, '0')}:${_asOf!.minute.toString().padLeft(2, '0')}',
                  style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500)),
            ),
        ]),
      );

  Widget _big(String n, String label, Color? c) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Text(n,
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold, color: c ?? _navy)),
        const SizedBox(width: 4),
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(label,
              style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600)),
        ),
      ]);

  Widget _filterBar() => Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        child: Column(children: [
          TextField(
            onChanged: (v) => setState(() => _q = v),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: 'Search design, brand, customer…',
              filled: true,
              fillColor: const Color(0xFFF4F6F8),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              FilterChip(
                label: const Text('★ Urgent'),
                selected: _urgentOnly,
                visualDensity: VisualDensity.compact,
                labelStyle: const TextStyle(fontSize: 11.5),
                onSelected: (v) => setState(() => _urgentOnly = v),
              ),
              const SizedBox(width: 10),
              Text('Group',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              const SizedBox(width: 6),
              for (final dim in _dims) ...[
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(dim.label, style: const TextStyle(fontSize: 11.5)),
                    selected: _groupBy == dim.key,
                    visualDensity: VisualDensity.compact,
                    selectedColor: const Color(0xFFF3E8F8),
                    onSelected: (_) => setState(() => _groupBy = dim.key),
                  ),
                ),
              ],
            ]),
          ),
        ]),
      );

  List<Widget> _groups(List<Map<String, dynamic>> rows) {
    final g = <String, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      g.putIfAbsent(_val(r, _groupBy), () => []).add(r);
    }
    final keys = g.keys.toList()..sort();
    return [
      for (final k in keys) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
          child: Row(children: [
            Expanded(
              child: Text(k.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .5,
                      color: _navy)),
            ),
            Text(
                '${g[k]!.fold<int>(0, (s, r) => s + _planOf(r))} boxes  ·  '
                '${g[k]!.fold<double>(0, (s, r) => s + _d(r, 'remaining_sqft')).toStringAsFixed(0)} sq ft',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade600)),
          ]),
        ),
        for (final r in g[k]!) _row(r),
      ]
    ];
  }

  /// One design row, laid out as COLUMNS — Design · Ticked · Make · Also wanted · Godown — so each
  /// field sits in its own labelled place instead of crowding onto the name line. Stacks on narrow.
  Widget _row(Map<String, dynamic> r) {
    final mine = _mine(r), others = _others(r);
    final mineOnQ =
        mine.where((l) => _ticked.contains(l['line_id'])).fold<int>(0, (s, l) => s + _free(l));
    final mineAllQ = mine.fold<int>(0, (s, l) => s + _free(l));
    final othOnQ =
        others.where((l) => _ticked.contains(l['line_id'])).fold<int>(0, (s, l) => s + _free(l));
    final othAllQ = others.fold<int>(0, (s, l) => s + _free(l));
    final made = _i(r, 'produced_boxes');
    final p = _i(r, 'p_stock'), f = _i(r, 'f_stock');

    final name = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          if (r['urgent'] == true)
            const Padding(
              padding: EdgeInsets.only(right: 5),
              child: Icon(Icons.star, size: 16, color: Colors.amber),
            ),
          Expanded(
            child: Text('${r['cover_word']}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
          ),
        ]),
        Text(
            '${r['brand']}  ·  ${r['surface']}  ·  ${r['size']}'
            '${(r['tile_type'] ?? '').toString().isEmpty ? '' : '  ·  ${r['tile_type']}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        if (made > 0)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('✓ $made already made for these orders',
                style: const TextStyle(
                    fontSize: 10.5, fontWeight: FontWeight.w700, color: _green)),
          ),
      ],
    );

    final ticked =
        _cell('Ticked', _tickButton(mineOnQ, mineAllQ, _green, () => _openTickList(r, true)));
    final make = _cell('Make', _makeCell(r));
    final also = _cell(
        'Also wanted',
        othAllQ > 0
            ? _tickButton(othOnQ, othAllQ, Colors.grey.shade700, () => _openTickList(r, false))
            : const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('—', style: TextStyle(color: Colors.grey))));
    final godown = _cell('Godown', _godownBox(p, f));

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: LayoutBuilder(builder: (_, c) {
          if (c.maxWidth >= 620) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: name),
              const SizedBox(width: 10),
              SizedBox(width: 96, child: ticked),
              const SizedBox(width: 8),
              SizedBox(width: 118, child: make),
              const SizedBox(width: 8),
              SizedBox(width: 96, child: also),
              const SizedBox(width: 8),
              SizedBox(width: 80, child: godown),
            ]);
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            name,
            const SizedBox(height: 8),
            Wrap(spacing: 14, runSpacing: 8, children: [
              SizedBox(width: 92, child: ticked),
              SizedBox(width: 110, child: make),
              SizedBox(width: 92, child: also),
              SizedBox(width: 80, child: godown),
            ]),
          ]);
        }),
      ),
    );
  }

  /// A labelled column cell — the uppercase label sits above its control.
  Widget _cell(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: TextStyle(
                  fontSize: 9,
                  letterSpacing: .5,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey.shade500)),
          const SizedBox(height: 3),
          child,
        ],
      );

  /// The tappable Ticked / Also-wanted control — opens the tick list.
  Widget _tickButton(int on, int all, Color c, VoidCallback tap) => InkWell(
        onTap: tap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
              color: on == all ? const Color(0xFFE7F3E8) : const Color(0xFFFBEFDC),
              borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            Text('$on',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    color: on == all ? c : _amber)),
            if (on != all)
              Text(' of $all',
                  style: const TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w700, color: _amber)),
            const Spacer(),
            Icon(Icons.arrow_drop_down, size: 18, color: Colors.grey.shade500),
          ]),
        ),
      );

  /// The Make quantity — the per-cover boxes to run, with the "+N vs ticked" delta under it.
  Widget _makeCell(Map<String, dynamic> r) {
    final d = _planOf(r) - _tickedQty(r);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextFormField(
        key: ValueKey('plan-${r['box_id']}-${_tickedQty(r)}'),
        initialValue: '${_planOf(r)}',
        keyboardType: TextInputType.number,
        enabled: !_saving,
        textAlign: TextAlign.right,
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          border: OutlineInputBorder(),
        ),
        style: const TextStyle(
            fontWeight: FontWeight.w800, fontSize: 15, color: _purple),
        onChanged: (v) =>
            setState(() => _plan[r['box_id']] = int.tryParse(v.trim()) ?? 0),
      ),
      if (d != 0)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text('${d > 0 ? '+' : ''}$d vs ticked',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: d > 0 ? _green : _amber)),
        ),
    ]);
  }

  /// Godown free / total — information only, never netted against demand.
  Widget _godownBox(int p, int f) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
            color: p != f ? const Color(0xFFFBEFDC) : const Color(0xFFF1F5F8),
            border: Border.all(color: p != f ? _amber : Colors.grey.shade300),
            borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('$f',
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 14, color: _green)),
          Text('free of $p',
              style: TextStyle(fontSize: 8.5, color: Colors.grey.shade600)),
        ]),
      );

  Widget _actionBar(List<Map<String, dynamic>> rows, int boxes) {
    final outcome = <Widget>[];
    for (final o in _orders) {
      final id = (o['id'] ?? '').toString();
      if (!_picked.contains(id)) continue;
      var total = 0, left = 0;
      for (final r in _rows) {
        for (final l in _linesOf(r)) {
          if (l['order_id'] != id || _free(l) == 0) continue;
          total++;
          if (!_ticked.contains(l['line_id'])) left++;
        }
      }
      if (total == 0) continue;
      final who = (o['customer_name'] ?? '').toString().trim().isNotEmpty
          ? (o['customer_name'] ?? '').toString()
          : (o['customer_hint'] ?? o['token']).toString();
      outcome.add(Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          Expanded(
            child: Text('$who — ${o['customer_hint']}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
                color: left == 0 ? const Color(0xFFF3E8F8) : const Color(0xFFFBEFDC),
                borderRadius: BorderRadius.circular(20)),
            child: Text(
                left == 0 ? 'goes to production' : '$left design pending',
                style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    color: left == 0 ? _purple : _amber)),
          ),
        ]),
      ));
    }
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ...outcome,
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: Text('${rows.length} design(s) · $boxes boxes',
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700)),
          ),
          OutlinedButton.icon(
            onPressed: boxes == 0 ? null : _openReview,
            icon: const Icon(Icons.visibility_outlined, size: 18),
            label: const Text('View plan'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _purple),
            onPressed: _saving || boxes == 0 ? null : _openVerify,
            icon: _saving
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.precision_manufacturing_outlined, size: 18),
            label: const Text('Take into production'),
          ),
        ]),
      ]),
    );
  }
}
