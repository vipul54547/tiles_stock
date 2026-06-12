import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/supabase_data_service.dart';

/// Stockist's inquiries (buyer My-Choice interest in their designs) as a flat
/// list that can be grouped **By Buyer**, **By Date**, or **By Design** — so the
/// stockist can answer "who wants what" and "what came in when", not just the
/// per-design totals shown on the dashboard.
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

class _Row {
  final String endUserId, company, contact, phone, city;
  final String designId, designName, size;
  final int quantity;
  final DateTime? updatedAt;
  _Row(Map<String, dynamic> j)
      : endUserId = (j['end_user_id'] ?? '').toString(),
        company = (j['company'] ?? '').toString(),
        contact = (j['contact'] ?? '').toString(),
        phone = (j['phone'] ?? '').toString(),
        city = (j['city'] ?? '').toString(),
        designId = (j['design_id'] ?? '').toString(),
        designName = (j['design_name'] ?? '').toString(),
        size = (j['size'] ?? '').toString(),
        quantity = (j['quantity'] as num?)?.toInt() ?? 0,
        updatedAt = j['updated_at'] != null
            ? DateTime.tryParse(j['updated_at'].toString())
            : null;
}

class _State extends State<InquiriesScreen> {
  final _data = SupabaseDataService();
  List<_Row> _rows = [];
  bool _loading = true;
  String _mode = 'Buyer'; // 'Buyer' | 'Date' | 'Design'

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await _data.getMyInquiryList();
    if (!mounted) return;
    setState(() {
      _rows = list.map((e) => _Row(e)).toList();
      _loading = false;
    });
  }

  String _fmtDate(DateTime? d) =>
      d == null ? '—' : '${d.day} ${_months[d.month - 1]} ${d.year}';

  // Group rows preserving the order keys are first seen (rows already arrive
  // newest-first), so date/buyer groups stay in a sensible order.
  Map<K, List<_Row>> _groupBy<K>(K Function(_Row) key) {
    final out = <K, List<_Row>>{};
    for (final r in _rows) {
      (out[key(r)] ??= []).add(r);
    }
    return out;
  }

  Future<void> _whatsapp(_Row r) async {
    final digits = r.phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return;
    final uri = Uri.parse('https://wa.me/$digits');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final totalBoxes = _rows.fold(0, (s, r) => s + r.quantity);
    final buyers = _rows.map((r) => r.endUserId).toSet().length;

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
                // Grouping toggle.
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                  child: Row(
                    children: [
                      for (final m in const ['Buyer', 'Date', 'Design']) ...[
                        Expanded(child: _modeChip(m)),
                        if (m != 'Design') const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${_rows.length} inquir${_rows.length == 1 ? 'y' : 'ies'} · '
                      '$buyers buyer${buyers == 1 ? '' : 's'} · $totalBoxes boxes',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ),
                ),
                Expanded(
                  child: _rows.isEmpty
                      ? const Center(
                          child: Text('No inquiries yet',
                              style: TextStyle(color: Colors.grey)))
                      : _body(),
                ),
              ],
            ),
    );
  }

  Widget _modeChip(String m) {
    final sel = _mode == m;
    return GestureDetector(
      onTap: () => setState(() => _mode = m),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: sel ? _navy : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: sel ? _navy : Colors.grey.shade300),
        ),
        child: Text('By $m',
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: sel ? Colors.white : Colors.grey.shade700)),
      ),
    );
  }

  Widget _body() {
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    final pad = EdgeInsets.fromLTRB(12, 6, 12, 12 + bottom);
    switch (_mode) {
      case 'Date':
        return _dateBody(pad);
      case 'Design':
        return _designBody(pad);
      default:
        return _buyerBody(pad);
    }
  }

  // ── By Buyer ──────────────────────────────────────────────────────────────
  Widget _buyerBody(EdgeInsets pad) {
    final groups = _groupBy((r) => r.endUserId);
    final keys = groups.keys.toList();
    return ListView.builder(
      padding: pad,
      itemCount: keys.length,
      itemBuilder: (_, i) {
        final rows = groups[keys[i]]!;
        final r0 = rows.first;
        final boxes = rows.fold(0, (s, r) => s + r.quantity);
        final sub = [
          if (r0.contact.isNotEmpty) r0.contact,
          if (r0.city.isNotEmpty) r0.city,
        ].join('  ·  ');
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            leading: CircleAvatar(
              backgroundColor: _navy.withValues(alpha: 0.1),
              child: const Icon(Icons.business, color: _navy, size: 20),
            ),
            title: Text(r0.company.isEmpty ? 'Buyer' : r0.company,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14)),
            subtitle: Text(
                '${sub.isEmpty ? '' : '$sub  ·  '}'
                '${rows.length} design${rows.length == 1 ? '' : 's'} · $boxes boxes',
                style: const TextStyle(fontSize: 12)),
            trailing: r0.phone.isEmpty
                ? null
                : IconButton(
                    tooltip: 'WhatsApp',
                    icon: const Icon(Icons.chat, color: Color(0xFF25D366)),
                    onPressed: () => _whatsapp(r0),
                  ),
            children: rows
                .map((r) => _lineRow(
                      '${r.designName}  (${r.size.replaceAll(' mm', '')})',
                      '${r.quantity} boxes',
                      _fmtDate(r.updatedAt),
                    ))
                .toList(),
          ),
        );
      },
    );
  }

  // ── By Date ───────────────────────────────────────────────────────────────
  Widget _dateBody(EdgeInsets pad) {
    final groups = _groupBy((r) => _fmtDate(r.updatedAt));
    final keys = groups.keys.toList();
    return ListView.builder(
      padding: pad,
      itemCount: keys.length,
      itemBuilder: (_, i) {
        final rows = groups[keys[i]]!;
        final boxes = rows.fold(0, (s, r) => s + r.quantity);
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                decoration: BoxDecoration(
                  color: _navy.withValues(alpha: 0.06),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(12)),
                ),
                child: Text('${keys[i]}   ·   $boxes boxes',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: _navy)),
              ),
              ...rows.map((r) => _lineRow(
                    r.company.isEmpty ? 'Buyer' : r.company,
                    '${r.quantity} boxes',
                    '${r.designName} (${r.size.replaceAll(' mm', '')})',
                  )),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
  }

  // ── By Design ─────────────────────────────────────────────────────────────
  Widget _designBody(EdgeInsets pad) {
    final groups = _groupBy((r) => r.designId);
    final keys = groups.keys.toList();
    return ListView.builder(
      padding: pad,
      itemCount: keys.length,
      itemBuilder: (_, i) {
        final rows = groups[keys[i]]!;
        final r0 = rows.first;
        final boxes = rows.fold(0, (s, r) => s + r.quantity);
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            leading: CircleAvatar(
              backgroundColor: _navy.withValues(alpha: 0.1),
              child: const Icon(Icons.grid_view_rounded, color: _navy, size: 20),
            ),
            title: Text(
                '${r0.designName}  (${r0.size.replaceAll(' mm', '')})',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14)),
            subtitle: Text(
                '${rows.length} buyer${rows.length == 1 ? '' : 's'} · $boxes boxes',
                style: const TextStyle(fontSize: 12)),
            children: rows
                .map((r) => _lineRow(
                      r.company.isEmpty ? 'Buyer' : r.company,
                      '${r.quantity} boxes',
                      _fmtDate(r.updatedAt),
                    ))
                .toList(),
          ),
        );
      },
    );
  }

  // One leaf line: left label, a boxes pill, and a small grey meta line.
  Widget _lineRow(String label, String boxes, String meta) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500)),
                if (meta.isNotEmpty)
                  Text(meta,
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: _navy.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(boxes,
                style: const TextStyle(
                    color: _navy,
                    fontWeight: FontWeight.w700,
                    fontSize: 11.5)),
          ),
        ],
      ),
    );
  }
}
