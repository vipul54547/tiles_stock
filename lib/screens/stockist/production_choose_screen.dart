import 'package:flutter/material.dart';

import '../../services/supabase_data_service.dart';
import 'production_plan_screen.dart';

/// 🏭 **PRODUCTION — STEP 1: CHOOSE THE ORDERS TO PLAN.**
///
/// A page of its own for one decision: which booked orders go into this round of planning. Picking
/// only brings their designs onto the next page — nothing is committed here. "Next" names the plan
/// (a dated draft) and opens it.
///
/// An order fully taken into production has left this list — it lives in Runs now, not here.
/// (docs/PRODUCTION_REDESIGN_PLAN.md)
class ProductionChooseScreen extends StatefulWidget {
  const ProductionChooseScreen({super.key});

  @override
  State<ProductionChooseScreen> createState() => _ProductionChooseScreenState();
}

const _navy = Color(0xFF1B4F72);
const _purple = Color(0xFF6A1B9A);

class _ProductionChooseScreenState extends State<ProductionChooseScreen> {
  final _data = SupabaseDataService();

  bool _loading = true;
  List<Map<String, dynamic>> _orders = [];
  List<Map<String, dynamic>> _drafts = [];
  final Set<String> _picked = {};
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final orders = await _data.myBookOrders();
    final drafts = await _data.myProductionPlans();
    if (!mounted) return;
    setState(() {
      _orders = orders.where((o) => (o['status'] ?? '') == 'open').toList();
      _drafts = drafts;
      // Drop any picks that are no longer open (e.g. taken while we were away).
      _picked.retainWhere(
          (id) => _orders.any((o) => (o['id'] ?? '').toString() == id));
      _loading = false;
    });
  }

  void _snack(String m, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(m), backgroundColor: error ? Colors.red : _navy));
  }

  int _i(Map m, String k) => (m[k] as num?)?.toInt() ?? 0;

  String _who(Map<String, dynamic> o) =>
      (o['customer_name'] ?? '').toString().trim().isNotEmpty
          ? (o['customer_name'] ?? '').toString()
          : (o['customer_hint'] ?? o['token']).toString();

  List<Map<String, dynamic>> get _visible {
    final q = _q.trim().toLowerCase();
    if (q.isEmpty) return _orders;
    return _orders.where((o) {
      final hay = [o['customer_name'], o['customer_hint'], o['token']]
          .map((x) => (x ?? '').toString().toLowerCase())
          .join(' ');
      return hay.contains(q);
    }).toList();
  }

  // ── the plan is created (as a draft) here, at Next ──────────────────────────────────────────
  Future<void> _next() async {
    final nameCtl = TextEditingController();
    var date = DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final boxes = _picked.fold<int>(0, (s, id) {
          final o = _orders.firstWhere((x) => (x['id'] ?? '').toString() == id,
              orElse: () => const {});
          return s + _i(o, 'remaining_boxes');
        });
        return AlertDialog(
          title: const Text('New production plan'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: nameCtl,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  labelText: 'Name this plan',
                  hintText: 'e.g. Monday kiln — sandstone punch',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: () async {
                final d = await showDatePicker(
                  context: ctx,
                  initialDate: date,
                  firstDate: DateTime(date.year - 1),
                  lastDate: DateTime(date.year + 2),
                );
                if (d != null) setD(() => date = d);
              },
              child: InputDecorator(
                decoration: const InputDecoration(
                    labelText: 'Planning date', border: OutlineInputBorder()),
                child: Row(children: [
                  const Icon(Icons.event, size: 18, color: _navy),
                  const SizedBox(width: 8),
                  Text(
                      '${date.day.toString().padLeft(2, '0')}/'
                      '${date.month.toString().padLeft(2, '0')}/${date.year}',
                      style: const TextStyle(fontSize: 13.5)),
                ]),
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                  '${_picked.length} order(s) · $boxes boxes. Nothing is committed yet — '
                  'the plan becomes a run only when you take it into production.',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Open plan')),
          ],
        );
      }),
    );
    if (ok != true || !mounted) return;

    final name = nameCtl.text.trim().isEmpty
        ? 'Plan ${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}'
        : nameCtl.text.trim();
    // Persist the draft the moment it's named — it survives an app-close from here on.
    String? id;
    try {
      id = await _data.productionPlanCreate(
          name: name, date: date, orderIds: _picked.toList());
    } catch (e) {
      _snack('$e', error: true);
      return;
    }
    if (id == null || !mounted) return;
    final draft = PlanDraft(
      id: id,
      name: name,
      date: date,
      pickedIds: {..._picked},
      orders: _orders,
    );
    final took = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => ProductionPlanScreen(draft: draft)));
    if (!mounted) return;
    // Taking into production moves orders to In production — refresh so they drop out, and clear
    // the picks that were just committed.
    if (took == true) _picked.clear();
    await _load();
  }

  // ── ♻️ resume a saved draft ─────────────────────────────────────────────────────────────────
  Future<void> _openDraft(Map<String, dynamic> d) async {
    final id = (d['id'] ?? '').toString();
    final loaded = await _data.productionPlanLoad(id);
    if (!mounted) return;
    if (loaded == null) {
      _snack('Could not open that draft.', error: true);
      return;
    }
    final orderIds = [
      for (final x in (loaded['order_ids'] as List?) ?? const []) x.toString()
    ];
    final lines = [
      for (final x in (loaded['lines'] as List?) ?? const [])
        Map<String, dynamic>.from(x as Map)
    ];
    final makes = [
      for (final x in (loaded['makes'] as List?) ?? const [])
        Map<String, dynamic>.from(x as Map)
    ];
    final date =
        DateTime.tryParse((loaded['plan_date'] ?? '').toString()) ?? DateTime.now();
    final draft = PlanDraft(
      id: id,
      name: (loaded['name'] ?? '').toString(),
      date: date,
      pickedIds: orderIds.toSet(),
      orders: _orders,
      savedLines: lines,
      savedMakes: makes,
    );
    await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => ProductionPlanScreen(draft: draft)));
    if (!mounted) return;
    await _load();
  }

  Future<void> _deleteDraft(Map<String, dynamic> d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard this draft?'),
        content: Text('"${(d['name'] ?? '').toString()}" will be removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _data.productionPlanDelete((d['id'] ?? '').toString());
    } catch (e) {
      _snack('$e', error: true);
      return;
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final list = _visible;
    final boxes = _picked.fold<int>(0, (s, id) {
      final o = _orders.firstWhere((x) => (x['id'] ?? '').toString() == id,
          orElse: () => const {});
      return s + _i(o, 'remaining_boxes');
    });
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: const Text('Choose orders to plan'),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh), tooltip: 'Refresh', onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              if (_drafts.isNotEmpty) _draftsBand(),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: TextField(
                  onChanged: (v) => setState(() => _q = v),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    hintText: 'Search customer or BO number…',
                    filled: true,
                    fillColor: const Color(0xFFF4F6F8),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none),
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _orders.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(28),
                          child: Text('No open booked orders to plan.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey)),
                        ),
                      )
                    : list.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(28),
                              child: Text('No order matches.',
                                  style: TextStyle(color: Colors.grey)),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.all(10),
                            itemCount: list.length,
                            itemBuilder: (_, i) => _orderTile(list[i]),
                          ),
              ),
              if (_picked.isNotEmpty)
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                          '${_picked.length} order(s) · $boxes boxes',
                          style: TextStyle(
                              fontSize: 12.5, color: Colors.grey.shade700)),
                    ),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: _navy),
                      onPressed: _next,
                      icon: const Icon(Icons.arrow_forward, size: 18),
                      label: const Text('Next'),
                    ),
                  ]),
                ),
            ]),
    );
  }

  String _draftDate(String? iso) {
    final d = DateTime.tryParse(iso ?? '');
    if (d == null) return '';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  Widget _draftsBand() => Container(
        width: double.infinity,
        color: const Color(0xFFF1ECF7),
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(right: 6, bottom: 4),
            child: Row(children: [
              const Icon(Icons.drafts_outlined, size: 16, color: _purple),
              const SizedBox(width: 6),
              Text('Resume a draft (${_drafts.length})',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: _purple)),
            ]),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 132),
            child: ListView(
              shrinkWrap: true,
              children: [for (final d in _drafts) _draftTile(d)],
            ),
          ),
        ]),
      );

  Widget _draftTile(Map<String, dynamic> d) {
    final orders = _i(d, 'order_count'), boxes = _i(d, 'box_count');
    return Card(
      margin: const EdgeInsets.only(bottom: 4, right: 6),
      elevation: 0,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(9),
          side: BorderSide(color: Colors.purple.shade100)),
      child: ListTile(
        dense: true,
        onTap: () => _openDraft(d),
        title: Text((d['name'] ?? '').toString(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        subtitle: Text(
            '${_draftDate((d['plan_date'] ?? '').toString())} · $orders order(s) · $boxes boxes',
            style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600)),
        trailing: IconButton(
          icon: Icon(Icons.delete_outline, size: 18, color: Colors.grey.shade500),
          tooltip: 'Discard draft',
          onPressed: () => _deleteDraft(d),
        ),
      ),
    );
  }

  Widget _orderTile(Map<String, dynamic> o) {
    final id = (o['id'] ?? '').toString();
    final on = _picked.contains(id);
    return InkWell(
      onTap: () => setState(() => on ? _picked.remove(id) : _picked.add(id)),
      borderRadius: BorderRadius.circular(9),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.fromLTRB(6, 8, 12, 8),
        decoration: BoxDecoration(
          color: on ? const Color(0xFFE7EEF4) : Colors.white,
          border: Border.all(color: on ? _navy : Colors.grey.shade200),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(children: [
          Checkbox(
            value: on,
            visualDensity: VisualDensity.compact,
            activeColor: _navy,
            onChanged: (v) =>
                setState(() => v == true ? _picked.add(id) : _picked.remove(id)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  if (o['urgent'] == true)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(Icons.star, size: 14, color: Colors.amber),
                    ),
                  Expanded(
                    child: Text(_who(o),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 13.5)),
                  ),
                ]),
                Text('${o['customer_hint']} · ${o['token']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600)),
              ],
            ),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${_i(o, 'remaining_boxes')}',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15, color: _purple)),
            Text('boxes',
                style: TextStyle(fontSize: 9, color: Colors.grey.shade500)),
          ]),
        ]),
      ),
    );
  }
}
