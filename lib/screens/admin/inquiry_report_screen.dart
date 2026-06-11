import 'package:flutter/material.dart';
import '../../services/supabase_data_service.dart';

/// Admin report of every buyer inquiry (My-Choice) across all stockists,
/// grouped by stockist. Read-only.
class InquiryReportScreen extends StatefulWidget {
  const InquiryReportScreen({super.key});
  @override
  State<InquiryReportScreen> createState() => _State();
}

class _State extends State<InquiryReportScreen> {
  final _svc = SupabaseDataService();
  late Future<List<Map<String, dynamic>>> _future;
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _future = _svc.getInquiryReport();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _matches(Map<String, dynamic> r) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return [r['stockist'], r['stockist_seq'], r['design'], r['buyer'], r['city']]
        .any((v) => (v ?? '').toString().toLowerCase().contains(q));
  }

  Future<void> _reload() async {
    final f = _svc.getInquiryReport();
    setState(() { _future = f; });
    await f;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Inquiry Reports')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'Search stockist, design, buyer, city…',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _query = '');
                        }),
              ),
            ),
          ),
          Expanded(child: _buildList()),
        ],
      ),
    );
  }

  Widget _buildList() {
    return FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (_, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows =
              (snap.data ?? []).where(_matches).toList();
          if (rows.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.bar_chart_outlined,
                      size: 72, color: Colors.grey.shade300),
                  const SizedBox(height: 16),
                  Text('No inquiries yet',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey.shade500)),
                ],
              ),
            );
          }

          // Group by stockist.
          final groups = <String, List<Map<String, dynamic>>>{};
          for (final r in rows) {
            final key = '${r['stockist'] ?? ''} (${r['stockist_seq'] ?? ''})';
            (groups[key] ??= []).add(r);
          }
          final totalBoxes = rows.fold(
              0, (s, r) => s + ((r['boxes'] as num?)?.toInt() ?? 0));

          final keys = groups.keys.toList();
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                  12, 12, 12, 12 + MediaQuery.viewPaddingOf(context).bottom),
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B4F72).withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                      '${rows.length} inquiries · $totalBoxes boxes · ${keys.length} stockists',
                      style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          color: Color(0xFF1B4F72))),
                ),
                const SizedBox(height: 8),
                ...keys.map((k) => _group(k, groups[k]!)),
              ],
            ),
          );
        },
      );
  }

  Widget _group(String title, List<Map<String, dynamic>> items) {
    final boxes =
        items.fold(0, (s, r) => s + ((r['boxes'] as num?)?.toInt() ?? 0));
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          title: Text(title,
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 14)),
          subtitle: Text('${items.length} inquiries · $boxes boxes',
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          children: items.map((r) {
            final city = (r['city'] ?? '').toString();
            return ListTile(
              dense: true,
              title: Text((r['design'] ?? '').toString(),
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              subtitle: Text(
                  '${r['buyer'] ?? ''}${city.isNotEmpty ? ' · $city' : ''}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
              trailing: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1565C0).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('${r['boxes']} boxes',
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1565C0))),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
