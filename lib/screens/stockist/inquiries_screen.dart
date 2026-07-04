import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/inquiry_order.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import 'stockist_add_order_screen.dart';

/// The stockist's single inquiry hub — every buyer order as a **token**, with
/// filters (status / date / buyer / design) + search, lifecycle actions
/// (Lock / Unlock / Reject), WhatsApp, and an expandable item list. Replaces
/// both the old by-design dashboard tab and the old by-buyer/date list, so the
/// "Inquiry" button next to "Stock" is the one powerful place.
class InquiriesScreen extends StatefulWidget {
  const InquiriesScreen({super.key});
  @override
  State<InquiriesScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

// status → (foreground, background) for the chip.
(Color, Color) _statusColors(String s) => switch (s) {
      'sent'        => (const Color(0xFF1565C0), const Color(0xFFE3F2FD)),
      'confirmed'   => (const Color(0xFF1565C0), const Color(0xFFE3F2FD)),
      'locked'      => (const Color(0xFF6A1B9A), const Color(0xFFF3E5F5)),
      'dispatching' => (const Color(0xFFE65100), const Color(0xFFFFF3E0)),
      'completed'   => (const Color(0xFF2E7D32), const Color(0xFFE8F5E9)),
      'rejected'    => (const Color(0xFFC62828), const Color(0xFFFFEBEE)),
      _             => (Colors.grey.shade700, const Color(0xFFF5F5F5)),
    };

// Filter-chip / status display name. In the Hold model, a 'locked' order is one
// the stockist has HELD (boxes reserved off buyer-facing stock).
String _statusName(String s) => switch (s) {
      'sent'        => 'Sent',
      'confirmed'   => 'Sent',
      'locked'      => 'Held',
      'dispatching' => 'Dispatching',
      'completed'   => 'Completed',
      'rejected'    => 'Rejected',
      _             => 'Draft',
    };

class _State extends State<InquiriesScreen> {
  final _data = SupabaseDataService();
  List<InquiryOrder> _orders = [];
  bool _loading = true;

  String _status = 'all';
  String _q = '';
  String? _buyerId;
  String? _designId;
  String? _brandName; // multi-brand filter (non-default brand name)
  DateTime? _from;
  DateTime? _to;
  final _searchCtrl = TextEditingController();

  static const _statuses = [
    'all', 'draft', 'sent', 'locked', 'dispatching', 'completed', 'rejected'
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await _data.getMyInquiries();
    if (!mounted) return;
    setState(() {
      _orders = list;
      _loading = false;
    });
  }

  int get _filterCount =>
      (_buyerId != null ? 1 : 0) +
      (_designId != null ? 1 : 0) +
      (_brandName != null ? 1 : 0) +
      (_from != null ? 1 : 0) +
      (_to != null ? 1 : 0);

  // Distinct non-default brand names across all orders (for the brand filter).
  List<String> get _allBrandNames {
    final s = <String>{};
    for (final o in _orders) {
      s.addAll(o.brands);
    }
    final l = s.toList()..sort();
    return l;
  }

  List<InquiryOrder> get _filtered {
    var list = _orders;
    if (_status != 'all') list = list.where((o) => o.status == _status).toList();
    if (_buyerId != null) {
      list = list.where((o) => o.endUserId == _buyerId).toList();
    }
    if (_designId != null) {
      list = list
          .where((o) => o.designs.any((d) => d['id'] == _designId))
          .toList();
    }
    if (_brandName != null) {
      list = list.where((o) => o.brands.contains(_brandName)).toList();
    }
    if (_from != null) {
      list = list
          .where((o) => !o.updatedAt.toLocal().isBefore(_from!))
          .toList();
    }
    if (_to != null) {
      final end = DateTime(_to!.year, _to!.month, _to!.day, 23, 59, 59);
      list = list.where((o) => !o.updatedAt.toLocal().isAfter(end)).toList();
    }
    if (_q.isNotEmpty) {
      final q = _q.toLowerCase();
      list = list
          .where((o) =>
              o.token.toLowerCase().contains(q) ||
              o.connectionCode.toLowerCase().contains(q) ||
              o.customerHint.toLowerCase().contains(q) ||
              o.company.toLowerCase().contains(q) ||
              o.contact.toLowerCase().contains(q) ||
              o.phone.contains(q) ||
              o.city.toLowerCase().contains(q) ||
              o.designNames.toLowerCase().contains(q))
          .toList();
    }
    return list;
  }

  String _fmtDateTime(DateTime d) {
    final l = d.toLocal();
    final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
    final m = l.minute.toString().padLeft(2, '0');
    final ap = l.hour < 12 ? 'AM' : 'PM';
    return '${l.day} ${_months[l.month - 1]} ${l.year}, $h:$m $ap';
  }

  String _fmtDate(DateTime? d) =>
      d == null ? 'Any' : '${d.day} ${_months[d.month - 1]} ${d.year}';

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    final boxes = filtered.fold(0, (s, o) => s + o.totalBoxes);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Inquiries'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addOrder,
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add Order'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _statusChips(),
                _searchFilterRow(),
                if (_filterCount > 0) _activeFilterBar(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${filtered.length} order${filtered.length == 1 ? '' : 's'} · $boxes boxes',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ),
                ),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(
                          child: Text('No inquiries match',
                              style: TextStyle(color: Colors.grey)))
                      : ListView.builder(
                          padding: EdgeInsets.fromLTRB(12, 4, 12,
                              12 + MediaQuery.viewPaddingOf(context).bottom),
                          itemCount: filtered.length,
                          itemBuilder: (_, i) => _orderCard(filtered[i]),
                        ),
                ),
              ],
            ),
    );
  }

  // ── Status filter chips ─────────────────────────────────────────────────────
  Widget _statusChips() {
    String count(String s) {
      final n = s == 'all'
          ? _orders.length
          : _orders.where((o) => o.status == s).length;
      return n == 0 ? '' : ' $n';
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      child: Row(
        children: _statuses.map((s) {
          final sel = _status == s;
          final label = (s == 'all' ? 'All' : _statusName(s)) + count(s);
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: GestureDetector(
              onTap: () => setState(() => _status = s),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: sel ? _navy : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: sel ? _navy : Colors.grey.shade400),
                ),
                child: Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: sel ? Colors.white : Colors.grey.shade700)),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Search + Filter button ──────────────────────────────────────────────────
  Widget _searchFilterRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _q = v),
              decoration: InputDecoration(
                hintText: 'Search code, token, buyer, design, phone…',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                suffixIcon: _q.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _q = '');
                        }),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Stack(
            clipBehavior: Clip.none,
            children: [
              OutlinedButton.icon(
                onPressed: _showFilterSheet,
                icon: const Icon(Icons.tune, size: 16),
                label: const Text('Filter'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _navy,
                  side: BorderSide(
                      color: _filterCount > 0 ? _navy : Colors.grey.shade400),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              if (_filterCount > 0)
                Positioned(
                  top: -6,
                  right: -6,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: const BoxDecoration(
                        color: _navy, shape: BoxShape.circle),
                    child: Center(
                      child: Text('$_filterCount',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _activeFilterBar() {
    final buyer = _buyerId == null
        ? null
        : _orders.firstWhere((o) => o.endUserId == _buyerId,
            orElse: () => InquiryOrder(
                id: '', token: '', status: 'draft',
                createdAt: DateTime.now(), updatedAt: DateTime.now()));
    final designName = _designId == null
        ? null
        : (() {
            for (final o in _orders) {
              for (final d in o.designs) {
                if (d['id'] == _designId) return (d['name'] ?? '').toString();
              }
            }
            return _designId!;
          })();
    Widget chip(String label, VoidCallback onClear) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Chip(
            label: Text(label, style: const TextStyle(fontSize: 11)),
            onDeleted: onClear,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        );
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          if (buyer != null && buyer.company.isNotEmpty)
            chip('Buyer: ${buyer.company}', () => setState(() => _buyerId = null)),
          if (designName != null)
            chip('Design: $designName', () => setState(() => _designId = null)),
          if (_brandName != null)
            chip('Brand: $_brandName', () => setState(() => _brandName = null)),
          if (_from != null)
            chip('From ${_fmtDate(_from)}', () => setState(() => _from = null)),
          if (_to != null)
            chip('To ${_fmtDate(_to)}', () => setState(() => _to = null)),
        ],
      ),
    );
  }

  void _showFilterSheet() {
    // Buyers + designs present across all orders (so no empty choices).
    final buyers = <String, String>{};
    final designs = <String, String>{};
    for (final o in _orders) {
      if (o.endUserId.isNotEmpty) buyers[o.endUserId] = o.company;
      for (final d in o.designs) {
        designs[(d['id'] ?? '').toString()] = (d['name'] ?? '').toString();
      }
    }
    final brandNames = _allBrandNames;
    String? buyerId = _buyerId;
    String? designId = _designId;
    String? brandName = _brandName;
    DateTime? from = _from;
    DateTime? to = _to;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16,
              16 + MediaQuery.of(ctx).viewPadding.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const Text('Filter inquiries',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 14),
              DropdownButtonFormField<String?>(
                initialValue: buyerId,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Buyer', isDense: true,
                    border: OutlineInputBorder()),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Any buyer')),
                  ...buyers.entries.map((e) => DropdownMenuItem(
                      value: e.key,
                      child: Text(e.value, overflow: TextOverflow.ellipsis))),
                ],
                onChanged: (v) => setSheet(() => buyerId = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: designId,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Design', isDense: true,
                    border: OutlineInputBorder()),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Any design')),
                  ...designs.entries.map((e) => DropdownMenuItem(
                      value: e.key,
                      child: Text(e.value, overflow: TextOverflow.ellipsis))),
                ],
                onChanged: (v) => setSheet(() => designId = v),
              ),
              if (brandNames.isNotEmpty) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: brandName,
                  isExpanded: true,
                  decoration: const InputDecoration(
                      labelText: 'Brand', isDense: true,
                      border: OutlineInputBorder()),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Any brand')),
                    ...brandNames.map((b) => DropdownMenuItem(
                        value: b,
                        child: Text(b, overflow: TextOverflow.ellipsis))),
                  ],
                  onChanged: (v) => setSheet(() => brandName = v),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        final d = await showDatePicker(
                          context: ctx,
                          initialDate: from ?? DateTime.now(),
                          firstDate: DateTime(2025),
                          lastDate: DateTime.now(),
                        );
                        if (d != null) setSheet(() => from = d);
                      },
                      child: Text('From: ${_fmtDate(from)}',
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        final d = await showDatePicker(
                          context: ctx,
                          initialDate: to ?? DateTime.now(),
                          firstDate: DateTime(2025),
                          lastDate: DateTime.now(),
                        );
                        if (d != null) setSheet(() => to = d);
                      },
                      child: Text('To: ${_fmtDate(to)}',
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  TextButton(
                    onPressed: () => setSheet(() {
                      buyerId = null;
                      designId = null;
                      brandName = null;
                      from = null;
                      to = null;
                    }),
                    child: const Text('Reset',
                        style: TextStyle(color: Colors.red)),
                  ),
                  const Spacer(),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _buyerId = buyerId;
                        _designId = designId;
                        _brandName = brandName;
                        _from = from;
                        _to = to;
                      });
                      Navigator.pop(ctx);
                    },
                    style: ElevatedButton.styleFrom(
                        backgroundColor: _navy, foregroundColor: Colors.white),
                    child: const Text('Apply'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Order card ──────────────────────────────────────────────────────────────
  Widget _orderCard(InquiryOrder o) {
    final (fg, bg) = _statusColors(o.status);
    final modified = o.updatedAt.difference(o.createdAt).inSeconds.abs() > 1;
    final sub = [
      if (o.contact.isNotEmpty) o.contact,
      if (o.city.isNotEmpty) o.city,
    ].join('  ·  ');

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(o.token,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                      color: bg, borderRadius: BorderRadius.circular(20)),
                  child: Text(_statusName(o.status),
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                          color: fg)),
                ),
                const Spacer(),
                Text('${o.totalBoxes} boxes',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: _navy)),
              ],
            ),
            // Connection code (shared in WhatsApp) — tap to copy.
            if (o.connectionCode.isNotEmpty) ...[
              const SizedBox(height: 4),
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: o.connectionCode));
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('Copied ${o.connectionCode}'),
                      duration: const Duration(seconds: 1)));
                },
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.tag, size: 12, color: Colors.grey.shade500),
                  const SizedBox(width: 2),
                  Text(o.connectionCode,
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                          color: Colors.grey.shade700)),
                  const SizedBox(width: 4),
                  Icon(Icons.copy, size: 11, color: Colors.grey.shade400),
                ]),
              ),
            ],
            const SizedBox(height: 6),
            Text(o.company.isEmpty ? 'Buyer' : o.company,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13)),
            // Editable customer hint — who the order is for (no profile stored).
            _hintRow(o),
            if (sub.isNotEmpty)
              Text(sub,
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
            const SizedBox(height: 4),
            Text(
              'Generated: ${_fmtDateTime(o.createdAt)}'
              '${modified ? '\nModified: ${_fmtDateTime(o.updatedAt)}' : ''}',
              style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600),
            ),
            if (o.designNames.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '${o.lineCount} design${o.lineCount == 1 ? '' : 's'}: ${o.designNames}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5),
              ),
            ],
            if (o.brands.isNotEmpty) ...[
              const SizedBox(height: 5),
              Wrap(
                spacing: 5,
                runSpacing: 4,
                children: [
                  for (final br in o.brands)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6A1B9A).withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.sell_outlined,
                            size: 11, color: Color(0xFF6A1B9A)),
                        const SizedBox(width: 3),
                        Text(br,
                            style: const TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF6A1B9A))),
                      ]),
                    ),
                ],
              ),
            ],
            if (o.isHeld) ...[
              const SizedBox(height: 6),
              _resChip(Icons.lock_outline,
                  '${o.heldBoxes} box${o.heldBoxes == 1 ? '' : 'es'} held (off buyer stock)',
                  const Color(0xFF6A1B9A)),
            ],
            const SizedBox(height: 8),
            _actions(o),
          ],
        ),
      ),
    );
  }

  // Editable customer-name hint — the stockist writes who this order is for
  // (no customer profile is stored). Tap to add/edit.
  Widget _hintRow(InquiryOrder o) {
    final has = o.customerHint.trim().isNotEmpty;
    return GestureDetector(
      onTap: () => _editHint(o),
      child: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(
          children: [
            Icon(has ? Icons.person_outline : Icons.person_add_alt_1_outlined,
                size: 13,
                color: has ? const Color(0xFF6A1B9A) : Colors.grey.shade500),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                has ? o.customerHint : 'Add customer name / hint',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontStyle: has ? FontStyle.normal : FontStyle.italic,
                  fontWeight: has ? FontWeight.w600 : FontWeight.normal,
                  color: has ? const Color(0xFF6A1B9A) : Colors.grey.shade500,
                ),
              ),
            ),
            Icon(Icons.edit, size: 11, color: Colors.grey.shade400),
          ],
        ),
      ),
    );
  }

  Future<void> _editHint(InquiryOrder o) async {
    final ctrl = TextEditingController(text: o.customerHint);
    final hint = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Customer name / hint'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          maxLength: 80,
          decoration: const InputDecoration(
            hintText: 'e.g. Ramesh (walk-in), site at Bopal…',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (hint == null) return; // cancelled
    await _run(() => _data.setInquiryHint(o.id, hint.trim()), 'Saved.');
  }

  Widget _resChip(IconData icon, String label, Color color) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w600, color: color)),
        ],
      );

  Widget _actions(InquiryOrder o) {
    final btns = <Widget>[
      _actionChip('Items', Icons.list_alt_outlined, _navy, () => _showItems(o)),
      // App/known-buyer orders send to their number; stockist-created orders
      // have no number but still offer WhatsApp (opens the chooser).
      if (o.phone.isNotEmpty || o.source == 'stockist')
        _actionChip('WhatsApp', Icons.chat, const Color(0xFF25D366),
            () => _whatsapp(o)),
      if (o.status == 'draft' || o.status == 'sent' || o.status == 'locked') ...[
        _actionChip('Hold', Icons.lock_outline, const Color(0xFF6A1B9A),
            () => _hold(o)),
        _actionChip('Hold selected', Icons.tune, const Color(0xFF6A1B9A),
            () => _holdSelected(o)),
      ],
      if (o.status == 'locked')
        _actionChip('Un-hold', Icons.lock_open_outlined,
            const Color(0xFFE65100), () => _unhold(o)),
      if (o.status == 'locked' || o.status == 'dispatching')
        _actionChip('Dispatch', Icons.local_shipping_outlined,
            const Color(0xFF00695C), () => _dispatch(o)),
      if (o.status != 'completed' && o.status != 'rejected')
        _actionChip('Reject', Icons.block_outlined, Colors.red.shade700,
            () => _reject(o)),
      // A rejected order can be permanently removed to keep the list clean.
      if (o.status == 'rejected')
        _actionChip('Delete', Icons.delete_outline, Colors.red.shade700,
            () => _delete(o)),
    ];
    return Wrap(spacing: 6, runSpacing: 6, children: btns);
  }

  Widget _actionChip(String label, IconData icon, Color color, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.35)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontSize: 11.5, fontWeight: FontWeight.bold, color: color)),
          ]),
        ),
      );

  // Create a stockist-own order (Phase E), then offer to send it on WhatsApp.
  Future<void> _addOrder() async {
    final res = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => const StockistAddOrderScreen()),
    );
    if (!mounted) return;
    await _load();
    if (res == null) return;
    // Find the freshly created order in the reloaded list to offer WhatsApp.
    final id = (res['id'] ?? '').toString();
    final created = _orders.where((o) => o.id == id);
    if (created.isNotEmpty) _whatsapp(created.first);
  }

  // ── Actions ───────────────────────────────────────────────────────────────
  Future<void> _whatsapp(InquiryOrder o) async {
    final digits = '${o.countryCode}${o.phone}'.replaceAll(RegExp(r'[^0-9]'), '');
    final who = o.customerHint.isNotEmpty
        ? o.customerHint
        : (o.company.isNotEmpty ? o.company : 'there');
    final code = o.connectionCode.isNotEmpty ? ' [${o.connectionCode}]' : '';
    final msg = 'Hello $who, regarding your order ${o.token}$code '
        '(${o.totalBoxes} boxes).';
    // App/known-buyer order → send straight to their number; a stockist-created
    // order has no stored number, so open the WhatsApp chooser to pick one.
    final uri = digits.isEmpty
        ? Uri.parse('https://wa.me/?text=${Uri.encodeComponent(msg)}')
        : Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(msg)}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  // Hold the WHOLE order — every line's full ordered quantity comes off the
  // buyer-facing stock (H_Quantity) and stays held until un-held or dispatched.
  Future<void> _hold(InquiryOrder o) async {
    await _run(() => _data.holdOrder(o.id),
        '${o.token} held — ${o.totalBoxes} box${o.totalBoxes == 1 ? '' : 'es'} off buyer stock.');
  }

  // Hold SELECTED quantities — a per-design picker (pre-filled to each line's
  // current hold, or its full ordered qty if nothing held yet).
  Future<void> _holdSelected(InquiryOrder o) async {
    final detail = await _data.getInquiryDetail(o.id);
    if (!mounted) return;
    final lines = ((detail?['lines'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    if (lines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No items to hold')));
      return;
    }
    // Pre-fill: if the order is already held, show each line's SAVED held qty
    // exactly (a deliberately-zeroed line stays 0); for a never-held order,
    // default every line to its full ordered quantity.
    final alreadyHeld = o.status == 'locked' || o.isHeld;
    final held = <String, int>{};
    for (final l in lines) {
      final id = (l['design_id'] ?? '').toString();
      final qty = (l['quantity'] as num?)?.toInt() ?? 0;
      final lineHeld = (l['line_held'] as num?)?.toInt() ?? 0;
      held[id] = alreadyHeld ? lineHeld : qty;
    }

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16,
              16 + MediaQuery.of(ctx).viewPadding.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              Text('Hold quantities · ${o.token}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 4),
              Text('Held boxes drop off the buyer-facing stock.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final l in lines)
                      _holdRow(l, held, setSheet),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    onPressed: () => setSheet(() {
                      for (final l in lines) {
                        held[(l['design_id'] ?? '').toString()] =
                            (l['quantity'] as num?)?.toInt() ?? 0;
                      }
                    }),
                    child: const Text('Hold all'),
                  ),
                  const Spacer(),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6A1B9A),
                        foregroundColor: Colors.white),
                    child: const Text('Apply hold'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true) return;
    final items = [
      for (final e in held.entries)
        {'design_id': e.key, 'held_qty': e.value},
    ];
    await _run(() => _data.holdOrderItems(o.id, items), '${o.token} hold updated.');
  }

  Widget _holdRow(
      Map<String, dynamic> l, Map<String, int> held, StateSetter setSheet) {
    final id = (l['design_id'] ?? '').toString();
    final name = (l['design_name'] ?? '').toString();
    final qty = (l['quantity'] as num?)?.toInt() ?? 0;
    final cur = held[id] ?? 0;
    void set(int v) => setSheet(() => held[id] = v.clamp(0, qty));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13)),
                Text('ordered $qty',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: cur > 0 ? () => set(cur - 1) : null,
          ),
          // Tap the number to type an exact quantity (clamped to the ordered qty).
          InkWell(
            onTap: () async {
              final v = await _promptQty(cur, qty);
              if (v != null) set(v);
            },
            borderRadius: BorderRadius.circular(6),
            child: Container(
              width: 48,
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('$cur',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: cur < qty ? () => set(cur + 1) : null,
          ),
        ],
      ),
    );
  }

  // Numeric entry for a hold quantity (clamped 0..max). Returns null on cancel.
  Future<int?> _promptQty(int current, int max) async {
    final ctrl = TextEditingController(text: '$current');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hold quantity'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            helperText: 'Max $max',
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (s) =>
              Navigator.pop(ctx, (int.tryParse(s.trim()) ?? current).clamp(0, max)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(
                ctx, (int.tryParse(ctrl.text.trim()) ?? current).clamp(0, max)),
            child: const Text('Set'),
          ),
        ],
      ),
    );
    return v;
  }

  Future<void> _unhold(InquiryOrder o) async {
    final ok = await _confirm('Un-hold ${o.token}?',
        'Releases all held boxes back to the buyer-facing stock. The order stays, '
        'ready to hold again.');
    if (!ok) return;
    await _run(() => _data.unholdOrder(o.id), '${o.token} released.');
  }

  Future<void> _dispatch(InquiryOrder o) async {
    final changed = await context.push<bool>('/stockist/inquiry/dispatch', extra: {
      'id': o.id,
      'token': o.token,
      'company': o.company,
      'phone': o.phone,
      'country_code': o.countryCode,
    });
    if (changed == true && mounted) _load();
  }

  Future<void> _reject(InquiryOrder o) async {
    final ok = await _confirm('Reject ${o.token}?',
        'Rejects ${o.company}\'s order and removes it from their basket. '
        'This cannot be undone.');
    if (!ok) return;
    await _run(() => _data.rejectOrder(o.id), '${o.token} rejected.');
  }

  Future<void> _delete(InquiryOrder o) async {
    final ok = await _confirm('Delete ${o.token}?',
        'Permanently removes this rejected order from your inquiry list. '
        'This cannot be undone.');
    if (!ok) return;
    await _run(() => _data.deleteInquiry(o.id), '${o.token} deleted.');
  }

  Future<bool> _confirm(String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Yes')),
        ],
      ),
    );
    return r == true;
  }

  Future<void> _run(Future<void> Function() action, String okMsg) async {
    try {
      await action();
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(okMsg), backgroundColor: const Color(0xFF2E7D32)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e'), backgroundColor: Colors.red));
    }
  }

  // Order line items (read-only here; editing/dispatch comes from the Dispatch flow).
  Future<void> _showItems(InquiryOrder o) async {
    final detail = await _data.getInquiryDetail(o.id);
    if (!mounted) return;
    final lines = (detail?['lines'] as List?) ?? const [];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.85,
        builder: (ctx, scroll) => Column(
          children: [
            Container(
              width: 40, height: 4,
              margin: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Text('${o.token} · ${o.statusLabel}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: lines.isEmpty
                  ? const Center(
                      child: Text('No items', style: TextStyle(color: Colors.grey)))
                  : ListView.separated(
                      controller: scroll,
                      padding: const EdgeInsets.all(12),
                      itemCount: lines.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (_, i) {
                        final l = Map<String, dynamic>.from(lines[i] as Map);
                        final img = (l['image'] ?? '').toString();
                        final qty = (l['quantity'] as num?)?.toInt() ?? 0;
                        final disp = (l['dispatched_qty'] as num?)?.toInt() ?? 0;
                        final avail = (l['available'] as num?)?.toInt() ?? 0;
                        return Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade200),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: img.isEmpty
                                    ? Container(
                                        width: 48, height: 48,
                                        color: Colors.grey.shade100,
                                        child: const Icon(
                                            Icons.image_not_supported,
                                            size: 20, color: Colors.grey))
                                    : CachedNetworkImage(
                                        imageUrl: CloudinaryService.thumbUrl(
                                            img, width: 200),
                                        width: 48, height: 48, fit: BoxFit.cover,
                                        placeholder: (_, __) => Container(
                                            color: Colors.grey.shade200),
                                        errorWidget: (_, __, ___) => Container(
                                            color: Colors.grey.shade200)),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text((l['design_name'] ?? '').toString(),
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13)),
                                    Text(
                                        '${(l['size'] ?? '').toString().replaceAll(' mm', '')} · '
                                        '${(l['surface'] ?? '').toString()}',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey.shade600)),
                                    if (disp > 0)
                                      Text('Dispatched: $disp',
                                          style: const TextStyle(
                                              fontSize: 11,
                                              color: Color(0xFFE65100))),
                                  ],
                                ),
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text('$qty boxes',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13, color: _navy)),
                                  Text('stock $avail',
                                      style: TextStyle(
                                          fontSize: 10.5,
                                          color: avail >= qty
                                              ? Colors.green.shade700
                                              : Colors.red.shade700)),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
