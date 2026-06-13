import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
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
  const DispatchInquiryScreen(
      {super.key, required this.inquiryId, this.token, this.company});
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
    super.dispose();
  }

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

    setState(() => _saving = true);
    try {
      final res = await _data.dispatchInquiry(widget.inquiryId, payload);
      if (!mounted) return;
      _dirty = false;
      final status = (res['status'] ?? '').toString();
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(status == 'completed'
            ? '$_token completed — all boxes dispatched.'
            : '$_token dispatched (partial).'),
        backgroundColor: const Color(0xFF2E7D32),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e'), backgroundColor: Colors.red));
    }
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
                    child: _lines.isEmpty
                        ? const Center(
                            child: Text('No items on this order',
                                style: TextStyle(color: Colors.grey)))
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                            itemCount: _lines.length,
                            itemBuilder: (_, i) => _lineCard(_lines[i]),
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: OutlinedButton.icon(
                      onPressed: _addDesign,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add a design'),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: _navy,
                          minimumSize: const Size.fromHeight(44)),
                    ),
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
