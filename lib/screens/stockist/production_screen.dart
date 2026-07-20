import 'package:flutter/material.dart';

import '../../services/supabase_data_service.dart';

/// 🏭 **PRODUCTION PLANNING — what the line has to make.**
///
/// Booked orders are the CUSTOMER view: who asked for what. This is the FACTORY view: the same
/// demand rolled up by what actually runs. One design ordered by three customers under three covers
/// is one thing to fire.
///
/// 🔑 **THE TICK IS THE DECISION.** Picking an order on the left only brings its designs onto the
/// page. Ticking a customer's line inside a quantity is what commits it to production; anything
/// left unticked stays **pending** on that order and comes back next time.
///
/// ⚠️ **Godown stock is INFORMATION, never a reservation, and never netted.** A booked order does
/// not touch stock — if he takes an order ten days from now those boxes had to stay free to sell
/// for ten days. Free and total sit side by side; he does his own arithmetic and types what to run.
/// (docs/PRODUCTION_PLANNING_PLAN.md)
class ProductionScreen extends StatefulWidget {
  const ProductionScreen({super.key});

  @override
  State<ProductionScreen> createState() => _ProductionScreenState();
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

class _ProductionScreenState extends State<ProductionScreen> {
  final _data = SupabaseDataService();

  bool _loading = true, _saving = false;
  DateTime? _asOf;
  List<Map<String, dynamic>> _rows = [];
  List<Map<String, dynamic>> _orders = [];

  /// Orders whose designs are on the page.
  final Set<String> _picked = {};

  /// 🔑 The booked lines he has committed. `book_order_line_id`.
  final Set<String> _ticked = {};

  /// box_id → boxes he typed. Absent = follow the ticks.
  final Map<String, int> _plan = {};

  String _groupBy = 'punch';
  bool _urgentOnly = false;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final res = await _data.myProductionDemand();
    final orders = await _data.myBookOrders();
    if (!mounted) return;
    setState(() {
      _rows = [
        for (final r in (res['rows'] as List?) ?? const [])
          Map<String, dynamic>.from(r as Map)
      ];
      _orders = orders.where((o) => (o['status'] ?? '') == 'open').toList();
      _asOf = DateTime.tryParse((res['as_of'] ?? '').toString())?.toLocal();
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

  /// Lines of this row that belong to a picked order / to some other order.
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

  int _planOf(Map<String, dynamic> r) =>
      _plan[r['box_id']] ?? _tickedQty(r);

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

  void _togglePicked(String id, bool on) {
    setState(() {
      if (on) {
        _picked.add(id);
        // Picking an order ticks its lines by default — doing nothing is the common case.
        for (final r in _rows) {
          for (final l in _linesOf(r)) {
            if (l['order_id'] == id && _free(l) > 0) _ticked.add(l['line_id']);
          }
        }
      } else {
        _picked.remove(id);
        for (final r in _rows) {
          for (final l in _linesOf(r)) {
            if (l['order_id'] == id) _ticked.remove(l['line_id']);
          }
        }
      }
      _plan.clear(); // the plan follows the ticks again
    });
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
              // ✅ tick all / none — several parties on one design is normal
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
            // 🔑 what has ALREADY been made for this customer on this design
            if (made > 0) 'made $made',
            if (planned > 0) 'planned $planned',
          ].join('  ·  '),
          style: TextStyle(
              fontSize: 10.5,
              color: made > 0 ? _green : Colors.grey.shade600)),
    );
  }

  // ── take into production ────────────────────────────────────────────────────────────────────
  Future<void> _take() async {
    final rows = _visible;
    final boxes = <Map<String, dynamic>>[];
    final demand = <Map<String, dynamic>>[];
    for (final r in rows) {
      final p = _planOf(r);
      if (p > 0) boxes.add({'box_id': r['box_id'], 'target_boxes': p});
      for (final l in _linesOf(r)) {
        if (_ticked.contains(l['line_id']) && _free(l) > 0) {
          demand.add({'book_order_line_id': l['line_id'], 'planned_boxes': _free(l)});
        }
      }
    }
    if (demand.isEmpty) {
      _snack('Tick at least one customer line — the run has to know who it is for.',
          error: true);
      return;
    }

    // ⚠️ A part-pending order is legitimate, but a MISSED tick looks identical to a deliberate one.
    // Name the orders that will keep something pending before he commits, and let him go back.
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

    final nameCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Take into production'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: nameCtl,
            autofocus: true,
            decoration: const InputDecoration(
                labelText: 'Name this run',
                hintText: 'e.g. Kiln Monday — sandstone punch'),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
                '${boxes.length} design(s) · '
                '${boxes.fold<int>(0, (s, b) => s + (b['target_boxes'] as int))} boxes · '
                '${demand.length} customer line(s)',
                style: const TextStyle(fontSize: 12.5)),
          ),
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
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Go back')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _purple),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Take into production')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _saving = true);
    try {
      final res = await _data.productionTakeIntoRun(
          name: nameCtl.text.trim(), boxes: boxes, demand: demand);
      if (!mounted) return;
      _snack('${res['name']} — ${res['boxes']} boxes for ${res['orders']} order(s).');
      _ticked.clear();
      _plan.clear();
      _picked.clear();
      await _load();
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      _snack('$e', error: true);
    }
    if (mounted) setState(() => _saving = false);
  }

  // ── build ───────────────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final rows = _visible;
    final boxes = rows.fold<int>(0, (s, r) => s + _planOf(r));
    final cover = rows.fold<int>(0, (s, r) => s + _tickedQty(r));
    final pieces = rows.fold<int>(
        0, (s, r) => s + _planOf(r) * _i(r, 'pieces'));

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: const Text('Production planning'),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh), tooltip: 'Refresh', onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(builder: (_, c) {
              final wide = c.maxWidth >= 900;
              final picker = _orderPicker();
              final plan = _planPane(rows, boxes, cover, pieces);
              return wide
                  ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      SizedBox(width: 290, child: picker),
                      const VerticalDivider(width: 1),
                      Expanded(child: plan),
                    ])
                  : ListView(children: [SizedBox(height: 240, child: picker), plan]);
            }),
    );
  }

  Widget _orderPicker() => Container(
        color: Colors.white,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(children: [
              const Text('Booked orders',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
              const Spacer(),
              Text('${_picked.length} picked',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: _orders.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('No open booked orders.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey, fontSize: 12.5)),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: _orders.length,
                    itemBuilder: (_, i) {
                      final o = _orders[i];
                      final id = (o['id'] ?? '').toString();
                      final on = _picked.contains(id);
                      final who =
                          (o['customer_name'] ?? '').toString().trim().isNotEmpty
                              ? (o['customer_name'] ?? '').toString()
                              : (o['customer_hint'] ?? o['token']).toString();
                      return InkWell(
                        onTap: () => _togglePicked(id, !on),
                        borderRadius: BorderRadius.circular(9),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 4),
                          padding: const EdgeInsets.fromLTRB(8, 8, 10, 8),
                          decoration: BoxDecoration(
                            color: on ? const Color(0xFFE7EEF4) : null,
                            border: Border.all(
                                color: on ? _navy : Colors.transparent),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Row(children: [
                            Checkbox(
                              value: on,
                              visualDensity: VisualDensity.compact,
                              activeColor: _navy,
                              onChanged: (v) => _togglePicked(id, v == true),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(children: [
                                    if (o['urgent'] == true)
                                      const Padding(
                                        padding: EdgeInsets.only(right: 4),
                                        child: Icon(Icons.star,
                                            size: 13, color: Colors.amber),
                                      ),
                                    Expanded(
                                      child: Text(who,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 12.5)),
                                    ),
                                  ]),
                                  Text(
                                      '${o['customer_hint']} · ${o['token']}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 10.5,
                                          color: Colors.grey.shade600)),
                                ],
                              ),
                            ),
                            Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text('${_i(o, 'remaining_boxes')}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                          color: _purple)),
                                  Text('boxes',
                                      style: TextStyle(
                                          fontSize: 9,
                                          color: Colors.grey.shade500)),
                                ]),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
        ]),
      );

  Widget _planPane(List<Map<String, dynamic>> rows, int boxes, int cover, int pieces) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
                            ? 'Pick a booked order on the left to plan it.'
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
        if (_picked.isNotEmpty) _actionBar(rows, boxes),
      ]);

  Widget _partyBar() {
    final names = <String>{};
    final notes = <String>[];
    for (final o in _orders) {
      if (!_picked.contains((o['id'] ?? '').toString())) continue;
      final who = (o['customer_name'] ?? '').toString().trim();
      names.add(who.isEmpty ? (o['customer_hint'] ?? '').toString() : who);
      notes.add('${o['customer_hint']} (${o['token']})');
    }
    return Container(
      width: double.infinity,
      color: const Color(0xFFE7EEF4),
      padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('PLANNING FOR',
            style: TextStyle(
                fontSize: 10,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w800,
                color: _navy)),
        const SizedBox(height: 2),
        Text(names.isEmpty ? 'Pick a booked order to begin' : names.join('  ·  '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: names.isEmpty ? 13.5 : 16.5,
                fontWeight: names.isEmpty ? FontWeight.w600 : FontWeight.w800,
                color: names.isEmpty ? Colors.grey.shade600 : Colors.black87)),
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
              for (final d in _dims) ...[
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(d.label, style: const TextStyle(fontSize: 11.5)),
                    selected: _groupBy == d.key,
                    visualDensity: VisualDensity.compact,
                    selectedColor: const Color(0xFFF3E8F8),
                    onSelected: (_) => setState(() => _groupBy = d.key),
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

  Widget _row(Map<String, dynamic> r) {
    final mine = _mine(r), others = _others(r);
    final mineOn = mine.where((l) => _ticked.contains(l['line_id']));
    final mineOnQ = mineOn.fold<int>(0, (s, l) => s + _free(l));
    final mineAllQ = mine.fold<int>(0, (s, l) => s + _free(l));
    final othOn = others.where((l) => _ticked.contains(l['line_id']));
    final othOnQ = othOn.fold<int>(0, (s, l) => s + _free(l));
    final othAllQ = others.fold<int>(0, (s, l) => s + _free(l));
    final made = _i(r, 'produced_boxes');
    final p = _i(r, 'p_stock'), f = _i(r, 'f_stock');

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(children: [
          Row(children: [
            if (r['urgent'] == true)
              const Padding(
                padding: EdgeInsets.only(right: 5),
                child: Icon(Icons.star, size: 17, color: Colors.amber),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${r['cover_word']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 13.5)),
                  Text(
                      '${r['brand']}  ·  ${r['surface']}  ·  ${r['size']}'
                      '${(r['tile_type'] ?? '').toString().isEmpty ? '' : '  ·  ${r['tile_type']}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                  // 🔑 what has ALREADY been produced against these orders, so the godown figure
                  // beside it is not a mystery.
                  if (made > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('✓ $made already made for these orders',
                          style: const TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: _green)),
                    ),
                ],
              ),
            ),
            // free / total, never netted against the demand
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                  color: p != f ? const Color(0xFFFBEFDC) : const Color(0xFFF1F5F8),
                  border: Border.all(
                      color: p != f ? _amber : Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8)),
              child: Column(children: [
                Text('$f',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13, color: _green)),
                Text('free of $p',
                    style: TextStyle(fontSize: 8.5, color: Colors.grey.shade600)),
              ]),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            _qty('Ticked', mineOnQ, mineAllQ, _green,
                () => _openTickList(r, true)),
            const SizedBox(width: 14),
            SizedBox(
              width: 108,
              child: TextFormField(
                key: ValueKey('plan-${r['box_id']}-${_tickedQty(r)}'),
                initialValue: '${_planOf(r)}',
                keyboardType: TextInputType.number,
                enabled: !_saving,
                decoration: const InputDecoration(
                  labelText: 'Make',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 15, color: _purple),
                onChanged: (v) => setState(() =>
                    _plan[r['box_id']] = int.tryParse(v.trim()) ?? 0),
              ),
            ),
            if (_planOf(r) != _tickedQty(r)) ...[
              const SizedBox(width: 6),
              Text(
                  '${_planOf(r) > _tickedQty(r) ? '+' : ''}${_planOf(r) - _tickedQty(r)}',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: _planOf(r) > _tickedQty(r) ? _green : _amber)),
            ],
            const Spacer(),
            if (othAllQ > 0)
              _qty('Also wanted', othOnQ, othAllQ, Colors.grey.shade700,
                  () => _openTickList(r, false)),
          ]),
        ]),
      ),
    );
  }

  Widget _qty(String label, int on, int all, Color c, VoidCallback tap) => InkWell(
        onTap: tap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: TextStyle(fontSize: 9.5, color: Colors.grey.shade600)),
            Row(children: [
              Text('$on',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      color: on == all ? c : _amber)),
              if (on != all)
                Text(' of $all',
                    style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: _amber)),
              const SizedBox(width: 2),
              Icon(Icons.arrow_drop_down, size: 17, color: Colors.grey.shade500),
            ]),
          ]),
        ),
      );

  Widget _actionBar(List<Map<String, dynamic>> rows, int boxes) {
    // what the button will do, before he presses it
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
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _purple),
            onPressed: _saving || boxes == 0 ? null : _take,
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
