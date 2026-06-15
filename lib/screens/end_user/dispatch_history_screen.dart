import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/dispatch_record.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';

/// Buyer's dispatch history: every dispatch note a supplier shipped against the
/// buyer's orders, newest first. Read-only — mirrors the stockist's dispatch
/// report (truck/invoice + per-design boxes, no rates). When [filterToken] is
/// set, only that order's dispatches are shown.
class DispatchHistoryScreen extends StatefulWidget {
  final String? filterToken;
  const DispatchHistoryScreen({super.key, this.filterToken});

  @override
  State<DispatchHistoryScreen> createState() => _DispatchHistoryScreenState();
}

const _navy = Color(0xFF1B4F72);

class _DispatchHistoryScreenState extends State<DispatchHistoryScreen> {
  final _service = SupabaseDataService();
  List<DispatchRecord> _records = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await _service.getMyDispatches();
    if (!mounted) return;
    setState(() {
      _records = widget.filterToken == null
          ? all
          : all.where((r) => r.token == widget.filterToken).toList();
      _loading = false;
    });
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  String _fmtDate(DateTime d) {
    final l = d.toLocal();
    return '${l.day} ${_months[l.month - 1]} ${l.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.filterToken == null
            ? 'Dispatch History'
            : 'Dispatches · ${widget.filterToken}'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _records.isEmpty
              ? _buildEmpty()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: EdgeInsets.fromLTRB(
                        12, 12, 12, 24 + MediaQuery.viewPaddingOf(context).bottom),
                    itemCount: _records.length,
                    itemBuilder: (_, i) => _recordCard(_records[i]),
                  ),
                ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.local_shipping_outlined,
                size: 72, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(
                widget.filterToken == null
                    ? 'No dispatches yet'
                    : 'Nothing dispatched on this order yet',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade500)),
            const SizedBox(height: 8),
            Text(
              'When a supplier ships boxes against your order,\n'
              'the dispatch details will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
            ),
          ],
        ),
      ),
    );
  }

  Widget _recordCard(DispatchRecord r) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Colors.grey.shade200)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: dispatch no + date + total boxes badge.
            Row(
              children: [
                const Icon(Icons.local_shipping_rounded, size: 18, color: _navy),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    r.dispatchNo.isEmpty ? 'Dispatch' : r.dispatchNo,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: const Color(0xFFE8F5E9),
                      borderRadius: BorderRadius.circular(20)),
                  child: Text('${r.totalBoxes} boxes',
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2E7D32))),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${_fmtDate(r.effectiveDate)}'
              '${r.stockistName.isNotEmpty ? '   ·   ${r.stockistName}' : ''}'
              '${r.token.isNotEmpty ? '   ·   Order ${r.token}' : ''}',
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
            ),

            // Truck / invoice meta chips.
            if (r.invoiceNo.isNotEmpty ||
                r.vehicleNo.isNotEmpty ||
                r.transporter.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 4, children: [
                if (r.invoiceNo.isNotEmpty) _meta(Icons.receipt_long, 'Invoice ${r.invoiceNo}'),
                if (r.vehicleNo.isNotEmpty) _meta(Icons.local_shipping, r.vehicleNo),
                if (r.transporter.isNotEmpty) _meta(Icons.route, r.transporter),
              ]),
            ],

            const Divider(height: 18),

            // Dispatched lines.
            ...r.lines.map(_lineRow),

            if (r.note.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: const Color(0xFFFFF8E1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFFE082))),
                child: Text('Note: ${r.note}',
                    style: TextStyle(
                        fontSize: 11.5, color: Colors.orange.shade900)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _meta(IconData icon, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: _navy.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: _navy),
          const SizedBox(width: 4),
          Text(text,
              style: const TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.w600, color: _navy)),
        ]),
      );

  Widget _lineRow(DispatchLine l) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: l.image.isEmpty
                ? Container(
                    width: 44,
                    height: 44,
                    color: Colors.grey.shade100,
                    child: const Icon(Icons.image_not_supported,
                        size: 18, color: Colors.grey))
                : CachedNetworkImage(
                    imageUrl: CloudinaryService.thumbUrl(l.image, width: 160),
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                    placeholder: (_, __) =>
                        Container(color: Colors.grey.shade200),
                    errorWidget: (_, __, ___) =>
                        Container(color: Colors.grey.shade200)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.designName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 12.5)),
                Text(
                  '${l.size.replaceAll(' mm', '')}'
                  '${l.surface.isNotEmpty ? ' · ${l.surface}' : ''}',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text('${l.quantity} boxes',
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 13, color: _navy)),
        ],
      ),
    );
  }
}
