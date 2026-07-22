import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/supabase_data_service.dart';

/// 🏭 **PRODUCTION POSITION.**
///
/// **By design** — the run's grade split (Program · Premium · Standard · Left).
///
/// **Allocate** — when a design is wanted by more than one order and there isn't
/// enough F_Stock for everyone, the stockist divides the shared stock among the
/// parties here (a box each). It goes **green** once the split fits F_Stock.
///
/// **By order** — send the allocated material to a held Ready order. An order's
/// Send unlocks only once its shared designs are green; a design with enough for
/// all is auto-allocated its full Ready. (PRODUCTION_REDESIGN §Phase 3 · order_from_stock)
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

  /// A design wanted by >1 order whose combined Ready exceeds its F_Stock → it
  /// must be split by hand. design_id → its F_Stock.
  final Map<String, int> _short = {};

  /// The claimants of a short design: each carries its order + the split box.
  final Map<String, List<Map<String, dynamic>>> _claims = {};

  /// line_id → the boxes to send. Real controllers only for SHORT lines (edited
  /// in Allocate); a non-short line just sends its full Ready.
  final Map<String, TextEditingController> _split = {};

  int _i(Map<String, dynamic> m, String k) => (m[k] as num?)?.toInt() ?? 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _split.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final orders =
        await _svc.productionPositionOrders((widget.run['id'] ?? '').toString());
    if (!mounted) return;
    // Group the run's order lines by design: combined Ready vs the shared F_Stock.
    final byDesign = <String, List<Map<String, dynamic>>>{};
    final fstockOf = <String, int>{};
    for (final o in orders) {
      for (final raw in (o['lines'] as List?) ?? const []) {
        final l = Map<String, dynamic>.from(raw as Map);
        final d = (l['design_id'] ?? '').toString();
        if (d.isEmpty) continue;
        (byDesign[d] ??= []).add({
          ...l,
          '_customer': o['customer'],
          '_token': o['token'],
          '_order_id': o['order_id'],
        });
        fstockOf[d] = _i(l, 'f_stock');
      }
    }
    for (final c in _split.values) {
      c.dispose();
    }
    _split.clear();
    _short.clear();
    _claims.clear();
    for (final e in byDesign.entries) {
      final ready = e.value.fold(0, (s, l) => s + _i(l, 'ready'));
      final f = fstockOf[e.key] ?? 0;
      // Short = its claimants together want more than there is.
      if (e.value.length > 1 && ready > f) {
        _short[e.key] = f;
        _claims[e.key] = e.value;
        // Greedy default split — oldest-first up to F_Stock, so it opens green.
        var left = f;
        for (final l in e.value) {
          final take = _i(l, 'ready').clamp(0, left);
          left -= take;
          _split[(l['line_id']).toString()] =
              TextEditingController(text: take == 0 ? '' : '$take');
        }
      }
    }
    setState(() {
      _orders = orders;
      _loading = false;
    });
  }

  // The boxes a line will send: the typed split (short design) or its full Ready.
  int _allocOf(Map<String, dynamic> l) {
    final id = (l['line_id']).toString();
    if (_split.containsKey(id)) {
      return int.tryParse(_split[id]!.text.trim()) ?? 0;
    }
    return _i(l, 'ready');
  }

  int _allocated(String designId) =>
      (_claims[designId] ?? const []).fold(0, (s, l) => s + _allocOf(l));

  bool _greenDesign(String designId) =>
      _allocated(designId) <= (_short[designId] ?? 0);

  /// An order can send once every SHORT design it touches is green.
  bool _orderSendable(Map<String, dynamic> o) {
    for (final raw in (o['lines'] as List?) ?? const []) {
      final d = (Map<String, dynamic>.from(raw as Map)['design_id'] ?? '')
          .toString();
      if (_short.containsKey(d) && !_greenDesign(d)) return false;
    }
    return true;
  }

  Future<void> _send(Map<String, dynamic> o) async {
    final payload = <Map<String, dynamic>>[];
    for (final raw in (o['lines'] as List?) ?? const []) {
      final l = Map<String, dynamic>.from(raw as Map);
      final q = _allocOf(l);
      if (q > 0) payload.add({'line_id': (l['line_id']).toString(), 'boxes': q});
    }
    if (payload.isEmpty) {
      _snack('Nothing ready to send.', _amber);
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
                ? '$sent boxes reserved → Ready order${token.isEmpty ? '' : ' ($token)'}'
                : 'Nothing sent — no free stock.',
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
                _title('By design — the run\'s totals'),
                for (final b in boxes) _designCard(b),
                if (_short.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _title('Allocate — shared stock is short; divide it'),
                  for (final d in _short.keys) _allocateCard(d),
                ],
                const SizedBox(height: 16),
                _title('By order — send ready material from here'),
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

  Widget _title(String s) => Padding(
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

  Widget _allocateCard(String designId) {
    final claims = _claims[designId] ?? const [];
    final f = _short[designId] ?? 0;
    final used = _allocated(designId);
    final green = used <= f;
    final head = claims.isEmpty ? '' : '${claims.first['cover_word']}';
    final sub = claims.isEmpty
        ? ''
        : '${claims.first['brand']} · ${claims.first['surface']} · ${claims.first['size']}';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: green ? _green : _red, width: 1.4)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(head,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
          Text(sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          const SizedBox(height: 8),
          for (final l in claims) _claimRow(l),
          const Divider(height: 16),
          Row(children: [
            Icon(green ? Icons.check_circle : Icons.error_outline,
                size: 16, color: green ? _green : _red),
            const SizedBox(width: 6),
            Text('Allocated $used of $f in stock',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: green ? _green : _red)),
            const Spacer(),
            if (!green)
              Text('${used - f} over — lower a box',
                  style: const TextStyle(fontSize: 11, color: _red)),
          ]),
        ]),
      ),
    );
  }

  Widget _claimRow(Map<String, dynamic> l) {
    final id = (l['line_id']).toString();
    final want = _i(l, 'ticked') - _i(l, 'sent');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        const Icon(Icons.person_outline, size: 14, color: _navy),
        const SizedBox(width: 5),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${l['_customer']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600)),
              Text('wants $want · ${l['_token']}',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
            ],
          ),
        ),
        SizedBox(
          width: 56,
          child: TextField(
            controller: _split[id],
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
                hintText: '0', isDense: true, border: OutlineInputBorder()),
          ),
        ),
      ]),
    );
  }

  Widget _orderCard(Map<String, dynamic> o) {
    final lines = [
      for (final l in (o['lines'] as List?) ?? const [])
        Map<String, dynamic>.from(l as Map)
    ];
    final sendable = _orderSendable(o);
    final total = lines.fold(0, (s, l) => s + _allocOf(l));
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
            for (final l in lines) _sendLine(l),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                if (!sendable)
                  const Expanded(
                    child: Text('Allocate the shared design(s) above first',
                        style: TextStyle(fontSize: 11, color: _red)),
                  )
                else
                  const Spacer(),
                FilledButton.icon(
                  onPressed: (_saving || !sendable || total == 0)
                      ? null
                      : () => _send(o),
                  icon: const Icon(Icons.playlist_add_check, size: 18),
                  label: Text(total > 0 ? 'Send $total → stock' : 'Send'),
                  style: FilledButton.styleFrom(backgroundColor: _green),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sendLine(Map<String, dynamic> l) {
    final alloc = _allocOf(l);
    final shared = _short.containsKey((l['design_id'] ?? '').toString());
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${l['cover_word']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13)),
              Text([
                'ticked ${_i(l, 'ticked')}',
                'made ${_i(l, 'made')}',
                'godown ${_i(l, 'f_stock')}',
                if (shared) 'shared',
              ].join('  ·  '),
                  style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$alloc',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: alloc > 0 ? _green : Colors.grey.shade500)),
            const Text('to send',
                style: TextStyle(fontSize: 9, color: Colors.grey)),
          ],
        ),
      ]),
    );
  }

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
