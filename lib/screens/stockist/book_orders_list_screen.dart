import 'package:flutter/material.dart';

import '../../services/supabase_data_service.dart';
import 'book_order_screen.dart';

/// 📕 **BOOKED ORDERS — standing demand, per customer.**
///
/// The customer-facing half of Book Order: who asked for what, and how much of it has been made.
/// (The factory-facing half is the Production screen, where the same demand is rolled up by TILE
/// instead of by customer.)
///
/// 🚫 **These never appear in Inquiries, and Inquiries never appears here.** Inquiries is
/// availability, holding and dispatch — a booked order does none of the three. It does not touch
/// stock at all until it is produced. (docs/PRODUCTION_PLANNING_PLAN.md)
class BookOrdersListScreen extends StatefulWidget {
  const BookOrdersListScreen({super.key});

  @override
  State<BookOrdersListScreen> createState() => _BookOrdersListScreenState();
}

const _navy = Color(0xFF1B4F72);
const _purple = Color(0xFF6A1B9A);
const _green = Color(0xFF2E7D32);

class _BookOrdersListScreenState extends State<BookOrdersListScreen> {
  final _data = SupabaseDataService();
  bool _loading = true;
  List<Map<String, dynamic>> _orders = [];
  String _status = 'open';
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await _data.myBookOrders();
    if (!mounted) return;
    setState(() {
      _orders = list;
      _loading = false;
    });
  }

  int _int(Map<String, dynamic> o, String k) => (o[k] as num?)?.toInt() ?? 0;

  static String _statusLabel(String s) => switch (s) {
        'open' => 'Open',
        'in_production' => 'In production',
        'closed' => 'Closed',
        'cancelled' => 'Cancelled',
        _ => 'All',
      };

  List<Map<String, dynamic>> get _filtered {
    final q = _q.trim().toLowerCase();
    return _orders.where((o) {
      if (_status != 'all' && (o['status'] ?? '') != _status) return false;
      if (q.isEmpty) return true;
      return [o['customer_name'], o['customer_hint'], o['token']]
          .map((x) => (x ?? '').toString().toLowerCase())
          .any((s) => s.contains(q));
    }).toList();
  }

  Future<void> _newOrder() async {
    final made = await Navigator.of(context).push<Map<String, dynamic>>(
        MaterialPageRoute(builder: (_) => const BookOrderScreen()));
    if (made != null) _load();
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    final boxes = list.fold<int>(0, (s, o) => s + _int(o, 'remaining_boxes'));
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: const Text('Booked orders'),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: _load),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newOrder,
        backgroundColor: _purple,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Book an order'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Column(children: [
                  TextField(
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
                  const SizedBox(height: 6),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      // 🔪 A sliced order MOVES TAB — it never vanishes. "It will not show in
                      // booked order" means not in the OPEN list, not gone.
                      for (final s in const [
                        'open', 'in_production', 'closed', 'cancelled', 'all'
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(_statusLabel(s),
                                style: const TextStyle(fontSize: 11.5)),
                            selected: _status == s,
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) => setState(() => _status = s),
                          ),
                        ),
                    ]),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                      '${list.length} order${list.length == 1 ? '' : 's'} · $boxes boxes still to make',
                      style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ),
              ),
              Expanded(
                child: list.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                              'No booked orders. Press "Book an order" to take one — it will not touch your stock until you produce it.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey)),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(10, 4, 10, 90),
                        itemCount: list.length,
                        itemBuilder: (_, i) => _card(list[i]),
                      ),
              ),
            ]),
    );
  }

  Widget _card(Map<String, dynamic> o) {
    final ordered = _int(o, 'ordered_boxes');
    final made = _int(o, 'produced_boxes');
    final left = _int(o, 'remaining_boxes');
    final status = (o['status'] ?? 'open').toString();
    final who = (o['customer_name'] ?? '').toString().trim().isNotEmpty
        ? (o['customer_name'] ?? '').toString()
        : (o['customer_hint'] ?? '').toString().trim();
    final note = (o['customer_hint'] ?? '').toString().trim();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => BookOrderDetailScreen(
                  orderId: (o['id'] ?? '').toString())));
          _load();
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (o['urgent'] == true)
                const Padding(
                  padding: EdgeInsets.only(right: 5),
                  child: Icon(Icons.star, size: 16, color: Colors.amber),
                ),
              Expanded(
                child: Text(who.isEmpty ? (o['token'] ?? '').toString() : who,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14)),
              ),
              if (status != 'open')
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                      color: const Color(0xFFF0F0F0),
                      borderRadius: BorderRadius.circular(20)),
                  child: Text(status,
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey.shade700)),
                ),
            ]),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                  [
                    if (note.isNotEmpty && note != who) note,
                    (o['token'] ?? '').toString(),
                    '${_int(o, 'line_count')} design(s)',
                  ].join('  ·  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            ),
            // 🔪 A SLICE says where it came from; a PARENT says where its work went. The customer's
            // own number never changes — only slices take a letter.
            if ((o['slice'] ?? '').toString().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(children: [
                  const Icon(Icons.call_split, size: 13, color: _purple),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                        'Slice ${o['slice']} of ${o['parent_token'] ?? ''} — in production',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w600, color: _purple)),
                  ),
                ]),
              ),
            if (((o['slices'] as List?) ?? const []).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final sl in (o['slices'] as List))
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                          color: const Color(0xFFF3E8F8),
                          borderRadius: BorderRadius.circular(20)),
                      child: Text(
                          '${(sl as Map)['token']} · ${(sl)['boxes']} boxes in production',
                          style: const TextStyle(
                              fontSize: 10, fontWeight: FontWeight.w700, color: _purple)),
                    ),
                ]),
              ),
            const SizedBox(height: 8),
            // ordered → made → still to make. No stock figure here on purpose: a booked order has
            // nothing to do with the godown until it is produced.
            Row(children: [
              _fig('Ordered', ordered, Colors.grey.shade700),
              const SizedBox(width: 16),
              _fig('Made', made, _green),
              const SizedBox(width: 16),
              _fig('To make', left, _purple),
              const Spacer(),
              if ((o['brands'] as List?)?.isNotEmpty ?? false)
                Text((o['brands'] as List).join(' · '),
                    style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600)),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _fig(String label, int n, Color c) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$n',
            style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.bold, color: c)),
        Text(label,
            style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
      ]);
}

/// One booked order: its lines, and what has been made against each.
class BookOrderDetailScreen extends StatefulWidget {
  final String orderId;
  const BookOrderDetailScreen({super.key, required this.orderId});

  @override
  State<BookOrderDetailScreen> createState() => _BookOrderDetailScreenState();
}

class _BookOrderDetailScreenState extends State<BookOrderDetailScreen> {
  final _data = SupabaseDataService();
  bool _loading = true;
  Map<String, dynamic> _o = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _data.bookOrderDetail(widget.orderId);
      if (!mounted) return;
      setState(() {
        _o = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('$e', error: true);
    }
  }

  void _snack(String m, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(m), backgroundColor: error ? Colors.red : _green));
  }

  Future<void> _setStatus(String s) async {
    try {
      await _data.bookOrderSetStatus(widget.orderId, s);
      await _load();
      _snack('Order $s.');
    } catch (e) {
      _snack('$e', error: true);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this booked order?'),
        content: const Text('It will be removed completely.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _data.bookOrderDelete(widget.orderId);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      // A refusal names how many boxes are already produced — it deserves a dialog, not a bar.
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.info_outline, color: _navy, size: 30),
          title: const Text('Cannot delete this order'),
          content: Text('$e', style: const TextStyle(fontSize: 13.5)),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = [
      for (final l in (_o['lines'] as List?) ?? const [])
        Map<String, dynamic>.from(l as Map)
    ];
    final who = (_o['customer_name'] ?? '').toString().trim().isNotEmpty
        ? (_o['customer_name'] ?? '').toString()
        : (_o['customer_hint'] ?? '').toString();
    final status = (_o['status'] ?? 'open').toString();
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: Text(_loading ? 'Booked order' : (_o['token'] ?? '').toString()),
        actions: [
          if (!_loading)
            PopupMenuButton<String>(
              onSelected: (v) => v == 'delete' ? _delete() : _setStatus(v),
              itemBuilder: (_) => [
                if (status != 'open')
                  const PopupMenuItem(value: 'open', child: Text('Re-open')),
                if (status == 'open')
                  const PopupMenuItem(
                      value: 'closed', child: Text('Close order')),
                if (status == 'open')
                  const PopupMenuItem(
                      value: 'cancelled', child: Text('Cancel order')),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(who,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16)),
                        const SizedBox(height: 2),
                        Text('${_o['token']}  ·  $status',
                            style: TextStyle(
                                fontSize: 11.5, color: Colors.grey.shade600)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                for (final l in lines) _lineCard(l),
              ],
            ),
    );
  }

  Widget _lineCard(Map<String, dynamic> l) {
    final ordered = (l['quantity'] as num?)?.toInt() ?? 0;
    final made = (l['produced_qty'] as num?)?.toInt() ?? 0;
    final left = (l['remaining'] as num?)?.toInt() ?? 0;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            IconButton(
              tooltip: l['is_urgent'] == true ? 'Urgent' : 'Mark urgent',
              visualDensity: VisualDensity.compact,
              icon: Icon(l['is_urgent'] == true ? Icons.star : Icons.star_border,
                  size: 19,
                  color: l['is_urgent'] == true
                      ? Colors.amber.shade700
                      : Colors.grey),
              onPressed: () async {
                try {
                  await _data.bookLineSetUrgent(
                      (l['id'] ?? '').toString(), l['is_urgent'] != true);
                  await _load();
                } catch (e) {
                  _snack('$e', error: true);
                }
              },
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${l['design_name']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13.5)),
                  Text('${l['brand']}  ·  ${l['surface']}  ·  ${l['size']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade600)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            _fig('Ordered', ordered, Colors.grey.shade700),
            const SizedBox(width: 18),
            _fig('Made', made, _green),
            const SizedBox(width: 18),
            _fig('To make', left, _purple),
          ]),
        ]),
      ),
    );
  }

  Widget _fig(String label, int n, Color c) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$n',
            style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.bold, color: c)),
        Text(label,
            style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
      ]);
}
