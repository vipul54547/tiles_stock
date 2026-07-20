import 'package:flutter/material.dart';

import '../../models/brand.dart';
import '../../models/choice_state.dart';
import '../../models/library_entry.dart';
import '../../services/supabase_data_service.dart';
import '../../utils/piece_label.dart';
import '../../widgets/customer_picker.dart';

/// 📕 **BOOK ORDER — an order for a tile that has NOT BEEN MADE YET.**
///
/// The stock side of the app starts at the godown: the tile exists, the boxes are on the shelf, the
/// buyer takes what is there. A large part of the trade runs the other way — the customer sees the
/// DESIGN, books an order, and the company produces against it. This screen is that door.
///
/// 🔑 **An order is per CUSTOMER and per BRAND.** He takes his material under one cover, and that
/// cover IS the box. So the brand is asked once, at the top, and every line hangs off it — which is
/// also why the design list only offers tiles that brand actually covers (`coverBrandIds`, the same
/// filter Add Stock uses; a cover WORD is not the truth, the BOX is).
///
/// 🚫 **Booking cannot invent a cover.** If the brand has no cover on a design the server refuses
/// in plain English and tells him to tick it in the Design Library. Same law as adding stock: a
/// cover is DECLARED by a human, never minted by a counter. (20260720e · docs/BOOK_ORDER_PLAN.md)
///
/// ⭐ Urgency is a FLAG, not a date — set here or flipped any time later. Production sorts on it.
/// The customer never sees it.
class BookOrderScreen extends StatefulWidget {
  const BookOrderScreen({super.key});

  @override
  State<BookOrderScreen> createState() => _BookOrderScreenState();
}

/// One booked line, before it is sent.
class _Line {
  _Line(this.tile, this.qty);
  final LibraryEntry tile;
  int qty;
  String? quality; // null = Premium — the grade is settled at the packing line
  bool urgent = false;
}

const _navy = Color(0xFF1B4F72);
const _green = Color(0xFF2E7D32);

class _BookOrderScreenState extends State<BookOrderScreen> {
  final _data = SupabaseDataService();

  bool _loading = true;
  bool _saving = false;

  List<Brand> _brands = [];
  List<LibraryEntry> _tiles = [];
  List<Map<String, dynamic>> _customers = [];

  /// 🔑 The picker must name the PIECE, not the print: one artwork carries several tiles and their
  /// names are identical. `pieceSuffixes` appends the surface (and a forked thickness) exactly as
  /// Add Stock does — composed, never stored. (utils/piece_label.dart)
  Map<String, String> _suffix = const {};

  String _label(LibraryEntry e) => '${e.masterName}${_suffix[e.id] ?? ''}';

  String? _brandId;
  String? _customerId;
  String _customerName = '';
  final _hint = TextEditingController();
  final _lines = <_Line>[];

  Brand? get _brand =>
      _brands.where((b) => b.id == _brandId).firstOrNull;

  /// Only the tiles this brand really covers — a BOX must already exist, because booking may not
  /// create one. An empty list is honest: tick the brand on some designs first.
  List<LibraryEntry> get _coveredTiles => _brandId == null
      ? const []
      : _tiles.where((t) => t.coverBrandIds.contains(_brandId)).toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _hint.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      _data.getMyBrands(),
      _data.getMyLibrary(),
      if (currentStockistCustomersEnabled)
        _data.listCustomers()
      else
        Future.value(<Map<String, dynamic>>[]),
    ]);
    if (!mounted) return;
    setState(() {
      _brands = (results[0] as List<Brand>).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      _tiles = results[1] as List<LibraryEntry>;
      _suffix = pieceSuffixes(_tiles);
      _customers = results[2] as List<Map<String, dynamic>>;
      _loading = false;
    });
  }

  void _snack(String m, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(m), backgroundColor: error ? Colors.red : _green));
  }

  /// 👥 PICK **or ADD** — the same sheet Dispatch and Add Order use, so a customer who walks in
  /// today can be booked without leaving the screen.
  ///
  /// 🏷️ Picking him PREFILLS his brand — the cover he usually takes. Only into a blank: a brand
  /// already chosen for this order is his, and is never overwritten.
  Future<void> _pickCustomer() async {
    final picked =
        await CustomerPicker.show(context, customers: _customers, svc: _data);
    if (picked == null) return;
    final id = (picked['id'] ?? '').toString();
    if (id.isEmpty) return;
    setState(() {
      if (!_customers.any((c) => (c['id'] ?? '').toString() == id)) {
        _customers = [..._customers, picked];
      }
      _customerId = id;
      _customerName = (picked['name'] ?? '').toString();
      final def = (picked['default_brand_id'] ?? '').toString();
      if (def.isNotEmpty && _brandId == null) _brandId = def;
    });
  }

  /// Changing the brand can strand lines whose tile that brand does not cover — drop those rather
  /// than carry a line the server would refuse.
  void _onBrand(String? id) {
    setState(() {
      _brandId = id;
      _lines.removeWhere((l) => id == null || !l.tile.coverBrandIds.contains(id));
    });
  }

  Future<void> _addLine() async {
    final opts = _coveredTiles.where((t) => !_lines.any((l) => l.tile.id == t.id)).toList();
    if (opts.isEmpty) {
      // 🔑 Three different situations, and only one of them is a problem. Saying "covers no other
      // design" for all three read like an error when in fact everything that brand carries was
      // already on the order.
      final name = _brand?.name ?? 'That brand';
      if (_brandId == null) {
        _snack('Pick a brand first.', error: true);
      } else if (_coveredTiles.isEmpty) {
        _snack('$name does not cover any design yet. '
            'Open a design in your Design Library and tick $name on it.',
            error: true);
      } else {
        // Not an error at all — he has simply added everything it carries.
        _snack('All ${_coveredTiles.length} of $name\'s design(s) '
            'are already on this order.');
      }
      return;
    }
    final picked = await showModalBottomSheet<LibraryEntry>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        var q = '';
        return StatefulBuilder(builder: (ctx, setSheet) {
          final shown = opts
              .where((t) =>
                  q.isEmpty ||
                  _label(t).toLowerCase().contains(q.toLowerCase()))
              .toList();
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.7,
              child: Column(children: [
                const SizedBox(height: 12),
                const Text('Pick a design',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                  child: TextField(
                    autofocus: true,
                    onChanged: (v) => setSheet(() => q = v),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search design…',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (_, i) {
                      final t = shown[i];
                      return ListTile(
                        leading: t.imageUrl.isEmpty
                            ? const Icon(Icons.image_outlined)
                            : ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Image.network(t.imageUrl,
                                    width: 44, height: 44, fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        const Icon(Icons.image_outlined))),
                        title: Text(_label(t),
                            style: const TextStyle(fontSize: 14)),
                        subtitle: Text(t.size,
                            style: const TextStyle(fontSize: 12)),
                        onTap: () => Navigator.pop(ctx, t),
                      );
                    },
                  ),
                ),
              ]),
            ),
          );
        });
      },
    );
    if (picked != null) setState(() => _lines.add(_Line(picked, 0)));
  }

  Future<void> _save() async {
    if (_brandId == null) {
      _snack('Pick the brand — a box is its cover.', error: true);
      return;
    }
    final good = _lines.where((l) => l.qty > 0).toList();
    if (good.isEmpty) {
      _snack('Add at least one design with a quantity.', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final res = await _data.createBookOrder(
        hint: _hint.text.trim(),
        brandId: _brandId!,
        customerId: _customerId,
        lines: [
          for (final l in good)
            {
              'library_id': l.tile.id,
              'quantity': l.qty,
              if (l.quality != null) 'quality': l.quality,
              'is_urgent': l.urgent,
            }
        ],
      );
      if (!mounted) return;
      _snack('Order booked — ${res['lines']} design(s).');
      Navigator.pop(context, res);
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      _snack('$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: const Text('Book Order'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 100),
              children: [
                _card([
                  const Text('Who it is for',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 10),
                  if (currentStockistCustomersEnabled) ...[
                    InkWell(
                      onTap: _saving ? null : _pickCustomer,
                      borderRadius: BorderRadius.circular(10),
                      child: InputDecorator(
                        decoration: _dec('Customer').copyWith(
                          suffixIcon: const Icon(Icons.arrow_drop_down),
                        ),
                        child: Text(
                          _customerName.isEmpty
                              ? 'Pick or add a customer'
                              : _customerName,
                          style: TextStyle(
                              fontSize: 14,
                              color: _customerName.isEmpty
                                  ? Colors.grey.shade500
                                  : Colors.black87),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  TextField(
                    controller: _hint,
                    enabled: !_saving,
                    decoration: _dec('Name / note').copyWith(
                        hintText: 'e.g. Rajesh — Surat programme'),
                  ),
                ]),
                const SizedBox(height: 12),
                _card([
                  const Row(children: [
                    Icon(Icons.sell_outlined, size: 18, color: _navy),
                    SizedBox(width: 8),
                    Text('Under which brand',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14)),
                  ]),
                  const SizedBox(height: 4),
                  Text(
                      'The cover this material ships in. It decides which designs you can book.',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade600)),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: _brandId,
                    isExpanded: true,
                    decoration: _dec('Brand *'),
                    hint: const Text('Pick a brand'),
                    items: [
                      for (final b in _brands)
                        DropdownMenuItem(
                            value: b.id,
                            child: Text(b.name, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: _saving ? null : _onBrand,
                  ),
                ]),
                const SizedBox(height: 12),
                _card([
                  Row(children: [
                    const Expanded(
                      child: Text('Designs to produce',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 14)),
                    ),
                    TextButton.icon(
                      onPressed: _saving ? null : _addLine,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add design'),
                    ),
                  ]),
                  if (_brandId != null && _coveredTiles.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                          '${_brand?.name ?? "This brand"} does not cover any design yet. '
                          'Open a design in your Design Library and tick this brand on it first.',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.redAccent)),
                    ),
                  if (_lines.isEmpty && _coveredTiles.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text('No designs yet — press Add design.',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade500)),
                    ),
                  for (int i = 0; i < _lines.length; i++) _lineRow(i),
                ]),
              ],
            ),
      bottomNavigationBar: _loading
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: _green),
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.check),
                    label: Text(_saving ? 'Booking…' : 'Book order'),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _lineRow(int i) {
    final l = _lines[i];
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_label(l.tile),
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600)),
                Text(l.tile.size,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              ],
            ),
          ),
          // ⭐ his own priority mark — not the customer's, and flippable later too
          IconButton(
            tooltip: l.urgent ? 'Urgent' : 'Mark urgent',
            visualDensity: VisualDensity.compact,
            icon: Icon(l.urgent ? Icons.star : Icons.star_border,
                size: 20, color: l.urgent ? Colors.amber.shade700 : Colors.grey),
            onPressed:
                _saving ? null : () => setState(() => l.urgent = !l.urgent),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18, color: Colors.red),
            onPressed: _saving ? null : () => setState(() => _lines.removeAt(i)),
          ),
        ]),
        Row(children: [
          SizedBox(
            width: 110,
            child: TextFormField(
              initialValue: l.qty == 0 ? '' : '${l.qty}',
              enabled: !_saving,
              keyboardType: TextInputType.number,
              decoration: _dec('Boxes *'),
              onChanged: (v) => l.qty = int.tryParse(v.trim()) ?? 0,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: l.quality,
              isExpanded: true,
              decoration: _dec('Quality'),
              // Blank IS the answer: the grade is settled at the packing line.
              hint: const Text('Premium', style: TextStyle(fontSize: 13)),
              items: const [
                DropdownMenuItem(value: null, child: Text('Premium')),
                DropdownMenuItem(value: 'Standard', child: Text('Standard')),
                DropdownMenuItem(value: 'Economy', child: Text('Economy')),
              ],
              onChanged:
                  _saving ? null : (v) => setState(() => l.quality = v),
            ),
          ),
        ]),
        const Divider(height: 18),
      ]),
    );
  }

  Widget _card(List<Widget> children) => Container(
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade200)),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  InputDecoration _dec(String? label) => InputDecoration(
        labelText: label,
        isDense: true,
        filled: true,
        fillColor: const Color(0xFFF7F9FB),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      );
}
