import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/inquiry_order.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../utils/order_message.dart';
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
      'locked'      => (const Color(0xFF6A1B9A), const Color(0xFFF3E5F5)),
      'dispatching' => (const Color(0xFFE65100), const Color(0xFFFFF3E0)),
      'completed'   => (const Color(0xFF2E7D32), const Color(0xFFE8F5E9)),
      'rejected'    => (const Color(0xFFC62828), const Color(0xFFFFEBEE)),
      _             => (Colors.grey.shade700, const Color(0xFFF5F5F5)),
    };

// Filter-chip / status display name. In the Hold model, a 'locked' order is one
// the stockist has HELD (boxes reserved off buyer-facing stock).
String _statusName(String s) => switch (s) {
      'ready'       => 'Ready orders',
      'sent'        => 'Sent',
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
  String? _expandedId; // accordion — only one order expanded at a time
  String? _buyerId;
  String? _designId;
  String? _brandName; // multi-brand filter (non-default brand name)
  DateTime? _from;
  DateTime? _to;
  final _searchCtrl = TextEditingController();

  // Completed orders are kept only under the dedicated "Completed" tab (a record),
  // and hidden from every other tab.
  static const _statuses = [
    'all', 'ready', 'sent', 'locked', 'dispatching', 'completed', 'rejected'
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
    // Completed orders are hidden from every tab EXCEPT the dedicated "Completed"
    // tab, where they're kept as a record.
    var list = _orders.where((o) {
      if (_status == 'completed') return o.status == 'completed';
      if (o.status == 'completed') return false;
      if (_status == 'ready') return o.isReadyOrder;
      if (_status != 'all') return o.status == _status;
      return true;
    }).toList();
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
        title: const Text('Inq/Ready Order'),
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
        label: const Text('Add Order from Stock'),
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
          ? _orders.where((o) => o.status != 'completed').length
          : s == 'ready'
              ? _orders
                  .where((o) => o.isReadyOrder && o.status != 'completed')
                  .length
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
    final expanded = _expandedId == o.id;
    // 👥 WHO the order is for, best answer first: the app buyer's company, else the SAVED
    // customer, else the free note. The saved customer used to be skipped entirely, so an order
    // booked for "pratap ceramic, gorakhpur" showed as just the note he happened to type.
    final buyerName = o.company.trim().isNotEmpty
        ? o.company.trim()
        : (o.customerName.trim().isNotEmpty
            ? o.customerName.trim()
            : o.customerHint.trim());
    // Primary line = buyer name if we have one, else the order number. Secondary
    // (small grey) = the note (when it is not already the title) + INQ + #C code.
    final primary = buyerName.isNotEmpty ? buyerName : o.token;
    final note = o.customerHint.trim();
    final secondary = [
      if (note.isNotEmpty && note != buyerName) note,
      if (buyerName.isNotEmpty) o.token,
      if (o.connectionCode.isNotEmpty) '#${o.connectionCode}',
    ].join('  ·  ');

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Collapsed header (tap to expand; accordion) ──
          InkWell(
            onTap: () =>
                setState(() => _expandedId = expanded ? null : o.id),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(primary,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14)),
                            ),
                            // 🔖 Minted from a booked order (order-from-stock).
                            if (o.isReadyOrder) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                    color: const Color(0xFF6A1B9A)
                                        .withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(6)),
                                child: const Text('Ready order',
                                    style: TextStyle(
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w800,
                                        color: Color(0xFF6A1B9A))),
                              ),
                            ],
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                  color: bg,
                                  borderRadius: BorderRadius.circular(20)),
                              child: Text(_statusName(o.status),
                                  style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.bold,
                                      color: fg)),
                            ),
                          ],
                        ),
                        if (secondary.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(secondary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey.shade600)),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${o.totalBoxes} boxes',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                          color: _navy)),
                  Icon(expanded ? Icons.expand_less : Icons.expand_more,
                      color: Colors.grey.shade500),
                ],
              ),
            ),
          ),
          // ── Expanded detail ──
          if (expanded) _orderDetail(o),
        ],
      ),
    );
  }

  Widget _orderDetail(InquiryOrder o) {
    final modified = o.updatedAt.difference(o.createdAt).inSeconds.abs() > 1;
    final sub = [
      if (o.contact.isNotEmpty) o.contact,
      if (o.city.isNotEmpty) o.city,
    ].join('  ·  ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1),
          const SizedBox(height: 8),
          if (o.connectionCode.isNotEmpty)
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
              maxLines: 3,
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
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
    // Quick buttons = the two most-used (Hold/Un-hold + Dispatch); everything
    // else goes in the "More" dropdown so nothing needs left/right swiping.
    final quick = <Widget>[
      if (o.status == 'draft' || o.status == 'sent' || o.status == 'locked')
        if (o.isHeld)
          _actionChip('Un-hold', Icons.lock_open_outlined,
              const Color(0xFFE65100), () => _unhold(o))
        else
          _actionChip('Hold', Icons.lock_outline, const Color(0xFF6A1B9A),
              () => _hold(o)),
      if (o.status == 'locked' || o.status == 'dispatching') ...[
        // Prepare the truck's pull sheet first; Dispatch records it after loading.
        _actionChip('Loading list', Icons.playlist_add_check_outlined, _navy,
            () => _loadingList(o)),
        _actionChip('Dispatch', Icons.local_shipping_outlined,
            const Color(0xFF00695C), () => _dispatch(o)),
      ],
    ];
    final canEdit =
        (o.status == 'draft' || o.status == 'sent') && o.endUserId.isEmpty;
    final canReject = o.status != 'completed' && o.status != 'rejected';
    final canDelete = o.status == 'rejected';
    return Row(
      children: [
        for (final w in quick)
          Padding(padding: const EdgeInsets.only(right: 6), child: w),
        const Spacer(),
        PopupMenuButton<String>(
          tooltip: 'More actions',
          onSelected: (v) {
            switch (v) {
              case 'items':
                _showItems(o);
              case 'share':
                _shareOrder(o);
              case 'edit':
                _editOrder(o);
              case 'reject':
                _reject(o);
              case 'delete':
                _delete(o);
            }
          },
          itemBuilder: (_) => [
            _menuItem('items', 'Items', Icons.list_alt_outlined, _navy),
            _menuItem('share', 'Send order', Icons.ios_share, _navy),
            if (canEdit) _menuItem('edit', 'Edit', Icons.edit_outlined, _navy),
            if (canReject)
              _menuItem('reject', 'Reject', Icons.block_outlined,
                  Colors.red.shade700),
            if (canDelete)
              _menuItem('delete', 'Delete', Icons.delete_outline,
                  Colors.red.shade700),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              border: Border.all(color: _navy.withValues(alpha: 0.4)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Text('More',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _navy)),
              Icon(Icons.arrow_drop_down, color: _navy, size: 20),
            ]),
          ),
        ),
      ],
    );
  }

  PopupMenuItem<String> _menuItem(
          String value, String label, IconData icon, Color color) =>
      PopupMenuItem<String>(
        value: value,
        child: Row(children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Text(label,
              style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        ]),
      );

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
    // Find the freshly created order → WhatsApp if we have a number, else Copy.
    final id = (res['id'] ?? '').toString();
    final created = _orders.where((o) => o.id == id);
    if (created.isNotEmpty) _shareOrder(created.first);
  }

  // Edit an OPEN, no-buyer order — reuses the add-order screen pre-filled with
  // the order's current hint + lines; saves via update_order_items.
  Future<void> _editOrder(InquiryOrder o) async {
    final detail = await _data.getInquiryDetail(o.id);
    if (!mounted) return;
    final lines = ((detail?['lines'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .map((l) => {'design_id': l['design_id'], 'quantity': l['quantity']})
        .toList();
    final res = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => StockistAddOrderScreen(
          orderId: o.id,
          initialHint: o.customerHint,
          initialLines: lines,
        ),
      ),
    );
    if (!mounted) return;
    if (res != null) {
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Order updated.'),
          backgroundColor: Color(0xFF2E7D32)));
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  // Build the full order message (size-grouped list) for WhatsApp/Copy.
  Future<String> _orderMessage(InquiryOrder o) async {
    final detail = await _data.getInquiryDetail(o.id);
    final lines = ((detail?['lines'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map));
    return buildOrderMessage([
      for (final l in lines)
        (
          name: (l['design_name'] ?? '').toString(),
          size: (l['size'] ?? '').toString(),
          surface: (l['surface'] ?? '').toString(),
          quality: (l['quality'] ?? '').toString(),
          qty: (l['quantity'] as num?)?.toInt() ?? 0,
        ),
    ], orderNo: o.token, connectionCode: o.connectionCode);
  }

  // Digits for wa.me — only when a REAL phone is on file (a lone country code
  // must not count).
  String _waDigits(InquiryOrder o) => o.phone.trim().isEmpty
      ? ''
      : '${o.countryCode}${o.phone}'.replaceAll(RegExp(r'[^0-9]'), '');

  // Share sheet with BOTH Copy and WhatsApp. WhatsApp uses the buyer's number if
  // on file, else opens the chooser so the stockist picks the chat.
  Future<void> _shareSheet(String message, {String digits = ''}) async {
    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2)),
              ),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: message));
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text('Copied — paste it in your chat.'),
                            backgroundColor: Color(0xFF2E7D32)));
                      }
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy'),
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      final uri = digits.isEmpty
                          ? Uri.parse(
                              'https://wa.me/?text=${Uri.encodeComponent(message)}')
                          : Uri.parse(
                              'https://wa.me/$digits?text=${Uri.encodeComponent(message)}');
                      if (ctx.mounted) Navigator.pop(ctx);
                      await launchUrl(uri, mode: LaunchMode.externalApplication);
                    },
                    icon: const Icon(Icons.chat, size: 18),
                    label: const Text('WhatsApp'),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF25D366),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13)),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  // Share the order — Copy and/or WhatsApp (both offered).
  Future<void> _shareOrder(InquiryOrder o) async {
    final msg = await _orderMessage(o);
    if (!mounted) return;
    await _shareSheet(msg, digits: _waDigits(o));
  }

  // Hold the WHOLE order — every line's full ordered quantity comes off the
  // buyer-facing stock (H_Quantity) and stays held until un-held or dispatched.
  Future<void> _hold(InquiryOrder o) async {
    await _run(() => _data.holdOrder(o.id),
        '${o.token} held — ${o.totalBoxes} box${o.totalBoxes == 1 ? '' : 'es'} off buyer stock.');
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

  /// Opens the one dispatch screen with this order pre-attached. The stock mode
  /// is no longer asked up-front — it's a radio pair on that screen, confirmed
  /// there behind the blinking countdown. (project_unified_dispatch_customers)
  Future<void> _dispatch(InquiryOrder o) async {
    final changed = await context.push<bool>('/stockist/dispatch/manual', extra: {
      'id': o.id,
    });
    if (changed == true && mounted) _load();
  }

  /// Prepare a loading list for this order — its designs prefill, and the
  /// stockist sets batches + boxes before the truck loads. (Loading List · LL4)
  Future<void> _loadingList(InquiryOrder o) async {
    await context.push('/stockist/loading-lists/edit', extra: {'inquiry_id': o.id});
    if (mounted) _load();
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

  // Items = order detail + partial-hold editor in one place. Each line shows the
  // ORIGINAL ordered qty and its (editable) HELD qty. Holdable orders
  // (draft/sent/locked) can adjust holds here and Save; others are read-only.
  Future<void> _showItems(InquiryOrder o) async {
    final detail = await _data.getInquiryDetail(o.id);
    if (!mounted) return;
    final lines = ((detail?['lines'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final holdable =
        o.status == 'draft' || o.status == 'sent' || o.status == 'locked';
    // Pre-fill held: saved line_held if already held, else full ordered qty.
    final alreadyHeld = o.isHeld || o.status == 'locked';
    final held = <String, int>{};
    for (final l in lines) {
      final id = (l['design_id'] ?? '').toString();
      final qty = (l['quantity'] as num?)?.toInt() ?? 0;
      final lineHeld = (l['line_held'] as num?)?.toInt() ?? 0;
      held[id] = alreadyHeld ? lineHeld : qty;
    }

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.9,
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
                    Text('${o.token} · ${_statusName(o.status)}',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                    const Spacer(),
                    Text('Ordered  ·  Hold',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade600)),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: lines.isEmpty
                    ? const Center(
                        child:
                            Text('No items', style: TextStyle(color: Colors.grey)))
                    : ListView.separated(
                        controller: scroll,
                        padding: const EdgeInsets.all(12),
                        itemCount: lines.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        itemBuilder: (_, i) {
                          final l = lines[i];
                          final id = (l['design_id'] ?? '').toString();
                          final img = (l['image'] ?? '').toString();
                          final qty = (l['quantity'] as num?)?.toInt() ?? 0;
                          final disp = (l['dispatched_qty'] as num?)?.toInt() ?? 0;
                          final hv = held[id] ?? 0;
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
                                          width: 48, height: 48,
                                          fit: BoxFit.cover,
                                          placeholder: (_, __) => Container(
                                              color: Colors.grey.shade200),
                                          errorWidget: (_, __, ___) => Container(
                                              color: Colors.grey.shade200)),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
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
                                const SizedBox(width: 8),
                                // Original ordered qty (grey) → held qty (purple,
                                // editable for holdable orders).
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text('Ordered $qty',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey.shade700)),
                                    const SizedBox(height: 4),
                                    if (holdable)
                                      InkWell(
                                        onTap: () async {
                                          final v = await _promptQty(hv, qty);
                                          if (v != null) {
                                            setSheet(() => held[id] = v);
                                          }
                                        },
                                        borderRadius: BorderRadius.circular(8),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10, vertical: 5),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF6A1B9A)
                                                .withValues(alpha: 0.06),
                                            border: Border.all(
                                                color: const Color(0xFF6A1B9A)),
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text('Hold $hv',
                                                  style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      fontSize: 14,
                                                      color: Color(0xFF6A1B9A))),
                                              const SizedBox(width: 3),
                                              const Icon(Icons.edit,
                                                  size: 12,
                                                  color: Color(0xFF6A1B9A)),
                                            ],
                                          ),
                                        ),
                                      )
                                    else
                                      Text('Held $hv',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 13,
                                              color: Color(0xFF6A1B9A))),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              if (holdable)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                    child: Row(
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
                        TextButton(
                          onPressed: () => setSheet(() {
                            for (final k in held.keys.toList()) {
                              held[k] = 0;
                            }
                          }),
                          child: const Text('Hold none'),
                        ),
                        const Spacer(),
                        ElevatedButton.icon(
                          onPressed: () => Navigator.pop(ctx, true),
                          icon: const Icon(Icons.lock_outline, size: 16),
                          label: const Text('Save hold'),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF6A1B9A),
                              foregroundColor: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (saved != true) return;
    final items = [
      for (final e in held.entries) {'design_id': e.key, 'held_qty': e.value},
    ];
    await _run(() => _data.holdOrderItems(o.id, items), '${o.token} hold updated.');
  }
}
