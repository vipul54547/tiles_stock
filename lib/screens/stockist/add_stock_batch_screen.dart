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

  /// The admin canonical surface stored on the holding (for filter/dispatch).
  final String surface;

  /// The stockist's OWN word they picked for it (shown; stored as surface_label).
  /// (project_per_brand_surface_mode)
  final String surfaceLabel;
  int qty;

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
    required this.surface,
    this.surfaceLabel = '',
    required this.qty,
    this.boxPieces,
    this.boxWeightKg,
  });

  /// Same design + brand + quality + SURFACE + WORD = the same holding. Includes
  /// the word so two aliases of one finish stay separate rows.
  String get key => '${master.id}|${brandId ?? ''}|$quality|$surface|$surfaceLabel';
}

class _State extends State<AddStockBatchScreen> {
  final _svc = SupabaseDataService();
  bool _loading = true;
  bool _saving = false;

  List<LibraryEntry> _masters = [];
  List<Brand> _brands = [];
  bool get _isM => currentStockistBusinessType == 'M';

  // The entry currently being built.
  LibraryEntry? _selMaster;
  String? _selBrandId;
  String _selQuality = 'Premium';
  /// The stockist's picked WORD (their alias) — the dropdown value. Stored as
  /// surface_label; its admin canonical (via _canonicalOf) is stored as
  /// surface_type. (project_per_brand_surface_mode)
  String _selSurfaceLabel = '';
  final _qtyCtrl = TextEditingController();

  // Desktop entry bar: one focus node per field, so Tab walks Brand → Design →
  // Surface → Quality → Qty and Enter on Qty adds the line. (Size is read-only
  // and takes no focus, so Tab flows straight past it.)
  final _fBrand = FocusNode();
  final _fDesign = FocusNode();
  final _fSurface = FocusNode();
  final _fQuality = FocusNode();
  final _fQty = FocusNode();

  /// The stockist's pickable surface options: each alias word with its admin
  /// finish, plus admin finishes they have no word for yet.
  List<({String label, String canonical})> _surfOptions = const [];

  /// libraryId → the surface this print was last stocked in, for prefill.
  Map<String, ({String label, String canonical})> _lastSurfaces = const {};

  /// Distinct labels for the dropdown (first wins on a repeat).
  List<String> get _surfLabels {
    final seen = <String>{};
    final out = <String>[];
    for (final o in _surfOptions) {
      if (seen.add(o.label)) out.add(o.label);
    }
    return out;
  }

  /// The admin canonical for a picked word ('None' when None/empty).
  String _canonicalOf(String label) {
    final l = label.trim();
    if (l.isEmpty || l.toLowerCase() == 'none') return 'None';
    for (final o in _surfOptions) {
      if (o.label == l) return o.canonical;
    }
    return l;
  }

  /// The word to show for an entry, '' when None.
  String _surfShown(String label) {
    final t = label.trim();
    return t.isEmpty || t.toLowerCase() == 'none' ? '' : t;
  }

  /// M only: the factory's own convention (its brands share it).
  bool _stockistUsesSurface = false;

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
    _fSurface.dispose();
    _fQuality.dispose();
    _fQty.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final masters = await _svc.getMyLibrary();
    final brands = await _svc.getMyBrands();
    final options = await _svc.getMySurfaceOptions();
    final lastSurfaces = await _svc.getLastSurfaceByLibrary();
    if (!mounted) return;
    setState(() {
      _masters = masters;
      _brands = brands;
      // surface_mode is loaded once at login — no need to re-fetch the profile here.
      _stockistUsesSurface = currentStockistAsksSurface;
      _surfOptions = options;
      _lastSurfaces = lastSurfaces;
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

  // ── Surface (project_per_brand_surface_mode) ──────────────────────────────
  // The library holds the PRINT; the surface is chosen HERE, when the tile is
  // made. Only an M has a convention worth enforcing: it IS the factory, so
  // 'attribute' means every entry must name a surface.
  //
  // A T/W has NO mode. It carries other factories' brands and just records what
  // the dispatch note said — a factory that ships "Satva White" + "Glossy" gets
  // the word picked; one that ships "m.satva white" gets None. The picker,
  // always shown and always offering None, serves both without a setting.

  /// Whether the CURRENT selection REQUIRES a surface. M + attribute only.
  bool get _selNeedsSurface => _selMaster != null && _isM && _stockistUsesSurface;

  /// The surface picker is shown ONLY when the stockist's boxes are stamped with the
  /// surface as a separate field (M + `attribute` — e.g. famous ceramic). Only then does
  /// one stamped name cover several surfaces, so only then is "which surface?" a real
  /// question — and what it is really asking is **which product**.
  ///
  /// Everyone else does NOT see it. Their design name already identifies exactly one
  /// product (a single surface, or the surface encoded in the number range:
  /// 10001-19999 = Glossy, 20001-29999 = Matt), so the product already knows its surface
  /// and the stock inherits it. Asking them to re-state it on every entry is noise.
  /// These attribute stockists are RARE. (product identity migration)
  bool get _selShowSurface => _selNeedsSurface;

  /// The admin canonical to send. **Empty when we did not ask** — an empty surface tells
  /// `stock_add_holding` to INHERIT the product's own surface. It must never be 'None':
  /// 'None' is not a surface, and sending it would look up a product that no longer
  /// exists and create a phantom beside the real one.
  String get _surfaceForEntry =>
      _selNeedsSurface ? _canonicalOf(_selSurfaceLabel) : '';

  /// The stockist's word to store as surface_label ('' when we did not ask).
  String get _labelForEntry {
    if (!_selNeedsSurface) return '';
    final l = _selSurfaceLabel.trim();
    return (l.isEmpty || l.toLowerCase() == 'none') ? '' : l;
  }

  /// Any row in the running list carries a real surface → show the SURFACE column.
  bool get _showSurfaceCol => _entries
      .any((e) => e.surface.isNotEmpty && e.surface.toLowerCase() != 'none');

  // A master's name under a brand (alias) when present, else its master name.
  String _displayName(LibraryEntry m, String? brandId) {
    final alias = brandId == null ? null : m.aliases[brandId];
    return (alias != null && alias.trim().isNotEmpty) ? alias.trim() : m.masterName;
  }

  List<LibraryEntry> _filteredMasters(String query, String? brandFilter) {
    final q = query.trim().toLowerCase();
    return _masters.where((m) {
      if (brandFilter != null &&
          m.brandId != brandFilter &&
          !m.aliases.containsKey(brandFilter)) {
        return false;
      }
      if (q.isEmpty) return true;
      final names = [m.masterName, ...m.aliases.values];
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
            final results = _filteredMasters(query, _brandFilter);
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
                                  title: Text(m.masterName),
                                  // A print has no surface — size only.
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
      // For M, default the brand to the master's own brand if none picked.
      if (_isM && _selBrandId == null && chosen.brandId.isNotEmpty) {
        _selBrandId = chosen.brandId;
      }
      // Prefill the surface this print was last stocked in, so restocking is
      // one tap. Falls back to the library's own word (M + surface-in-name,
      // where the surface really is part of the print), then 'None'. Always
      // editable. When a surface is REQUIRED we leave the last pick standing.
      if (!_selNeedsSurface) {
        _selSurfaceLabel = _rememberedSurface(chosen);
      }
    });
  }

  /// The surface to prefill for [m]: the one this print was last stocked in,
  /// else the word on the library row (M + surface-in-name), else 'None'.
  ///
  /// Only ever returns something the picker can actually show. The dropdown
  /// falls back to 'None' for a value it doesn't hold, which would leave the UI
  /// saying "None" while the entry silently saved something else.
  String _rememberedSurface(LibraryEntry m) {
    final labels = _surfLabels;
    final last = _lastSurfaces[m.id];
    if (last != null) {
      final w = last.label.trim();
      if (labels.contains(w)) return w;
      // Stock entered before this stockist had a word for that finish: prefill
      // THEIR word for the same admin canonical, never the bare canonical.
      final c = last.canonical.trim();
      for (final o in _surfOptions) {
        if (o.canonical == c && labels.contains(o.label)) return o.label;
      }
    }
    final w = m.surfaceLabel.trim();
    return labels.contains(w) ? w : 'None';
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
    if (_selNeedsSurface &&
        (_selSurfaceLabel.trim().isEmpty ||
            _selSurfaceLabel.toLowerCase() == 'none')) {
      _snack('Pick a surface.', Colors.red);
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
      surface: _surfaceForEntry,
      surfaceLabel: _labelForEntry,
      qty: qty,
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
        '${_surfShown(existing.surfaceLabel).isNotEmpty ? '${_surfShown(existing.surfaceLabel)} · ' : ''}'
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
          final r = await _svc.libraryForBox(
            libraryId: e.master.id,
            brandId: e.brandId,
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
          'surface': e.surface,
          'surface_label': e.surfaceLabel,
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
                                  '${_surfShown(e.surfaceLabel).isNotEmpty ? ' · ${_surfShown(e.surfaceLabel)}' : ''}'
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
    final surfMissing = _selNeedsSurface &&
        (_selSurfaceLabel.trim().isEmpty ||
            _selSurfaceLabel.toLowerCase() == 'none');

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
                  onSelected: (b) => setState(() => _selBrandId = b.id),
                ),
                width: 150,
              ),
            _hField(
              'Design',
              ComboField<LibraryEntry>(
                focusNode: _fDesign,
                value: _selMaster,
                options: _filteredMasters('', _brandFilter),
                labelOf: (m) => _displayName(m, _isM ? _selBrandId : null),
                detailOf: (m) => m.size.replaceAll(' mm', ''),
                hint: 'Type to search design',
                hasError: _selMaster == null,
                onSelected: _onDesignChosen,
              ),
              width: 260,
            ),
            _hField('Size (auto)', _hReadonly(sizeText), width: 100),
            // Always in the bar, even before a design is picked — greyed, and
            // skipped by Tab. It used to appear only once a design was chosen,
            // which re-flowed the whole row under the stockist's hands.
            // Only an `attribute` stockist sees this — for everyone else the product
            // already carries its surface and the stock inherits it.
            if (_selShowSurface)
              _hField(
                'Surface *',
                ComboField<String>(
                  focusNode: _fSurface,
                  enabled: true,
                  value: _surfaceOptions.contains(_selSurfaceLabel)
                      ? _selSurfaceLabel
                      : null,
                  options: _surfaceOptions,
                  labelOf: (s) => s,
                  hint: 'Select',
                  hasError: surfMissing,
                  onSelected: (s) => setState(() => _selSurfaceLabel = s),
                ),
                width: 150,
              ),
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

  /// The surface words on offer. **'None' is gone** — a tile always has a surface, and
  /// the picker only appears at all when a surface is genuinely required.
  List<String> get _surfaceOptions => _surfLabels;

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
        design: _displayName(e.master, e.brandId),
        brand: e.brandName?.isNotEmpty == true ? e.brandName! : '—',
        size: e.master.size.replaceAll(' mm', ''),
        surface: _surfShown(e.surfaceLabel).isEmpty ? '—' : _surfShown(e.surfaceLabel),
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
            // Size belongs to the print — shown, never typed.
            if (_selMaster != null) ...[
              const SizedBox(height: 8),
              Row(children: [
                _autoChip(
                    Icons.straighten, _selMaster!.size.replaceAll(' mm', '')),
              ]),
            ],
            // Attribute → required pick; in_name → optional (may tag a surface).
            if (_selShowSurface) ...[
              const SizedBox(height: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_selNeedsSurface ? 'Surface *' : 'Surface',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  ComboField<String>(
                    value: _surfaceOptions.contains(_selSurfaceLabel)
                        ? _selSurfaceLabel
                        : (_selNeedsSurface ? null : 'None'),
                    options: _surfaceOptions,
                    labelOf: (s) => s,
                    hasError: _selNeedsSurface &&
                        (_selSurfaceLabel.trim().isEmpty ||
                            _selSurfaceLabel.toLowerCase() == 'none'),
                    onSelected: (s) => setState(() => _selSurfaceLabel = s),
                  ),
                ],
              ),
            ],
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

  /// "This batch's boxes are packed differently." They enter what is ON the box — pieces and
  /// weight — and nothing else. Whether that makes a new product is the server's 1 mm rule to
  /// decide, not theirs: within 1 mm it is ordinary drift and the stock joins this same design.
  Future<void> _editBox(_Entry e) async {
    final box = e.master.boxes[e.brandId ?? e.master.brandId];
    final pcsCtrl = TextEditingController(
        text: '${e.boxPieces ?? (box?.pieces ?? e.master.piecesPerBox)}');
    final kgCtrl = TextEditingController(
        text: (e.boxWeightKg ?? box?.weightKg ?? e.master.boxWeightKg) > 0
            ? _trimKg(e.boxWeightKg ?? box?.weightKg ?? e.master.boxWeightKg)
            : '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final pcs = int.tryParse(pcsCtrl.text.trim()) ?? 0;
          final kg = double.tryParse(kgCtrl.text.trim()) ?? 0;
          final band = thicknessRangeLabel(
              e.master.size, pcs, kg, e.master.tileType);
          return AlertDialog(
            title: const Text('This batch\'s box'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Only if these boxes are packed differently from before. '
                  'The thickness is worked out from them.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
                const SizedBox(height: 12),
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
                const SizedBox(height: 8),
                Text(
                  band == null
                      ? 'Thickness is worked out from the pieces and box weight.'
                      : 'Thickness: $band',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight:
                        band == null ? FontWeight.normal : FontWeight.w600,
                    color: band == null
                        ? Colors.grey.shade600
                        : Colors.teal.shade700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'A small weight change is the same tile — box weights drift. '
                  'Only a real difference makes a separate design.',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
            actions: [
              if (e.hasBoxOverride)
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Same as before'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: (int.tryParse(pcsCtrl.text.trim()) ?? 0) > 0 &&
                        (double.tryParse(kgCtrl.text.trim()) ?? 0) > 0
                    ? () => Navigator.pop(ctx, true)
                    : null,
                child: const Text('Use this box'),
              ),
            ],
          );
        },
      ),
    );

    if (saved == null || !mounted) return;
    setState(() {
      if (saved) {
        e.boxPieces = int.tryParse(pcsCtrl.text.trim());
        e.boxWeightKg = double.tryParse(kgCtrl.text.trim());
      } else {
        e.boxPieces = null; // back to "same as always"
        e.boxWeightKg = null;
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
                      if (_surfShown(e.surfaceLabel).isNotEmpty) _surfShown(e.surfaceLabel),
                      if (e.brandName?.isNotEmpty == true) e.brandName!,
                      e.quality,
                    ].join(' · '),
                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
                  ),
                  // 🔑 The stockist knows when a batch is packed differently — they can see it on
                  // the box. This is the ONLY place that fact can be reported, because they open
                  // Add stock (not Add design) for a tile already in the library.
                  const SizedBox(height: 3),
                  InkWell(
                    onTap: () => _editBox(e),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        e.hasBoxOverride
                            ? 'Box: ${e.boxPieces} pcs · ${_trimKg(e.boxWeightKg!)} kg'
                            : 'Different box weight?',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: e.hasBoxOverride
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: e.hasBoxOverride
                              ? Colors.teal.shade700
                              : _navy.withValues(alpha: 0.75),
                          decoration: e.hasBoxOverride
                              ? TextDecoration.none
                              : TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
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
