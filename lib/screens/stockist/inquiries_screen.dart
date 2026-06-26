import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/inquiry_order.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';

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

// Filter-chip / status display name. The buyer "sends" an inquiry; the stockist's
// lock ('locked') is shown as the real "Confirmed".
String _statusName(String s) => switch (s) {
      'sent'        => 'Sent',
      'confirmed'   => 'Sent',
      'locked'      => 'Confirmed',
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
                hintText: 'Search token, buyer, design, phone…',
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
                  child: Text(o.statusLabel,
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
            const SizedBox(height: 6),
            Text(o.company.isEmpty ? 'Buyer' : o.company,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13)),
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
            if (_reservationLine(o) != null) ...[
              const SizedBox(height: 6),
              _reservationLine(o)!,
            ],
            const SizedBox(height: 8),
            _actions(o),
          ],
        ),
      ),
    );
  }

  // A small reservation/acceptance status line for a confirmed (locked) order.
  Widget? _reservationLine(InquiryOrder o) {
    if (o.isAccepted) {
      return _resChip(Icons.handshake_outlined, 'Accepted by buyer',
          const Color(0xFF2E7D32));
    }
    if (o.reservationActive) {
      return _resChip(Icons.timer_outlined,
          'Reserved · ${o.daysLeft} day${o.daysLeft == 1 ? '' : 's'} left',
          const Color(0xFF1565C0));
    }
    if (o.reservationExpired) {
      return _resChip(Icons.timer_off_outlined,
          'Reservation expired — buyer didn\'t accept', const Color(0xFFE65100));
    }
    return null;
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
      if (o.phone.isNotEmpty)
        _actionChip('WhatsApp', Icons.chat, const Color(0xFF25D366),
            () => _whatsapp(o)),
      if (o.status == 'draft' || o.status == 'sent')
        _actionChip('Confirm Order', Icons.check_circle_outline,
            const Color(0xFF2E7D32), () => _confirmOrder(o)),
      if (o.status == 'locked')
        _actionChip('Reopen', Icons.lock_open_outlined, const Color(0xFFE65100),
            () => _reopen(o)),
      if (o.status == 'locked' || o.status == 'dispatching')
        _actionChip('Dispatch', Icons.local_shipping_outlined,
            const Color(0xFF00695C), () => _dispatch(o)),
      if (o.status != 'completed' && o.status != 'rejected')
        _actionChip('Reject', Icons.block_outlined, Colors.red.shade700,
            () => _reject(o)),
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

  // ── Actions ───────────────────────────────────────────────────────────────
  Future<void> _whatsapp(InquiryOrder o) async {
    final digits = '${o.countryCode}${o.phone}'.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return;
    final msg = 'Hello ${o.company}, regarding your order ${o.token} '
        '(${o.totalBoxes} boxes).';
    final uri = Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(msg)}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _confirmOrder(InquiryOrder o) async {
    final days = await _askGuaranteeDays(o);
    if (days == null) return; // cancelled
    await _run(() => _data.lockInquiry(o.id, days: days),
        days > 0
            ? '${o.token} confirmed — reserved for $days day${days == 1 ? '' : 's'}.'
            : '${o.token} confirmed.');
  }

  /// Confirm dialog that also captures the guarantee window (N days the boxes are
  /// reserved for this buyer). Returns the chosen days (0 = no reservation), or
  /// null if cancelled. (project_fstock_model · Phase 2)
  Future<int?> _askGuaranteeDays(InquiryOrder o) async {
    int days = 7; // sensible default
    final ctrl = TextEditingController(text: '7');
    const presets = [3, 7, 15, 30];
    return showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          void setDays(int d) {
            setD(() {
              days = d;
              ctrl.text = d == 0 ? '' : '$d';
            });
          }

          return AlertDialog(
            title: Text('Confirm ${o.token}?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Confirming locks the order — the buyer can no longer change it. '
                  'It becomes ready for dispatch.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
                const Text('Reserve the boxes for the buyer for:',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final p in presets)
                      ChoiceChip(
                        label: Text('$p d'),
                        selected: days == p,
                        onSelected: (_) => setDays(p),
                      ),
                    ChoiceChip(
                      label: const Text('None'),
                      selected: days == 0,
                      onSelected: (_) => setDays(0),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    SizedBox(
                      width: 70,
                      child: TextField(
                        controller: ctrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            isDense: true, border: OutlineInputBorder()),
                        onChanged: (v) =>
                            setD(() => days = int.tryParse(v.trim()) ?? 0),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text('days', style: TextStyle(fontSize: 13)),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  days > 0
                      ? 'These boxes are held off the buyer-facing stock for '
                          '$days day${days == 1 ? '' : 's'}. The buyer can Accept to '
                          'keep them locked; otherwise they auto-release.'
                      : 'No time reservation — boxes are only held once the buyer Accepts.',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
                ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, days < 0 ? 0 : days),
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2E7D32),
                    foregroundColor: Colors.white),
                child: const Text('Confirm'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _reopen(InquiryOrder o) async {
    final ok = await _confirm('Reopen ${o.token}?',
        'This lets the buyer change the order again and clears the confirmed copy.');
    if (!ok) return;
    await _run(() => _data.unlockInquiry(o.id), '${o.token} reopened.');
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
