import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/tile_design.dart';
import '../../models/choice_state.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../widgets/save_bar.dart';
import '../../widgets/unsaved_changes.dart';

/// Stockist creates OR edits their own order for a (possibly non-app) customer: a
/// free-text customer hint + designs picked from their F_Stock with box
/// quantities. Create saves a no-buyer inquiry (source='stockist'); edit replaces
/// an existing OPEN no-buyer order's lines. On success pops the order's
/// `{id, token, connection_code}` (create) so the caller can offer WhatsApp / a
/// link. (project_dispatch_order_redesign · Phase E)
class StockistAddOrderScreen extends StatefulWidget {
  /// When editing, the order id + its current hint/lines to pre-fill. Null = new.
  final String? orderId;
  final String initialHint;
  final List<Map<String, dynamic>> initialLines; // [{design_id, quantity}]
  const StockistAddOrderScreen({
    super.key,
    this.orderId,
    this.initialHint = '',
    this.initialLines = const [],
  });
  @override
  State<StockistAddOrderScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);

// ── Shared little helpers ─────────────────────────────────────────────────────

// Small Premium/Standard pill.
Widget qualityBadge(String quality) {
  final isP = quality.trim().toLowerCase().startsWith('p');
  final c = isP ? Colors.amber : Colors.blue;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
    child: Text(isP ? 'Premium' : 'Standard',
        style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: isP ? Colors.amber.shade900 : Colors.blue.shade800)),
  );
}

// Numeric entry for a box quantity (dialog → keyboard never covers anything).
Future<int?> promptQty(BuildContext context, int current) {
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

class _Pick {
  final TileDesign d;
  int qty;
  _Pick(this.d, this.qty);
}

class _State extends State<StockistAddOrderScreen> {
  final _data = SupabaseDataService();
  final _hintCtrl = TextEditingController();
  final _picks = <String, _Pick>{}; // designId → pick
  List<TileDesign> _stock = [];      // F_Stock > 0 (picker source)
  Map<String, String> _brandById = {}; // brandId → name (my_stock has no name)
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;

  bool get _isEdit => widget.orderId != null;

  @override
  void initState() {
    super.initState();
    _hintCtrl.text = widget.initialHint;
    _load();
  }

  @override
  void dispose() {
    _hintCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final all = await _data.getDesignsByStockist(currentStockistUUID);
    final brands = await _data.getMyBrands();
    if (!mounted) return;
    setState(() {
      _brandById = {for (final b in brands) b.id: b.name};
      _stock = all.where((d) => d.fStock > 0).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      for (final l in widget.initialLines) {
        final id = (l['design_id'] ?? '').toString();
        final qty = (l['quantity'] as num?)?.toInt() ?? 0;
        TileDesign? d;
        for (final e in all) {
          if (e.id == id) { d = e; break; }
        }
        if (d != null && qty > 0) _picks[id] = _Pick(d, qty);
      }
      _loading = false;
    });
  }

  String _brandOf(TileDesign d) => _brandById[d.brandId ?? ''] ?? '';

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  int get _totalBoxes =>
      _picks.values.fold(0, (s, p) => s + (p.qty > 0 ? p.qty : 0));

  // Open the full-screen picker (select + set quantities), pre-filled with the
  // current picks; apply its result on return.
  Future<void> _pickDesigns() async {
    final result = await Navigator.of(context).push<Map<String, int>>(
      MaterialPageRoute(
        builder: (_) => DesignPicker(
          stock: _stock,
          brandById: _brandById,
          initial: {for (final e in _picks.entries) e.key: e.value.qty},
        ),
      ),
    );
    if (result == null) return;
    setState(() {
      _picks.removeWhere((id, p) => !result.containsKey(id));
      for (final e in result.entries) {
        if (_picks.containsKey(e.key)) {
          _picks[e.key]!.qty = e.value;
        } else {
          final m = _stock.where((x) => x.id == e.key);
          if (m.isNotEmpty) _picks[e.key] = _Pick(m.first, e.value);
        }
      }
      _dirty = true;
    });
  }

  Future<void> _save() async {
    final lines = _picks.values
        .where((p) => p.qty > 0)
        .map((p) => {'design_id': p.d.id, 'quantity': p.qty})
        .toList();
    if (lines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Add at least one design with a quantity.')));
      return;
    }
    setState(() => _saving = true);
    try {
      if (_isEdit) {
        await _data.updateStockistOrder(
            widget.orderId!, _hintCtrl.text.trim(), lines);
        if (!mounted) return;
        _dirty = false;
        Navigator.pop(context, {'id': widget.orderId});
      } else {
        final res =
            await _data.createStockistOrder(_hintCtrl.text.trim(), lines);
        if (!mounted) return;
        _dirty = false;
        Navigator.pop(context, res); // {id, token, connection_code}
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e'), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    final picks = _picks.values.toList();
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit Order' : 'New Order'),
        actions: [
          if (!_loading)
            TextButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.check, color: Colors.white, size: 18),
              label: const Text('Save', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      bottomNavigationBar: SaveBar(
        label: '${_isEdit ? 'Save changes' : 'Save Order'} ($_totalBoxes boxes)',
        icon: Icons.check_circle_outline,
        color: const Color(0xFF2E7D32),
        onPressed: _save,
        saving: _saving,
        dirty: _dirty,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : UnsavedChangesGuard(
              isDirty: _dirty,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                children: [
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: TextField(
                        controller: _hintCtrl,
                        textCapitalization: TextCapitalization.words,
                        maxLength: 80,
                        onChanged: (_) => _markDirty(),
                        decoration: const InputDecoration(
                          labelText: 'Customer name / hint',
                          hintText: 'e.g. Ramesh (walk-in), site at Bopal…',
                          helperText:
                              'Just a note for you — no customer details are stored.',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('Designs',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 14)),
                      const Spacer(),
                      OutlinedButton.icon(
                        onPressed: _pickDesigns,
                        icon: const Icon(Icons.add, size: 18),
                        label: Text(picks.isEmpty ? 'Select' : 'Add / edit'),
                        style: OutlinedButton.styleFrom(foregroundColor: _navy),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (picks.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                          child: Text('No designs yet — tap Select.',
                              style: TextStyle(color: Colors.grey))),
                    )
                  else
                    ...picks.map(_pickCard),
                ],
              ),
            ),
    );
  }

  // Review card on the order screen: brand · size on one line, surface next to
  // the tappable quantity box.
  Widget _pickCard(_Pick p) {
    final d = p.d;
    final over = p.qty > d.fStock;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: d.faceImageUrls.isEmpty
                  ? Container(
                      width: 52, height: 52,
                      color: Colors.grey.shade100,
                      child: const Icon(Icons.image_not_supported,
                          size: 20, color: Colors.grey))
                  : CachedNetworkImage(
                      imageUrl: CloudinaryService.thumbUrl(
                          d.faceImageUrls.first, width: 200),
                      width: 52, height: 52, fit: BoxFit.cover,
                      placeholder: (_, __) => Container(color: Colors.grey.shade200),
                      errorWidget: (_, __, ___) => Container(color: Colors.grey.shade200)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(d.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14)),
                    ),
                    const SizedBox(width: 6),
                    qualityBadge(d.quality),
                  ]),
                  const SizedBox(height: 3),
                  Text(
                    [
                      if (_brandOf(d).isNotEmpty) _brandOf(d),
                      d.size.replaceAll(' mm', ''),
                    ].join(' · '),
                    style:
                        TextStyle(fontSize: 12.5, color: Colors.grey.shade800),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Surface next to the quantity box.
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                InkWell(
                  onTap: () =>
                      setState(() { _picks.remove(d.id); _dirty = true; }),
                  child: Icon(Icons.close, size: 18, color: Colors.grey.shade500),
                ),
                const SizedBox(height: 2),
                if (d.hasSurface)
                  Text(d.surfaceCardLabel,
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade800)),
                const SizedBox(height: 3),
                InkWell(
                  onTap: () async {
                    final v = await promptQty(context, p.qty);
                    if (v != null) setState(() { p.qty = v; _dirty = true; });
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 84,
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                    decoration: BoxDecoration(
                      color: _navy.withValues(alpha: 0.04),
                      border: Border.all(
                          color: over ? Colors.red.shade400 : _navy),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('${p.qty}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 19)),
                            const SizedBox(width: 3),
                            Icon(Icons.edit, size: 13, color: Colors.grey.shade600),
                          ],
                        ),
                        const Text('tap to edit boxes',
                            style: TextStyle(fontSize: 8.5, color: Colors.grey)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Full-screen design picker: select + set quantity in one place ─────────────

class DesignPicker extends StatefulWidget {
  final List<TileDesign> stock;
  final Map<String, String> brandById;
  final Map<String, int> initial; // designId → qty
  const DesignPicker(
      {super.key,
      required this.stock,
      required this.brandById,
      required this.initial});
  @override
  State<DesignPicker> createState() => DesignPickerState();
}

class DesignPickerState extends State<DesignPicker> {
  late Map<String, int> _qtys;
  final _searchCtrl = TextEditingController();
  String _q = '';
  final _fSize = <String>{}, _fQual = <String>{}, _fSurf = <String>{}, _fBrand = <String>{};

  @override
  void initState() {
    super.initState();
    _qtys = Map.of(widget.initial);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String _brandOf(TileDesign d) => widget.brandById[d.brandId ?? ''] ?? '';

  List<String> _distinct(String Function(TileDesign) f) {
    final s = <String>{};
    for (final d in widget.stock) {
      final v = f(d).trim();
      if (v.isNotEmpty) s.add(v);
    }
    return s.toList()..sort();
  }

  int get _activeFilters =>
      _fSize.length + _fQual.length + _fSurf.length + _fBrand.length;

  List<TileDesign> get _filtered {
    bool pass(TileDesign d) =>
        (_fSize.isEmpty || _fSize.contains(d.size)) &&
        (_fQual.isEmpty || _fQual.contains(d.quality)) &&
        (_fSurf.isEmpty || _fSurf.contains(d.surfaceWord)) &&
        (_fBrand.isEmpty || _fBrand.contains(_brandOf(d)));
    final ql = _q.toLowerCase();
    // Chosen designs are always kept (even if they don't match search) so a
    // selection is never dropped. Order stays a STABLE alphabetical list — we do
    // NOT pin selected to the top, otherwise a row jumps when you tap it (looked
    // like the wrong row got selected).
    return widget.stock
        .where((d) =>
            _qtys.containsKey(d.id) ||
            ((_q.isEmpty || d.name.toLowerCase().contains(ql)) && pass(d)))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  void _openFilter() {
    FocusScope.of(context).unfocus();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setF) {
          Widget section(String title, List<String> opts, Set<String> sel,
                  {String Function(String)? label}) =>
              opts.isEmpty
                  ? const SizedBox.shrink()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 10, bottom: 4),
                          child: Text(title,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 13)),
                        ),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final o in opts)
                              FilterChip(
                                label: Text(label == null ? o : label(o),
                                    style: const TextStyle(fontSize: 12)),
                                selected: sel.contains(o),
                                onSelected: (v) {
                                  setF(() => v ? sel.add(o) : sel.remove(o));
                                  setState(() {});
                                },
                              ),
                          ],
                        ),
                      ],
                    );
          return Padding(
            padding: EdgeInsets.fromLTRB(
                16, 12, 16, 16 + MediaQuery.of(ctx).viewPadding.bottom),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40, height: 4,
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  Row(children: [
                    const Text('Filter designs',
                        style:
                            TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const Spacer(),
                    TextButton(
                      onPressed: () {
                        setF(() {
                          _fSize.clear();
                          _fQual.clear();
                          _fSurf.clear();
                          _fBrand.clear();
                        });
                        setState(() {});
                      },
                      child: const Text('Clear all',
                          style: TextStyle(color: Colors.red)),
                    ),
                  ]),
                  section('Size', _distinct((d) => d.size), _fSize,
                      label: (s) => s.replaceAll(' mm', '')),
                  section('Quality', _distinct((d) => d.quality), _fQual),
                  section('Surface', _distinct((d) => d.surfaceWord), _fSurf),
                  section('Brand', _distinct(_brandOf), _fBrand),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(ctx),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: _navy, foregroundColor: Colors.white),
                      child: const Text('Done'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    final total = _qtys.values.fold(0, (s, v) => s + v);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select designs'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _qtys),
            child: const Text('Done', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
          child: SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context, _qtys),
              style: ElevatedButton.styleFrom(
                  backgroundColor: _navy, foregroundColor: Colors.white),
              child: Text(
                  'Done · ${_qtys.length} design${_qtys.length == 1 ? '' : 's'} · $total boxes'),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _q = v),
                    decoration: InputDecoration(
                      hintText: 'Search designs…',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      isDense: true,
                      suffixIcon: _q.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _q = '');
                              }),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _openFilter,
                  icon: const Icon(Icons.tune, size: 16),
                  label: Text(
                      _activeFilters > 0 ? 'Filter ($_activeFilters)' : 'Filter'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _navy,
                    side: BorderSide(
                        color: _activeFilters > 0 ? _navy : Colors.grey.shade400),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: filtered.isEmpty
                ? const Center(
                    child: Text('No designs match',
                        style: TextStyle(color: Colors.grey)))
                : ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) => _row(filtered[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _row(TileDesign d) {
    final sel = _qtys.containsKey(d.id);
    final qv = _qtys[d.id] ?? 0;
    final over = qv > d.fStock;
    void toggle(bool v) => setState(() {
          if (v) {
            _qtys[d.id] = d.fStock; // tick = full free stock
          } else {
            _qtys.remove(d.id);
          }
        });
    return InkWell(
      onTap: () => toggle(!sel),
      child: Container(
        color: sel ? _navy.withValues(alpha: 0.04) : null,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Checkbox(value: sel, onChanged: (v) => toggle(v ?? false)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(d.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14)),
                    ),
                    const SizedBox(width: 6),
                    qualityBadge(d.quality),
                  ]),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (_brandOf(d).isNotEmpty) _brandOf(d),
                      d.size.replaceAll(' mm', ''),
                    ].join(' · '),
                    style:
                        TextStyle(fontSize: 12.5, color: Colors.grey.shade800),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Surface right next to the quantity box.
            Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (d.hasSurface)
                  Text(d.surfaceCardLabel,
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade800)),
                const SizedBox(height: 3),
                InkWell(
                  onTap: () async {
                    final v = await promptQty(context, sel ? qv : d.fStock);
                    if (v != null) {
                      setState(() {
                        if (v > 0) {
                          _qtys[d.id] = v;
                        } else {
                          _qtys.remove(d.id);
                        }
                      });
                    }
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 68,
                    padding:
                        const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                    decoration: BoxDecoration(
                      color: sel ? _navy.withValues(alpha: 0.05) : null,
                      border: Border.all(
                          color: over
                              ? Colors.red.shade400
                              : (sel ? _navy : Colors.grey.shade400)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(sel ? '$qv' : '+',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 16)),
                            const SizedBox(width: 2),
                            Icon(Icons.edit, size: 12, color: Colors.grey.shade600),
                          ],
                        ),
                        const Text('boxes',
                            style: TextStyle(fontSize: 8.5, color: Colors.grey)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
