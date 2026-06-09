import 'package:flutter/material.dart';
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
    final rows = _filtered;
    if (rows.isEmpty) {
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

    final totalBoxes = rows.fold(
        0, (s, r) => s + ((r['quantity_dispatched'] as num?)?.toInt() ?? 0));

    return RefreshIndicator(
      onRefresh: _load,
      child: Column(
        children: [
          Container(
            width: double.infinity,
            color: Colors.red.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text('${rows.length} dispatches · $totalBoxes boxes total',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.red.shade700)),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: rows.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _dispatchCard(rows[i]),
            ),
          ),
        ],
      ),
    );
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

  Widget _dispatchCard(Map<String, dynamic> r) {
    final designName = _designName(r);
    final qty = (r['quantity_dispatched'] as num?)?.toInt() ?? 0;
    final buyer = (r['buyer_name'] ?? '').toString();
    final notes = (r['notes'] ?? '').toString();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.local_shipping_outlined,
                size: 20, color: Colors.red.shade700),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(designName,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                if (buyer.isNotEmpty)
                  Row(
                    children: [
                      Icon(Icons.business_outlined,
                          size: 13, color: Colors.grey.shade600),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(buyer,
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade700),
                            overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                if (notes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(notes,
                        style: TextStyle(
                            fontSize: 11,
                            fontStyle: FontStyle.italic,
                            color: Colors.grey.shade500)),
                  ),
                const SizedBox(height: 4),
                Text(_formatDate(r['created_at']?.toString()),
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.red.shade700,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('-$qty',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14)),
          ),
        ],
      ),
    );
  }
}
