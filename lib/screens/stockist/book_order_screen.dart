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
///
/// 🔑 **The BRAND lives here, on the line — not on the order.** A BOX is `(packing, brand)`, and a
/// line points at one, so the brand has always belonged to the line. Holding it on the order made
/// changing it silently rewrite which brand every line's boxes were for. (20260720l)
class _Line {
  _Line(this.tile, this.brandId, this.qty);
  final LibraryEntry tile;
  String brandId;
  int qty;
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

  String? _customerId;
  String _customerName = '';
  final _hint = TextEditingController();
  final _lines = <_Line>[];

  // ── the entry row: brand → design → boxes → Add ────────────────────────────────────────────
  String? _entryBrandId;
  LibraryEntry? _entryTile;
  final _entryQty = TextEditingController();

  /// The cover this customer usually takes — what a fresh entry row resets to.
  String? _customerBrandId;

  String _brandName(String id) =>
      _brands.where((b) => b.id == id).firstOrNull?.name ?? '—';

  /// Every tile ANY brand covers — a BOX must already exist, because booking may not create one.
  /// Which brand a given line goes under is chosen on the line itself.
  List<LibraryEntry> get _bookableTiles =>
      _tiles.where((t) => t.coverBrandIds.isNotEmpty).toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _hint.dispose();
    _entryQty.dispose();
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
    final picked = await CustomerPicker.show(context,
        customers: _customers,
        svc: _data,
        brands: _brands,
        initialBrandId: _entryBrandId);
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
      if (def.isNotEmpty) {
        _customerBrandId = def;
        // Only fills a BLANK row — a brand he has already chosen is his.
        _entryBrandId ??= def;
      }
    });
  }


  /// 🔑 **THE ENTRY ROW: brand → design → boxes → Add.**
  ///
  /// The brand is chosen FIRST, and the design list is then filtered to what that brand actually
  /// covers. Picking the brand afterwards (or on the header) meant the picker had to guess which
  /// cover a design was for, and could hand him a FAMOUS line when he had chosen KHAKHI.
  ///
  /// After Add the row resets to the customer's usual brand, ready for the next line.
  Future<void> _pickEntryDesign() async {
    if (_entryBrandId == null) {
      _snack('Pick the brand first — it decides which designs you can book.',
          error: true);
      return;
    }
    // Only what THIS brand covers, minus pairs already on the order.
    final opts = _tiles
        .where((t) =>
            t.coverBrandIds.contains(_entryBrandId) &&
            !_lines.any(
                (l) => l.tile.id == t.id && l.brandId == _entryBrandId))
        .toList();
    if (opts.isEmpty) {
      final nm = _brandName(_entryBrandId!);
      final covers =
          _tiles.where((t) => t.coverBrandIds.contains(_entryBrandId)).length;
      if (covers == 0) {
        _snack('$nm does not cover any design yet. Open a design in your '
            'Design Library and tick $nm on it.', error: true);
      } else {
        _snack('All $covers design(s) $nm covers are already on this order.');
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
                Text('Designs ${_brandName(_entryBrandId!)} covers',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
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
    if (picked != null) setState(() => _entryTile = picked);
  }

  /// Commit the entry row, then hand him a fresh one on the customer's usual brand.
  void _commitEntry() {
    final qty = int.tryParse(_entryQty.text.trim()) ?? 0;
    if (_entryBrandId == null) {
      _snack('Pick the brand.', error: true);
      return;
    }
    if (_entryTile == null) {
      _snack('Pick the design.', error: true);
      return;
    }
    if (qty <= 0) {
      _snack('Enter how many boxes.', error: true);
      return;
    }
    setState(() {
      _lines.add(_Line(_entryTile!, _entryBrandId!, qty));
      _entryTile = null;
      _entryQty.clear();
      // Back to this customer's usual cover, ready for the next line.
      _entryBrandId = _customerBrandId ?? _entryBrandId;
    });
  }

  Future<void> _save() async {
    final good = _lines.where((l) => l.qty > 0).toList();
    if (good.isEmpty) {
      _snack('Add at least one design with a quantity.', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final res = await _data.createBookOrder(
        hint: _hint.text.trim(),
        customerId: _customerId,
        lines: [
          for (final l in good)
            {
              'library_id': l.tile.id,
              'brand_id': l.brandId,
              'quantity': l.qty,
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
                    Icon(Icons.playlist_add, size: 18, color: _navy),
                    SizedBox(width: 8),
                    Text('Add a design',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14)),
                  ]),
                  const SizedBox(height: 4),
                  Text(
                      'Brand first — it decides which designs you can book. '
                      'Add gives you a fresh row on this customer’s usual brand.',
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                  const SizedBox(height: 10),
                  _entryRow(),
                ]),
                const SizedBox(height: 12),
                _card([
                  Text('On this order  (${_lines.length})',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 14)),
                  if (_bookableTiles.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                          'No design has a brand cover yet. Open a design in your '
                          'Design Library and tick a brand on it first.',
                          style:
                              TextStyle(fontSize: 12, color: Colors.redAccent)),
                    ),
                  if (_lines.isEmpty && _bookableTiles.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text('Nothing added yet.',
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

  /// The entry row: **brand → design → boxes → Add**, in that order, because the brand
  /// decides which designs are bookable at all.
  Widget _entryRow() {
    final tile = _entryTile;
    return Column(children: [
      Row(children: [
        SizedBox(
          width: 140,
          child: DropdownButtonFormField<String>(
            initialValue: _entryBrandId,
            isExpanded: true,
            decoration: _dec('Brand *'),
            hint: const Text('Brand', style: TextStyle(fontSize: 13)),
            items: [
              for (final b in _brands)
                DropdownMenuItem(
                    value: b.id,
                    child: Text(b.name,
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis)),
            ],
            onChanged: _saving
                ? null
                : (v) => setState(() {
                      _entryBrandId = v;
                      // A design chosen under the old brand may not be covered by the new one.
                      if (tile != null && v != null &&
                          !tile.coverBrandIds.contains(v)) {
                        _entryTile = null;
                      }
                    }),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: InkWell(
            onTap: _saving ? null : _pickEntryDesign,
            borderRadius: BorderRadius.circular(10),
            child: InputDecorator(
              decoration: _dec('Design *')
                  .copyWith(suffixIcon: const Icon(Icons.arrow_drop_down)),
              child: Text(tile == null ? 'Pick a design' : _label(tile),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13.5,
                      color: tile == null
                          ? Colors.grey.shade500
                          : Colors.black87)),
            ),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        SizedBox(
          width: 140,
          child: TextField(
            controller: _entryQty,
            enabled: !_saving,
            keyboardType: TextInputType.number,
            decoration: _dec('Boxes *'),
            onSubmitted: (_) => _commitEntry(),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SizedBox(
            height: 44,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _navy),
              onPressed: _saving ? null : _commitEntry,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
            ),
          ),
        ),
      ]),
    ]);
  }

  /// A line already on the order. The brand is settled — it was chosen on the entry row — so this
  /// row shows it as a chip and keeps only what is still worth changing: quantity, grade, star.
  Widget _lineRow(int i) {
    final l = _lines[i];
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
                color: _navy, borderRadius: BorderRadius.circular(6)),
            child: Text(_brandName(l.brandId),
                style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_label(l.tile),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600)),
                Text(l.tile.size,
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              ],
            ),
          ),
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
              key: ValueKey('qty-${l.tile.id}-${l.brandId}'),
              initialValue: '${l.qty}',
              enabled: !_saving,
              keyboardType: TextInputType.number,
              decoration: _dec('Boxes *'),
              onChanged: (v) => l.qty = int.tryParse(v.trim()) ?? 0,
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
