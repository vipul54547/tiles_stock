import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/supabase_data_service.dart';
import '../services/cloudinary_service.dart';

/// Login-free, READ-ONLY page a buyer opens from a "Dispatch link"
/// (`/d/<token>`): they see exactly what the stockist dispatched — supplier,
/// date, invoice/vehicle/transporter, and the design lines with box counts.
/// A dispatch is a record of what already shipped, so there is nothing to
/// confirm or edit (unlike the old order link). Shared from All Dispatches.
class DispatchLinkScreen extends StatefulWidget {
  final String token;
  const DispatchLinkScreen({super.key, required this.token});
  @override
  State<DispatchLinkScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);

class _State extends State<DispatchLinkScreen> {
  final _svc = SupabaseDataService();
  Map<String, dynamic>? _d;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await _svc.publicDispatch(widget.token);
    if (!mounted) return;
    setState(() {
      _d = d;
      _loading = false;
    });
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  String _fmtDate(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    return '${dt.day} ${_months[dt.month - 1]} ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_d == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Dispatch')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.link_off, size: 64, color: Colors.grey.shade400),
                const SizedBox(height: 16),
                const Text('This dispatch link is no longer available.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text('It may have expired.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade600)),
              ],
            ),
          ),
        ),
      );
    }
    return _view();
  }

  Widget _view() {
    final d = _d!;
    final stockist = Map<String, dynamic>.from(d['stockist'] ?? const {});
    final sName = (stockist['name'] ?? '').toString();
    final sCity = (stockist['city'] ?? '').toString();
    final buyer = (d['buyer'] ?? '').toString().trim();
    final orderToken = (d['order_token'] ?? '').toString();
    final dispNo = (d['dispatch_no'] ?? '').toString();
    final date = _fmtDate(d['dispatched_on']?.toString());
    final invoice = (d['invoice_no'] ?? '').toString().trim();
    final vehicle = (d['vehicle_no'] ?? '').toString().trim();
    final transporter = (d['transporter'] ?? '').toString().trim();
    final note = (d['note'] ?? '').toString().trim();
    final total = (d['total'] as num?)?.toInt() ?? 0;
    final lines = ((d['lines'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: Text(dispNo.isEmpty ? 'Dispatch' : 'Dispatch $dispNo'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            borderRadius: BorderRadius.circular(8)),
                        child: Icon(Icons.local_shipping_outlined,
                            color: Colors.red.shade700),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(sName.isEmpty ? 'Your supplier' : sName,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 16)),
                            if (sCity.isNotEmpty)
                              Text(sCity,
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      color: Colors.grey.shade600)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _kv('Dispatch No', dispNo),
                  _kv('Date', date),
                  if (orderToken.isNotEmpty) _kv('Order', orderToken),
                  if (buyer.isNotEmpty) _kv('To', buyer),
                  if (invoice.isNotEmpty) _kv('Invoice No', invoice),
                  if (vehicle.isNotEmpty) _kv('Vehicle', vehicle),
                  if (transporter.isNotEmpty) _kv('Transporter', transporter),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text('Dispatched — $total box${total == 1 ? '' : 'es'}',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: Colors.grey.shade700)),
          ),
          const SizedBox(height: 8),
          for (final l in lines) _lineCard(l),
          if (note.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.sticky_note_2_outlined,
                        size: 18, color: Colors.grey.shade600),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(note,
                            style: const TextStyle(fontSize: 13))),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    if (v.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(k,
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
          ),
          Expanded(
            child: Text(v,
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _lineCard(Map<String, dynamic> l) {
    final name = (l['name'] ?? '').toString();
    final size = (l['size'] ?? '').toString().replaceAll(' mm', '');
    final surface = (l['surface'] ?? '').toString();
    final img = (l['image'] ?? '').toString();
    final qty = (l['quantity'] as num?)?.toInt() ?? 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: img.isEmpty
                  ? Container(
                      width: 54, height: 54,
                      color: Colors.grey.shade100,
                      child: const Icon(Icons.image_not_supported,
                          size: 20, color: Colors.grey))
                  : CachedNetworkImage(
                      imageUrl: CloudinaryService.thumbUrl(img, width: 200),
                      width: 54, height: 54, fit: BoxFit.cover,
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
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (size.isNotEmpty) size,
                      if (surface.isNotEmpty) surface,
                    ].join(' · '),
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text('$qty',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(width: 2),
            Text('box${qty == 1 ? '' : 'es'}',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }
}
