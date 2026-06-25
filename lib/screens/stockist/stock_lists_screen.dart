import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/stock_catalog.dart';
import '../../models/library_entry.dart';
import '../../models/choice_state.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../widgets/filter_section.dart';

const _navy = Color(0xFF1B4F72);

// "Make Stock List" — list the stockist's lists (brand-free v2 + any existing),
// create a new one, or edit one. Editing opens the design picker/builder.
// (project_fstock_model · stocklists v2)
class StockListsScreen extends StatefulWidget {
  const StockListsScreen({super.key});
  @override
  State<StockListsScreen> createState() => _StockListsScreenState();
}

class _StockListsScreenState extends State<StockListsScreen> {
  final _data = SupabaseDataService();
  List<StockCatalog> _lists = [];
  Map<String, int> _counts = {}; // catalogId → member count
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final lists = await _data.getCatalogs(currentStockistUUID);
    final designs = await _data.getDesignsByStockist(currentStockistUUID);
    // member count = unique library masters whose membership includes the list.
    final counts = <String, int>{};
    final seen = <String, Set<String>>{}; // catalogId → libIds counted
    for (final d in designs) {
      for (final cid in d.catalogIds) {
        (seen[cid] ??= <String>{}).add(d.libraryId);
      }
    }
    seen.forEach((cid, libs) => counts[cid] = libs.length);
    if (!mounted) return;
    setState(() {
      _lists = lists
          .where((c) => c.isActive && !c.pendingDelete)
          .toList();
      _counts = counts;
      _loading = false;
    });
  }

  Future<void> _open(StockCatalog? list) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => StockListBuilderScreen(existing: list)));
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Stock lists'),
        backgroundColor: _navy,
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(null),
        backgroundColor: _navy,
        icon: const Icon(Icons.add),
        label: const Text('New list'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _lists.isEmpty
              ? Center(
                  child: Text('No stock lists yet. Tap "New list".',
                      style: TextStyle(color: Colors.grey.shade600)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 90),
                  children: [
                    for (final c in _lists)
                      Card(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: ListTile(
                          title: Text(c.name,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(
                              [
                                '${_counts[c.id] ?? 0} designs',
                                if (c.description.trim().isNotEmpty)
                                  c.description.trim(),
                              ].join(' · '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _open(c),
                        ),
                      ),
                  ],
                ),
    );
  }
}

// ── Builder ──────────────────────────────────────────────────────────────────
// New or edit one stock list: name + description + two-section design picker
// (in-list on top with Remove · available below with Add) + search + bulk add.
// Operates on LIBRARY MASTERS (membership is by library_id). F shown per design.
class StockListBuilderScreen extends StatefulWidget {
  final StockCatalog? existing;
  const StockListBuilderScreen({super.key, this.existing});
  @override
  State<StockListBuilderScreen> createState() => _StockListBuilderScreenState();
}

class _DesignEntry {
  final String libId;
  final String name; // master (M) or own (T/W) name
  final String image;
  final int fStock; // summed across this master's holdings
  final String sizeLabel;
  // Filter attributes (aggregated across this master's holdings).
  final String size;
  final String colour;
  final String tileType;
  final Set<String> qualities;
  final Set<String> surfaces;
  _DesignEntry(this.libId, this.name, this.image, this.fStock, this.sizeLabel,
      {this.size = '',
      this.colour = '',
      this.tileType = '',
      this.qualities = const {},
      this.surfaces = const {}});
}

class _StockListBuilderScreenState extends State<StockListBuilderScreen> {
  final _data = SupabaseDataService();
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();

  final List<_DesignEntry> _all = [];
  final Map<String, Set<String>> _aliasByLib = {}; // libId → alias names (lower)
  final Set<String> _selected = {}; // libIds in the list
  String _search = '';
  // Rich filter (same facets as the Stock/Control page) for "Add designs".
  final Set<String> _fSizes = {};
  final Set<String> _fQualities = {};
  final Set<String> _fSurfaces = {};
  final Set<String> _fColours = {};
  final Set<String> _fTypes = {};
  final _minFCtrl = TextEditingController();
  final _maxFCtrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;

  int get _activeFilterCount =>
      _fSizes.length +
      _fQualities.length +
      _fSurfaces.length +
      _fColours.length +
      _fTypes.length +
      (_minFCtrl.text.trim().isNotEmpty ? 1 : 0) +
      (_maxFCtrl.text.trim().isNotEmpty ? 1 : 0);

  bool get _isM => currentStockistBusinessType == 'M';
  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _nameCtrl.text = widget.existing?.name ?? '';
    _descCtrl.text = widget.existing?.description ?? '';
    _searchCtrl.addListener(
        () => setState(() => _search = _searchCtrl.text.trim().toLowerCase()));
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _searchCtrl.dispose();
    _minFCtrl.dispose();
    _maxFCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final designs = await _data.getDesignsByStockist(currentStockistUUID);
    final lib = await _data.getMyLibrary();
    _aliasByLib.clear();
    for (final LibraryEntry e in lib) {
      final names = <String>{e.masterName.toLowerCase()};
      names.addAll(e.aliases.values.map((v) => v.toLowerCase()));
      _aliasByLib[e.id] = names;
    }
    // Dedupe holdings → one entry per library master; aggregate F + facets; seed
    // selection. A master spans qualities/surfaces, so those are collected as sets.
    final byLib = <String, _DesignEntry>{};
    final fSum = <String, int>{};
    final quals = <String, Set<String>>{};
    final surfs = <String, Set<String>>{};
    for (final d in designs) {
      if (d.libraryId.isEmpty) continue;
      fSum[d.libraryId] = (fSum[d.libraryId] ?? 0) + d.fStock;
      (quals[d.libraryId] ??= <String>{}).add(d.quality);
      if (d.surfaceType.trim().isNotEmpty && d.surfaceType != 'None') {
        (surfs[d.libraryId] ??= <String>{}).add(d.surfaceType);
      }
      byLib.putIfAbsent(
          d.libraryId,
          () => _DesignEntry(
                d.libraryId,
                _isM && d.masterDesignName.trim().isNotEmpty
                    ? d.masterDesignName
                    : d.name,
                d.faceImageUrls.isNotEmpty ? d.faceImageUrls.first : '',
                0,
                d.size.replaceAll(' mm', ''),
                size: d.size,
                colour: d.colour,
                tileType: d.tileType,
              ));
      if (_isEdit && d.catalogIds.contains(widget.existing!.id)) {
        _selected.add(d.libraryId);
      }
    }
    _all
      ..clear()
      ..addAll(byLib.values.map((e) => _DesignEntry(
            e.libId, e.name, e.image, fSum[e.libId] ?? 0, e.sizeLabel,
            size: e.size,
            colour: e.colour,
            tileType: e.tileType,
            qualities: quals[e.libId] ?? const {},
            surfaces: surfs[e.libId] ?? const {},
          )));
    _all.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (!mounted) return;
    setState(() => _loading = false);
  }

  bool _matchesSearch(_DesignEntry e) {
    if (_search.isEmpty) return true;
    if (e.name.toLowerCase().contains(_search)) return true;
    if (_isM) {
      final a = _aliasByLib[e.libId];
      if (a != null && a.any((x) => x.contains(_search))) return true;
    }
    return false;
  }

  bool _matches(_DesignEntry e) {
    if (!_matchesSearch(e)) return false;
    if (_fSizes.isNotEmpty && !_fSizes.contains(e.size)) return false;
    if (_fColours.isNotEmpty && !_fColours.contains(e.colour)) return false;
    if (_fTypes.isNotEmpty && !_fTypes.contains(e.tileType)) return false;
    if (_fQualities.isNotEmpty && !e.qualities.any(_fQualities.contains)) {
      return false;
    }
    if (_fSurfaces.isNotEmpty && !e.surfaces.any(_fSurfaces.contains)) {
      return false;
    }
    final minF = int.tryParse(_minFCtrl.text.trim());
    final maxF = int.tryParse(_maxFCtrl.text.trim());
    if (minF != null && e.fStock < minF) return false;
    if (maxF != null && e.fStock > maxF) return false;
    return true;
  }

  Future<void> _openFilterSheet() async {
    final sizes = _all.map((e) => e.size).toSet().toList()..sort();
    final colours = _all
        .map((e) => e.colour)
        .where((c) => c.trim().isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final types = _all
        .map((e) => e.tileType)
        .where((t) => t.trim().isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final qualities = _all.expand((e) => e.qualities).toSet().toList()..sort();
    final surfaces = _all.expand((e) => e.surfaces).toSet().toList()..sort();

    final lSizes = Set<String>.from(_fSizes);
    final lQual = Set<String>.from(_fQualities);
    final lSurf = Set<String>.from(_fSurfaces);
    final lCol = Set<String>.from(_fColours);
    final lType = Set<String>.from(_fTypes);
    final minCtrl = TextEditingController(text: _minFCtrl.text);
    final maxCtrl = TextEditingController(text: _maxFCtrl.text);

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget chipWrap(List<String> opts, Set<String> sel) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final o in opts)
                    FilterChip(
                      label: Text(o.replaceAll(' mm', ''),
                          style: const TextStyle(fontSize: 12)),
                      selected: sel.contains(o),
                      onSelected: (_) => setSheet(() =>
                          sel.contains(o) ? sel.remove(o) : sel.add(o)),
                      selectedColor: _navy.withValues(alpha: 0.15),
                      checkmarkColor: _navy,
                      visualDensity: VisualDensity.compact,
                    ),
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
                      if (sizes.isNotEmpty)
                        FilterSection(
                            title: 'Size',
                            summary: filterSummary(lSizes),
                            child: chipWrap(sizes, lSizes)),
                      if (qualities.isNotEmpty)
                        FilterSection(
                            title: 'Quality',
                            summary: filterSummary(lQual),
                            child: chipWrap(qualities, lQual)),
                      if (surfaces.isNotEmpty)
                        FilterSection(
                            title: 'Finish',
                            summary: filterSummary(lSurf),
                            child: chipWrap(surfaces, lSurf)),
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
        _fSizes
          ..clear()
          ..addAll(lSizes);
        _fQualities
          ..clear()
          ..addAll(lQual);
        _fSurfaces
          ..clear()
          ..addAll(lSurf);
        _fColours
          ..clear()
          ..addAll(lCol);
        _fTypes
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
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Give the list a name.')));
      return;
    }
    setState(() => _saving = true);
    try {
      final id = await _data.saveStockList(
          id: widget.existing?.id,
          name: name,
          description: _descCtrl.text.trim());
      await _data.setListDesigns(id, _selected.toList());
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
    final inList = _all.where((e) => _selected.contains(e.libId)).toList();
    final available =
        _all.where((e) => !_selected.contains(e.libId) && _matches(e)).toList();
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit list' : 'New list'),
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
                              strokeWidth: 2, color: Colors.white))))
              : TextButton(
                  onPressed: _save,
                  child: const Text('Save',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold))),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                  child: Column(
                    children: [
                      TextField(
                        controller: _nameCtrl,
                        decoration: const InputDecoration(
                            labelText: 'List name',
                            isDense: true,
                            border: OutlineInputBorder()),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _descCtrl,
                        decoration: const InputDecoration(
                            labelText: 'Description (optional)',
                            hintText: 'Remember what is in this list',
                            isDense: true,
                            border: OutlineInputBorder()),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                    children: [
                      _sectionHeader('In this list', inList.length),
                      if (inList.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('No designs yet — add some below.',
                              style: TextStyle(
                                  fontSize: 12.5, color: Colors.black54)),
                        ),
                      for (final e in inList) _row(e, inList: true),
                      const SizedBox(height: 8),
                      // Add section: search + bulk-add + available rows.
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text('Add designs',
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13.5,
                                      color: _navy)),
                            ),
                            if (available.isNotEmpty)
                              TextButton(
                                onPressed: () => setState(() => _selected
                                    .addAll(available.map((e) => e.libId))),
                                child: Text('Add all (${available.length})'),
                              ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
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
                                  fillColor: Colors.white,
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
                              label: Text(_activeFilterCount > 0
                                  ? 'Filters ($_activeFilterCount)'
                                  : 'Filters'),
                              style: OutlinedButton.styleFrom(
                                  foregroundColor: _navy,
                                  side: BorderSide(
                                      color: _activeFilterCount > 0
                                          ? _navy
                                          : Colors.grey.shade400)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (available.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                              _search.isEmpty
                                  ? 'All designs are in this list.'
                                  : 'No matches.',
                              style: const TextStyle(
                                  fontSize: 12.5, color: Colors.black54)),
                        ),
                      for (final e in available) _row(e, inList: false),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _sectionHeader(String label, int count) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
        child: Text('$label ($count)',
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 13.5, color: _navy)),
      );

  Widget _row(_DesignEntry e, {required bool inList}) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 42,
                height: 42,
                child: e.image.isEmpty
                    ? Container(
                        color: Colors.grey.shade200,
                        child: Icon(Icons.image_outlined,
                            size: 18, color: Colors.grey.shade400))
                    : CachedNetworkImage(
                        imageUrl: CloudinaryService.thumbUrl(e.image, width: 120),
                        fit: BoxFit.cover,
                        placeholder: (_, __) =>
                            Container(color: Colors.grey.shade100),
                        errorWidget: (_, __, ___) =>
                            Container(color: Colors.grey.shade200),
                      ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text('${e.sizeLabel} · F ${e.fStock}',
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                ],
              ),
            ),
            inList
                ? TextButton.icon(
                    onPressed: () =>
                        setState(() => _selected.remove(e.libId)),
                    icon: const Icon(Icons.remove_circle_outline, size: 18),
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                    label: const Text('Remove'),
                  )
                : FilledButton.icon(
                    onPressed: () => setState(() => _selected.add(e.libId)),
                    icon: const Icon(Icons.add, size: 18),
                    style: FilledButton.styleFrom(backgroundColor: _navy),
                    label: const Text('Add'),
                  ),
          ],
        ),
      ),
    );
  }
}
