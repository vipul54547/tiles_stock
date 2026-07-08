import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../config/app_config.dart';
import '../../services/supabase_data_service.dart';

/// A flat, newest-first log of every dispatch this stockist has recorded —
/// across all designs. Reached from the dashboard's "Records" action.
/// Supports three combinable filters: date range, design, and buyer.
class AllDispatchesScreen extends StatefulWidget {
  const AllDispatchesScreen({super.key});
  @override
  State<AllDispatchesScreen> createState() => _State();
}

enum _DatePreset { all, today, week, month, custom }

class _State extends State<AllDispatchesScreen> {
  final _dataSvc = SupabaseDataService();

  List<Map<String, dynamic>> _all = []; // full set, newest-first from the DB
  bool _loading = true;

  // Filters
  _DatePreset _datePreset = _DatePreset.all;
  DateTimeRange? _customRange;
  String? _designFilter; // design name
  String? _buyerFilter;  // buyer name
  String? _expandedKey;  // accordion — one dispatch event open at a time

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rows = await _dataSvc.getAllDispatches();
    if (!mounted) return;
    setState(() {
      _all = rows;
      _loading = false;
    });
  }

  // ── Filtering ───────────────────────────────────────────────────────────────

  String _designName(Map<String, dynamic> r) {
    final d = r['designs'];
    return (d is Map ? d['name'] : null)?.toString() ?? 'Unknown design';
  }

  DateTimeRange? _activeDateRange() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (_datePreset) {
      case _DatePreset.all:
        return null;
      case _DatePreset.today:
        return DateTimeRange(start: today, end: today);
      case _DatePreset.week:
        // Current week starting Monday.
        final monday = today.subtract(Duration(days: today.weekday - 1));
        return DateTimeRange(start: monday, end: today);
      case _DatePreset.month:
        return DateTimeRange(
            start: DateTime(now.year, now.month, 1), end: today);
      case _DatePreset.custom:
        return _customRange;
    }
  }

  List<Map<String, dynamic>> get _filtered {
    final range = _activeDateRange();
    return _all.where((r) {
      if (_designFilter != null && _designName(r) != _designFilter) {
        return false;
      }
      if (_buyerFilter != null &&
          (r['buyer_name'] ?? '').toString() != _buyerFilter) {
        return false;
      }
      if (range != null) {
        final dt = DateTime.tryParse(r['created_at']?.toString() ?? '')
            ?.toLocal();
        if (dt == null) return false;
        final day = DateTime(dt.year, dt.month, dt.day);
        if (day.isBefore(range.start) || day.isAfter(range.end)) return false;
      }
      return true;
    }).toList(); // _all is already newest-first, so order is preserved.
  }

  bool get _hasFilters =>
      _datePreset != _DatePreset.all ||
      _designFilter != null ||
      _buyerFilter != null;

  // Group the filtered dispatch rows into dispatch EVENTS — one per dispatch note
  // (rows without a note stand alone). Newest-first order preserved. When a design
  // filter is active, each group only carries that design's line(s).
  List<({String key, List<Map<String, dynamic>> rows})> get _groups {
    final order = <String>[];
    final map = <String, List<Map<String, dynamic>>>{};
    for (final r in _filtered) {
      final key = (r['dispatch_note_id'] ?? 'row:${r['id']}').toString();
      if (!map.containsKey(key)) order.add(key);
      (map[key] ??= []).add(r);
    }
    return [for (final k in order) (key: k, rows: map[k]!)];
  }

  Map<String, dynamic> _note(Map<String, dynamic> r) {
    final n = r['dispatch_notes'];
    return n is Map ? Map<String, dynamic>.from(n) : const {};
  }

  int _boxesOf(List<Map<String, dynamic>> rows) => rows.fold(
      0, (s, r) => s + ((r['quantity_dispatched'] as num?)?.toInt() ?? 0));

  List<String> get _designOptions =>
      _all.map(_designName).toSet().toList()..sort();

  List<String> get _buyerOptions => _all
      .map((r) => (r['buyer_name'] ?? '').toString())
      .where((b) => b.isNotEmpty)
      .toSet()
      .toList()
    ..sort();

  String get _dateLabel {
    switch (_datePreset) {
      case _DatePreset.all:
        return 'Any date';
      case _DatePreset.today:
        return 'Today';
      case _DatePreset.week:
        return 'This week';
      case _DatePreset.month:
        return 'This month';
      case _DatePreset.custom:
        final r = _customRange;
        if (r == null) return 'Custom';
        return '${_short(r.start)} – ${_short(r.end)}';
    }
  }

  String _short(DateTime d) => '${d.day}/${d.month}';

  // ── Filter actions ──────────────────────────────────────────────────────────

  Future<void> _pickDate() async {
    final selected = await showModalBottomSheet<_DatePreset>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            const Text('Filter by date',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            for (final p in [
              (_DatePreset.all, 'Any date', Icons.all_inclusive),
              (_DatePreset.today, 'Today', Icons.today),
              (_DatePreset.week, 'This week', Icons.view_week_outlined),
              (_DatePreset.month, 'This month', Icons.calendar_month_outlined),
              (_DatePreset.custom, 'Custom range…', Icons.date_range_outlined),
            ])
              ListTile(
                leading: Icon(p.$3, color: const Color(0xFF6A1B9A)),
                title: Text(p.$2),
                trailing: _datePreset == p.$1
                    ? const Icon(Icons.check, color: Color(0xFF6A1B9A))
                    : null,
                onTap: () => Navigator.pop(context, p.$1),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;

    if (selected == _DatePreset.custom) {
      final now = DateTime.now();
      final range = await showDateRangePicker(
        context: context,
        firstDate: DateTime(now.year - 5),
        lastDate: now,
        initialDateRange: _customRange,
      );
      if (range == null) return;
      setState(() {
        _datePreset = _DatePreset.custom;
        _customRange = range;
      });
    } else {
      setState(() => _datePreset = selected);
    }
  }

  Future<void> _pickFromList(
      String title, List<String> options, String? current,
      ValueChanged<String?> onPick) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Text(title,
                  style:
                      const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 4),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.clear_all),
                      title: const Text('All'),
                      trailing: current == null
                          ? const Icon(Icons.check, color: Color(0xFF6A1B9A))
                          : null,
                      onTap: () => Navigator.pop(context, ''), // sentinel
                    ),
                    for (final o in options)
                      ListTile(
                        title: Text(o),
                        trailing: current == o
                            ? const Icon(Icons.check,
                                color: Color(0xFF6A1B9A))
                            : null,
                        onTap: () => Navigator.pop(context, o),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null) return; // dismissed
    onPick(selected == '' ? null : selected);
  }

  void _clearFilters() => setState(() {
        _datePreset = _DatePreset.all;
        _customRange = null;
        _designFilter = null;
        _buyerFilter = null;
      });

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('All Dispatches'),
        actions: [
          if (_hasFilters)
            TextButton(
              onPressed: _clearFilters,
              child: const Text('Clear',
                  style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildFilterRow(),
                Expanded(child: _buildList()),
              ],
            ),
    );
  }

  Widget _buildFilterRow() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _filterChip(
                Icons.date_range_outlined,
                _dateLabel,
                _datePreset != _DatePreset.all,
                _pickDate),
            const SizedBox(width: 8),
            _filterChip(
                Icons.grid_view_rounded,
                _designFilter ?? 'All designs',
                _designFilter != null,
                () => _pickFromList('Filter by design', _designOptions,
                    _designFilter, (v) => setState(() => _designFilter = v))),
            const SizedBox(width: 8),
            _filterChip(
                Icons.business_outlined,
                _buyerFilter ?? 'All buyers',
                _buyerFilter != null,
                () => _pickFromList('Filter by buyer', _buyerOptions,
                    _buyerFilter, (v) => setState(() => _buyerFilter = v))),
          ],
        ),
      ),
    );
  }

  Widget _filterChip(
      IconData icon, String label, bool active, VoidCallback onTap) {
    const accent = Color(0xFF6A1B9A);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? accent.withValues(alpha: 0.1) : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: active ? accent : Colors.grey.shade300,
              width: active ? 1.5 : 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: active ? accent : Colors.grey.shade600),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: active ? accent : Colors.grey.shade700)),
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down,
                size: 18, color: active ? accent : Colors.grey.shade600),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    final groups = _groups;
    if (groups.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.local_shipping_outlined,
                        size: 72, color: Colors.grey.shade300),
                    const SizedBox(height: 16),
                    Text(
                        _all.isEmpty
                            ? 'No dispatches yet'
                            : 'No dispatches match these filters',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey.shade500)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final totalBoxes =
        groups.fold(0, (s, g) => s + _boxesOf(g.rows));
    final header = _designFilter != null
        ? '$_designFilter · ${groups.length} dispatches · $totalBoxes boxes'
        : '${groups.length} dispatches · $totalBoxes boxes total';

    return RefreshIndicator(
      onRefresh: _load,
      child: Column(
        children: [
          Container(
            width: double.infinity,
            color: Colors.red.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(header,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.red.shade700)),
          ),
          Expanded(
            child: ListView.separated(
              padding: EdgeInsets.fromLTRB(
                  12, 12, 12, 12 + MediaQuery.viewPaddingOf(context).bottom),
              itemCount: groups.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _dispatchGroupCard(groups[i]),
            ),
          ),
        ],
      ),
    );
  }

  // Date only, e.g. "4 Jul 2026" (collapsed row). [iso] may be a date or datetime.
  String _dateOnly(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  String _formatDate(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ap = dt.hour < 12 ? 'AM' : 'PM';
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}, $h:$m $ap';
  }

  // One dispatch EVENT (grouped) — collapsed to buyer + boxes + DSP·date·truck;
  // tap to expand the design lines + time + invoice/vehicle/transporter.
  Widget _dispatchGroupCard(({String key, List<Map<String, dynamic>> rows}) g) {
    final rows = g.rows;
    final first = rows.first;
    final note = _note(first);
    final buyer = (first['buyer_name'] ?? '').toString().trim();
    final primary = buyer.isNotEmpty ? buyer : 'Walk-in';
    final total = _boxesOf(rows);
    final dispNo = (note['dispatch_no'] ?? '').toString().trim();
    final vehicle = (note['vehicle_no'] ?? '').toString().trim();
    final dateStr =
        _dateOnly(note['dispatched_on']?.toString() ?? first['created_at']?.toString());
    final expanded = _expandedKey == g.key;

    final secondary = [
      if (dispNo.isNotEmpty) dispNo,
      if (dateStr.isNotEmpty) dateStr,
      if (vehicle.isNotEmpty) '🚚 $vehicle',
    ].join('  ·  ');

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () =>
                setState(() => _expandedKey = expanded ? null : g.key),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8)),
                    child: Icon(Icons.local_shipping_outlined,
                        size: 20, color: Colors.red.shade700),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(primary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 14)),
                        if (secondary.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(secondary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11.5,
                                    color: Colors.grey.shade600)),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('$total boxes',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                          color: Colors.red.shade700)),
                  Icon(expanded ? Icons.expand_less : Icons.expand_more,
                      color: Colors.grey.shade500),
                ],
              ),
            ),
          ),
          if (expanded) _groupDetail(rows, note),
        ],
      ),
    );
  }

  Widget _groupDetail(
      List<Map<String, dynamic>> rows, Map<String, dynamic> note) {
    final first = rows.first;
    final orderRef = (first['notes'] ?? '').toString().trim();
    final invoice = (note['invoice_no'] ?? '').toString().trim();
    final vehicle = (note['vehicle_no'] ?? '').toString().trim();
    final transporter = (note['transporter'] ?? '').toString().trim();
    final meta = [
      if (invoice.isNotEmpty) '🧾 $invoice',
      if (vehicle.isNotEmpty) '🚚 $vehicle',
      if (transporter.isNotEmpty) transporter,
    ].join('   ·   ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1),
          const SizedBox(height: 6),
          Text(_formatDate(first['created_at']?.toString()),
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          if (orderRef.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(orderRef,
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade700)),
            ),
          const SizedBox(height: 6),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(_designName(r),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                  ),
                  Text('${(r['quantity_dispatched'] as num?)?.toInt() ?? 0}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13)),
                ],
              ),
            ),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(meta,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ],
          // A dispatch link + PDF are per-dispatch-note actions. Note-less
          // walk-in rows (no dispatch_note_id) can't be linked.
          if ((first['dispatch_note_id'] ?? '').toString().isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _dispatchLink(
                        first['dispatch_note_id'].toString()),
                    icon: const Icon(Icons.link, size: 17),
                    label: const Text('Dispatch link',
                        style: TextStyle(fontSize: 12.5)),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF6A1B9A),
                        padding: const EdgeInsets.symmetric(vertical: 9)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _createPdfStub,
                    icon: const Icon(Icons.picture_as_pdf_outlined, size: 17),
                    label: const Text('Create PDF',
                        style: TextStyle(fontSize: 12.5)),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.grey.shade700,
                        padding: const EdgeInsets.symmetric(vertical: 9)),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // Mint (or reuse) a login-free dispatch link and offer to share it. There's no
  // buyer phone in this flat log, so we lead with Copy (per the no-phone rule)
  // and offer a generic WhatsApp share the stockist can aim at any contact.
  Future<void> _dispatchLink(String noteId) async {
    try {
      final token = await _dataSvc.createDispatchLink(noteId);
      if (!mounted || token == null || token.isEmpty) return;
      final url = '${AppConfig.shareBaseUrl}/d/$token';
      final msg = 'Dispatch details:\n$url';
      await _shareLinkSheet(url, msg);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _shareLinkSheet(String url, String msg) async {
    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Share dispatch link',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(url,
                    style: const TextStyle(fontSize: 12.5)),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: url));
                        if (ctx.mounted) Navigator.pop(ctx);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Link copied.'),
                                  backgroundColor: Color(0xFF2E7D32)));
                        }
                      },
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Copy link'),
                      style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 13)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        final uri = Uri.parse(
                            'https://wa.me/?text=${Uri.encodeComponent(msg)}');
                        await launchUrl(uri,
                            mode: LaunchMode.externalApplication);
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.chat_rounded, size: 18),
                      label: const Text('WhatsApp'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF25D366),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Placeholder for a future dispatch-note PDF export.
  void _createPdfStub() {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('PDF export is coming soon.'),
        backgroundColor: Color(0xFF6A1B9A)));
  }
}
