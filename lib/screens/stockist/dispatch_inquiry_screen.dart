import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/tile_design.dart';
import '../../models/choice_state.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../widgets/save_bar.dart';
import '../../widgets/unsaved_changes.dart';

/// Dispatch a locked order by token: every line shows buyer-ordered vs your
/// stock, with an editable "Dispatch now" box per line. The stockist can add or
/// remove designs and dispatch MORE than current stock (with a warning) when
/// physical stock differs. Submitting reduces stock, logs each dispatch, and
/// moves the order to Dispatching / Completed.
class DispatchInquiryScreen extends StatefulWidget {
  final String inquiryId;
  final String? token;
  final String? company;
  final String? phone;       // buyer phone — to send the dispatch report
  final String? countryCode; // buyer dialling code (e.g. +91)
  const DispatchInquiryScreen(
      {super.key,
      required this.inquiryId,
      this.token,
      this.company,
      this.phone,
      this.countryCode});
  @override
  State<DispatchInquiryScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);

class _Line {
  final String designId, name, size, surface, image;
  final int ordered;            // buyer-requested boxes (reference)
  final int dispatchedAlready;  // already dispatched on earlier rounds
  int available;                // current system stock
  final TextEditingController ctrl;
  _Line({
    required this.designId,
    required this.name,
    required this.size,
    required this.surface,
    required this.image,
    required this.ordered,
    required this.dispatchedAlready,
    required this.available,
    required this.ctrl,
  });
  int get remaining => (ordered - dispatchedAlready).clamp(0, 1 << 30);
  int get dispatchNow => int.tryParse(ctrl.text.trim()) ?? 0;
}

class _State extends State<DispatchInquiryScreen> {
  final _data = SupabaseDataService();
  final _lines = <_Line>[];
  String _token = '';
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;

  // Dispatch-note metadata (sent to the buyer in the WhatsApp report).
  final _invoiceCtrl = TextEditingController();
  final _vehicleCtrl = TextEditingController();
  final _transporterCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  DateTime _date = DateTime.now();

  @override
  void initState() {
    super.initState();
    _token = widget.token ?? '';
    _load();
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.ctrl.dispose();
    }
    _invoiceCtrl.dispose();
    _vehicleCtrl.dispose();
    _transporterCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  String _fmtDate(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<void> _load() async {
    final detail = await _data.getInquiryDetail(widget.inquiryId);
    if (!mounted) return;
    final lines = (detail?['lines'] as List?) ?? const [];
    setState(() {
      _token = (detail?['token'] ?? _token).toString();
      _lines.clear();
      for (final raw in lines) {
        final l = Map<String, dynamic>.from(raw as Map);
        final ordered = (l['quantity'] as num?)?.toInt() ?? 0;
        final dispatched = (l['dispatched_qty'] as num?)?.toInt() ?? 0;
        final remaining = (ordered - dispatched).clamp(0, 1 << 30);
        _lines.add(_Line(
          designId: (l['design_id'] ?? '').toString(),
          name: (l['design_name'] ?? '').toString(),
          size: (l['size'] ?? '').toString(),
          surface: (l['surface'] ?? '').toString(),
          image: (l['image'] ?? '').toString(),
          ordered: ordered,
          dispatchedAlready: dispatched,
          available: (l['available'] as num?)?.toInt() ?? 0,
          ctrl: TextEditingController(text: remaining > 0 ? '$remaining' : ''),
        ));
      }
      _loading = false;
    });
  }

  Future<void> _addDesign() async {
    final all = await _data.getDesignsByStockist(currentStockistUUID);
    if (!mounted) return;
    final existing = _lines.map((l) => l.designId).toSet();
    final options = all
        .where((d) => d.boxQuantity > 0 && !existing.contains(d.id))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    if (options.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No other in-stock designs to add.')));
      return;
    }
    final picked = await showModalBottomSheet<TileDesign>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        var q = '';
        return StatefulBuilder(
          builder: (ctx, setS) {
            final filtered = q.isEmpty
                ? options
                : options
                    .where((d) => d.name.toLowerCase().contains(q.toLowerCase()))
                    .toList();
            return SizedBox(
              height: MediaQuery.sizeOf(ctx).height * 0.7,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                    child: TextField(
                      autofocus: true,
                      onChanged: (v) => setS(() => q = v),
                      decoration: InputDecoration(
                        hintText: 'Search a design to add…',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        isDense: true,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final d = filtered[i];
                        return ListTile(
                          dense: true,
                          title: Text(d.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                              '${d.size.replaceAll(' mm', '')} · ${d.surfaceType}'),
                          trailing: Text('${d.boxQuantity} in stock',
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.grey)),
                          onTap: () => Navigator.pop(ctx, d),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    if (picked == null || !mounted) return;
    setState(() {
      _lines.add(_Line(
        designId: picked.id,
        name: picked.name,
        size: picked.size,
        surface: picked.surfaceType,
        image: picked.faceImageUrls.isNotEmpty ? picked.faceImageUrls.first : '',
        ordered: 0,
        dispatchedAlready: 0,
        available: picked.boxQuantity,
        ctrl: TextEditingController(),
      ));
      _dirty = true;
    });
  }

  Future<void> _submit() async {
    final over = _lines.where((l) => l.dispatchNow > l.available).toList();
    if (over.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Dispatch more than stock?'),
          content: Text(
              '${over.length} design${over.length == 1 ? '' : 's'} '
              'dispatch more boxes than you have in stock. This is allowed — the '
              'system stock for those will be set to 0. Continue?\n\n'
              '${over.map((l) => '• ${l.name}: ${l.dispatchNow} > ${l.available}').join('\n')}'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Dispatch anyway')),
          ],
        ),
      );
      if (ok != true) return;
    }

    final payload = _lines
        .map((l) => {'design_id': l.designId, 'dispatch': l.dispatchNow})
        .toList();
    final totalNow = _lines.fold(0, (s, l) => s + l.dispatchNow);
    final dispatchedLines = _lines.where((l) => l.dispatchNow > 0).toList();

    setState(() => _saving = true);
    try {
      final res = await _data.dispatchInquiry(
        widget.inquiryId, payload,
        invoiceNo: _invoiceCtrl.text.trim(),
        vehicleNo: _vehicleCtrl.text.trim(),
        transporter: _transporterCtrl.text.trim(),
        note: _noteCtrl.text.trim(),
        date: _date,
      );
      if (!mounted) return;
      _dirty = false;
      final status = (res['status'] ?? '').toString();
      final outstanding = (res['outstanding'] as num?)?.toInt() ?? 0;
      final dispatchNo = (res['dispatch_no'] ?? '').toString();
      if (totalNow > 0) {
        final report =
            _buildReport(dispatchNo, dispatchedLines, totalNow, outstanding);
        await _showReportSheet(report, status);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Order updated.'),
            backgroundColor: Color(0xFF2E7D32)));
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e'), backgroundColor: Colors.red));
    }
  }

  // Builds the WhatsApp dispatch-report text (no rates, by design).
  String _buildReport(
      String dispatchNo, List<_Line> lines, int total, int outstanding) {
    final b = StringBuffer();
    b.writeln('Dispatch update — Order $_token');
    if (dispatchNo.isNotEmpty) b.writeln('Dispatch No: $dispatchNo');
    b.writeln('Date: ${_fmtDate(_date)}');
    if (_invoiceCtrl.text.trim().isNotEmpty) {
      b.writeln('Invoice No: ${_invoiceCtrl.text.trim()}');
    }
    if (_vehicleCtrl.text.trim().isNotEmpty) {
      b.writeln('Vehicle No: ${_vehicleCtrl.text.trim()}');
    }
    if (_transporterCtrl.text.trim().isNotEmpty) {
      b.writeln('Transporter: ${_transporterCtrl.text.trim()}');
    }
    b.writeln();
    b.writeln('Dispatched now:');
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      b.writeln(
          '${i + 1}. ${l.name} (${l.size.replaceAll(' mm', '')}) — ${l.dispatchNow} boxes');
    }
    b.writeln('Total dispatched: $total boxes');
    if (outstanding > 0) b.writeln('Balance pending: $outstanding boxes');
    if (_noteCtrl.text.trim().isNotEmpty) {
      b.writeln();
      b.writeln('Note: ${_noteCtrl.text.trim()}');
    }
    return b.toString();
  }

  // Post-dispatch: preview the report and let the stockist send it to the buyer.
  Future<void> _showReportSheet(String report, String status) async {
    final digits = '${widget.countryCode ?? ''}${widget.phone ?? ''}'
        .replaceAll(RegExp(r'[^0-9]'), '');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(ctx).viewPadding.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.check_circle, color: Color(0xFF2E7D32)),
              const SizedBox(width: 8),
              Text(
                  status == 'completed'
                      ? 'Order completed'
                      : 'Dispatch recorded',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
            ]),
            const SizedBox(height: 10),
            const Text('Dispatch report for the buyer:',
                style: TextStyle(fontSize: 12.5)),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 260),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: SingleChildScrollView(
                child: Text(report,
                    style: const TextStyle(fontSize: 12.5, height: 1.5)),
              ),
            ),
            const SizedBox(height: 14),
            if (digits.isNotEmpty)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    final uri = Uri.parse(
                        'https://wa.me/$digits?text=${Uri.encodeComponent(report)}');
                    await launchUrl(uri,
                        mode: LaunchMode.externalApplication);
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  icon: const Icon(Icons.chat_rounded, size: 18),
                  label: const Text('Send report via WhatsApp'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF25D366),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                ),
              )
            else
              const Text('No buyer phone on file — report not sent.',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Done')),
          ],
        ),
      ),
    );
  }

  void _dispatchAllRemaining() {
    setState(() {
      for (final l in _lines) {
        l.ctrl.text = l.remaining > 0 ? '${l.remaining}' : '';
      }
      _dirty = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final totalNow = _lines.fold(0, (s, l) => s + l.dispatchNow);
    return Scaffold(
      appBar: AppBar(
        title: Text(_token.isEmpty ? 'Dispatch order' : 'Dispatch $_token'),
      ),
      bottomNavigationBar: SaveBar(
        label: 'Record Dispatch ($totalNow boxes)',
        icon: Icons.local_shipping_outlined,
        color: Colors.red[700],
        onPressed: _submit,
        saving: _saving,
        dirty: _dirty || totalNow > 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : UnsavedChangesGuard(
              isDirty: _dirty,
              child: Column(
                children: [
                  if (widget.company != null && widget.company!.isNotEmpty)
                    Container(
                      width: double.infinity,
                      color: _navy.withValues(alpha: 0.05),
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text('Buyer: ${widget.company}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, color: _navy)),
                    ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                      children: [
                        _metaSection(),
                        const SizedBox(height: 12),
                        if (_lines.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(
                                child: Text('No items on this order',
                                    style: TextStyle(color: Colors.grey))),
                          )
                        else
                          ..._lines.map(_lineCard),
                        const SizedBox(height: 4),
                        OutlinedButton.icon(
                          onPressed: _addDesign,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add a design'),
                          style: OutlinedButton.styleFrom(
                              foregroundColor: _navy,
                              minimumSize: const Size.fromHeight(44)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  // Dispatch-note details (Invoice / Vehicle / Date / Transporter / Note) +
  // a one-tap "All remaining" that fills every line's Send box.
  Widget _metaSection() {
    InputDecoration dec(String label) => InputDecoration(
          labelText: label,
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        );
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Text('Dispatch details',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const Spacer(),
              TextButton.icon(
                onPressed: _lines.isEmpty ? null : _dispatchAllRemaining,
                icon: const Icon(Icons.done_all, size: 16),
                label: const Text('All remaining',
                    style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _invoiceCtrl,
                  onChanged: (_) => _markDirty(),
                  decoration: dec('Invoice No'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _vehicleCtrl,
                  onChanged: (_) => _markDirty(),
                  decoration: dec('Vehicle / Truck No'),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: DateTime(2025),
                      lastDate: DateTime.now().add(const Duration(days: 1)),
                    );
                    if (d != null) setState(() { _date = d; _dirty = true; });
                  },
                  icon: const Icon(Icons.event, size: 16),
                  label: Text('Date: ${_fmtDate(_date)}',
                      style: const TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: _navy,
                      minimumSize: const Size.fromHeight(44)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _transporterCtrl,
                  onChanged: (_) => _markDirty(),
                  decoration: dec('Transporter (optional)'),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: _noteCtrl,
              onChanged: (_) => _markDirty(),
              maxLines: 2,
              decoration: dec('Note (optional)'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lineCard(_Line l) {
    final over = l.dispatchNow > l.available;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: l.image.isEmpty
                  ? Container(
                      width: 56, height: 56,
                      color: Colors.grey.shade100,
                      child: const Icon(Icons.image_not_supported,
                          size: 22, color: Colors.grey))
                  : CachedNetworkImage(
                      imageUrl: CloudinaryService.thumbUrl(l.image, width: 200),
                      width: 56, height: 56, fit: BoxFit.cover,
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
                  Text(l.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13)),
                  Text(
                      '${l.size.replaceAll(' mm', '')} · ${l.surface}',
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                  const SizedBox(height: 4),
                  Wrap(spacing: 6, runSpacing: 2, children: [
                    if (l.ordered > 0)
                      _meta('Ordered ${l.ordered}', _navy),
                    if (l.dispatchedAlready > 0)
                      _meta('Done ${l.dispatchedAlready}', const Color(0xFFE65100)),
                    _meta('Stock ${l.available}',
                        over ? Colors.red.shade700 : Colors.green.shade700),
                  ]),
                  if (over)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                          'More than your stock — allowed, stock will become 0.',
                          style: TextStyle(
                              fontSize: 10.5, color: Colors.red.shade700)),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              children: [
                SizedBox(
                  width: 70,
                  child: TextField(
                    controller: l.ctrl,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    onChanged: (_) {
                      _markDirty();
                      setState(() {});
                    },
                    decoration: InputDecoration(
                      labelText: 'Send',
                      isDense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline,
                      size: 20, color: Colors.red.shade400),
                  tooltip: 'Remove from this dispatch',
                  onPressed: () => setState(() {
                    l.ctrl.dispose();
                    _lines.remove(l);
                    _dirty = true;
                  }),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _meta(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
            color: c.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(4)),
        child: Text(t,
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w600, color: c)),
      );
}
