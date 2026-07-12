import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../widgets/customer_picker.dart';

const _navy = Color(0xFF1B4F72);
const _green = Color(0xFF2E7D32);

/// Saved-customer directory → tap a customer to see everything they have ever
/// taken. Opt-in (`customers_enabled`); the caller gates entry on that flag.
/// (project_customer_history)
class CustomerListScreen extends StatefulWidget {
  const CustomerListScreen({super.key});
  @override
  State<CustomerListScreen> createState() => _CustomerListState();
}

class _CustomerListState extends State<CustomerListScreen> {
  final _svc = SupabaseDataService();
  List<Map<String, dynamic>> _customers = [];
  bool _loading = true;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = await _svc.listCustomers();
    if (!mounted) return;
    setState(() {
      _customers = c;
      _loading = false;
    });
  }

  Future<void> _addCustomer() async {
    final created =
        await CustomerPicker.show(context, customers: _customers, svc: _svc);
    // Only the New-customer path adds a row we don't have; a plain pick just
    // opens that customer's history.
    if (created == null) return;
    final id = (created['id'] ?? '').toString();
    if (id.isEmpty) return;
    if (!mounted) return;
    await _load();
    _open(created);
  }

  void _open(Map<String, dynamic> c) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CustomerHistoryScreen(
        customerId: (c['id'] ?? '').toString(),
        customerName: (c['name'] ?? '').toString(),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final ql = _q.trim().toLowerCase();
    final list = _customers
        .where((c) => (c['name'] ?? '').toString().toLowerCase().contains(ql))
        .toList();
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(title: const Text('Customers')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addCustomer,
        backgroundColor: _green,
        icon: const Icon(Icons.person_add_alt),
        label: const Text('New / find'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                  child: TextField(
                    onChanged: (v) => setState(() => _q = v),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search customers…',
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none),
                    ),
                  ),
                ),
                Expanded(
                  child: list.isEmpty
                      ? Center(
                          child: Text(
                              _customers.isEmpty
                                  ? 'No saved customers yet.'
                                  : 'No customer matches.',
                              style: const TextStyle(color: Colors.grey)))
                      : ListView.separated(
                          itemCount: list.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final c = list[i];
                            final where = [
                              (c['city'] ?? '').toString(),
                              (c['district'] ?? '').toString(),
                            ].where((x) => x.isNotEmpty).join(', ');
                            return ListTile(
                              tileColor: Colors.white,
                              leading: const CircleAvatar(
                                  backgroundColor: Color(0xFFE3ECF3),
                                  child: Icon(Icons.person_outline,
                                      color: _navy)),
                              title: Text((c['name'] ?? '').toString(),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              subtitle: where.isEmpty ? null : Text(where),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _open(c),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

/// One customer's dispatch history: header + summary + a timeline of dispatch
/// notes (walk-in and order alike), each expandable to its design lines.
class CustomerHistoryScreen extends StatefulWidget {
  final String customerId;
  final String customerName;
  const CustomerHistoryScreen(
      {super.key, required this.customerId, required this.customerName});
  @override
  State<CustomerHistoryScreen> createState() => _CustomerHistoryState();
}

class _CustomerHistoryState extends State<CustomerHistoryScreen> {
  final _svc = SupabaseDataService();
  Map<String, dynamic>? _data;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await _svc.myCustomerHistory(widget.customerId);
    if (!mounted) return;
    setState(() {
      _data = d;
      _loading = false;
    });
  }

  // "Word (Canonical)" — same rule as TileDesign.surfaceCardLabel, on the raw
  // label/type the RPC returns.
  String _surfaceLabel(String word, String canonical) {
    final c = canonical.trim();
    if (c.isEmpty || c.toLowerCase() == 'none') return '';
    final w = word.trim();
    if (w.isEmpty || w.toLowerCase() == c.toLowerCase()) return c;
    return '$w ($c)';
  }

  Future<void> _copy(String v) async {
    await Clipboard.setData(ClipboardData(text: v));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)));
    }
  }

  Future<void> _launch(Uri uri) async {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open — number copied instead')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
          title: Text(widget.customerName.isEmpty
              ? 'Customer'
              : widget.customerName)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _data == null
              ? const Center(
                  child: Text('Customer not found.',
                      style: TextStyle(color: Colors.grey)))
              : _body(_data!),
    );
  }

  Widget _body(Map<String, dynamic> d) {
    final cust = Map<String, dynamic>.from(d['customer'] as Map? ?? {});
    final summary = Map<String, dynamic>.from(d['summary'] as Map? ?? {});
    final dispatches = (d['dispatches'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final phone = (cust['phone'] ?? '').toString().trim();
    final cc = (cust['country_code'] ?? '+91').toString().trim();
    final where = [
      (cust['city'] ?? '').toString(),
      (cust['district'] ?? '').toString(),
      (cust['state'] ?? '').toString(),
    ].where((x) => x.trim().isNotEmpty).join(', ');

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        // Header card.
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text((cust['name'] ?? widget.customerName).toString(),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 18)),
                if (where.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(where,
                      style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
                ],
                if (phone.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: Text('$cc $phone',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                    _iconBtn(Icons.copy, 'Copy', () => _copy('$cc $phone')),
                    _iconBtn(Icons.call, 'Call',
                        () => _launch(Uri.parse('tel:$cc$phone'))),
                    _iconBtn(Icons.chat, 'WhatsApp', () {
                      final digits = '$cc$phone'.replaceAll(RegExp(r'[^0-9]'), '');
                      _launch(Uri.parse('https://wa.me/$digits'));
                    }),
                  ]),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        // Summary strip.
        Row(children: [
          _stat('${summary['total_boxes'] ?? 0}', 'boxes taken'),
          const SizedBox(width: 8),
          _stat('${summary['dispatch_count'] ?? 0}', 'dispatches'),
          const SizedBox(width: 8),
          _stat(_fmtDate((summary['last_dispatched_on'] ?? '').toString()),
              'last visit'),
        ]),
        const SizedBox(height: 14),
        if (dispatches.isEmpty)
          const Padding(
            padding: EdgeInsets.all(28),
            child: Center(
                child: Text('No dispatches yet.',
                    style: TextStyle(color: Colors.grey))),
          )
        else
          ...dispatches.map(_dispatchCard),
      ],
    );
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback onTap) => IconButton(
        icon: Icon(icon, size: 20, color: _navy),
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        onPressed: onTap,
      );

  Widget _stat(String value, String label) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
          decoration: BoxDecoration(
              color: Colors.white, borderRadius: BorderRadius.circular(10)),
          child: Column(children: [
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 16, color: _navy)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ]),
        ),
      );

  Widget _dispatchCard(Map<String, dynamic> dn) {
    final lines = (dn['lines'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final token = (dn['token'] ?? '').toString();
    final invoice = (dn['invoice_no'] ?? '').toString().trim();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          title: Row(children: [
            Text(_fmtDate((dn['dispatched_on'] ?? '').toString()),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const Spacer(),
            Text('${dn['total_boxes'] ?? 0} boxes',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, color: _green, fontSize: 14)),
          ]),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text([
              '#${dn['dispatch_no'] ?? ''}',
              if (token.isNotEmpty) 'Order $token' else 'Walk-in',
              if (invoice.isNotEmpty) 'Inv $invoice',
            ].join('  ·  '),
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ),
          children: lines.map(_lineRow).toList(),
        ),
      ),
    );
  }

  Widget _lineRow(Map<String, dynamic> ln) {
    final img = (ln['image'] ?? '').toString();
    final surface = _surfaceLabel((ln['surface_label'] ?? '').toString(),
        (ln['surface_type'] ?? '').toString());
    final meta = [
      (ln['brand'] ?? '').toString(),
      (ln['size'] ?? '').toString().replaceAll(' mm', ''),
      (ln['quality'] ?? '').toString(),
      if (surface.isNotEmpty) surface,
    ].where((x) => x.trim().isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: img.isEmpty
              ? Container(
                  width: 40,
                  height: 40,
                  color: Colors.grey.shade100,
                  child: const Icon(Icons.image_not_supported,
                      size: 16, color: Colors.grey))
              : CachedNetworkImage(
                  imageUrl: CloudinaryService.thumbUrl(img, width: 120),
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(color: Colors.grey.shade200),
                  errorWidget: (_, __, ___) =>
                      Container(color: Colors.grey.shade200)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text((ln['design_name'] ?? '').toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13.5)),
              if (meta.isNotEmpty)
                Text(meta,
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade700)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text('${ln['quantity'] ?? 0}',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(width: 2),
        Text('box', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      ]),
    );
  }

  static const _months = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  String _fmtDate(String iso) {
    // 'YYYY-MM-DD' → 'D Mon YYYY'. Falls back to raw string.
    final parts = iso.split('-');
    if (parts.length != 3) return iso.isEmpty ? '—' : iso;
    final y = parts[0];
    final m = int.tryParse(parts[1]) ?? 0;
    final d = int.tryParse(parts[2]) ?? 0;
    if (m < 1 || m > 12) return iso;
    return '$d ${_months[m]} $y';
  }
}
