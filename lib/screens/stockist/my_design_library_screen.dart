import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/brand.dart';
import '../../models/choice_state.dart';
import '../../models/library_entry.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../utils/tile_types.dart';
import '../../utils/finishes.dart';
import 'dna_editor_sheet.dart';

/// Stockist's own Design Library: master (physical) designs with their image +
/// the name each tile carries under every brand the stockist runs. This is the
/// ONLY place a design's identity/photo is edited; stock screens are quantity-only.
/// (project_stockist_library)
class MyDesignLibraryScreen extends StatefulWidget {
  const MyDesignLibraryScreen({super.key});
  @override
  State<MyDesignLibraryScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);

class _State extends State<MyDesignLibraryScreen> {
  final _data = SupabaseDataService();
  List<Brand> _brands = [];
  List<LibraryEntry> _entries = [];
  List<String> _sizes = [];
  Map<String, List<String>> _dnaTags = {}; // libraryId → DNA labels (their words)
  bool _loading = true;

  // Search + filters
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _showFilters = false;
  final Set<String> _fSizes = {};
  final Set<String> _fBrands = {}; // brand ids

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // Distinct sizes present in the library, for the size filter.
  List<String> get _sizesInUse {
    final s = _entries.map((e) => e.size).where((x) => x.isNotEmpty).toSet().toList()
      ..sort();
    return s;
  }

  // Entries after search + size/brand filters.
  List<LibraryEntry> get _filtered {
    final q = _query.trim().toLowerCase();
    return _entries.where((e) {
      if (q.isNotEmpty) {
        final hay = '${e.masterName} ${e.aliases.values.join(' ')}'.toLowerCase();
        if (!hay.contains(q)) return false;
      }
      if (_fSizes.isNotEmpty && !_fSizes.contains(e.size)) return false;
      if (_fBrands.isNotEmpty &&
          !e.aliases.keys.any((bid) => _fBrands.contains(bid))) {
        return false;
      }
      return true;
    }).toList();
  }

  int get _filterCount => _fSizes.length + _fBrands.length;

  Future<void> _load() async {
    setState(() => _loading = true);
    final results = await Future.wait([
      _data.getMyBrands(),
      _data.getMyLibrary(),
      _data.getActiveSizeNames(),
      _data.dnaMyLibraryTags(),
    ]);
    if (!mounted) return;
    final brands = results[0] as List<Brand>;
    // Default brand first, then by sort order (matches the editor column order).
    brands.sort((a, b) {
      if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
      return a.sortOrder.compareTo(b.sortOrder);
    });
    setState(() {
      _brands = brands;
      _entries = results[1] as List<LibraryEntry>;
      _sizes = results[2] as List<String>;
      _dnaTags = results[3] as Map<String, List<String>>;
      _loading = false;
    });
  }

  // Refresh just the DNA tags (after the per-design mapper sheet closes).
  Future<void> _reloadDnaTags() async {
    final tags = await _data.dnaMyLibraryTags();
    if (mounted) setState(() => _dnaTags = tags);
  }

  String _brandName(String brandId) =>
      _brands.firstWhere((b) => b.id == brandId,
          orElse: () => const Brand(id: '', name: '?')).name;

  // Two-tone pill used wherever we show a brand→name pair (library card + the
  // merge picker): solid navy = the BRAND, light = that brand's design name, so
  // "my brand vs its name" reads at a glance.
  Widget _brandNamePill(String brandId, String name) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: _navy.withValues(alpha: 0.20)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              color: _navy,
              child: Text(_brandName(brandId),
                  style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              color: _navy.withValues(alpha: 0.06),
              child: Text(name,
                  style: const TextStyle(fontSize: 11, color: _navy)),
            ),
          ],
        ),
      );

  Future<void> _openEditor([LibraryEntry? entry]) async {
    if (_brands.isEmpty) {
      _snack('Add a brand first — designs live under a brand.', error: true);
      return;
    }
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _LibraryEditorScreen(
            brands: _brands, sizes: _sizes, all: _entries, existing: entry),
      ),
    );
    if (saved == true) _load();
  }

  // "+ Add design" entry. For M the tile's identity spans brands (one box, many
  // brand-names), so we lead with a BRAND-FIRST guided step: the human enters
  // through their brand, then SEES the existing boxes (across all brands, with
  // photos) before a blank form can spawn a duplicate. T/W are silos — brand IS
  // the identity — so they go straight to the editor. (project_addflow_redesign)
  Future<void> _addDesign() async {
    if (_brands.isEmpty) {
      _snack('Add a brand first — designs live under a brand.', error: true);
      return;
    }
    if (currentStockistBusinessType != 'M') {
      await _openEditor();
      return;
    }
    await _showBrandFirstSheet();
  }

  // Brand-first guided add (M): pick the brand context, type the tile's name,
  // and match it VISUALLY against every existing box (cross-brand). The human
  // either links their brand's name onto an existing tile, or declares it new.
  Future<void> _showBrandFirstSheet() async {
    final result = await showModalBottomSheet<_BrandFirstResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.9),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _BrandFirstSheet(brands: _brands, entries: _entries),
    );
    if (result == null || !mounted) return;
    if (result.isLink) {
      await _linkBrandNameToBox(result.box!, result.brandId, result.name);
    } else {
      // New tile: open the editor pre-filled with the typed name + brand alias.
      final saved = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => _LibraryEditorScreen(
            brands: _brands,
            sizes: _sizes,
            all: _entries,
            existing: null,
            prefillName: result.name,
            prefillBrandId: result.brandId,
          ),
        ),
      );
      if (saved == true) _load();
    }
  }

  // One existing-box row in the brand-first search: photo + master name + size/

  // Link the typed brand-name onto an EXISTING box (brand-agnostic for M): merge
  // the name into the box's aliases, keep everything else. No duplicate master.
  Future<void> _linkBrandNameToBox(
      LibraryEntry box, String brandId, String name) async {
    try {
      await _data.upsertLibraryMaster(
        id: box.id,
        size: box.size,
        masterName: box.masterName,
        imageUrl: box.imageUrl,
        brandId: null, // M boxes are brand-agnostic
        aliases: {...box.aliases, brandId: name},
        surfaceType: box.surfaceType,
        stockType: box.stockType,
        tileType: box.tileType,
        piecesPerBox: box.piecesPerBox,
        boxWeightKg: box.boxWeightKg,
        thicknessMm: box.thicknessMm,
        colour: box.colour,
        finishLabel: box.finishLabel,
      );
      _snack('Added "$name" to "${box.masterName}".');
      await _load();
    } catch (e) {
      _snack('$e', error: true);
    }
  }

  // Open the duplicate-review screen with the current groups; reload on return
  // (a merge changed the library).
  Future<void> _openDuplicatesReview() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _DuplicatesReviewScreen(
            groups: _duplicateGroups, brands: _brands),
      ),
    );
    if (changed == true) _load();
  }

  Future<void> _confirmDelete(LibraryEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete design?'),
        content: Text('Remove "${e.masterName}" (${e.size}) from your library? '
            'This does not change any stock counts.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _data.deleteLibraryMaster(e.id);
      await _load();
    } catch (err) {
      _snack('$err', error: true);
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: error ? Colors.red : null));
  }

  // Other masters of the SAME size — the only merge candidates (the server also
  // enforces same-size). Used to show/hide the per-tile merge action.
  List<LibraryEntry> _sameSizeSiblings(LibraryEntry keep) =>
      _entries.where((o) => o.id != keep.id && o.size == keep.size).toList();

  static String _normSurface(String s) {
    final t = s.trim().toLowerCase();
    return t.isEmpty ? 'none' : t;
  }

  // Likely-duplicate groups: 2+ M boxes sharing the SAME identity key
  // (master name + size), brand-agnostic. Surface is intentionally excluded:
  // the same tile often arrives from different suppliers with different surface
  // labels, creating two masters that should be one. The human confirms via
  // the Merge tool. (project_addflow_redesign_ddpi #4)
  List<List<LibraryEntry>> get _duplicateGroups {
    final groups = <String, List<LibraryEntry>>{};
    for (final e in _entries) {
      final key = '${e.masterName.trim().toLowerCase()}|${e.size}';
      (groups[key] ??= []).add(e);
    }
    final out = groups.values.where((g) => g.length > 1).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    return out;
  }

  // Merge: pick a same-size duplicate to FOLD INTO [keep]. The dropped master's
  // brand names, DNA and (if [keep] has none) photo move onto [keep]; the drop is
  // deleted. Stock rows have no FK to masters, so counts are untouched.
  Future<void> _openMergeSheet(LibraryEntry keep) async {
    final candidates = _sameSizeSiblings(keep);
    if (candidates.isEmpty) {
      _snack('No other ${keep.size.replaceAll(' mm', '')} designs to merge.');
      return;
    }
    var query = '';
    final chosen = await showModalBottomSheet<LibraryEntry>(
      context: context,
      isScrollControlled: true,
      // Cap the height so the header clears the status bar (and so it never
      // pushes off-screen for a long library).
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.88),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final q = query.trim().toLowerCase();
          final list = q.isEmpty
              ? candidates
              : candidates.where((c) {
                  final hay = ('${c.masterName} '
                          '${c.aliases.entries.map((a) => '${_brandName(a.key)} ${a.value}').join(' ')}')
                      .toLowerCase();
                  return hay.contains(q);
                }).toList();
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle.
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(top: 8, bottom: 2),
                  decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Fold a duplicate into "${keep.masterName}"',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15)),
                      const SizedBox(height: 2),
                      Text(
                          'Pick the same tile listed twice. Its brand names, DNA '
                          'and photo move here; the duplicate is removed. Stock '
                          'is unchanged.',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600)),
                      const SizedBox(height: 10),
                      TextField(
                        onChanged: (v) => setSheet(() => query = v),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search, size: 20),
                          hintText: 'Search by design or brand name',
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 10),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 12),
                Flexible(
                  child: list.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(28),
                          child: Text('No match for "$query".',
                              style: TextStyle(color: Colors.grey.shade600)),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                          itemCount: list.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 2),
                          itemBuilder: (_, i) {
                            final c = list[i];
                            return InkWell(
                              onTap: () => Navigator.pop(ctx, c),
                              borderRadius: BorderRadius.circular(8),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 7),
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.center,
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
                                      child: SizedBox(
                                        width: 44,
                                        height: 44,
                                        child: c.imageUrl.isEmpty
                                            ? Container(
                                                color: Colors.grey.shade100,
                                                child: Icon(
                                                    Icons.image_outlined,
                                                    size: 20,
                                                    color:
                                                        Colors.grey.shade400))
                                            : CachedNetworkImage(
                                                imageUrl:
                                                    CloudinaryService.thumbUrl(
                                                        c.imageUrl,
                                                        width: 120),
                                                fit: BoxFit.cover,
                                                placeholder: (_, __) =>
                                                    Container(
                                                        color: Colors
                                                            .grey.shade200),
                                                errorWidget: (_, __, ___) =>
                                                    Container(
                                                        color: Colors
                                                            .grey.shade200)),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(c.masterName,
                                              style: const TextStyle(
                                                  fontSize: 14,
                                                  fontWeight:
                                                      FontWeight.w600)),
                                          if (c.aliases.isNotEmpty) ...[
                                            const SizedBox(height: 5),
                                            Wrap(
                                              spacing: 6,
                                              runSpacing: 4,
                                              children: c.aliases.entries
                                                  .map((a) => _brandNamePill(
                                                      a.key, a.value))
                                                  .toList(),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    const Icon(Icons.call_merge,
                                        color: _navy),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (chosen == null || !mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Merge these designs?'),
        content: Text('"${chosen.masterName}" will be removed and folded into '
            '"${keep.masterName}". Its brand names, DNA and photo move across. '
            'This cannot be undone, but stock counts are unaffected.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _navy),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Merge')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _data.mergeLibraryMasters(keepId: keep.id, dropId: chosen.id);
      await _load();
      _snack('Merged into "${keep.masterName}".');
    } catch (err) {
      _snack('$err', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('My Design Library'),
        actions: [
          // M only: PDF import builds the library (design identity + photos, no stock).
          if (currentStockistBusinessType == 'M')
            IconButton(
              icon: const Icon(Icons.picture_as_pdf),
              tooltip: 'Import PDF (add designs)',
              onPressed: () async {
                final brands = _brands;
                final defaultBrand = brands.isEmpty
                    ? null
                    : brands.firstWhere((b) => b.isDefault,
                        orElse: () => brands.first);
                if (defaultBrand == null) return;
                final done = await context.push<bool>(
                    '/stockist/stock/import-supplier-pdf',
                    extra: defaultBrand.id);
                if (done == true) _load();
              },
            ),
          // M only: surface likely-duplicate masters (pre-#7 leftovers) for the
          // human to review + merge. Badge = how many groups are waiting.
          if (currentStockistBusinessType == 'M' && _duplicateGroups.isNotEmpty)
            IconButton(
              tooltip: 'Find duplicates',
              icon: Badge.count(
                count: _duplicateGroups.length,
                child: const Icon(Icons.content_copy_outlined),
              ),
              onPressed: _openDuplicatesReview,
            ),
          IconButton(
            icon: const Icon(Icons.spellcheck),
            tooltip: 'My Words (DNA terms)',
            onPressed: () => context.push('/stockist/dna-words'),
          ),
          if (_brands.length > 1)
            IconButton(
              icon: const Icon(Icons.account_tree_outlined),
              tooltip: 'Import name mapping (Excel)',
              onPressed: () async {
                final done = await context
                    .push<bool>('/stockist/library/import-mapping');
                if (done == true) _load();
              },
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addDesign,
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add design'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_entries.isNotEmpty) _searchBar(),
                if (_showFilters && _entries.isNotEmpty) _filterChips(),
                Expanded(
                  child: _entries.isEmpty
                      ? _empty()
                      : Builder(builder: (_) {
                          final list = _filtered;
                          if (list.isEmpty) {
                            return const Center(
                                child: Text('No designs match.',
                                    style: TextStyle(color: Colors.grey)));
                          }
                          return ListView.separated(
                            padding: EdgeInsets.fromLTRB(12, 4, 12,
                                90 + MediaQuery.viewPaddingOf(context).bottom),
                            itemCount: list.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (_, i) => _tile(list[i]),
                          );
                        }),
                ),
              ],
            ),
    );
  }

  Widget _searchBar() {
    final shown = _filtered.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: 'Search by design or brand name…',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _query = '');
                            },
                          ),
                    isDense: true,
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: Colors.grey.shade300)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: Colors.grey.shade300)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => setState(() => _showFilters = !_showFilters),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 11),
                  decoration: BoxDecoration(
                    color: _filterCount > 0 ? _navy : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.tune,
                          size: 18,
                          color: _filterCount > 0
                              ? Colors.white
                              : Colors.grey.shade600),
                      if (_filterCount > 0) ...[
                        const SizedBox(width: 4),
                        Text('$_filterCount',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold)),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('$shown of ${_entries.length} designs',
                  style: const TextStyle(fontSize: 11.5, color: Colors.grey)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChips() {
    final sizes = _sizesInUse;
    final multiBrand = _brands.length > 1;
    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (sizes.isNotEmpty) ...[
            const Text('Size',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 2,
              children: sizes.map((s) {
                return FilterChip(
                  label: Text(s.replaceAll(' mm', ''),
                      style: const TextStyle(fontSize: 12)),
                  selected: _fSizes.contains(s),
                  onSelected: (v) => setState(
                      () => v ? _fSizes.add(s) : _fSizes.remove(s)),
                );
              }).toList(),
            ),
          ],
          if (multiBrand) ...[
            const SizedBox(height: 8),
            const Text('Brand',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 2,
              children: _brands.map((b) {
                return FilterChip(
                  label: Text(b.name, style: const TextStyle(fontSize: 12)),
                  selected: _fBrands.contains(b.id),
                  onSelected: (v) => setState(
                      () => v ? _fBrands.add(b.id) : _fBrands.remove(b.id)),
                );
              }).toList(),
            ),
          ],
          if (_filterCount > 0)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() {
                  _fSizes.clear();
                  _fBrands.clear();
                }),
                child: const Text('Clear filters'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _empty() => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.collections_outlined,
                size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text('No designs yet',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.grey.shade600)),
            const SizedBox(height: 4),
            Text('Tap "Add design" to create your first master.',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
          ],
        ),
      );

  Widget _tile(LibraryEntry e) {
    // When the library is filtered to a SINGLE brand, the stockist is viewing it
    // "as that brand", so the title shows THAT brand's name for the tile (e.g.
    // ANUJ's "601001") instead of the master name. Only designs carrying that
    // brand's alias are shown when filtered, so the alias is always present here.
    final singleBrand = _fBrands.length == 1 ? _fBrands.first : null;
    final brandAlias = singleBrand == null ? null : e.aliases[singleBrand];
    final showBrandName = brandAlias != null && brandAlias.isNotEmpty;
    final titleName = showBrandName ? brandAlias : e.masterName;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 56,
                height: 56,
                child: e.imageUrl.isEmpty
                    ? Container(
                        color: Colors.grey.shade100,
                        child: Icon(Icons.image_outlined,
                            color: Colors.grey.shade400))
                    : CachedNetworkImage(
                        imageUrl:
                            CloudinaryService.thumbUrl(e.imageUrl, width: 160),
                        fit: BoxFit.cover,
                        placeholder: (_, __) =>
                            Container(color: Colors.grey.shade200),
                        errorWidget: (_, __, ___) =>
                            Container(color: Colors.grey.shade200)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title = the MASTER identity name only (no brand prefix) + a
                  // small "Master" tag, so the stockist sees the design's one true
                  // name; each brand's own name is in the chips below.
                  Row(
                    children: [
                      Flexible(
                        child: Text(titleName,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 14)),
                      ),
                      // "Master" tag only when showing the master name (M, and not
                      // currently renamed to a single brand's alias).
                      if (currentStockistBusinessType == 'M' && !showBrandName) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('Master',
                              style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey.shade600)),
                        ),
                      ],
                    ],
                  ),
                  Text(e.size.replaceAll(' mm', ''),
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  if (e.surfaceType.isNotEmpty &&
                      e.surfaceType.toLowerCase() != 'none')
                    Text(e.surfaceType,
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade500)),
                  // Per-brand chips show what each brand calls this tile — shown
                  // for every design (1+ brands) so the brand→name mapping is
                  // always visible. Two-tone pill: solid navy = the BRAND, light =
                  // that brand's design name — so "my brand vs its name" is obvious.
                  if (e.aliases.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: e.aliases.entries
                          .map((a) => _brandNamePill(a.key, a.value))
                          .toList(),
                    ),
                  ],
                  if ((_dnaTags[e.id] ?? const []).isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 5,
                      runSpacing: 4,
                      children: _dnaTags[e.id]!.map((t) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFFB9770E).withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(t,
                              style: const TextStyle(
                                  fontSize: 11, color: Color(0xFF8A5A09))),
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            ),
            Column(
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.science_outlined,
                      size: 20, color: Color(0xFFB9770E)),
                  tooltip: 'Design DNA (for search)',
                  onPressed: () async {
                    await showDnaEditor(context,
                        libraryId: e.id, designName: e.masterName);
                    await _reloadDnaTags();
                  },
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  tooltip: 'Edit',
                  onPressed: () => _openEditor(e),
                ),
                if (_sameSizeSiblings(e).isNotEmpty)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.call_merge, size: 20, color: _navy),
                    tooltip: currentStockistBusinessType == 'M'
                        ? 'Merge a duplicate into this'
                        : 'Merge a duplicate design into this one',
                    onPressed: () => _openMergeSheet(e),
                  ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline,
                      size: 20, color: Colors.red),
                  tooltip: 'Delete',
                  onPressed: () => _confirmDelete(e),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Brand-first guided "Add design" sheet ────────────────────────────────────
// Using a proper StatefulWidget (not StatefulBuilder) so the TextEditingController
// is disposed in dispose() and the FocusScope inside the modal is torn down in
// the correct order, preventing the _dependents.isEmpty assertion crash.
class _BrandFirstSheet extends StatefulWidget {
  final List<Brand> brands;
  final List<LibraryEntry> entries;
  const _BrandFirstSheet({required this.brands, required this.entries});
  @override
  State<_BrandFirstSheet> createState() => _BrandFirstSheetState();
}

class _BrandFirstSheetState extends State<_BrandFirstSheet> {
  final _ctrl = TextEditingController();
  String? _brandId;

  @override
  void initState() {
    super.initState();
    _brandId = widget.brands.length == 1 ? widget.brands.first.id : null;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String _brandName(String id) => widget.brands
      .firstWhere((b) => b.id == id, orElse: () => const Brand(id: '', name: '?'))
      .name;

  @override
  Widget build(BuildContext context) {
    final brand = _brandId == null
        ? null
        : widget.brands.firstWhere((b) => b.id == _brandId,
            orElse: () => widget.brands.first);
    final q = _ctrl.text.trim().toLowerCase();
    final candidates = q.isEmpty
        ? const <LibraryEntry>[]
        : (widget.entries.where((e) {
            final hay =
                '${e.masterName} ${e.aliases.values.join(' ')}'.toLowerCase();
            return hay.contains(q);
          }).toList()
          ..sort((a, b) => a.masterName
              .toLowerCase()
              .compareTo(b.masterName.toLowerCase())));

    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(
          bottom: mq.viewInsets.bottom + mq.padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40, height: 4,
              margin: const EdgeInsets.only(top: 8, bottom: 6),
              decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          if (brand == null) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 6),
              child: Text('Which brand are you adding for?',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final b in widget.brands)
                    ListTile(
                      leading:
                          const Icon(Icons.sell_outlined, color: _navy),
                      title: Text(b.name),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => setState(() => _brandId = b.id),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ] else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Add a design for ${brand.name}',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                  if (widget.brands.length > 1)
                    TextButton(
                      onPressed: () => setState(() => _brandId = null),
                      child: const Text('Change'),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text(
                  'Type the name. If this tile is already yours under '
                  'another brand, pick it below — don\'t make a duplicate.',
                  style:
                      TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _ctrl,
                textCapitalization: TextCapitalization.words,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Tile name in ${brand.name}',
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            if (q.isNotEmpty)
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    if (candidates.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                            'No existing tile matches "${_ctrl.text.trim()}".',
                            style:
                                TextStyle(color: Colors.grey.shade600)),
                      )
                    else
                      for (final c in candidates)
                        _candidateCard(context, c, brand.id),
                  ],
                ),
              ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.pop(
                      context,
                      _BrandFirstResult.create(
                          brand.id, _ctrl.text.trim())),
                  icon: const Icon(Icons.add),
                  label: Text(q.isEmpty
                      ? 'Create a new tile'
                      : 'None of these — create new tile'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: _navy,
                      side: const BorderSide(color: _navy),
                      padding:
                          const EdgeInsets.symmetric(vertical: 12)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _candidateCard(
      BuildContext context, LibraryEntry e, String brandId) {
    final already = (e.aliases[brandId] ?? '').trim().isNotEmpty;
    final surface = e.surfaceType.trim();
    final sub = [
      e.size.replaceAll(' mm', ''),
      if (surface.isNotEmpty && surface.toLowerCase() != 'none') surface,
    ].join(' · ');
    void onLink() => Navigator.pop(
        context, _BrandFirstResult.link(e, brandId, _ctrl.text.trim()));
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: e.imageUrl.isEmpty
              ? Container(
                  width: 48, height: 48,
                  color: Colors.grey.shade200,
                  child: Icon(Icons.image_outlined,
                      color: Colors.grey.shade400, size: 22))
              : CachedNetworkImage(
                  imageUrl:
                      CloudinaryService.thumbUrl(e.imageUrl, width: 120),
                  width: 48, height: 48, fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                      width: 48, height: 48, color: Colors.grey.shade200),
                  errorWidget: (_, __, ___) => Container(
                      width: 48, height: 48, color: Colors.grey.shade200),
                ),
        ),
        title: Text(e.masterName,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(sub,
                style: TextStyle(
                    fontSize: 11, color: Colors.grey.shade600)),
            if (e.aliases.isNotEmpty) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 4, runSpacing: 4,
                children: [
                  for (final a in e.aliases.entries)
                    _pill(a.key, a.value),
                ],
              ),
            ],
          ],
        ),
        trailing: already
            ? Tooltip(
                message:
                    'This brand already names it "${e.aliases[brandId]}"',
                child: Icon(Icons.check_circle,
                    color: Colors.green.shade600))
            : TextButton(onPressed: onLink, child: const Text('This one')),
        onTap: already ? null : onLink,
      ),
    );
  }

  Widget _pill(String brandId, String name) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: _navy.withValues(alpha: 0.20)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              color: _navy,
              child: Text(_brandName(brandId),
                  style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              color: _navy.withValues(alpha: 0.06),
              child: Text(name,
                  style: const TextStyle(fontSize: 11, color: _navy)),
            ),
          ],
        ),
      );
}

/// Outcome of the brand-first guided add sheet: either LINK the typed name onto
/// an existing box, or CREATE a new tile (open the editor pre-filled).
class _BrandFirstResult {
  final bool isLink;
  final LibraryEntry? box; // set when isLink
  final String brandId;
  final String name;
  const _BrandFirstResult._(this.isLink, this.box, this.brandId, this.name);
  factory _BrandFirstResult.link(
          LibraryEntry box, String brandId, String name) =>
      _BrandFirstResult._(true, box, brandId, name);
  factory _BrandFirstResult.create(String brandId, String name) =>
      _BrandFirstResult._(false, null, brandId, name);
}

/// Full-page editor for one master design: image, size, master name, and the
/// design name under each brand. The only place these are editable.
class _LibraryEditorScreen extends StatefulWidget {
  final List<Brand> brands;
  final List<String> sizes;
  final List<LibraryEntry> all; // for live duplicate detection
  final LibraryEntry? existing;
  // Brand-first guided add: a new tile arrives pre-filled with the typed name
  // (master + that brand's alias) so the human doesn't re-type. (null = blank.)
  final String? prefillName;
  final String? prefillBrandId;
  const _LibraryEditorScreen(
      {required this.brands,
      required this.sizes,
      required this.all,
      this.existing,
      this.prefillName,
      this.prefillBrandId});
  @override
  State<_LibraryEditorScreen> createState() => _EditorState();
}

class _EditorState extends State<_LibraryEditorScreen> {
  final _data = SupabaseDataService();
  final _picker = ImagePicker();

  final _master = TextEditingController();
  final Map<String, TextEditingController> _aliasCtrls = {};
  String _size = '';
  String _imageUrl = '';
  bool _uploading = false;
  bool _saving = false;
  bool _dirty = false;

  // Identity (physical) attributes — the design IS these. Set once, here.
  // (identity split)
  final _piecesCtrl = TextEditingController();
  final _weightCtrl = TextEditingController();
  final _colourCtrl = TextEditingController();
  final _finishCtrl = TextEditingController();
  String _surface = 'None';
  String _tileType = kTileTypes.first;
  String _stockType = 'Uncertain';
  List<String> _surfaces = const ['None'];
  static const _stockTypes = ['Continuous', 'One Time', 'Uncertain'];
  // True once the user edits the master name by hand — until then it mirrors the
  // default brand's name (locked rule: first upload master name = brand-1 name).
  bool _masterTouched = false;
  String? _error;

  bool get _isEdit => widget.existing != null;
  Brand get _defaultBrand => widget.brands.first;

  // A master is bound to ONE brand: the first brand the user named, else the
  // default brand. (Identity is now per-brand, so this is the design's brand.)
  String get _targetBrandId => widget.brands
      .map((b) => b.id)
      .firstWhere((id) => _aliasCtrls[id]?.text.trim().isNotEmpty ?? false,
          orElse: () => _defaultBrand.id);

  // The SAME tile already in the library, or null. M: brand-AGNOSTIC — one tile
  // is one box across all brands, keyed by name+size+SURFACE. T/W: brand silo.
  LibraryEntry? get _dupMatch {
    final name = _master.text.trim().toLowerCase();
    if (name.isEmpty || _size.isEmpty) return null;
    final isM = currentStockistBusinessType == 'M';
    final surf = _surface.trim().isEmpty ? 'none' : _surface.trim().toLowerCase();
    for (final e in widget.all) {
      if (e.id == widget.existing?.id) continue;
      if (e.masterName.trim().toLowerCase() != name || e.size != _size) continue;
      final hit = isM
          ? (e.surfaceType.trim().isEmpty
                  ? 'none'
                  : e.surfaceType.trim().toLowerCase()) ==
              surf
          : e.brandId == _targetBrandId;
      if (hit) return e;
    }
    return null;
  }

  bool get _isDuplicate => _dupMatch != null;

  @override
  void initState() {
    super.initState();
    for (final b in widget.brands) {
      _aliasCtrls[b.id] = TextEditingController();
    }
    final e = widget.existing;
    if (e != null) {
      _master.text = e.masterName;
      _masterTouched = true;
      _size = e.size;
      _imageUrl = e.imageUrl;
      e.aliases.forEach((bid, name) {
        _aliasCtrls[bid]?.text = name;
      });
      _surface = e.surfaceType.isEmpty ? 'None' : e.surfaceType;
      _tileType = kTileTypes.contains(e.tileType) ? e.tileType : kTileTypes.first;
      _stockType = _stockTypes.contains(e.stockType) ? e.stockType : 'Uncertain';
      if (e.piecesPerBox > 0) _piecesCtrl.text = '${e.piecesPerBox}';
      if (e.boxWeightKg > 0) _weightCtrl.text = _trimNum(e.boxWeightKg);
      _colourCtrl.text = e.colour;
      _finishCtrl.text = e.finishLabel ?? '';
    } else {
      if (widget.sizes.isNotEmpty) _size = widget.sizes.first;
      // Brand-first guided add pre-fills the typed name as the master + the
      // chosen brand's alias, so the human lands on a half-done form, not blank.
      final pre = widget.prefillName?.trim() ?? '';
      if (pre.isNotEmpty) {
        _master.text = pre;
        _masterTouched = true;
        final bid = widget.prefillBrandId;
        if (bid != null && _aliasCtrls.containsKey(bid)) {
          _aliasCtrls[bid]!.text = pre;
        }
      }
    }
    _master.addListener(() {
      if (_master.text != (widget.existing?.masterName ?? '')) _masterTouched = true;
      if (mounted) setState(() {}); // refresh the live duplicate hint
    });
    _loadSurfaces();
  }

  static String _trimNum(double v) =>
      v % 1 == 0 ? v.toStringAsFixed(0) : v.toString();

  // Admin's live finish list (matches what stockists align PDFs to); 'None'
  // first. Falls back to the built-in list if the fetch fails.
  Future<void> _loadSurfaces() async {
    try {
      final types = await _data.getSurfaceTypes(activeOnly: true);
      final names = types.map((t) => t.name).toList();
      final all = ['None', ...names.where((n) => n != 'None')];
      if (mounted && all.isNotEmpty) {
        setState(() {
          _surfaces = all;
          if (!_surfaces.contains(_surface)) _surface = _surfaces.first;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _surfaces = ['None', ...kFinishes.where((f) => f != 'None')]);
      }
    }
  }

  @override
  void dispose() {
    _master.dispose();
    _piecesCtrl.dispose();
    _weightCtrl.dispose();
    _colourCtrl.dispose();
    _finishCtrl.dispose();
    for (final c in _aliasCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined, color: _navy),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: _navy),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final x = await _picker.pickImage(
        source: source, maxWidth: 1600, imageQuality: 88);
    if (x == null) return;
    setState(() => _uploading = true);
    final url = await CloudinaryService.uploadImage(x.path);
    if (!mounted) return;
    setState(() {
      _uploading = false;
      if (url != null) {
        _imageUrl = url;
        _dirty = true;
      } else {
        _error = 'Image upload failed. Try again.';
      }
    });
  }

  // Keep the master name mirroring the default brand's name until the user types
  // a master name of their own.
  void _onDefaultAliasChanged(String v) {
    _dirty = true;
    if (!_masterTouched) {
      _master.text = v;
      _master.selection =
          TextSelection.collapsed(offset: _master.text.length);
    }
  }

  // M auto-link: the entered tile already exists — ADD the brand name(s) the
  // stockist typed onto that existing box (merged with its current names), so a
  // duplicate master is never created.
  Future<void> _offerLinkToExisting(LibraryEntry dup) async {
    const navy = Color(0xFF1B4F72);
    final entered = <String, String>{
      for (final e in _aliasCtrls.entries)
        if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim()
    };
    // Only the names that are genuinely NEW on the existing tile.
    final adding = <String, String>{
      for (final e in entered.entries)
        if ((dup.aliases[e.key] ?? '').trim().toLowerCase() !=
            e.value.toLowerCase())
          e.key: e.value
    };
    final brandList = adding.keys
        .map((id) => widget.brands
            .firstWhere((b) => b.id == id,
                orElse: () => const Brand(id: '', name: '?'))
            .name)
        .join(', ');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('This tile is already in your library'),
        content: Text(adding.isEmpty
            ? '"${dup.masterName}" (${dup.size}) already exists. There is no new '
                'brand name to add.'
            : '"${dup.masterName}" (${dup.size}) already exists. Add your '
                'name${adding.length > 1 ? 's' : ''} ($brandList) to it instead '
                'of creating a duplicate?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          if (adding.isNotEmpty)
            FilledButton(
                style: FilledButton.styleFrom(backgroundColor: navy),
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Add to it')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _data.upsertLibraryMaster(
        id: dup.id,
        size: dup.size,
        masterName: dup.masterName,
        imageUrl: dup.imageUrl,
        brandId: null, // M boxes are brand-agnostic
        aliases: {...dup.aliases, ...adding},
        surfaceType: dup.surfaceType,
        stockType: dup.stockType,
        tileType: dup.tileType,
        piecesPerBox: dup.piecesPerBox,
        boxWeightKg: dup.boxWeightKg,
        thicknessMm: dup.thicknessMm,
        colour: dup.colour,
        finishLabel: dup.finishLabel,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$e';
      });
    }
  }

  Future<void> _save() async {
    final master = _master.text.trim();
    if (master.isEmpty) {
      setState(() => _error = 'Master design name is required.');
      return;
    }
    if (_size.trim().isEmpty) {
      setState(() => _error = 'Pick a size.');
      return;
    }
    final dup = _dupMatch;
    if (dup != null) {
      // M, adding: the same tile already exists — offer to ADD this brand's
      // name onto it (link), instead of spawning a duplicate master.
      if (widget.existing == null && currentStockistBusinessType == 'M') {
        await _offerLinkToExisting(dup);
        return;
      }
      // T/W silo, or renaming onto another tile while editing → a real clash.
      setState(() =>
          _error = 'You already have "$master" at size $_size in your library.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final aliases = {
      for (final e in _aliasCtrls.entries) e.key: e.value.text.trim(),
    };
    final pieces = int.tryParse(_piecesCtrl.text.trim()) ?? 0;
    final weight = double.tryParse(_weightCtrl.text.trim()) ?? 0;
    final thickness =
        approxThicknessMm(_size, pieces, weight, _tileType) ?? 0;
    try {
      await _data.upsertLibraryMaster(
        id: widget.existing?.id,
        size: _size,
        masterName: master,
        imageUrl: _imageUrl,
        brandId: _targetBrandId,
        aliases: aliases,
        surfaceType: _surface,
        stockType: _stockType,
        tileType: _tileType,
        piecesPerBox: pieces,
        boxWeightKg: weight,
        thicknessMm: thickness,
        colour: _colourCtrl.text.trim(),
        finishLabel: _finishCtrl.text.trim(),
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$e';
      });
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty || _saving) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your edits to this design will be lost.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep editing')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard')),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        if (await _confirmDiscard()) nav.pop();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF5F5F5),
        appBar: AppBar(title: Text(_isEdit ? 'Edit design' : 'Add design')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            // Image
            Center(
              child: GestureDetector(
                onTap: _uploading ? null : _pickImage,
                child: Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _uploading
                      ? const Center(child: CircularProgressIndicator())
                      : _imageUrl.isEmpty
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.add_a_photo_outlined,
                                    color: Colors.grey.shade400, size: 30),
                                const SizedBox(height: 6),
                                Text('Add photo',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade500)),
                              ],
                            )
                          : Image.network(
                              CloudinaryService.thumbUrl(_imageUrl, width: 400),
                              fit: BoxFit.cover),
                ),
              ),
            ),
            if (_imageUrl.isNotEmpty)
              Center(
                child: TextButton.icon(
                  onPressed: _uploading ? null : _pickImage,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Change photo'),
                ),
              ),
            const SizedBox(height: 12),
            // Size
            DropdownButtonFormField<String>(
              initialValue: _size.isEmpty ? null : _size,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Size', border: OutlineInputBorder()),
              items: widget.sizes
                  .map((s) => DropdownMenuItem(
                      value: s, child: Text(s.replaceAll(' mm', ''))))
                  .toList(),
              onChanged: (v) => setState(() {
                _size = v ?? '';
                _dirty = true;
              }),
            ),
            const SizedBox(height: 14),
            // Master name
            TextField(
              controller: _master,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: currentStockistBusinessType == 'M' ? 'Master design name' : 'Design name',
                // M: a match isn't an error — saving will add the brand name to
                // the existing tile, so we hint (not red-error). T/W: hard clash.
                helperText: (_isDuplicate && currentStockistBusinessType == 'M')
                    ? 'Already in your library — saving adds your brand name to it'
                    : 'Your internal name for this tile',
                border: const OutlineInputBorder(),
                errorText: (_isDuplicate && currentStockistBusinessType != 'M')
                    ? 'You already have "${_master.text.trim()}" at this size'
                    : null,
              ),
            ),
            const SizedBox(height: 18),
            Text('Design name under each brand',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: Colors.grey.shade800)),
            const SizedBox(height: 2),
            Text(
                'The name this same tile is sold as in each brand. Leave blank if '
                'a brand does not carry it.',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            const SizedBox(height: 10),
            ...widget.brands.map(_aliasField),
            if (widget.brands.length == 1)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 14, color: Colors.grey.shade500),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                          'Have more brands? Ask the admin to enable them — a '
                          'field will appear here for each.',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade600)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 20),
            _detailsSection(),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                    backgroundColor: _navy,
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(_isEdit ? 'Save changes' : 'Add to library'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Tile details (identity attributes) ─────────────────────────────────────
  Widget _detailsSection() {
    final pieces = int.tryParse(_piecesCtrl.text.trim()) ?? 0;
    final weight = double.tryParse(_weightCtrl.text.trim()) ?? 0;
    final thick = thicknessRangeLabel(_size, pieces, weight, _tileType);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Tile details',
            style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: Colors.grey.shade800)),
        const SizedBox(height: 2),
        Text('These describe the design itself — set once. Stock screens only '
            'ask for quality and quantity.',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        const SizedBox(height: 10),
        _dropdown('Surface / finish', _surfaces, _surface,
            (v) => setState(() {
                  _surface = v ?? _surface;
                  _dirty = true;
                })),
        const SizedBox(height: 12),
        _dropdown('Tile type', kTileTypes, _tileType,
            (v) => setState(() {
                  _tileType = v ?? _tileType;
                  _dirty = true;
                })),
        const SizedBox(height: 12),
        _dropdown('Restock type', _stockTypes, _stockType,
            (v) => setState(() {
                  _stockType = v ?? _stockType;
                  _dirty = true;
                })),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _piecesCtrl,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() => _dirty = true),
              decoration: const InputDecoration(
                  labelText: 'Pieces / box',
                  isDense: true,
                  border: OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _weightCtrl,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() => _dirty = true),
              decoration: const InputDecoration(
                  labelText: 'Box weight (kg)',
                  isDense: true,
                  border: OutlineInputBorder()),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(
              thick == null
                  ? 'Thickness: enter pieces & weight'
                  : 'Approx. thickness: $thick',
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _colourCtrl,
          textCapitalization: TextCapitalization.words,
          onChanged: (_) => setState(() => _dirty = true),
          decoration: const InputDecoration(
              labelText: 'Colour (optional)',
              isDense: true,
              border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _finishCtrl,
          textCapitalization: TextCapitalization.words,
          onChanged: (_) => setState(() => _dirty = true),
          decoration: const InputDecoration(
              labelText: 'Your finish word (optional)',
              helperText: 'e.g. Carving, Lustra, Punch Ghr — shown on the design',
              helperMaxLines: 2,
              isDense: true,
              border: OutlineInputBorder()),
        ),
      ],
    );
  }

  Widget _dropdown(String label, List<String> items, String value,
      ValueChanged<String?> onChanged) {
    final v = items.contains(value) ? value : (items.isEmpty ? null : items.first);
    return DropdownButtonFormField<String>(
      initialValue: v,
      isExpanded: true,
      decoration: InputDecoration(
          labelText: label, isDense: true, border: const OutlineInputBorder()),
      items: items
          .map((s) => DropdownMenuItem(value: s, child: Text(s)))
          .toList(),
      onChanged: onChanged,
    );
  }

  Widget _aliasField(Brand b) {
    final isDefault = b.id == _defaultBrand.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: _aliasCtrls[b.id],
        textCapitalization: TextCapitalization.words,
        onChanged: isDefault
            ? _onDefaultAliasChanged
            : (_) => _dirty = true,
        decoration: InputDecoration(
          labelText: isDefault ? '${b.name} (default)' : b.name,
          isDense: true,
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.sell_outlined, size: 18),
        ),
      ),
    );
  }
}

/// Reviews likely-duplicate master groups (same name+size+surface, brand-
/// agnostic) and lets the human fold each group into ONE box. Never auto-merges
/// — images may genuinely differ, so the human picks which to keep after seeing
/// them side by side. Pops `true` if any merge happened. (#4 cleanup tool)
class _DuplicatesReviewScreen extends StatefulWidget {
  final List<List<LibraryEntry>> groups;
  final List<Brand> brands;
  const _DuplicatesReviewScreen({required this.groups, required this.brands});
  @override
  State<_DuplicatesReviewScreen> createState() => _DuplicatesReviewState();
}

class _DuplicatesReviewState extends State<_DuplicatesReviewScreen> {
  final _data = SupabaseDataService();
  // Working copy of each group (entries can drop out as they're merged).
  late List<List<LibraryEntry>> _groups;
  final Set<String> _dismissed = {}; // group keys the human marked "different"
  final Map<String, String> _keepId = {}; // group key -> chosen keep entry id
  String? _busyKey;
  bool _changed = false;
  bool _mergingAll = false;
  final _searchCtrl = TextEditingController();
  String _search = '';

  @override
  void initState() {
    super.initState();
    _groups = [
      for (final g in widget.groups) List<LibraryEntry>.from(g)
    ];
    for (final g in _groups) {
      _keepId[_key(g)] = _pickDefaultKeep(g).id;
    }
    _searchCtrl.addListener(() => setState(() => _search = _searchCtrl.text.trim().toLowerCase()));
  }

  // A stable key for a group (its shared identity — name+size, no surface).
  String _key(List<LibraryEntry> g) {
    final e = g.first;
    return '${e.masterName.trim().toLowerCase()}|${e.size}';
  }

  // Default keep = the richest row: has an image, then most brand names.
  LibraryEntry _pickDefaultKeep(List<LibraryEntry> g) {
    final sorted = List<LibraryEntry>.from(g)
      ..sort((a, b) {
        final ai = a.imageUrl.isNotEmpty ? 1 : 0;
        final bi = b.imageUrl.isNotEmpty ? 1 : 0;
        if (ai != bi) return bi - ai;
        return b.aliases.length.compareTo(a.aliases.length);
      });
    return sorted.first;
  }

  String _brandName(String id) => widget.brands
      .firstWhere((b) => b.id == id, orElse: () => const Brand(id: '', name: '?'))
      .name;

  void _snack(String m, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), backgroundColor: error ? Colors.red : null));
  }

  Future<void> _mergeGroup(List<LibraryEntry> g) async {
    final key = _key(g);
    final keepId = _keepId[key];
    if (keepId == null) return;
    final keep = g.firstWhere((e) => e.id == keepId, orElse: () => g.first);
    final drops = g.where((e) => e.id != keep.id).toList();
    if (drops.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Merge ${drops.length + 1} into one?'),
        content: Text(
            'Keep "${keep.masterName}" (${keep.size}) and fold the other '
            '${drops.length} into it. Their brand names and DNA move onto the '
            'kept tile; stock counts are untouched. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _navy),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Merge')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busyKey = key);
    try {
      for (final d in drops) {
        await _data.mergeLibraryMasters(keepId: keep.id, dropId: d.id);
      }
      _changed = true;
      setState(() {
        _groups.removeWhere((x) => _key(x) == key);
        _busyKey = null;
      });
      _snack('Merged into "${keep.masterName}".');
    } catch (e) {
      setState(() => _busyKey = null);
      _snack('$e', error: true);
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _mergeAll(List<List<LibraryEntry>> groups) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Merge all ${groups.length} group${groups.length == 1 ? '' : 's'}?'),
        content: const Text(
            'Each group will be merged into its selected tile. Brand names, '
            'DNA and photos move across. Stock counts are untouched. '
            'This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _navy),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Merge All')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _mergingAll = true);
    final merged = <String>[];
    try {
      for (final g in groups) {
        final key = _key(g);
        final keepId = _keepId[key];
        if (keepId == null) continue;
        final keep = g.firstWhere((e) => e.id == keepId, orElse: () => g.first);
        for (final d in g.where((e) => e.id != keep.id)) {
          await _data.mergeLibraryMasters(keepId: keep.id, dropId: d.id);
        }
        merged.add(key);
        _changed = true;
      }
      setState(() {
        _groups.removeWhere((x) => merged.contains(_key(x)));
        _mergingAll = false;
      });
      _snack('Merged ${merged.length} group${merged.length == 1 ? '' : 's'}.');
    } catch (e) {
      setState(() => _mergingAll = false);
      _snack('$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = _groups
        .where((g) => !_dismissed.contains(_key(g)))
        .where((g) => _search.isEmpty ||
            g.first.masterName.toLowerCase().contains(_search))
        .toList();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF5F5F5),
        appBar: AppBar(
          title: const Text('Find duplicates'),
          actions: [
            if (visible.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _mergingAll
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: _navy))
                    : TextButton(
                        onPressed: _busyKey != null
                            ? null
                            : () => _mergeAll(visible),
                        child: const Text('Merge All',
                            style: TextStyle(color: _navy)),
                      ),
              ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: 'Search by design name…',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _search.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () => _searchCtrl.clear(),
                        )
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
            Expanded(
              child: visible.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle_outline,
                                size: 48, color: Colors.green.shade400),
                            const SizedBox(height: 12),
                            Text(
                                _search.isNotEmpty
                                    ? 'No matches for "$_search".'
                                    : _changed
                                        ? 'All done — nothing left to review.'
                                        : 'No duplicates to review.',
                                style: const TextStyle(fontSize: 15)),
                          ],
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
                          child: Text(
                              'These tiles share a name and size. Pick the one '
                              'to KEEP and merge the rest — or mark them as genuinely '
                              'different to leave them alone.',
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: Colors.grey.shade700)),
                        ),
                        for (final g in visible) _groupCard(g),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupCard(List<LibraryEntry> g) {
    final key = _key(g);
    final e0 = g.first;
    final busy = _busyKey == key;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                      '${e0.masterName} · ${e0.size.replaceAll(' mm', '')}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 14)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.orange.shade200)),
                  child: Text('${g.length} copies',
                      style: TextStyle(
                          fontSize: 11, color: Colors.orange.shade900)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('Tap a tile to keep it.',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            const SizedBox(height: 8),
            for (final e in g) _entryRow(key, e),
            const SizedBox(height: 6),
            Row(
              children: [
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(() => _dismissed.add(key)),
                  child: const Text('They are different'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: busy ? null : () => _mergeGroup(g),
                  style: FilledButton.styleFrom(backgroundColor: _navy),
                  icon: busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.call_merge, size: 18),
                  label: Text('Merge ${g.length} → 1'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _entryRow(String key, LibraryEntry e) {
    final isKeep = _keepId[key] == e.id;
    return InkWell(
      onTap: () => setState(() => _keepId[key] = e.id),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: isKeep ? _navy.withValues(alpha: 0.06) : null,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: isKeep ? _navy : Colors.grey.shade200,
              width: isKeep ? 1.5 : 1),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: e.imageUrl.isEmpty
                  ? Container(
                      width: 54,
                      height: 54,
                      color: Colors.grey.shade200,
                      child: Icon(Icons.image_outlined,
                          color: Colors.grey.shade400, size: 22))
                  : CachedNetworkImage(
                      imageUrl:
                          CloudinaryService.thumbUrl(e.imageUrl, width: 140),
                      width: 54,
                      height: 54,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(
                          width: 54, height: 54, color: Colors.grey.shade200),
                      errorWidget: (_, __, ___) => Container(
                          width: 54, height: 54, color: Colors.grey.shade200),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (e.aliases.isEmpty)
                    Text('(no brand names)',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade500))
                  else
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final a in e.aliases.entries)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: _navy.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text('${_brandName(a.key)}: ${a.value}',
                                style:
                                    const TextStyle(fontSize: 10, color: _navy)),
                          ),
                      ],
                    ),
                  if (e.imageUrl.isEmpty) ...[
                    const SizedBox(height: 2),
                    Text('no photo',
                        style: TextStyle(
                            fontSize: 10, color: Colors.grey.shade500)),
                  ],
                  if (e.surfaceType.isNotEmpty &&
                      e.surfaceType.toLowerCase() != 'none') ...[
                    const SizedBox(height: 2),
                    Text(e.surfaceType,
                        style: TextStyle(
                            fontSize: 10, color: Colors.grey.shade500)),
                  ],
                ],
              ),
            ),
            if (isKeep)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.check_circle, color: _navy, size: 22),
              )
            else
              Icon(Icons.radio_button_unchecked,
                  color: Colors.grey.shade400, size: 22),
          ],
        ),
      ),
    );
  }
}
