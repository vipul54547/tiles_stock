import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/supabase_data_service.dart';
import '../services/cloudinary_service.dart';

/// Login-free page a buyer opens from an "Order link" (`/o/<token>`): they see
/// the order the stockist pre-filled (photos, sizes, quantities, live stock),
/// adjust quantities, and confirm — which marks it confirmed and notifies the
/// stockist. (project_dispatch_order_redesign · Phase B Part 2)
class OrderLinkScreen extends StatefulWidget {
  final String token;
  const OrderLinkScreen({super.key, required this.token});
  @override
  State<OrderLinkScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);

class _State extends State<OrderLinkScreen> {
  final _svc = SupabaseDataService();
  Map<String, dynamic>? _order;
  final _lines = <Map<String, dynamic>>[];
  final _qty = <String, int>{}; // design_id → chosen qty
  bool _loading = true;
  bool _submitting = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final o = await _svc.publicOrder(widget.token);
    if (!mounted) return;
    setState(() {
      _order = o;
      _lines
        ..clear()
        ..addAll(((o?['lines'] as List?) ?? const [])
            .map((e) => Map<String, dynamic>.from(e as Map)));
      for (final l in _lines) {
        _qty[(l['design_id'] ?? '').toString()] =
            (l['quantity'] as num?)?.toInt() ?? 0;
      }
      _loading = false;
    });
  }

  int get _total => _qty.values.fold(0, (s, v) => s + v);

  Future<void> _confirm() async {
    final lines = [
      for (final e in _qty.entries) {'design_id': e.key, 'quantity': e.value},
    ];
    if (_total <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Set a quantity on at least one design.')));
      return;
    }
    setState(() => _submitting = true);
    try {
      await _svc.confirmOrderLink(widget.token, lines);
      if (!mounted) return;
      setState(() => _done = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e'), backgroundColor: Colors.red));
    }
  }

  Future<int?> _promptQty(int current) {
    final ctrl = TextEditingController(text: current > 0 ? '$current' : '');
    int parse(String s) => (int.tryParse(s.trim()) ?? current).clamp(0, 1 << 30);
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Boxes'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onSubmitted: (s) => Navigator.pop(ctx, parse(s)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, parse(ctrl.text)),
              child: const Text('Set')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_order == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Order link')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.link_off, size: 64, color: Colors.grey.shade400),
                const SizedBox(height: 16),
                const Text('This order link is no longer available.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text('It may have expired or already been processed.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade600)),
              ],
            ),
          ),
        ),
      );
    }
    if (_done) return _successView();
    return _reviewView();
  }

  Widget _reviewView() {
    final o = _order!;
    final stockist = Map<String, dynamic>.from(o['stockist'] ?? const {});
    final sName = (stockist['name'] ?? '').toString();
    final sCity = (stockist['city'] ?? '').toString();
    final token = (o['token'] ?? '').toString();
    final code = (o['connection_code'] ?? '').toString();

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: const Text('Review your order'),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            height: 50,
            child: ElevatedButton.icon(
              onPressed: _submitting ? null : _confirm,
              icon: _submitting
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check_circle_outline),
              label: Text(_submitting
                  ? 'Confirming…'
                  : 'Confirm order · $_total boxes'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2E7D32),
                  foregroundColor: Colors.white),
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(sName.isEmpty ? 'Your supplier' : sName,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                  if (sCity.isNotEmpty)
                    Text(sCity,
                        style: TextStyle(
                            fontSize: 12.5, color: Colors.grey.shade600)),
                  const SizedBox(height: 6),
                  Text(
                    'Order $token${code.isNotEmpty ? '  ·  $code' : ''}',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Check the quantities and tap Confirm. Tap a number to change it; set 0 to remove a design.',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          for (final l in _lines) _lineCard(l),
        ],
      ),
    );
  }

  Widget _lineCard(Map<String, dynamic> l) {
    final id = (l['design_id'] ?? '').toString();
    final name = (l['name'] ?? '').toString();
    final size = (l['size'] ?? '').toString().replaceAll(' mm', '');
    final surface = (l['surface'] ?? '').toString();
    final quality = (l['quality'] ?? '').toString();
    final img = (l['image'] ?? '').toString();
    final available = (l['available'] as num?)?.toInt() ?? 0;
    final qv = _qty[id] ?? 0;
    final over = qv > available;
    void set(int v) => setState(() => _qty[id] = v.clamp(0, 1 << 30));

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
                      if (quality.isNotEmpty) quality,
                    ].join(' · '),
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    over ? 'Only $available in stock' : '$available in stock',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color:
                            over ? Colors.red.shade700 : Colors.green.shade700),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: qv > 0 ? () => set(qv - 1) : null,
            ),
            InkWell(
              onTap: () async {
                final v = await _promptQty(qv);
                if (v != null) set(v);
              },
              borderRadius: BorderRadius.circular(6),
              child: Container(
                width: 46,
                padding: const EdgeInsets.symmetric(vertical: 5),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: over ? Colors.red.shade400 : Colors.grey.shade400),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('$qv',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              onPressed: () => set(qv + 1),
            ),
          ],
        ),
      ),
    );
  }

  Widget _successView() {
    final o = _order!;
    final stockist = Map<String, dynamic>.from(o['stockist'] ?? const {});
    final phone = '${stockist['country_code'] ?? ''}${stockist['phone'] ?? ''}'
        .replaceAll(RegExp(r'[^0-9]'), '');
    final rawPhone = (stockist['phone'] ?? '').toString().trim();
    final token = (o['token'] ?? '').toString();
    final code = (o['connection_code'] ?? '').toString();
    final msg =
        'I have confirmed my order $token${code.isNotEmpty ? ' [$code]' : ''} '
        '($_total boxes).';

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle,
                  color: Color(0xFF2E7D32), size: 72),
              const SizedBox(height: 16),
              const Text('Order confirmed',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
              const SizedBox(height: 8),
              Text(
                'Your supplier has been notified. They will process order '
                '$token${code.isNotEmpty ? ' ($code)' : ''}.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 20),
              if (rawPhone.isNotEmpty)
                ElevatedButton.icon(
                  onPressed: () => launchUrl(
                      Uri.parse(
                          'https://wa.me/$phone?text=${Uri.encodeComponent(msg)}'),
                      mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.chat_rounded, size: 18),
                  label: const Text('Message the supplier'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF25D366),
                      foregroundColor: Colors.white),
                )
              else
                OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: msg));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Copied — paste it to your supplier.')));
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy confirmation'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
