import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/tile_design.dart';
import '../../models/brand.dart';
import '../../models/library_entry.dart';
import '../../models/choice_state.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../widgets/filter_section.dart';

// Stock Control — the stockist sets C_Quantity (boxes to HOLD BACK) per holding;
// F_Stock = max(0, P − H − C) is shown live and is what dealers see. H (bookings)
// is 0 in Phase 1. Rows are grouped: M by master_design_name, T/W by design name.
// (project_fstock_model)
class StockControlScreen extends StatefulWidget {
  const StockControlScreen({super.key});
  @override
  State<StockControlScreen> createState() => _StockControlScreenState();
}

class _StockControlScreenState extends State<StockControlScreen> {
  static const _navy = Color(0xFF1B4F72);

  final _data = SupabaseDataService();
  final _searchCtrl = TextEditingController();

  List<TileDesign> _designs = [];
  List<Brand> _brands = [];
  // libraryId → all brand-alias names (lowercased) of that master — for M search
  // that surfaces the whole master group even when a related alias doesn't match.
  final Map<String, Set<String>> _aliasByLib = {};
  // designId → editable control-quantity input (seeded from controlQuantity).
  final Map<String, TextEditingController> _ctrls = {};

  String _search = '';
  String _brandFilter = 'all';
  final Set<String> _sizes = {};
  final Set<String> _qualities = {};
  final Set<String> _surfaces = {};
  final Set<String> _colours = {};
  final Set<String> _types = {};
  // F_Stock (shown qty) range filter — blank = no bound.
  final _minFCtrl = TextEditingController();
  final _maxFCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;

  int get _activeFilterCount =>
      _sizes.length +
      _qualities.length +
      _surfaces.length +
      _colours.length +
      _types.length +
      (_minFCtrl.text.trim().isNotEmpty ? 1 : 0) +
      (_maxFCtrl.text.trim().isNotEmpty ? 1 : 0);

  bool get _isM => currentStockistBusinessType == 'M';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(
        () => setState(() => _search = _searchCtrl.text.trim().toLowerCase()));
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _minFCtrl.dispose();
    _maxFCtrl.dispose();
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final designs = await _data.getDesignsByStockist(currentStockistUUID);
    final brands = await _data.getMyBrands();
    final lib = await _data.getMyLibrary();
    _aliasByLib.clear();
    for (final LibraryEntry e in lib) {
      final names = <String>{e.masterName.toLowerCase()};
      names.addAll(e.aliases.values.map((v) => v.toLowerCase()));
      _aliasByLib[e.id] = names;
    }
    for (final c in _ctrls.values) {
      c.dispose();
    }
    _ctrls.clear();
    for (final d in designs) {
      _ctrls[d.id] = TextEditingController(
          text: d.controlQuantity > 0 ? '${d.controlQuantity}' : '');
    }
    if (!mounted) return;
    setState(() {
      _designs = designs;
      _brands = brands;
      _loading = false;
    });
  }

  // ── filtering ────────────────────────────────────────────────────────────
  bool _matchesSearch(TileDesign d) {
    if (_search.isEmpty) return true;
    if (d.name.toLowerCase().contains(_search)) return true;
    if (d.masterDesignName.toLowerCase().contains(_search)) return true;
    // M: surface the whole master group — match any brand alias of this master.
    if (_isM) {
      final aliases = _aliasByLib[d.libraryId];
      if (aliases != null && aliases.any((a) => a.contains(_search))) return true;
    }
    return false;
  }

  List<TileDesign> get _filtered {
    final minF = int.tryParse(_minFCtrl.text.trim());
    final maxF = int.tryParse(_maxFCtrl.text.trim());
    return _designs.where((d) {
      if (!_matchesSearch(d)) return false;
      if (_brandFilter != 'all' && d.brandId != _brandFilter) return false;
      if (_sizes.isNotEmpty && !_sizes.contains(d.size)) return false;
      if (_qualities.isNotEmpty && !_qualities.contains(d.quality)) return false;
      if (_surfaces.isNotEmpty && !_surfaces.contains(d.surfaceWord)) return false;
      if (_colours.isNotEmpty && !_colours.contains(d.colour)) return false;
      if (_types.isNotEmpty && !_types.contains(d.tileType)) return false;
      final f = _fOf(d); // range filters on F_Stock (what dealers see)
      if (minF != null && f < minF) return false;
      if (maxF != null && f > maxF) return false;
      return true;
    }).toList();
  }

  // Group key: M → master design name; T/W → the holding's own name.
  String _groupKey(TileDesign d) {
    final m = d.masterDesignName.trim();
    return _isM && m.isNotEmpty ? m : d.name.trim();
  }

  // Ordered groups: rows within a group stay contiguous (by size/quality/
  // surface). Groups are ordered to save the stockist scrolling — designs
  // they've ALREADY controlled come first (so they can review/adjust without
  // hunting), then by biggest stock (most boxes) first, then alphabetical as a
  // tiebreak. Uses the SAVED control value (d.controlQuantity), not the live
  // edited one, so rows don't jump around while typing.
  List<MapEntry<String, List<TileDesign>>> get _groups {
    final map = <String, List<TileDesign>>{};
    for (final d in _filtered) {
      (map[_groupKey(d)] ??= []).add(d);
    }
    for (final rows in map.values) {
      rows.sort((a, b) {
        final s = a.size.compareTo(b.size);
        if (s != 0) return s;
        final q = a.quality.compareTo(b.quality);
        if (q != 0) return q;
        return a.surfaceType.compareTo(b.surfaceType);
      });
    }
    bool controlled(List<TileDesign> rows) =>
        rows.any((d) => d.controlQuantity > 0);
    int maxBoxes(List<TileDesign> rows) =>
        rows.fold(0, (m, d) => d.boxQuantity > m ? d.boxQuantity : m);
    final entries = map.entries.toList()
      ..sort((a, b) {
        // 1) controlled groups first
        final ca = controlled(a.value), cb = controlled(b.value);
        if (ca != cb) return ca ? -1 : 1;
        // 2) most boxes first
        final box = maxBoxes(b.value).compareTo(maxBoxes(a.value));
        if (box != 0) return box;
        // 3) alphabetical tiebreak (stable)
        return a.key.toLowerCase().compareTo(b.key.toLowerCase());
      });
    return entries;
  }

  int _controlOf(TileDesign d) {
    final t = _ctrls[d.id]?.text.trim() ?? '';
    return int.tryParse(t.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
  }

  int _fOf(TileDesign d) {
    final f = d.boxQuantity - _controlOf(d) - d.heldQuantity; // F = max(0, P−C−H)
    return f < 0 ? 0 : f;
  }

  Future<void> _save() async {
    // Only changed rows; clamp C to ≤ P (can't hide more than you have).
    final changed = <({String id, int controlQuantity})>[];
    for (final d in _designs) {
      // Over-hold is allowed (C may exceed P) — acts as a sticky full-hide that
      // survives a future restock. F is still clamped at 0. (fstock model)
      final c = _controlOf(d);
      if (c != d.controlQuantity) {
        changed.add((id: d.id, controlQuantity: c));
      }
    }
    if (changed.isEmpty) {
      Navigator.of(context).pop(false);
      return;
    }
    setState(() => _saving = true);
    try {
      await _data.setControlQuantities(changed);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save — $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    final multiBrand = _brands.length > 1;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Stock control'),
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        actions: [
          _saving
              ? const Padding(
                  padding: EdgeInsets.only(right: 16),
                  child: Center(
                      child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))),
                )
              : TextButton(
                  onPressed: _save,
                  child: const Text('Save',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _searchAndFilters(multiBrand),
                const Divider(height: 1),
                Expanded(
                  child: groups.isEmpty
                      ? Center(
                          child: Text(
                              _designs.isEmpty
                                  ? 'No stock yet.'
                                  : 'No designs match your filters.',
                              style: TextStyle(color: Colors.grey.shade600)),
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                          children: [
                            for (final g in groups) ...[
                              _groupHeader(g.key, g.value.length),
                              for (final d in g.value) _row(d),
                            ],
                          ],
                        ),
                ),
              ],
            ),
    );
  }

  Widget _searchAndFilters(bool multiBrand) {
    Widget brandChip(String label, bool sel, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: FilterChip(
            label: Text(label, style: const TextStyle(fontSize: 12)),
            selected: sel,
            onSelected: (_) => onTap(),
            selectedColor: _navy.withValues(alpha: 0.15),
            checkmarkColor: _navy,
            visualDensity: VisualDensity.compact,
          ),
        );
    final active = _activeFilterCount;
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: 'Search design name…',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _search.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () => _searchCtrl.clear())
                        : null,
                    isDense: true,
                    filled: true,
                    fillColor: const Color(0xFFF5F5F5),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _openFilterSheet,
                icon: const Icon(Icons.tune, size: 18),
                label: Text(active > 0 ? 'Filters ($active)' : 'Filters'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: _navy,
                    side: BorderSide(
                        color: active > 0 ? _navy : Colors.grey.shade400)),
              ),
            ],
          ),
          if (multiBrand) ...[
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  brandChip('All brands', _brandFilter == 'all',
                      () => setState(() => _brandFilter = 'all')),
                  for (final b in _brands)
                    brandChip(b.name, _brandFilter == b.id,
                        () => setState(() => _brandFilter = b.id)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Rich filter sheet (mirrors the Stock page): multi-select facets + an F_Stock
  // (shown qty) range. Edits local copies; Apply commits, Reset clears.
  Future<void> _openFilterSheet() async {
    final sizes = _designs.map((d) => d.size).toSet().toList()..sort();
    final surfaces = _designs
        .where((d) => d.hasSurface)
        .map((d) => d.surfaceWord) // the stockist's own word
        .toSet()
        .toList()
      ..sort();
    final colours = _designs
        .map((d) => d.colour)
        .where((c) => c.trim().isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final types = _designs
        .map((d) => d.tileType)
        .where((t) => t.trim().isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final qualities = _designs.map((d) => d.quality).toSet().toList()..sort();

    final lSizes = Set<String>.from(_sizes);
    final lQual = Set<String>.from(_qualities);
    final lSurf = Set<String>.from(_surfaces);
    final lCol = Set<String>.from(_colours);
    final lType = Set<String>.from(_types);
    var showMore = false; // reveal advanced facets (Tile Type, Colour)
    final minCtrl = TextEditingController(text: _minFCtrl.text);
    final maxCtrl = TextEditingController(text: _maxFCtrl.text);

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget chip(String label, bool sel, VoidCallback onTap) => FilterChip(
                label: Text(label, style: const TextStyle(fontSize: 12)),
                selected: sel,
                onSelected: (_) => setSheet(onTap),
                selectedColor: _navy.withValues(alpha: 0.15),
                checkmarkColor: _navy,
                visualDensity: VisualDensity.compact,
              );
          Widget chipWrap(List<String> opts, Set<String> sel) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final o in opts)
                    chip(o.replaceAll(' mm', ''), sel.contains(o),
                        () => sel.toggle(o)),
                ],
              );
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.7,
            maxChildSize: 0.92,
            builder: (_, scroll) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Row(
                    children: [
                      const Text('Filters',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setSheet(() {
                          lSizes.clear();
                          lQual.clear();
                          lSurf.clear();
                          lCol.clear();
                          lType.clear();
                          minCtrl.clear();
                          maxCtrl.clear();
                        }),
                        child: const Text('Reset all',
                            style: TextStyle(color: Colors.red, fontSize: 13)),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: Colors.grey.shade200),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    children: [
                      const Text('Shown qty (F)',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13)),
                      const SizedBox(width: 12),
                      Expanded(child: _rangeBox(minCtrl, 'Min')),
                      const SizedBox(width: 8),
                      Expanded(child: _rangeBox(maxCtrl, 'Max')),
                    ],
                  ),
                ),
                Divider(height: 1, color: Colors.grey.shade200),
                Expanded(
                  child: ListView(
                    controller: scroll,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      // Essentials — always visible.
                      if (sizes.isNotEmpty)
                        FilterSection(
                            title: 'Size',
                            summary: filterSummary(lSizes),
                            child: chipWrap(sizes, lSizes)),
                      FilterSection(
                          title: 'Quality',
                          summary: filterSummary(lQual),
                          child: chipWrap(qualities, lQual)),
                      if (surfaces.isNotEmpty)
                        FilterSection(
                            title: 'Finish',
                            summary: filterSummary(lSurf),
                            child: chipWrap(surfaces, lSurf)),
                      // Advanced — behind the "More filters" toggle.
                      if (types.isNotEmpty || colours.isNotEmpty)
                        MoreFiltersToggle(
                          expanded: showMore,
                          activeHidden: (lType.isNotEmpty ? 1 : 0) +
                              (lCol.isNotEmpty ? 1 : 0),
                          onToggle: () => setSheet(() => showMore = !showMore),
                        ),
                      if (showMore) ...[
                        if (types.isNotEmpty)
                          FilterSection(
                              title: 'Tile Type',
                              summary: filterSummary(lType),
                              child: chipWrap(types, lType)),
                        if (colours.isNotEmpty)
                          FilterSection(
                              title: 'Colour',
                              summary: filterSummary(lCol),
                              child: chipWrap(colours, lCol)),
                      ],
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: ElevatedButton.styleFrom(
                            backgroundColor: _navy,
                            foregroundColor: Colors.white),
                        child: const Text('Apply'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (ok == true) {
      setState(() {
        _sizes
          ..clear()
          ..addAll(lSizes);
        _qualities
          ..clear()
          ..addAll(lQual);
        _surfaces
          ..clear()
          ..addAll(lSurf);
        _colours
          ..clear()
          ..addAll(lCol);
        _types
          ..clear()
          ..addAll(lType);
        _minFCtrl.text = minCtrl.text.trim();
        _maxFCtrl.text = maxCtrl.text.trim();
      });
    }
    minCtrl.dispose();
    maxCtrl.dispose();
  }

  Widget _rangeBox(TextEditingController c, String hint) => TextField(
        controller: c,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          border:
              OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );

  Widget _groupHeader(String name, int count) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 12, 6, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(name.isEmpty ? '(unnamed)' : name,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13.5,
                      color: _navy)),
            ),
            Text('$count', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          ],
        ),
      );

  Widget _row(TileDesign d) {
    final p = d.boxQuantity;
    final f = _fOf(d);
    final img = d.faceImageUrls.isNotEmpty ? d.faceImageUrls.first : '';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 44,
                height: 44,
                child: img.isEmpty
                    ? Container(
                        color: Colors.grey.shade200,
                        child: Icon(Icons.image_outlined,
                            size: 18, color: Colors.grey.shade400))
                    : CachedNetworkImage(
                        imageUrl: CloudinaryService.thumbUrl(img, width: 120),
                        fit: BoxFit.cover,
                        placeholder: (_, __) =>
                            Container(color: Colors.grey.shade100),
                        errorWidget: (_, __, ___) => Container(
                            color: Colors.grey.shade200,
                            child: const Icon(Icons.broken_image_outlined,
                                size: 16)),
                      ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(
                      [
                        d.size.replaceAll(' mm', ''),
                        d.quality,
                        if (d.hasSurface) d.displaySurface,
                        if (d.brandName.trim().isNotEmpty) d.brandName,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _fig('P', p, Colors.grey.shade600),
                      const SizedBox(width: 10),
                      _fig('H', d.heldQuantity, const Color(0xFF1565C0)),
                      const SizedBox(width: 10),
                      _fig('F', f, const Color(0xFF2E7D32)),
                      if (f == 0 && _controlOf(d) > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                              color: const Color(0xFFEF6C00)
                                  .withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(4)),
                          child: const Text('Hidden',
                              style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFFEF6C00))),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // C_Quantity input (hold-back). F recomputes live on change.
            SizedBox(
              width: 64,
              child: TextField(
                controller: _ctrls[d.id],
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Hold',
                  labelStyle: const TextStyle(fontSize: 11),
                  hintText: '0',
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fig(String label, int value, Color color) => Text.rich(
        TextSpan(children: [
          TextSpan(
              text: '$label ',
              style: TextStyle(fontSize: 10, color: color.withValues(alpha: 0.7))),
          TextSpan(
              text: '$value',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.bold, color: color)),
        ]),
      );
}

extension _ToggleSet<T> on Set<T> {
  void toggle(T v) => contains(v) ? remove(v) : add(v);
}
