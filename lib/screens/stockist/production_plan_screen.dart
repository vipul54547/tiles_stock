import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/supabase_data_service.dart';
import 'production_packing_screen.dart';

/// 📝 **A plan in progress.** Named + dated on the Choose-orders page, and persisted server-side as a
/// draft (`production_plans`) so he can close the app and come back to it. Reopening carries the
/// saved ticks + makes in [savedLines] / [savedMakes]; a fresh draft leaves them null and the Plan
/// page seeds the defaults.
class PlanDraft {
  PlanDraft({
    required this.id,
    required this.name,
    required this.date,
    required this.pickedIds,
    required this.orders,
    this.savedLines,
    this.savedMakes,
  });

  /// `production_plans.id` — the draft's server home.
  final String id;
  final String name;
  final DateTime date;

  /// The booked orders he chose to plan (`book_orders.id`).
  final Set<String> pickedIds;

  /// The open booked-order metadata (from `my_book_orders`) — for the party bar, the pending
  /// warning and the per-order outcome. The picked SET is fixed here; picking happens one page back.
  final List<Map<String, dynamic>> orders;

  /// Reopen only — the saved ticks `[{line_id, planned_boxes}]` and per-cover make overrides
  /// `[{box_id, target_boxes}]`. Null on a fresh draft (then the Plan page defaults everything).
  final List<Map<String, dynamic>>? savedLines;
  final List<Map<String, dynamic>>? savedMakes;
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

  /// 🏭 Every cover he can run, for "Add design" (produce for stock / the remaining,
  /// picked by what's on the line). Fetched lazily, once. (stock production)
  List<Map<String, dynamic>>? _addable;

  /// The orders being planned — fixed, chosen one page back.
  Set<String> get _picked => widget.draft.pickedIds;
  List<Map<String, dynamic>> get _orders => widget.draft.orders;

  /// 🔑 The booked lines he has committed → **how many boxes of each** goes into production. A line
  /// may go in PART (300 of 500 now, the rest stays pending). Absent from the map = not ticked.
  /// `book_order_line_id` → planned boxes.
  final Map<String, int> _lineQty = {};

  bool _isTicked(dynamic lineId) => _lineQty.containsKey('$lineId');

  /// The effective ticked quantity of a line — clamped to what is currently free (demand may have
  /// shrunk since it was ticked). 0 when the line is not ticked.
  int _tq(Map l) {
    final q = _lineQty['${l['line_id']}'];
    return q == null ? 0 : q.clamp(0, _free(l));
  }

  /// box_id → boxes he typed. Absent = follow the ticks.
  final Map<String, int> _plan = {};

  String _groupBy = 'punch';
  bool _urgentOnly = false;
  String _q = '';

  /// The View-plan review toggles between grouping by ORDER (default) and by DESIGN.
  bool _reviewByDesign = false;

  /// Autosave the draft a beat after the last change, and a flag so a taken draft is not re-saved.
  Timer? _saveTimer;
  bool _taken = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    // A clean save on the way out, unless the draft was just taken into production (then it's gone).
    if (!_taken) _saveDraft();
    super.dispose();
  }

  /// 🏭 Add a design to run for STOCK (or the remaining) — pick a cover the run
  /// isn't already making and drop it in with a Make quantity. It carries no
  /// order, so its output goes to free stock. Session-only (not saved in the
  /// draft) — add it and take the run in.
  Future<void> _addDesign() async {
    _addable ??= await _data.myAddableBoxes();
    if (!mounted) return;
    final taken = _rows.map((r) => '${r['box_id']}').toSet();
    final pool = _addable!
        .where((b) => !taken.contains('${b['box_id']}'))
        .toList();
    if (pool.isEmpty) {
      _snack('Every design is already on the plan.');
      return;
    }
    final chosen = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        String q = '';
        return StatefulBuilder(builder: (ctx, setSheet) {
          final ql = q.trim().toLowerCase();
          final res = ql.isEmpty
              ? pool
              : pool.where((b) => [
                    b['cover_word'], b['print_name'], b['brand'],
                    b['surface'], b['size']
                  ].map((x) => '$x'.toLowerCase()).any((s) => s.contains(ql)))
                  .toList();
          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.75,
            child: Column(children: [
              const SizedBox(height: 12),
              const Text('Add a design to run',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                      hintText: 'Search design / brand / surface',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder()),
                  onChanged: (v) => setSheet(() => q = v),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: res.length,
                  itemBuilder: (_, i) {
                    final b = res[i];
                    final f = (b['f_stock'] as num?)?.toInt() ?? 0;
                    return ListTile(
                      title: Text('${b['cover_word']}',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text([
                        b['brand'], b['surface'], b['size'],
                        'godown $f'
                      ].where((x) => '$x'.trim().isNotEmpty).join('  ·  ')),
                      onTap: () => Navigator.pop(ctx, b),
                    );
                  },
                ),
              ),
            ]),
          );
        });
      },
    );
    if (chosen != null) {
      // Mark it so _visible keeps it — a stock design has no order line behind it.
      chosen['_added'] = true;
      setState(() => _rows.insert(0, chosen));
      _snack('${chosen['cover_word']} added — set its Make quantity.');
    }
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
      _lineQty.clear();
      _plan.clear();

      final saved = widget.draft.savedLines;
      if (saved != null) {
        // ♻️ Reopen — restore the saved ticks (with their quantity) + makes, intersected with LIVE
        // demand so a line or cover that has since gone is dropped rather than resurrected. A saved
        // quantity is clamped to what is currently free.
        final freeById = <String, int>{};
        for (final r in _rows) {
          for (final l in _linesOf(r)) {
            if (_free(l) > 0) freeById['${l['line_id']}'] = _free(l);
          }
        }
        for (final s in saved) {
          final id = '${s['line_id']}';
          final free = freeById[id];
          if (free == null) continue;
          final q = (s['planned_boxes'] as num?)?.toInt() ?? free;
          _lineQty[id] = q.clamp(1, free);
        }
        for (final m in widget.draft.savedMakes ?? const []) {
          final box = '${m['box_id']}';
          if (_rows.any((r) => '${r['box_id']}' == box)) {
            _plan[box] = (m['target_boxes'] as num?)?.toInt() ?? 0;
          }
        }
      } else {
        // Fresh draft — tick every free line of the picked orders at its full remaining quantity.
        for (final r in _rows) {
          for (final l in _linesOf(r)) {
            if (_picked.contains(l['order_id']) && _free(l) > 0) {
              _lineQty['${l['line_id']}'] = _free(l);
            }
          }
        }
      }
      _loading = false;
    });
  }

  // ── 💾 autosave the draft ───────────────────────────────────────────────────────────────────
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 700), _saveDraft);
  }

  Future<void> _saveDraft() async {
    if (_taken) return;
    final lines = <Map<String, dynamic>>[];
    for (final r in _rows) {
      for (final l in _linesOf(r)) {
        final q = _tq(l);
        if (q > 0) lines.add({'line_id': l['line_id'], 'planned_boxes': q});
      }
    }
    final makes = [
      for (final e in _plan.entries) {'box_id': e.key, 'target_boxes': e.value}
    ];
    try {
      await _data.productionPlanSave(
          planId: widget.draft.id,
          orderIds: _picked.toList(),
          lines: lines,
          makes: makes);
    } catch (e) {
      // Best-effort: a transient autosave miss retries on the next change / on leave.
      debugPrint('draft autosave failed: $e');
    }
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

  int _tickedQty(Map<String, dynamic> r) =>
      _linesOf(r).fold(0, (s, l) => s + _tq(l));

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
      // An added stock design has no order line, so it isn't "mine" by demand —
      // keep it anyway; every other (order) row must have a picked line.
      if (r['_added'] != true && _mine(r).isEmpty) return false;
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
  /// 🔑 **Each line carries a quantity box** — a line may go into production in PART (300 of 500 now,
  /// 200 stays pending). Ticking prefills the whole remaining; type down to send less.
  Future<void> _openTickList(Map<String, dynamic> r, bool mine) async {
    final lines = mine ? _mine(r) : _others(r);
    if (lines.isEmpty) return;
    // One controller per line, seeded with the current (or default) quantity.
    final ctrls = <String, TextEditingController>{
      for (final l in lines)
        '${l['line_id']}':
            TextEditingController(text: '${_tq(l) > 0 ? _tq(l) : _free(l)}'),
    };
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final onQ = lines.fold<int>(0, (s, l) => s + _tq(l));
        final allQ = lines.fold<int>(0, (s, l) => s + _free(l));
        final allOn = lines.every((l) => _isTicked(l['line_id']));
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
            width: 400,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setD(() => setState(() {
                        for (final l in lines) {
                          final id = '${l['line_id']}';
                          final free = _free(l);
                          if (allOn) {
                            _lineQty.remove(id);
                          } else if (free > 0) {
                            _lineQty[id] =
                                (int.tryParse(ctrls[id]!.text.trim()) ?? free).clamp(1, free);
                            ctrls[id]!.text = '${_lineQty[id]}';
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
                    for (final l in lines) _tickRow(l, r, setD, ctrls),
                  ],
                ),
              ),
              const Divider(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(children: [
                  const Text('Going in',
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
                    'What you leave off — a whole line or part of one — stays pending on that order '
                    'and comes back next time.',
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
    for (final c in ctrls.values) {
      c.dispose();
    }
    setState(() {});
    _scheduleSave();
  }

  Widget _tickRow(Map<String, dynamic> l, Map<String, dynamic> r, StateSetter setD,
      Map<String, TextEditingController> ctrls) {
    final free = _free(l);
    final id = '${l['line_id']}';
    final made = _i(l, 'produced');
    final planned = _i(l, 'planned');
    final on = _isTicked(id);
    final ctrl = ctrls[id]!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Checkbox(
          value: on,
          activeColor: _green,
          visualDensity: VisualDensity.compact,
          onChanged: free == 0
              ? null
              : (v) => setD(() => setState(() {
                    if (v == true) {
                      _lineQty[id] =
                          (int.tryParse(ctrl.text.trim()) ?? free).clamp(1, free);
                      ctrl.text = '${_lineQty[id]}';
                    } else {
                      _lineQty.remove(id);
                    }
                    _plan.remove(r['box_id']);
                  })),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (l['urgent'] == true)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(Icons.star, size: 13, color: Colors.amber),
                ),
              Expanded(
                child: Text('${l['customer']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ]),
            Text(
                [
                  '${l['note']}'.trim().isEmpty ? '${l['token']}' : '${l['note']} · ${l['token']}',
                  if (made > 0) 'made $made',
                  if (planned > 0) 'planned $planned',
                ].join('  ·  '),
                style: TextStyle(
                    fontSize: 10.5, color: made > 0 ? _green : Colors.grey.shade600)),
          ]),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 58,
          child: TextField(
            controller: ctrl,
            enabled: on,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.right,
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 7, vertical: 8),
              border: OutlineInputBorder(),
            ),
            style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 14,
                color: on ? _green : Colors.grey),
            onChanged: (v) {
              final parsed = int.tryParse(v.trim()) ?? 0;
              final clamped = parsed.clamp(1, free);
              setD(() => setState(() {
                    _lineQty[id] = clamped;
                    _plan.remove(r['box_id']);
                  }));
              if (parsed > free) {
                ctrl.text = '$clamped';
                ctrl.selection =
                    TextSelection.collapsed(offset: ctrl.text.length);
              }
            },
          ),
        ),
        const SizedBox(width: 5),
        Text('/ $free',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
      ]),
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
        final q = _tq(l);
        if (q > 0) {
          demand.add({'book_order_line_id': l['line_id'], 'planned_boxes': q});
        }
      }
    }
    return (boxes: boxes, demand: demand);
  }

  /// 🔒 The safety gate. **Cancel · Verify · Yes** — Verify opens the plan review, Yes commits.
  Future<void> _openVerify() async {
    final c = _collect();
    // A run needs a Make quantity somewhere — either against a ticked order line
    // or an added stock design (which carries no customer). Demand may be empty
    // for a pure stock run.
    if (c.boxes.isEmpty) {
      _snack('Set a Make quantity on at least one design.', error: true);
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
          // A line not FULLY taken (unticked, or ticked in part) keeps something pending.
          if (l['order_id'] == id && _free(l) > 0 && _tq(l) < _free(l)) {
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
                  Text('${e.key} — ${e.value} design(s) not fully taken',
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
      // The draft has become a run — retire it so it leaves the "resume a draft" list.
      _taken = true;
      _saveTimer?.cancel();
      try {
        await _data.productionPlanDelete(widget.draft.id);
      } catch (e) {
        debugPrint('draft delete after take failed: $e');
      }
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
        if (_tq(l) > 0) entries.add((r: r, l: l));
      }
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final total = entries.fold<int>(0, (s, e) => s + _tq(e.l));
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
                total: g[k]!.fold<int>(0, (s, e) => s + _tq(e.l)),
                lines: [
                  for (final e in g[k]!)
                    (label: '${e.l['customer']}', sub: '${e.l['token']}', qty: _tq(e.l))
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
                total: g[k]!.fold<int>(0, (s, e) => s + _tq(e.l)),
                lines: [
                  for (final e in g[k]!)
                    (label: '${e.r['cover_word']}', sub: '${e.r['brand']} · ${e.r['surface']}', qty: _tq(e.l))
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
          TextButton.icon(
            onPressed: _saving ? null : _addDesign,
            icon: const Icon(Icons.add, size: 18, color: Colors.white),
            label: const Text('Add design',
                style: TextStyle(color: Colors.white, fontSize: 13)),
          ),
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
    final mineOnQ = mine.fold<int>(0, (s, l) => s + _tq(l));
    final mineAllQ = mine.fold<int>(0, (s, l) => s + _free(l));
    final othOnQ = others.fold<int>(0, (s, l) => s + _tq(l));
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
        onChanged: (v) {
          setState(() => _plan[r['box_id']] = int.tryParse(v.trim()) ?? 0);
          _scheduleSave();
        },
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
          if (_tq(l) < _free(l)) left++;
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
