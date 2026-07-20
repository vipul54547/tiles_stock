import 'package:flutter/material.dart';

import '../../services/supabase_data_service.dart';

/// 🏭 **PRODUCTION PLANNING — what the line has to make.**
///
/// Inquiries is the CUSTOMER view: who wants what, and what you owe them. This is the FACTORY
/// view: the same demand rolled up by what actually runs on the line. One tile ordered by three
/// customers under three covers is **one thing to make**, and that is how it appears here.
///
/// 🔑 **He plans by what is RUNNING** — *"which punch is running, which surface is running, which
/// body is running"* — so those three are the default grouping, and every one of them is a filter.
///
/// ⚠️ **`in godown now` is INFORMATION, never a reservation.** A booked order does not touch stock:
/// if he takes Pratap's order ten days from now, those boxes must have been free to sell for ten
/// days. So the demand column and the stock column sit side by side and are **never** netted — no
/// "you only need 300". He reads both and decides, on the day. (docs/PRODUCTION_PLANNING_PLAN.md)
class ProductionScreen extends StatefulWidget {
  const ProductionScreen({super.key});

  @override
  State<ProductionScreen> createState() => _ProductionScreenState();
}

const _navy = Color(0xFF1B4F72);
const _purple = Color(0xFF6A1B9A);

/// The dimensions he can group and filter by. `key` is the field on a demand row.
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

  bool _loading = true;
  DateTime? _asOf;
  List<Map<String, dynamic>> _rows = [];

  /// 🔑 His three, in his order. Ordered — `Punch ▸ Surface ▸ Body` reads differently from
  /// `Body ▸ Punch ▸ Surface`, and the first one is how a kiln day is actually planned.
  final List<String> _groupBy = ['punch', 'surface', 'tile_type'];

  /// dimension → the one value he has narrowed to (null = all).
  final Map<String, String> _filter = {};
  bool _urgentOnly = false;
  final _q = TextEditingController();
  final _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
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
      _loading = false;
    });
  }

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

  int _int(Map<String, dynamic> r, String k) => (r[k] as num?)?.toInt() ?? 0;
  double _dbl(Map<String, dynamic> r, String k) =>
      (r[k] as num?)?.toDouble() ?? 0;

  List<Map<String, dynamic>> get _filtered {
    final q = _q.text.trim().toLowerCase();
    return _rows.where((r) {
      for (final e in _filter.entries) {
        if (_val(r, e.key) != e.value) return false;
      }
      if (_urgentOnly && r['urgent'] != true) return false;
      if (q.isNotEmpty) {
        final hay = [
          r['print_name'], r['cover_word'], r['brand'], r['surface'],
          for (final l in (r['lines'] as List?) ?? const [])
            (l as Map)['customer'],
        ].map((x) => (x ?? '').toString().toLowerCase()).join(' ');
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();
  }

  /// Distinct values present for a dimension, so a filter never offers an empty answer.
  List<String> _valuesFor(String key) {
    final s = <String>{for (final r in _rows) _val(r, key)};
    final l = s.toList()..sort();
    return l;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filtered;
    final boxes = rows.fold<int>(0, (s, r) => s + _int(r, 'remaining_boxes'));
    final pieces = rows.fold<int>(0, (s, r) => s + _int(r, 'remaining_pieces'));
    final sqft = rows.fold<double>(0, (s, r) => s + _dbl(r, 'remaining_sqft'));

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: const Text('Production planning'),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              _totals(rows.length, boxes, pieces, sqft),
              _filterBar(),
              _groupBar(),
              const Divider(height: 1),
              Expanded(
                child: rows.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                              _rows.isEmpty
                                  ? 'Nothing booked yet. A booked order appears here the moment it is taken — it never touches your stock until you produce it.'
                                  : 'No booked design matches these filters.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.grey)),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 24),
                        children: _buildGroups(rows, 0, ''),
                      ),
              ),
            ]),
    );
  }

  Widget _totals(int n, int boxes, int pieces, double sqft) => Container(
        width: double.infinity,
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('TO MAKE',
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: .8,
                  color: Colors.grey.shade600)),
          const SizedBox(height: 2),
          Wrap(spacing: 16, runSpacing: 2, children: [
            _big('$boxes', 'boxes'),
            _big('$pieces', 'pieces'),
            _big(sqft.toStringAsFixed(0), 'sq ft'),
            _big('$n', n == 1 ? 'line' : 'lines'),
          ]),
          if (_asOf != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                  'Stock figures as of '
                  '${_asOf!.hour.toString().padLeft(2, '0')}:${_asOf!.minute.toString().padLeft(2, '0')}',
                  style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500)),
            ),
        ]),
      );

  Widget _big(String n, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Text(n,
            style: const TextStyle(
                fontSize: 19, fontWeight: FontWeight.bold, color: _navy)),
        const SizedBox(width: 4),
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(label,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        ),
      ]);

  Widget _filterBar() => Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        child: Column(children: [
          TextField(
            controller: _q,
            onChanged: (_) => setState(() {}),
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
                label: const Text('⭐ Urgent'),
                selected: _urgentOnly,
                onSelected: (v) => setState(() => _urgentOnly = v),
                labelStyle: const TextStyle(fontSize: 11.5),
                visualDensity: VisualDensity.compact,
              ),
              for (final d in _dims) ...[
                const SizedBox(width: 6),
                _dimFilter(d.key, d.label),
              ],
              if (_filter.isNotEmpty || _urgentOnly) ...[
                const SizedBox(width: 6),
                TextButton.icon(
                  onPressed: () => setState(() {
                    _filter.clear();
                    _urgentOnly = false;
                  }),
                  icon: const Icon(Icons.clear, size: 15),
                  label: const Text('Clear', style: TextStyle(fontSize: 11.5)),
                ),
              ],
            ]),
          ),
        ]),
      );

  Widget _dimFilter(String key, String label) {
    final picked = _filter[key];
    return PopupMenuButton<String>(
      tooltip: label,
      onSelected: (v) => setState(() {
        if (v == '__all__') {
          _filter.remove(key);
        } else {
          _filter[key] = v;
        }
      }),
      itemBuilder: (_) => [
        const PopupMenuItem(value: '__all__', child: Text('All')),
        for (final v in _valuesFor(key)) PopupMenuItem(value: v, child: Text(v)),
      ],
      child: Chip(
        visualDensity: VisualDensity.compact,
        backgroundColor: picked == null ? null : const Color(0xFFE3ECF3),
        label: Text(picked == null ? label : '$label: $picked',
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: picked == null ? FontWeight.normal : FontWeight.w700,
                color: picked == null ? null : _navy)),
        avatar: const Icon(Icons.arrow_drop_down, size: 18),
      ),
    );
  }

  /// 🔑 Grouping is ORDERED — tap a chip to move it to the front. `Punch ▸ Surface ▸ Body` is how a
  /// kiln day is planned; the same three in another order answer a different question.
  Widget _groupBar() => Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        child: Row(children: [
          Text('Group', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final d in _dims) ...[
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text(
                          _groupBy.contains(d.key)
                              ? '${_groupBy.indexOf(d.key) + 1}. ${d.label}'
                              : d.label,
                          style: const TextStyle(fontSize: 11.5)),
                      selected: _groupBy.contains(d.key),
                      visualDensity: VisualDensity.compact,
                      onSelected: (v) => setState(() {
                        if (v) {
                          if (_groupBy.length < 3) _groupBy.add(d.key);
                        } else {
                          _groupBy.remove(d.key);
                        }
                        _expanded.clear();
                      }),
                    ),
                  ),
                ],
              ]),
            ),
          ),
        ]),
      );

  List<Widget> _buildGroups(
      List<Map<String, dynamic>> rows, int level, String path) {
    if (level >= _groupBy.length) {
      return [for (final r in rows) _demandRow(r)];
    }
    final key = _groupBy[level];
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      groups.putIfAbsent(_val(r, key), () => []).add(r);
    }
    final keys = groups.keys.toList()..sort();
    return [
      for (final g in keys) ...[
        _groupHeader(g, groups[g]!, level),
        ..._buildGroups(groups[g]!, level + 1, '$path/$g'),
      ]
    ];
  }

  Widget _groupHeader(String name, List<Map<String, dynamic>> rows, int level) {
    final boxes = rows.fold<int>(0, (s, r) => s + _int(r, 'remaining_boxes'));
    final sqft = rows.fold<double>(0, (s, r) => s + _dbl(r, 'remaining_sqft'));
    final urgent = rows.any((r) => r['urgent'] == true);
    return Padding(
      padding: EdgeInsets.fromLTRB(4.0 + level * 12, level == 0 ? 12 : 6, 4, 4),
      child: Row(children: [
        if (urgent)
          const Padding(
            padding: EdgeInsets.only(right: 4),
            child: Icon(Icons.star, size: 14, color: Colors.amber),
          ),
        Expanded(
          child: Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: level == 0 ? 13.5 : 12.5,
                  fontWeight: level == 0 ? FontWeight.w800 : FontWeight.w600,
                  color: level == 0 ? _navy : Colors.grey.shade700)),
        ),
        Text('$boxes boxes · ${sqft.toStringAsFixed(0)} sq ft',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade600)),
      ]),
    );
  }

  Widget _demandRow(Map<String, dynamic> r) {
    final id = (r['box_id'] ?? '').toString();
    final open = _expanded.contains(id);
    final lines = [
      for (final l in (r['lines'] as List?) ?? const [])
        Map<String, dynamic>.from(l as Map)
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Column(children: [
        InkWell(
          onTap: () => setState(
              () => open ? _expanded.remove(id) : _expanded.add(id)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Row(children: [
              if (r['urgent'] == true)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
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
                            fontWeight: FontWeight.w700, fontSize: 13.5)),
                    Text(
                        '${r['brand']}  ·  ${r['surface']}  ·  ${r['size']}'
                        '${(r['tile_type'] ?? '').toString().isEmpty ? '' : '  ·  ${r['tile_type']}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade600)),
                  ],
                ),
              ),
              // ── TO MAKE ── and ── in godown ── deliberately side by side and NEVER netted.
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('${_int(r, 'remaining_boxes')} boxes',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13.5,
                        color: _purple)),
                Text('${_int(r, 'remaining_pieces')} pcs · '
                    '${_dbl(r, 'remaining_sqft').toStringAsFixed(0)} sq ft',
                    style: TextStyle(
                        fontSize: 10.5, color: Colors.grey.shade600)),
              ]),
              const SizedBox(width: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F8),
                    borderRadius: BorderRadius.circular(8)),
                child: Column(children: [
                  Text('${_int(r, 'in_stock_now')}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13)),
                  Text('in godown',
                      style: TextStyle(
                          fontSize: 9, color: Colors.grey.shade600)),
                ]),
              ),
              Icon(open ? Icons.expand_less : Icons.expand_more,
                  size: 20, color: Colors.grey.shade500),
            ]),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Column(children: [
              const Divider(height: 1),
              const SizedBox(height: 6),
              // 🔑 WHO wants it. One tile under one cover can be several customers' demand — this
              // is the line that tells him whose order he is about to run.
              for (final l in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(children: [
                    if (l['urgent'] == true)
                      const Icon(Icons.star, size: 13, color: Colors.amber),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text('${l['customer']}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12)),
                    ),
                    Text('${l['token']}',
                        style: TextStyle(
                            fontSize: 10.5, color: Colors.grey.shade500)),
                    const SizedBox(width: 10),
                    Text('${l['remaining']} boxes',
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                  ]),
                ),
              if ((r['punch'] ?? '').toString().isNotEmpty ||
                  (r['series'] ?? '').toString().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                          [
                            if ((r['punch'] ?? '').toString().isNotEmpty)
                              'Punch: ${r['punch']}'
                                  '${(r['punch_type'] ?? '').toString().isEmpty ? '' : ' ▸ ${r['punch_type']}'}',
                            if ((r['series'] ?? '').toString().isNotEmpty)
                              'Series: ${r['series']}',
                          ].join('   ·   '),
                          style: TextStyle(
                              fontSize: 10.5, color: Colors.grey.shade600)),
                    ),
                  ]),
                ),
            ]),
          ),
      ]),
    );
  }
}
