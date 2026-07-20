import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/library_entry.dart';
import '../../models/brand.dart';
import '../../models/choice_state.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../widgets/save_bar.dart';
import '../../widgets/combo_field.dart';
import '../../utils/tile_types.dart';
import '../../utils/piece_label.dart';

/// Batch manual stock entry. The stockist builds a list of rows — each a
/// Design + (M:) Brand + Quality + Quantity — and commits them together. Only
/// the QUANTITY is typed; everything else is a searchable selection. Adding
/// stock only touches P_Stock (no stock list — that's a separate concern), so
/// there is no list picker here. Replaces the old one-design-at-a-time form.
class AddStockBatchScreen extends StatefulWidget {
  final String? initialBrandId;
  const AddStockBatchScreen({super.key, this.initialBrandId});
  @override
  State<AddStockBatchScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);
const _green = Color(0xFF2E7D32);

/// One built-up entry (before commit).
class _Entry {
  final LibraryEntry master;
  final String? brandId;   // M only; null → the master's own brand
  final String? brandName;
  final String quality;
  int qty;

  /// 📦 WHICH PACKING these boxes are. Null = the tile's first (one tile, one packing — the
  /// overwhelmingly common case).
  ///
  /// 🔑 TEN BOXES OF A 5-PIECE PACKING AND TEN OF A 4-PIECE PACKING ARE NOT THE SAME AMOUNT OF
  /// TILE. A box count means nothing without the packing inside it, so the hold points at a BOX
  /// (a packing in a brand's cover) and this is what says which.
  final String? packingId;

  /// 🔑 THIS BATCH's box, when the stockist says it is packed differently from the design's.
  /// Null = same as always (the overwhelmingly common case).
  ///
  /// They report a fact off the box — pieces and weight. They never pick a thickness and never
  /// decide whether it is a new product; the server's 1 mm rule does that. Within 1 mm it is
  /// ordinary weight drift (a 600x1200 2-pc box went 28 kg → 26 kg = 0.62 mm) and the stock joins
  /// the existing design. Beyond it, the design FORKS into a genuinely different tile.
  /// (docs/THICKNESS_AND_BODY_IDENTITY_PLAN.md)
  int? boxPieces;
  double? boxWeightKg;
  bool get hasBoxOverride => boxPieces != null && boxWeightKg != null;

  _Entry({
    required this.master,
    required this.brandId,
    required this.brandName,
    required this.quality,
    required this.qty,
    this.packingId,
    this.boxPieces,
    this.boxWeightKg,
  });

  /// Same BOX + quality = the same holding — and the box is the PACKING in a brand's COVER.
  ///
  /// The packing is in the key because it has to be: ten boxes of a 5-piece packing and ten of a
  /// 4-piece one are different amounts of tile, and merging them into one row of "20 boxes" says
  /// nothing. (The surface is not in the key — it belongs to the piece, and `master.id` already IS
  /// the piece.)
  String get key => '${master.id}|${brandId ?? ''}|${packingId ?? ''}|$quality';
}

class _State extends State<AddStockBatchScreen> {
  final _svc = SupabaseDataService();
  bool _loading = true;
  bool _saving = false;

  List<LibraryEntry> _masters = [];
  List<Brand> _brands = [];
  bool get _isM => currentStockistBusinessType == 'M';

  /// libraryId -> `" — Raindrops (11.5–12.0 mm)"`. A piece has no name of its own, so picking one
  /// by name alone is ambiguous the moment a print carries two: cura's two `6003 (SV)` pieces
  /// (8.4 mm and 11.8 mm) were TWO IDENTICAL ROWS in this picker — and choosing the wrong one adds
  /// boxes to the wrong tile. The suffix (not a whole label) so the name in front can still be the
  /// BOX's word for an M. Rebuilt whenever the library reloads. (utils/piece_label)
  Map<String, String> _pieceSuffix = const {};

  // The entry currently being built.
  LibraryEntry? _selMaster;
  String? _selBrandId;
  String _selQuality = 'Premium';
  /// 🔑 THIS batch's box, when the stockist says these boxes are packed differently. Set in the
  /// form BEFORE Add, because that is when they are looking at the box. Null = same as always.
  /// Whether it becomes a new stock line is the 1 mm rule's decision, not theirs.
  int? _selBoxPieces;
  double? _selBoxWeight;

  /// 📦 The PACKING of the selected design that he is holding boxes of. Null until a design with
  /// more than one packing is chosen — with a single packing there is nothing to ask.
  String? _selPackingId;
  final _qtyCtrl = TextEditingController();

  // Desktop entry bar: one focus node per field, so Tab walks Brand → Design → Quality → Qty and
  // Enter on Qty adds the line. (Size is read-only and takes no focus, so Tab flows straight past
  // it. There is no Surface field — the design picker already named the piece.)
  final _fBrand = FocusNode();
  final _fDesign = FocusNode();
  final _fQuality = FocusNode();
  final _fQty = FocusNode();

  /// The packing of an ENTRY, for the review table — the box he is counting.
  String _packingShown(_Entry e) {
    final list = e.master.packings;
    if (list.isEmpty) return '';
    final p = e.packingId == null
        ? list.first
        : list.firstWhere((x) => x.id == e.packingId, orElse: () => list.first);
    return '${p.pieces} pcs · ${_trimKg(p.weightKg)} kg';
  }

  /// The surface to SHOW for an entry. It belongs to the PIECE and is inherited — nobody chose it
  /// here, and nothing here can change it. His own word when he has one, else the canonical.
  String _surfShown(_Entry e) => pieceSurfaceWord(e.master);

  // Top brand filter — narrows the Design picker (M).
  String? _brandFilter;

  final _entries = <_Entry>[];

  @override
  void initState() {
    super.initState();
    final b = widget.initialBrandId;
    if (b != null && b != 'all' && b.isNotEmpty) {
      _brandFilter = b;
      _selBrandId = b;
    }
    _load();
  }

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _fBrand.dispose();
    _fDesign.dispose();
    _fQuality.dispose();
    _fQty.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final masters = await _svc.getMyLibrary();
    final brands = await _svc.getMyBrands();
    if (!mounted) return;
    setState(() {
      _masters = masters;
      _pieceSuffix = pieceSuffixes(masters);
      _brands = brands;
      _loading = false;
    });
  }

  String _brandNameOf(String? id) {
    if (id == null) return '';
    final m = _brands.where((b) => b.id == id).toList();
    return m.isEmpty ? '' : m.first.name;
  }

  Brand? get _selBrand {
    final m = _brands.where((b) => b.id == _selBrandId).toList();
    return m.isEmpty ? null : m.first;
  }

  // ── Surface ───────────────────────────────────────────────────────────────

  /// 🚫 **ADD STOCK NO LONGER ASKS FOR A SURFACE — nobody sees a surface field here.**
  ///
  /// It used to, for an M whose boxes stamp the surface as a separate field (`attribute`, e.g.
  /// famous). But that picker was a WORKAROUND: the design picker showed only the PRINT's name
  /// (`1001`), which could not tell that print's three pieces apart, so the surface dropdown was
  /// really asking **which product**. The picker now names the PIECE — `1001 — MATTE` — so the
  /// question is already answered, and asking it twice meant the two answers could DISAGREE:
  /// choose `1001 — MATTE`, pick surface `CARV`, and the boxes landed on the **Carving** product
  /// instead. It could also MINT a product outright (famous's list offers `Golden Series`, which
  /// is not a surface at all).
  ///
  /// The stock now INHERITS the piece's own surface, which is what every other stockist already
  /// did. Surface is still product identity — the question just belongs in the Library, where a
  /// product is made, not at the stock counter.
  /// (20260714c_stock_add_holding_never_creates_a_product)

  /// Show the SURFACE column when any row has one. Every piece has a surface (`surface_type` is
  /// NOT NULL), so in practice this is always true — it is read from the PIECE, not chosen here.
  bool get _showSurfaceCol => _entries.any((e) => _surfShown(e).isNotEmpty);

  // A master's name under a brand (alias) when present, else its master name.
  /// Names ONE PIECE of tile. The name in front is the BOX's word when a brand is chosen (an M
  /// reads what is stamped on that brand's box), else the PRINT's. Either way the surface — and,
  /// on a fork, the thickness — is appended, because the name alone does NOT identify a piece:
  /// a print carrying two pieces gives two rows with the same name. (utils/piece_label)
  String _displayName(LibraryEntry m, String? brandId) {
    final alias = brandId == null ? null : m.aliases[brandId];
    final name =
        (alias != null && alias.trim().isNotEmpty) ? alias.trim() : m.masterName;
    return '$name${_pieceSuffix[m.id] ?? ''}';
  }

  /// 🎁 Which brand the design list is for: the one he has PICKED (M shows the field), else the
  /// brand this screen was opened from. Filtering on `_brandFilter` alone left the list unfiltered
  /// whenever he arrived without a brand context and then chose one here.
  String? get _designBrand => _isM ? _selBrandId : _brandFilter;

  List<LibraryEntry> _filteredMasters(String query, String? brandFilter) {
    final q = query.trim().toLowerCase();
    return _masters.where((m) {
      // 🔑 A brand can only be stocked on a design it actually COVERS — the BOX is the truth.
      // Not the cover WORD (a brand may wrap a design and print nothing on it) and not
      // `brandId` (a stale first-seen hint). Offering an uncovered design here was worse than
      // cosmetic: `_box_for` MINTS a missing box, so adding stock invented a cover.
      if (brandFilter != null && !m.coverBrandIds.contains(brandFilter)) {
        return false;
      }
      if (q.isEmpty) return true;
      // The print's word, every box's word, AND the surface — a stockist looking for the Matt one
      // will type "matt", and it is what tells the pieces of a print apart.
      final names = [
        m.masterName,
        ...m.aliases.values,
        pieceSurfaceWord(m),
      ];
      return names.any((n) => n.toLowerCase().contains(q));
    }).toList()
      ..sort((a, b) => a.masterName.compareTo(b.masterName));
  }

  int get _totalBoxes => _entries.fold(0, (s, e) => s + e.qty);

  void _snack(String m, [Color c = _green]) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c));

  // ── Pickers ─────────────────────────────────────────────────────────────

  Future<void> _pickDesign() async {
    final chosen = await showModalBottomSheet<LibraryEntry>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        String query = '';
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final results = _filteredMasters(query, _designBrand);
            return Padding(
              padding: EdgeInsets.only(
                  bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.75,
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    const Text('Select design',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                      child: TextField(
                        autofocus: true,
                        onChanged: (v) => setSheet(() => query = v),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search),
                          hintText: 'Search design name…',
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                    Expanded(
                      child: results.isEmpty
                          ? const Center(child: Text('No designs match.'))
                          : ListView.separated(
                              itemCount: results.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (_, i) {
                                final m = results[i];
                                return ListTile(
                                  leading: ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: m.imageUrl.isEmpty
                                        ? Container(
                                            width: 44, height: 44,
                                            color: Colors.grey.shade100,
                                            child: const Icon(
                                                Icons.image_not_supported,
                                                size: 18, color: Colors.grey))
                                        : CachedNetworkImage(
                                            imageUrl: CloudinaryService.thumbUrl(
                                                m.imageUrl, width: 120),
                                            width: 44, height: 44,
                                            fit: BoxFit.cover,
                                            placeholder: (_, __) => Container(
                                                color: Colors.grey.shade200),
                                            errorWidget: (_, __, ___) =>
                                                Container(
                                                    color:
                                                        Colors.grey.shade200)),
                                  ),
                                  // The PIECE, not the print: two pieces of one print used to be
                                  // two identical rows here. (utils/piece_label)
                                  title: Text(_displayName(m, _isM ? _selBrandId : null)),
                                  // The size belongs to the print; the surface is already in the
                                  // title, because it is what makes this piece a piece.
                                  subtitle: Text(m.size.replaceAll(' mm', '')),
                                  onTap: () => Navigator.pop(ctx, m),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (chosen != null) _onDesignChosen(chosen);
  }

  /// A design was chosen — from the sheet (touch) or the combo field (keyboard).
  void _onDesignChosen(LibraryEntry chosen) {
    setState(() {
      _selMaster = chosen;
      // Default to its FIRST packing. When a design has only one there is no question to ask, and
      // the Packing field is not shown at all.
      _selPackingId =
          chosen.packings.isNotEmpty ? chosen.packings.first.id : null;
      _selBoxPieces = null;   // the override belonged to the previous design
      _selBoxWeight = null;
      // For M, default the brand to the master's own brand if none picked.
      if (_isM && _selBrandId == null && chosen.brandId.isNotEmpty) {
        _selBrandId = chosen.brandId;
      }
    });
  }

  Future<void> _pickBrand() async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        String query = '';
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final results = _brands
                .where((b) =>
                    b.name.toLowerCase().contains(query.trim().toLowerCase()))
                .toList()
              ..sort((a, b) => a.name.compareTo(b.name));
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.6,
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    const Text('Select brand',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                      child: TextField(
                        onChanged: (v) => setSheet(() => query = v),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search),
                          hintText: 'Search brand…',
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        children: [
                          for (final b in results)
                            ListTile(
                              title: Text(b.name),
                              onTap: () => Navigator.pop(ctx, b.id),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (chosen != null) setState(() => _selBrandId = chosen);
  }

  // ── Add / duplicate ───────────────────────────────────────────────────────

  void _resetRow() {
    _selMaster = null;
    _qtyCtrl.clear();
    // The box override belongs to the design that was just added — never carry it onto the next.
    _selBoxPieces = null;
    _selBoxWeight = null;
    // brand + quality + surface kept for faster repeated entry.
  }

  void _addEntry() {
    if (_selMaster == null) {
      _snack('Pick a design first.', Colors.red);
      return;
    }
    if (_isM && _selBrandId == null) {
      _snack('Pick a brand.', Colors.red);
      return;
    }
    final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
    if (qty <= 0) {
      _snack('Enter a quantity.', Colors.red);
      return;
    }
    final e = _Entry(
      master: _selMaster!,
      brandId: _isM ? _selBrandId : null,
      brandName: _isM ? _brandNameOf(_selBrandId) : null,
      quality: _selQuality,
      qty: qty,
      packingId: _selPackingId,
      boxPieces: _selBoxPieces,
      boxWeightKg: _selBoxWeight,
    );
    final idx = _entries.indexWhere((x) => x.key == e.key);
    if (idx >= 0) {
      _resolveDuplicate(idx, e);
      return;
    }
    setState(() {
      // Newest on top — the row you just added is the one you want to check.
      _entries.insert(0, e);
      _resetRow();
    });
  }

  // Same design+brand+quality already in the list: show BOTH quantities and let
  // the stockist Remove one (discard the new) or Add both (sum into one row).
  Future<void> _resolveDuplicate(int existingIdx, _Entry incoming) async {
    final existing = _entries[existingIdx];
    final label =
        '${_displayName(existing.master, existing.brandId)} · '
        '${_surfShown(existing).isNotEmpty ? '${_surfShown(existing)} · ' : ''}'
        '${existing.brandName?.isNotEmpty == true ? '${existing.brandName} · ' : ''}'
        '${existing.quality}';
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Already added'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Text('Existing:  ${existing.qty} boxes'),
            Text('New:        ${incoming.qty} boxes'),
            const SizedBox(height: 8),
            Text('Add both = ${existing.qty + incoming.qty} boxes',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: _green)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'one'),
              child: const Text('Remove one')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, 'both'),
              child: const Text('Add both')),
        ],
      ),
    );
    if (choice == 'both') {
      setState(() {
        existing.qty += incoming.qty;
        _resetRow();
      });
    } else if (choice == 'one') {
      // Keep the existing single row, discard the new one.
      setState(_resetRow);
    }
  }

  Future<void> _editQty(_Entry e) async {
    final ctrl = TextEditingController(text: '${e.qty}');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Boxes'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onSubmitted: (s) =>
              Navigator.pop(ctx, int.tryParse(s.trim()) ?? e.qty),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () =>
                  Navigator.pop(ctx, int.tryParse(ctrl.text.trim()) ?? e.qty),
              child: const Text('Set')),
        ],
      ),
    );
    if (v != null && v > 0) setState(() => e.qty = v);
  }

  Future<void> _addNewDesign() async {
    await context.push('/stockist/library');
    await _load(); // the new design is now selectable
  }

  // ── Save ───────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (_entries.isEmpty) {
      _snack('Add at least one design.', Colors.red);
      return;
    }
    final action = await _confirmSheet();
    if (action != 'save') return; // 'edit' or dismissed → stay on the page

    setState(() => _saving = true);
    try {
      // An entry whose box is packed differently must first be told WHICH product it belongs to.
      // The server compares the thickness this box implies against the design's: within 1 mm it is
      // the same tile (ordinary drift), beyond it the design forks into a different one. Resolve
      // before the batch, then stock against whatever came back.
      var forked = 0;
      final payload = <Map<String, dynamic>>[];
      for (final e in _entries) {
        var libraryId = e.master.id;
        if (e.hasBoxOverride) {
          // Which TILE does a packing of this many pieces at this weight belong to? No brand —
          // the answer is the weight PER PIECE, which is a property of the tile.
          final r = await _svc.tileForPacking(
            libraryId: e.master.id,
            pieces: e.boxPieces!,
            weightKg: e.boxWeightKg!,
          );
          libraryId = (r['library_id'] ?? e.master.id).toString();
          if (r['forked'] == true) forked++;
        }
        payload.add({
          'library_id': libraryId,
          'quality': e.quality,
          'quantity': e.qty,
          'brand_id': e.brandId,
          // 📦 WHICH PACKING these boxes are. The server turns (design + brand + packing) into a
          // BOX — a packing in that brand's cover — and the hold points at it. Null = the tile's
          // first packing. (docs/PACKING_BOX_HOLD_PLAN.md)
          'packing_id': e.packingId,
          // 🚫 NO SURFACE. The piece already knows its own, and the server inherits it. Sending
          // one that contradicts `library_id` is now REFUSED rather than quietly moving the stock
          // to a different product. (20260714c)
        });
      }
      final res = await _svc.addInventoryBatch(payload);
      if (!mounted) return;
      final count = (res['count'] as num?)?.toInt() ?? _entries.length;
      final boxes = (res['boxes'] as num?)?.toInt() ?? _totalBoxes;
      _snack('Added $count design${count == 1 ? '' : 's'} · $boxes boxes.'
          '${forked > 0 ? ' $forked went to a new thickness.' : ''}');
      context.pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('$e', Colors.red);
    }
  }

  // Confirm-or-edit sheet. Only Save + Edit are active; Edit just collapses the
  // sheet and returns to the page for more changes.
  Future<String?> _confirmSheet() {
    return showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Save ${_entries.length} '
                  'design${_entries.length == 1 ? '' : 's'} · $_totalBoxes boxes?',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final e in _entries)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${_displayName(e.master, e.brandId)}'
                                  '${_surfShown(e).isNotEmpty ? ' · ${_surfShown(e)}' : ''}'
                                  '${e.brandName?.isNotEmpty == true ? ' · ${e.brandName}' : ''}'
                                  ' · ${e.quality}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              Text('${e.qty}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, 'edit'),
                      style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 13)),
                      child: const Text('Edit'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(ctx, 'save'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: _green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 13)),
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Wide windows (desktop) get the software-style horizontal entry bar + table;
    // phones keep the stacked card layout. (project_batch_stock_and_grids)
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      appBar: AppBar(title: const Text('Add Stock')),
      bottomNavigationBar: SaveBar(
        label: _entries.isEmpty
            ? 'Save'
            : 'Save ${_entries.length} design${_entries.length == 1 ? '' : 's'} · $_totalBoxes boxes',
        icon: Icons.check,
        color: _green,
        onPressed: _save,
        saving: _saving,
        dirty: _entries.isNotEmpty,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (wide ? _desktopBody() : _mobileBody()),
    );
  }

  Widget _mobileBody() => ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        children: [
          _entryBuilder(),
          const SizedBox(height: 14),
          if (_entries.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text('No entries yet — add designs above.',
                    style: TextStyle(color: Colors.grey.shade500)),
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('${_entries.length} to add · $_totalBoxes boxes',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: Colors.grey.shade700)),
            ),
            const SizedBox(height: 8),
            ..._entries.asMap().entries.map((me) => _entryTile(me.key)),
          ],
        ],
      );

  // ── Desktop: horizontal entry bar + table (matches the stockist's sketch) ────

  Widget _desktopBody() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: _desktopEntryBar(),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: _desktopTable(),
          ),
        ),
      ],
    );
  }

  /// The whole line is enterable from the keyboard:
  ///
  ///   f Tab · delt ↓ Tab · m Tab · p Tab · 40 Enter
  ///
  /// Every field is a [ComboField] — type to filter, ↓ to pick, Tab to move on.
  /// Size is read-only and takes no focus, so Tab flows past it. Enter on the
  /// quantity presses Add and puts the cursor back on Design for the next line.
  ///
  /// Laid out as a Wrap, NOT a Row: Design used to be the only Expanded field
  /// among fixed-width ones, so the moment Surface appeared it was squeezed to a
  /// ~20px slit (its label wrapped to "Desi/gn"). Fixed widths that flow onto a
  /// second line cannot do that.
  Widget _desktopEntryBar() {
    final sizeText =
        _selMaster == null ? '—' : _selMaster!.size.replaceAll(' mm', '');

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            if (_isM)
              _hField(
                'Brand',
                ComboField<Brand>(
                  focusNode: _fBrand,
                  value: _selBrand,
                  options: [..._brands]
                    ..sort((a, b) => a.name.compareTo(b.name)),
                  labelOf: (b) => b.name,
                  hint: 'Select brand',
                  hasError: _selBrandId == null,
                  onSelected: (b) => setState(() {
                    _selBrandId = b.id;
                    // The chosen design may not be covered by the new brand — drop it rather
                    // than carry a pick the list no longer offers.
                    if (_selMaster != null &&
                        !_selMaster!.coverBrandIds.contains(b.id)) {
                      _selMaster = null;
                      _selPackingId = null;
                    }
                  }),
                ),
                width: 150,
              ),
            _hField(
              'Design',
              ComboField<LibraryEntry>(
                focusNode: _fDesign,
                value: _selMaster,
                options: _filteredMasters('', _designBrand),
                labelOf: (m) => _displayName(m, _isM ? _selBrandId : null),
                detailOf: (m) => m.size.replaceAll(' mm', ''),
                hint: 'Type to search design',
                hasError: _selMaster == null,
                onSelected: _onDesignChosen,
              ),
              width: 260,
            ),
            _hField('Size (auto)', _hReadonly(sizeText), width: 100),
            // 📦 WHICH PACKING? Only asked when this design really has more than one — with a
            // single packing there is nothing to choose, and a field with one option is noise.
            //
            // 🔑 It has to be asked when there IS more than one: ten boxes of a 5-piece packing and
            // ten of a 4-piece packing are NOT the same amount of tile.
            if ((_selMaster?.packings.length ?? 0) > 1)
              _hField(
                'Packing *',
                ComboField<String>(
                  value: _selPackingId,
                  options: [for (final p in _selMaster!.packings) p.id],
                  labelOf: (id) {
                    final p =
                        _selMaster!.packings.firstWhere((x) => x.id == id);
                    return '${p.pieces} pcs · ${_trimKg(p.weightKg)} kg';
                  },
                  hint: 'Which box?',
                  hasError: _selPackingId == null,
                  onSelected: (id) => setState(() => _selPackingId = id),
                ),
                width: 170,
              ),
            // 🚫 NO SURFACE FIELD. The design picker already named the PIECE
            // (`1001 — MATTE`), so the surface is decided; the stock inherits it.
            _hField(
              'Quality',
              ComboField<String>(
                focusNode: _fQuality,
                value: _selQuality,
                options: const ['Premium', 'Standard'],
                labelOf: (s) => s,
                onSelected: (s) => setState(() => _selQuality = s),
              ),
              width: 130,
            ),
            _hField('Qty (boxes)', _qtyField(), width: 100),
            SizedBox(
              height: 44,
              child: ElevatedButton.icon(
                onPressed: _addEntryAndFocusDesign,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: _green, foregroundColor: Colors.white),
              ),
            ),
            SizedBox(
              height: 44,
              child: OutlinedButton.icon(
                onPressed: _addNewDesign,
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                label: const Text('New design'),
                style: OutlinedButton.styleFrom(foregroundColor: _navy),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Add the line, then put the cursor back on Design — the stockist is always
  /// entering another one.
  void _addEntryAndFocusDesign() {
    final before = _entries.length;
    _addEntry();
    // Only jump on a real add. A rejected row (no qty, no surface) must keep the
    // cursor where the stockist can fix it.
    if (_entries.length > before) _fDesign.requestFocus();
  }

  Widget _hField(String label, Widget child, {double? width}) {
    final col = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade600)),
        const SizedBox(height: 5),
        child,
      ],
    );
    return width == null ? col : SizedBox(width: width, child: col);
  }

  Widget _hReadonly(String value) => Container(
        height: 44,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
            color: Colors.grey.shade100,
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(8)),
        child: Text(value,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade700)),
      );

  /// Desktop quantity. The last field of the line, so Enter here means Add.
  Widget _qtyField() => SizedBox(
        height: 44,
        child: TextField(
          controller: _qtyCtrl,
          focusNode: _fQty,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onSubmitted: (_) => _addEntryAndFocusDesign(),
          decoration: InputDecoration(
            hintText: '0',
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      );

  Widget _desktopTable() {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            color: const Color(0xFFF3F5F8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: _tableRow(
              design: 'DESIGN',
              brand: 'BRAND',
              size: 'SIZE',
              surface: 'SURFACE',
              quality: 'QUALITY',
              qty: 'QTY (BOXES)',
              header: true,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _entries.isEmpty
                ? Center(
                    child: Text(
                        'No entries yet — pick a design above and press Add.',
                        style: TextStyle(color: Colors.grey.shade500)),
                  )
                : ListView.separated(
                    itemCount: _entries.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) => _desktopRow(i),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _desktopRow(int i) {
    final e = _entries[i];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: _tableRow(
        // The design carries its PACKING, because that is what he is counting boxes of. Without it
        // a row saying "10 boxes" does not say how much tile.
        design: _packingShown(e).isEmpty
            ? _displayName(e.master, e.brandId)
            : '${_displayName(e.master, e.brandId)}   ·   ${_packingShown(e)}',
        brand: e.brandName?.isNotEmpty == true ? e.brandName! : '—',
        size: e.master.size.replaceAll(' mm', ''),
        surface: _surfShown(e).isEmpty ? '—' : _surfShown(e),
        quality: e.quality,
        qty: '${e.qty}',
        onQty: () => _editQty(e),
        onRemove: () => setState(() => _entries.removeAt(i)),
      ),
    );
  }

  Widget _tableRow({
    required String design,
    required String brand,
    required String size,
    required String surface,
    required String quality,
    required String qty,
    bool header = false,
    VoidCallback? onQty,
    VoidCallback? onRemove,
  }) {
    final labelStyle = TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: Colors.grey.shade600,
        letterSpacing: 0.4);
    const cellStyle = TextStyle(fontSize: 13);
    Widget qualityCell() {
      if (header) return Text(quality, style: labelStyle);
      final amber = quality == 'Premium';
      final c = amber ? const Color(0xFFB26206) : const Color(0xFF1565C0);
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
          decoration: BoxDecoration(
              color: c.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999)),
          child: Text(quality,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700, color: c)),
        ),
      );
    }

    return Row(
      children: [
        Expanded(
            flex: 3,
            child: Text(design,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: header
                    ? labelStyle
                    : cellStyle.copyWith(fontWeight: FontWeight.w600))),
        Expanded(
            flex: 2,
            child: Text(brand,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: header ? labelStyle : cellStyle)),
        SizedBox(
            width: 90,
            child: Text(size, style: header ? labelStyle : cellStyle)),
        if (_showSurfaceCol)
          SizedBox(
              width: 110,
              child: Text(surface,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: header ? labelStyle : cellStyle)),
        SizedBox(width: 120, child: qualityCell()),
        SizedBox(
          width: 90,
          child: header
              ? Text(qty, style: labelStyle, textAlign: TextAlign.right)
              : Align(
                  alignment: Alignment.centerRight,
                  child: InkWell(
                    onTap: onQty,
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                          color: _navy.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(6)),
                      child: Text(qty,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: _navy)),
                    ),
                  ),
                ),
        ),
        SizedBox(
          width: 40,
          child: header
              ? const SizedBox()
              : IconButton(
                  icon: Icon(Icons.delete_outline,
                      size: 20, color: Colors.red.shade400),
                  onPressed: onRemove,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
        ),
      ],
    );
  }

  Widget _entryBuilder() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // M brand filter (narrows the design list).
            if (_isM) ...[
              _selectField(
                label: 'Brand',
                value: _selBrandId == null
                    ? 'Select brand'
                    : _brandNameOf(_selBrandId),
                icon: Icons.storefront_outlined,
                onTap: _pickBrand,
                placeholder: _selBrandId == null,
              ),
              const SizedBox(height: 10),
            ],
            _selectField(
              label: 'Design',
              value: _selMaster == null
                  ? 'Search & select design'
                  : _displayName(_selMaster!, _isM ? _selBrandId : null),
              icon: Icons.grid_view_rounded,
              onTap: _pickDesign,
              placeholder: _selMaster == null,
            ),
            // Size and SURFACE belong to the print — shown, never typed. Both are part of what
            // makes this tile this tile, so the stockist can see at a glance which one they picked.
            if (_selMaster != null) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                _autoChip(
                    Icons.straighten, _selMaster!.size.replaceAll(' mm', '')),
                if (_selSurfaceOfMaster.isNotEmpty)
                  _autoChip(Icons.texture, _selSurfaceOfMaster),
                if (_selMaster!.thicknessMm != null)
                  _autoChip(Icons.height,
                      thicknessBandLabel(_selMaster!.thicknessMm) ?? ''),
              ]),
              const SizedBox(height: 6),
              // 🔑 The ONLY place a different packing can be reported. They open Add stock (not
              // Add design) for a tile they already have, so this is where they notice the boxes
              // are packed differently. They enter what is ON the box; the 1 mm rule decides
              // whether it becomes a separate stock line.
              InkWell(
                onTap: _editSelBox,
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text(
                    _selBoxPieces != null && _selBoxWeight != null
                        ? 'This batch: $_selBoxPieces pcs · '
                            '${_trimKg(_selBoxWeight!)} kg  (tap to change)'
                        : 'Different pieces or box weight?',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: _selBoxPieces != null
                          ? FontWeight.w600
                          : FontWeight.normal,
                      color: _selBoxPieces != null
                          ? Colors.teal.shade700
                          : _navy.withValues(alpha: 0.8),
                      decoration: _selBoxPieces != null
                          ? TextDecoration.none
                          : TextDecoration.underline,
                    ),
                  ),
                ),
              ),
            ],
            // 🚫 NO SURFACE FIELD — see the desktop bar. The piece is already chosen.
            // Each control sits beside the button it belongs with: pick the
            // quality of a design you may still need to create, then type the
            // boxes and Add.
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Quality',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      SegmentedButton<String>(
                        showSelectedIcon: false,
                        style: ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          textStyle: WidgetStateProperty.all(
                              const TextStyle(fontSize: 12)),
                        ),
                        segments: const [
                          ButtonSegment(value: 'Premium', label: Text('Premium')),
                          ButtonSegment(value: 'Standard', label: Text('Standard')),
                        ],
                        selected: {_selQuality},
                        onSelectionChanged: (s) =>
                            setState(() => _selQuality = s.first),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 44,
                    child: OutlinedButton.icon(
                      onPressed: _addNewDesign,
                      icon: const Icon(Icons.add_photo_alternate_outlined,
                          size: 18),
                      label: const Text('New design',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: _navy,
                          padding: const EdgeInsets.symmetric(horizontal: 8)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Quantity',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      SizedBox(
                        height: 44,
                        child: TextField(
                          controller: _qtyCtrl,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly
                          ],
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'Boxes',
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 12),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 44,
                    child: ElevatedButton.icon(
                      onPressed: _addEntry,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: _navy,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 8)),
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

  // A read-only fact about the chosen design (size, surface) — phone layout.
  Widget _autoChip(IconData icon, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.grey.shade600),
            const SizedBox(width: 5),
            Text(text,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade700)),
          ],
        ),
      );

  Widget _selectField({
    required String label,
    required String value,
    required IconData icon,
    required VoidCallback onTap,
    required bool placeholder,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade400),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(icon, size: 18, color: _navy),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          color: placeholder
                              ? Colors.grey.shade500
                              : Colors.black87)),
                ),
                Icon(Icons.arrow_drop_down, color: Colors.grey.shade600),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static String _trimKg(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  /// The selected design's own surface, as the stockist's own word where they have one.
  String get _selSurfaceOfMaster {
    final m = _selMaster;
    if (m == null) return '';
    final word = m.surfaceLabel.trim();
    final canon = m.surfaceType.trim();
    if (word.isEmpty || word.toLowerCase() == canon.toLowerCase()) return canon;
    return '$word ($canon)';
  }

  /// What WILL happen if this box is used — worked out with the same rule the server applies, so
  /// the stockist is told before they commit, never surprised after.
  ///
  /// Within 1 mm of a design they already have → the SAME tile (box weights drift). Beyond it →
  /// a genuinely different tile, which becomes its own stock line.
  ({bool forks, String verdict, String? band}) _boxVerdict(int pcs, double kg) {
    final m = _selMaster!;
    final mm = approxThicknessMm(m.size, pcs, kg, m.tileType);
    if (mm == null) {
      return (
        forks: false,
        verdict: 'Enter the pieces and box weight.',
        band: null
      );
    }
    // every product of this same print + size + surface + body
    final siblings = _masters.where((o) =>
        o.masterName.toLowerCase() == m.masterName.toLowerCase() &&
        o.size == m.size &&
        o.surfaceType == m.surfaceType &&
        o.tileType == m.tileType &&
        o.thicknessMm != null);

    LibraryEntry? near;
    for (final o in siblings) {
      if ((o.thicknessMm! - mm).abs() <= 1.0) {
        if (near == null ||
            (o.thicknessMm! - mm).abs() < (near.thicknessMm! - mm).abs()) {
          near = o;
        }
      }
    }
    final band = thicknessBandLabel(mm);
    if (near != null) {
      final diff = (near.thicknessMm! - mm).abs().toStringAsFixed(2);
      return (
        forks: false,
        verdict: 'Same design — only $diff mm different, which is normal box-weight drift. '
            'The stock goes on the SAME row.',
        band: band,
      );
    }
    return (
      forks: true,
      verdict: 'This is a different tile — more than 1 mm thicker or thinner. '
          'It will become a NEW stock line, shown as ($band).',
      band: band,
    );
  }

  /// "These boxes are packed differently." Shows the design's ORIGINAL box, takes the new one,
  /// works out what it means, and asks before applying it.
  Future<void> _editSelBox() async {
    final m = _selMaster;
    if (m == null) return;
    // The tile's PACKING — brand-free. A tile may have several; the first is the reference the
    // 1 mm rule measures drift against.
    final pk = m.packings.isNotEmpty ? m.packings.first : null;
    final origPcs = pk?.pieces ?? m.piecesPerBox;
    final origKg = pk?.weightKg ?? m.boxWeightKg;

    final pcsCtrl = TextEditingController(
        text: _selBoxPieces != null ? '$_selBoxPieces' : '');
    final kgCtrl = TextEditingController(
        text: _selBoxWeight != null ? _trimKg(_selBoxWeight!) : '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        final pcs = int.tryParse(pcsCtrl.text.trim()) ?? 0;
        final kg = double.tryParse(kgCtrl.text.trim()) ?? 0;
        final ready = pcs > 0 && kg > 0;
        final v = ready ? _boxVerdict(pcs, kg) : null;

        return AlertDialog(
          title: const Text('This batch\'s box'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // What this design is packed as TODAY — so they can compare against the box in
                // front of them rather than remember it.
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Currently',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey.shade700)),
                      const SizedBox(height: 3),
                      Text(
                        origPcs > 0 && origKg > 0
                            ? '$origPcs pcs · ${_trimKg(origKg)} kg'
                                '${m.thicknessMm != null ? '  ·  ${thicknessBandLabel(m.thicknessMm)}' : ''}'
                            : 'No box recorded yet',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text('This batch',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade700)),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: pcsCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'Pieces / box',
                          border: OutlineInputBorder(),
                          isDense: true),
                      onChanged: (_) => setLocal(() {}),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: kgCtrl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                          labelText: 'Box weight (kg)',
                          border: OutlineInputBorder(),
                          isDense: true),
                      onChanged: (_) => setLocal(() {}),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                // The answer, BEFORE they commit to it.
                if (v != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: (v.forks ? Colors.teal : Colors.blueGrey)
                          .withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Thickness: ${v.band}',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: v.forks
                                    ? Colors.teal.shade800
                                    : Colors.blueGrey.shade800)),
                        const SizedBox(height: 4),
                        Text(v.verdict,
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade800)),
                      ],
                    ),
                  )
                else
                  Text('Enter the pieces and box weight.',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Discard'),
            ),
            FilledButton(
              onPressed: ready ? () => Navigator.pop(ctx, true) : null,
              child: const Text('Save'),
            ),
          ],
        );
      }),
    );

    if (saved == null || !mounted) return;
    setState(() {
      if (saved) {
        _selBoxPieces = int.tryParse(pcsCtrl.text.trim());
        _selBoxWeight = double.tryParse(kgCtrl.text.trim());
      } else {
        _selBoxPieces = null; // discard → back to the design's own box
        _selBoxWeight = null;
      }
    });
  }

  Widget _entryTile(int i) {
    final e = _entries[i];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_displayName(e.master, e.brandId),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(
                    [
                      e.master.size.replaceAll(' mm', ''),
                      if (_surfShown(e).isNotEmpty) _surfShown(e),
                      if (e.brandName?.isNotEmpty == true) e.brandName!,
                      e.quality,
                    ].join(' · '),
                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
                  ),
                  if (e.hasBoxOverride) ...[
                    const SizedBox(height: 3),
                    Text(
                      'This batch: ${e.boxPieces} pcs · ${_trimKg(e.boxWeightKg!)} kg',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.teal.shade700),
                    ),
                  ],
                ],
              ),
            ),
            InkWell(
              onTap: () => _editQty(e),
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: _navy.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('${e.qty}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: _navy)),
              ),
            ),
            IconButton(
              icon: Icon(Icons.delete_outline,
                  size: 20, color: Colors.red.shade400),
              onPressed: () => setState(() => _entries.removeAt(i)),
            ),
          ],
        ),
      ),
    );
  }
}
