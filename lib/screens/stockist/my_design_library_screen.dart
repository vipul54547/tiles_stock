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
import '../../utils/dna_chains.dart';
import '../../utils/platform_kind.dart';
import 'dna_editor_sheet.dart';

/// "24.0" -> "24", "10.1" -> "10.1". Used by both the card chips and the editor.
String _trimNum(double v) => v % 1 == 0 ? v.toStringAsFixed(0) : v.toString();

/// One pickable surface: the stockist's own WORD and the admin CANONICAL it means.
/// The word is shown and stored as `surface_label` (display only); the canonical is
/// stored as `surface_type` and IS the product's identity. (my_surface_options)
typedef SurfaceOption = ({String label, String canonical});

/// How a surface reads in a picker: their word with the canonical it maps to, so
/// "RAINDROP (Sugar)" is self-explanatory. Just the name when they are the same.
String _surfaceOptionText(SurfaceOption o) =>
    o.label.trim().toLowerCase() == o.canonical.trim().toLowerCase()
        ? o.canonical
        : '${o.label} (${o.canonical})';

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
  // Surface is part of the PRODUCT's identity — Glossy and Matt of one print are two
  // products — so the editor must be able to pick one. (product identity migration)
  //
  // These are the stockist's OWN WORDS, each with the admin canonical it means:
  // livok picks "RAINDROP", and Sugar is what gets stored. A surface they have no word
  // of their own for falls back to the admin name. The word is what they read on their
  // boxes; the canonical is the identity. (my_surface_options — never 'None')
  List<SurfaceOption> _surfaces = [];
  Map<String, List<DnaTag>> _dnaTags = {}; // libraryId → DNA tags (their words)
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
      _data.getMySurfaceOptions(),
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
      _dnaTags = results[3] as Map<String, List<DnaTag>>;
      // De-duplicated by word: two of their aliases can share a display word, and a
      // dropdown needs its values distinct.
      final seen = <String>{};
      _surfaces = [
        for (final o in results[4] as List<SurfaceOption>)
          if (o.label.trim().isNotEmpty && seen.add(o.label.trim().toLowerCase())) o
      ];
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
            brands: _brands,
            sizes: _sizes,
            surfaces: _surfaces,
            all: _entries,
            existing: entry),
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
            surfaces: _surfaces,
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
  // Merge candidates. Same size AND same surface only — two surfaces are two different
  // products, and `library_merge_masters` now refuses to merge across them, so we must
  // not offer it. (product identity migration)
  List<LibraryEntry> _sameSizeSiblings(LibraryEntry keep) => _entries
      .where((o) =>
          o.id != keep.id &&
          o.size == keep.size &&
          o.surfaceType.trim().toLowerCase() ==
              keep.surfaceType.trim().toLowerCase())
      .toList();

  // Likely-duplicate groups: 2+ boxes sharing the SAME product key
  // (master name + size + surface), brand-agnostic.
  //
  // Surface used to be excluded here on the theory that one tile arriving from two
  // suppliers with different surface words was really one master. That theory is dead:
  // surface IS product identity, so Glossy and Matt of one print are two products and
  // are NOT duplicates of each other. Including it is what stops this tool from offering
  // to merge them back into the collapse bug we just repaired.
  List<List<LibraryEntry>> get _duplicateGroups {
    final groups = <String, List<LibraryEntry>>{};
    for (final e in _entries) {
      final key = '${e.masterName.trim().toLowerCase()}|${e.size}'
          '|${e.surfaceType.trim().toLowerCase()}';
      (groups[key] ??= []).add(e);
    }
    final out = groups.values.where((g) => g.length > 1).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    return out;
  }

  // Family (concept) correction. The app auto-groups variants by name-root
  // (1801-A / 1801-B / 1801, etc.); here the stockist only CORRECTS the
  // auto-result — remove a wrong member (it stands alone) or add a missing one
  // — without ever building a list from scratch. Buyer then sees the perfected
  // family on the tile page. (design_family)
  Future<void> _openFamilySheet(LibraryEntry keep) async {
    Future<Map<String, dynamic>> load() => _data.myFamilyFor(keep.id);
    var data = await load();
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final key = (data['family_key'] ?? '').toString();
          final members = ((data['members'] as List?) ?? const [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          final memberIds =
              members.map((m) => '${m['library_id']}').toSet();

          Future<void> refresh() async {
            final d = await load();
            if (ctx.mounted) setSheet(() => data = d);
          }

          Future<void> removeMember(String libId) async {
            // Stand-alone = point it at its own id (a unique key).
            await _data.familySetOverride(libId, libId);
            await refresh();
          }

          Future<void> addMember() async {
            final picked = await _pickFamilyAddition(keep, memberIds);
            if (picked == null) return;
            await _data.familySetOverride(picked.id, key);
            await refresh();
          }

          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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
                      const Text('Design family',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15)),
                      const SizedBox(height: 2),
                      Text(
                          'Variants sold as a set. Auto-grouped by name — remove '
                          'a wrong one or add a missing one. Buyers see the whole '
                          'family on the tile page.',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600)),
                    ],
                  ),
                ),
                const Divider(height: 12),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    children: [
                      if (members.length < 2)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                              'No family yet — this design stands alone. Add a '
                              'same-size variant to start a family.',
                              style: TextStyle(color: Colors.grey.shade600)),
                        ),
                      for (final m in members)
                        _familyMemberRow(m, onRemove: () => removeMember('${m['library_id']}')),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: addMember,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add a design to this family'),
                        style: OutlinedButton.styleFrom(foregroundColor: _navy),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (mounted) _load();
  }

  Widget _familyMemberRow(Map<String, dynamic> m,
      {required VoidCallback onRemove}) {
    final name = (m['name'] ?? '').toString();
    final img = (m['image_url'] ?? '').toString();
    final fStock = (m['f_stock'] as num?)?.toInt() ?? 0;
    final inStock = fStock > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 44,
              height: 44,
              child: img.isEmpty
                  ? Container(
                      color: Colors.grey.shade100,
                      child: Icon(Icons.image_outlined,
                          size: 20, color: Colors.grey.shade400))
                  : CachedNetworkImage(
                      imageUrl: CloudinaryService.thumbUrl(img, width: 120),
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
                Text(name,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(inStock ? '$fStock boxes' : 'Out of stock',
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: inStock
                            ? const Color(0xFF2E7D32)
                            : const Color(0xFFC62828))),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close, size: 18, color: Colors.red.shade400),
            tooltip: 'Remove from family',
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }

  // Same-size sibling picker for "add to family" — reuses the merge-sheet list
  // style, excluding members already in the family.
  Future<LibraryEntry?> _pickFamilyAddition(
      LibraryEntry keep, Set<String> excludeIds) {
    final candidates = _sameSizeSiblings(keep)
        .where((c) => !excludeIds.contains(c.id))
        .toList();
    if (candidates.isEmpty) {
      _snack('No other ${keep.size.replaceAll(' mm', '')} designs to add.');
      return Future.value(null);
    }
    var query = '';
    return showModalBottomSheet<LibraryEntry>(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final q = query.trim().toLowerCase();
          final list = q.isEmpty
              ? candidates
              : candidates
                  .where((c) => c.masterName.toLowerCase().contains(q))
                  .toList();
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(top: 8, bottom: 2),
                  decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: TextField(
                    onChanged: (v) => setSheet(() => query = v),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 20),
                      hintText: 'Search a design to add',
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const Divider(height: 12),
                Flexible(
                  child: list.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text('No match for "$query".',
                              style: TextStyle(color: Colors.grey.shade600)))
                      : ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                          itemCount: list.length,
                          itemBuilder: (_, i) {
                            final c = list[i];
                            return InkWell(
                              onTap: () => Navigator.pop(ctx, c),
                              borderRadius: BorderRadius.circular(8),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 7),
                                child: Row(
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
                                                imageUrl: CloudinaryService
                                                    .thumbUrl(c.imageUrl,
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
                                      child: Text(c.masterName,
                                          style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600)),
                                    ),
                                    const SizedBox(width: 8),
                                    const Icon(Icons.add_circle_outline,
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
          // 🚫 THE PDF IMPORT IS GONE FROM HERE — deliberately, not by accident.
          //
          // A supplier PDF prints the name stamped on the BOX (`brand_design_name`): the
          // FACTORY'S word, per-brand, free text ("1001", "CARRARA GOLD"). It is NOT the
          // stockist's own word for the artwork — and `print_name` is exactly that. Feeding a
          // PDF label into print_name forges a WRONG PRINT for every row, and the print sits at
          // the top of the identity chain, so the damage runs all the way down.
          //
          // A FOLDER is the honest source: HE NAMED THE FILES. The route and the parser survive
          // for re-use elsewhere; only the way in is closed.
          //
          // Windows only — it reads a folder tree with dart:io, and his images live on his PC.
          if (isWindowsDesktop)
            IconButton(
              icon: const Icon(Icons.drive_folder_upload_outlined),
              tooltip: 'Import images from a folder (add designs)',
              onPressed: () async {
                final done =
                    await context.push<bool>('/stockist/library/import-images');
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
          // PRODUCT DOOR (b) — the Excel sheet. It carries the four facts the old mapping
          // importer could not express (surface, tile type, pieces/box, box weight), so a
          // product it creates is COMPLETE. It imports no stock; that is the other door.
          IconButton(
            icon: const Icon(Icons.table_chart_outlined),
            tooltip: 'Import products from Excel (no stock)',
            onPressed: () async {
              final done = await context
                  .push<bool>('/stockist/library/import-products');
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
                          // One card per PRINT, not per product. (_byPrint)
                          final prints = _byPrint(list);
                          return ListView.separated(
                            padding: EdgeInsets.fromLTRB(12, 4, 12,
                                90 + MediaQuery.viewPaddingOf(context).bottom),
                            itemCount: prints.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (_, i) => _printCard(prints[i]),
                          );
                        }),
                ),
              ],
            ),
    );
  }

  Widget _searchBar() {
    final shown = _filtered.length;
    final shownPrints = _byPrint(_filtered).length;
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
              // Designs (products) is the honest count — but the cards are PRINTS, so
              // say how many prints they sit in whenever the two differ.
              child: Text(
                  shownPrints == shown
                      ? '$shown of ${_entries.length} designs'
                      : '$shown of ${_entries.length} designs · $shownPrints prints',
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

  /// The product's surface for display: `Word (Canonical)` when the stockist has their
  /// own word for it, else just the canonical. Empty for 'None' — a product with no
  /// surface should not shout about it.
  static String _surfaceOf(LibraryEntry e) {
    final canon = e.surfaceType.trim();
    if (canon.isEmpty || canon.toLowerCase() == 'none') return '';
    final word = e.surfaceLabel.trim();
    if (word.isEmpty || word.toLowerCase() == canon.toLowerCase()) return canon;
    return '$word ($canon)';
  }

  /// The SURFACE chip — deliberately its OWN chip, sitting beside the DNA chips but NOT a
  /// DNA tag. Surface as a `dna_attribute` was tried and killed
  /// ([[project_per_brand_surface_mode]]); the deactivated row is still in the DB and must
  /// never be reactivated. This is a plain identity field with a fast edit affordance.
  Widget _surfaceChip(LibraryEntry e) {
    final text = _surfaceOf(e);
    return InkWell(
      onTap: () => _editSurface(e),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFF1B4F72).withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: const Color(0xFF1B4F72).withValues(alpha: 0.20)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text.isEmpty ? 'Set surface' : text,
                style: const TextStyle(
                    fontSize: 11, color: _navy, fontWeight: FontWeight.w600)),
            const SizedBox(width: 4),
            const Icon(Icons.edit, size: 11, color: _navy),
          ],
        ),
      ),
    );
  }

  /// Change a product's surface. This is an IDENTITY change — the server cascades it to
  /// every holding of the product, and refuses if the print already exists in the target
  /// surface (that would be a duplicate).
  Future<void> _editSurface(LibraryEntry e) async {
    // Their own words. ('None' can't appear — my_surface_options excludes it.)
    final options = _surfaces;
    if (options.isEmpty) return;

    final picked = await showModalBottomSheet<SurfaceOption>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Surface for "${e.masterName}"',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 4),
                  Text(
                      'The surface is part of the design. Changing it moves this '
                      'design’s stock with it.',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                ],
              ),
            ),
            const Divider(height: 16),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final s in options)
                    ListTile(
                      dense: true,
                      title: Text(_surfaceOptionText(s)),
                      trailing: s.canonical.toLowerCase() ==
                              e.surfaceType.trim().toLowerCase()
                          ? const Icon(Icons.check, color: _navy, size: 18)
                          : null,
                      onTap: () => Navigator.pop(ctx, s),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    // Nothing to do only if BOTH the identity and their word are already what was
    // picked — re-picking the same canonical under a different word still changes
    // the label they read on the card.
    if (picked.canonical.toLowerCase() == e.surfaceType.trim().toLowerCase() &&
        picked.label.toLowerCase() == e.surfaceLabel.trim().toLowerCase()) {
      return;
    }

    try {
      // canonical = identity (surface_type); label = their word (surface_label).
      // The server cascades both to every holding of this product.
      await _data.setLibrarySurface(e.id, picked.canonical, label: picked.label);
    } catch (err) {
      if (!mounted) return;
      _snack('$err', error: true);
      return;
    }
    if (!mounted) return;
    _snack('Surface changed to ${_surfaceOptionText(picked)}.');
    _load();
  }

  /// THE BOX chip — `4 pcs · 24 kg · 8.5–9.0 mm`. Tap to set how each brand packs this print.
  ///
  /// Pieces + weight live on the BOX (product × brand), because brands can pack differently.
  /// Thickness is DERIVED from them and never typed — and shown as a 0.5 mm BAND, never a
  /// bare "8.8 mm": it is inferred from box weight, not measured, and every thickness filter
  /// in the app chips on these bands.
  Widget _boxChip(LibraryEntry e) {
    final band = thicknessBandLabel(e.thicknessMm);
    final bits = <String>[
      if (e.piecesPerBox > 0) '${e.piecesPerBox} pcs',
      if (e.boxWeightKg > 0) '${_trimNum(e.boxWeightKg)} kg',
      if (band != null) band,
    ];
    return InkWell(
      onTap: () => _editBox(e),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inventory_2_outlined, size: 11, color: Colors.grey.shade700),
            const SizedBox(width: 4),
            Text(bits.isEmpty ? 'Set box' : bits.join(' · '),
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade800,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  /// Per-brand box editor. One row per brand that carries this print, because the same print
  /// may ship 4/box under one brand and 6/box under another. Thickness is shown live as they
  /// type — derived, never entered.
  Future<void> _editBox(LibraryEntry e) async {
    // Only the brands that actually carry this print (its boxes); fall back to the product's
    // own brand so a single-brand print is still editable.
    final brandIds = e.boxes.keys.toSet();
    if (brandIds.isEmpty && e.brandId.isNotEmpty) brandIds.add(e.brandId);
    final brands =
        _brands.where((b) => brandIds.contains(b.id)).toList();
    if (brands.isEmpty) {
      _snack('This design has no brand yet — add one first.', error: true);
      return;
    }

    // Prefill from this brand's OTHER boxes at the same size: packing does not vary within a
    // brand, so the stockist should type it once per (brand, size), not once per design.
    ({int pieces, double weightKg})? sameSizeDefault(String brandId) {
      for (final o in _entries) {
        if (o.id == e.id || o.size != e.size) continue;
        final b = o.boxes[brandId];
        if (b != null && b.pieces > 0 && b.weightKg > 0) return b;
      }
      return null;
    }

    final pieceCtrls = <String, TextEditingController>{};
    final weightCtrls = <String, TextEditingController>{};
    for (final b in brands) {
      final cur = e.boxes[b.id];
      final def = sameSizeDefault(b.id);
      final p = (cur != null && cur.pieces > 0) ? cur.pieces : (def?.pieces ?? 0);
      final w =
          (cur != null && cur.weightKg > 0) ? cur.weightKg : (def?.weightKg ?? 0);
      pieceCtrls[b.id] =
          TextEditingController(text: p > 0 ? '$p' : '');
      weightCtrls[b.id] =
          TextEditingController(text: w > 0 ? _trimNum(w) : '');
    }

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        // The 0.5 mm BAND, not a bare number — same rule as the chip, and the same
        // formula the server will derive on save, so the preview and the stored value
        // agree.
        String derived(String brandId) {
          final p = int.tryParse(pieceCtrls[brandId]!.text.trim()) ?? 0;
          final w = double.tryParse(weightCtrls[brandId]!.text.trim()) ?? 0;
          return thicknessRangeLabel(e.size, p, w, e.tileType) ?? '—';
        }

        return Padding(
          padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.viewInsetsOf(ctx).bottom + 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Box for "${e.masterName}"  ·  ${e.size.replaceAll(' mm', '')}',
                  style:
                      const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 4),
              Text(
                  'Each brand can pack the same tile differently. Thickness is worked out '
                  'from the weight — you never type it.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              const Divider(height: 20),
              for (final b in brands) ...[
                Text(b.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13, color: _navy)),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: pieceCtrls[b.id],
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setSheet(() {}),
                      decoration: const InputDecoration(
                          labelText: 'Pieces / box',
                          isDense: true,
                          border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: weightCtrls[b.id],
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => setSheet(() {}),
                      decoration: const InputDecoration(
                          labelText: 'Box weight (kg)',
                          isDense: true,
                          border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 74,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Thickness',
                            style: TextStyle(
                                fontSize: 10, color: Colors.grey.shade600)),
                        Text(derived(b.id),
                            style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: _navy)),
                      ],
                    ),
                  ),
                ]),
                const SizedBox(height: 14),
              ],
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        );
      }),
    );

    if (saved != true || !mounted) return;

    try {
      for (final b in brands) {
        final p = int.tryParse(pieceCtrls[b.id]!.text.trim()) ?? 0;
        final w = double.tryParse(weightCtrls[b.id]!.text.trim()) ?? 0;
        if (p <= 0 && w <= 0) continue;
        await _data.setLibraryBox(e.id, b.id,
            pieces: p > 0 ? p : null, weightKg: w > 0 ? w : null);
      }
    } catch (err) {
      if (!mounted) return;
      _snack('$err', error: true);
      return;
    }
    if (!mounted) return;
    _snack('Box saved.');
    _load();
  }

  /// The thickness to show in brackets beside [e]'s name, or null for a plain name.
  ///
  /// A print+size+surface+body can hold more than one product only when their thicknesses are more
  /// than 1 mm apart — a genuinely different tile. The FIRST one created is the original and reads
  /// plainly; anything forked off it later carries its thickness so the two are distinguishable.
  String? _forkedThicknessOf(LibraryEntry e) {
    if (e.thicknessMm == null) return null;
    final siblings = _entries.where((o) =>
        o.masterName.toLowerCase() == e.masterName.toLowerCase() &&
        o.size == e.size &&
        o.surfaceType == e.surfaceType &&
        o.tileType == e.tileType);
    if (siblings.length < 2) return null; // the only one of its kind — nothing to tell apart

    // The oldest is the original. Anything without a date sorts as oldest-unknown and keeps its
    // plain name rather than being mislabelled.
    DateTime? oldest;
    for (final o in siblings) {
      if (o.createdAt == null) continue;
      if (oldest == null || o.createdAt!.isBefore(oldest)) oldest = o.createdAt;
    }
    if (oldest == null || e.createdAt == null) return null;
    if (!e.createdAt!.isAfter(oldest)) return null; // this IS the original

    return thicknessBandLabel(e.thicknessMm);
  }

  // ── THE LIBRARY CARD = ONE PRINT ────────────────────────────────────────────
  // The card mirrors the model, top to bottom:
  //
  //   PRINT    the ARTWORK — one name, one size, one photo, stored ONCE.
  //     └ PRODUCT   one PIECE of tile: surface · body · thickness. A print can carry
  //                 several (a Glossy and a Matt; an 8 mm and a 12 mm).
  //         └ BOX   per brand: the name that brand STAMPS on the box, and how that
  //                 brand PACKS it (pieces, weight). Two brands pack independently.
  //
  // Before this, the Library showed one flat card per PRODUCT, so two surfaces of one
  // artwork looked like two unrelated designs sharing a photo by coincidence.

  /// Group the (already filtered) products into their prints, in list order.
  List<List<LibraryEntry>> _byPrint(List<LibraryEntry> list) {
    final groups = <String, List<LibraryEntry>>{};
    for (final e in list) {
      // A product always points at a print. The name|size fallback only guards against
      // a blank print_id — a row must never vanish from the Library.
      final key =
          e.printId.isNotEmpty ? e.printId : '${e.masterName}|${e.size}';
      (groups[key] ??= <LibraryEntry>[]).add(e);
    }
    // Oldest first inside a print: the ORIGINAL leads and the product later forked off
    // it by a genuinely different thickness follows — which is what wears the brackets.
    for (final g in groups.values) {
      g.sort((a, b) => (a.createdAt ?? DateTime(0))
          .compareTo(b.createdAt ?? DateTime(0)));
    }
    return groups.values.toList();
  }

  Widget _printCard(List<LibraryEntry> products) {
    final print = products.first; // name · size · photo belong to the PRINT
    final many = products.length > 1;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── THE PRINT ──────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 60,
                    height: 60,
                    child: print.imageUrl.isEmpty
                        ? Container(
                            color: Colors.grey.shade100,
                            child: Icon(Icons.image_outlined,
                                color: Colors.grey.shade400))
                        : CachedNetworkImage(
                            imageUrl: CloudinaryService.thumbUrl(print.imageUrl,
                                width: 160),
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
                      Text(print.masterName,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15)),
                      const SizedBox(height: 1),
                      Text(print.size.replaceAll(' mm', ''),
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600)),
                      // Only worth saying when the print really is carried more than
                      // once — it is the whole reason the card is grouped.
                      if (many) ...[
                        const SizedBox(height: 5),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: _navy.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('${products.length} designs',
                              style: const TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: _navy)),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          // ── ITS PRODUCTS ───────────────────────────────────────────────────
          for (final e in products) _productRow(e, indent: many),
        ],
      ),
    );
  }

  /// One PRODUCT: surface · body · thickness, its per-brand BOXES, its DNA, its actions.
  Widget _productRow(LibraryEntry e, {required bool indent}) {
    final forked = _forkedThicknessOf(e);
    final dnaChains = buildDnaChainMap(_dnaTags[e.id] ?? const <DnaTag>[]);
    final brandIds = <String>{...e.aliases.keys, ...e.boxes.keys};
    return Container(
      decoration: BoxDecoration(
        // A tinted, ruled band only when the print carries more than one product —
        // otherwise the single product IS the card and a box around it is just noise.
        color: indent ? const Color(0xFFF7F9FB) : null,
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // IDENTITY: surface (tap to change) · body · thickness.
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _surfaceChip(e),
                    _bodyChip(e),
                    _thicknessChip(e, forked),
                  ],
                ),
                // THE BOXES: one row per brand — the name it stamps + how it packs.
                if (brandIds.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  for (final bid in brandIds) _brandBoxRow(e, bid),
                ] else ...[
                  const SizedBox(height: 6),
                  _boxChip(e), // no brand yet → the "Set box" affordance
                ],
                if (dnaChains.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  for (final grp in dnaChains.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 3, right: 6),
                            child: Text('${grp.key}:',
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.grey.shade600)),
                          ),
                          Expanded(
                            child: Wrap(
                              spacing: 5,
                              runSpacing: 4,
                              children: grp.value
                                  .map((chain) => Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 7, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFB9770E)
                                              .withValues(alpha: 0.10),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Text(chain,
                                            style: const TextStyle(
                                                fontSize: 11,
                                                color: Color(0xFF8A5A09))),
                                      ))
                                  .toList(),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
          // Every action here acts on the PRODUCT (library_id), never on the print.
          Column(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(),
                icon: const Icon(Icons.science_outlined,
                    size: 19, color: Color(0xFFB9770E)),
                tooltip: 'Design DNA (for search)',
                onPressed: () async {
                  await showDnaEditor(context,
                      libraryId: e.id, designName: e.masterName);
                  await _reloadDnaTags();
                },
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(),
                icon: const Icon(Icons.edit_outlined, size: 19),
                tooltip: 'Edit',
                onPressed: () => _openEditor(e),
              ),
              if (_sameSizeSiblings(e).isNotEmpty)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(),
                  icon: const Icon(Icons.call_merge, size: 19, color: _navy),
                  tooltip: currentStockistBusinessType == 'M'
                      ? 'Merge a duplicate into this'
                      : 'Merge a duplicate design into this one',
                  onPressed: () => _openMergeSheet(e),
                ),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(),
                icon:
                    const Icon(Icons.grid_view_outlined, size: 19, color: _navy),
                tooltip: 'Design family (concept group)',
                onPressed: () => _openFamilySheet(e),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(),
                icon: const Icon(Icons.delete_outline,
                    size: 19, color: Colors.red),
                tooltip: 'Delete',
                onPressed: () => _confirmDelete(e),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The BODY (tile_type). Honestly blank when undeclared — never guessed.
  Widget _bodyChip(LibraryEntry e) {
    final has = e.tileType.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: has ? Colors.grey.shade100 : const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
            color: has ? Colors.grey.shade300 : Colors.orange.shade200),
      ),
      child: Text(has ? e.tileType : 'no body',
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: has ? Colors.grey.shade800 : Colors.orange.shade900)),
    );
  }

  /// The THICKNESS — DERIVED from the box, never typed. A product forked off the
  /// original by a genuinely different thickness (>1 mm) is marked, so two products of
  /// one print can be told apart at a glance.
  Widget _thicknessChip(LibraryEntry e, String? forked) {
    final band = thicknessBandLabel(e.thicknessMm);
    if (band == null) {
      // Say what is ACTUALLY missing. thickness = weight / (pieces × area × DENSITY),
      // and the density comes from the BODY — so a product with a perfectly good box but
      // no body still has no thickness, and telling him to "set a box" sends him to fix
      // the one thing that isn't broken.
      final hasBox = e.boxes.values
          .any((b) => b.pieces > 0 && b.weightKg > 0);
      final String why;
      if (!hasBox) {
        why = 'no thickness — set a box';
      } else if (e.tileType.trim().isEmpty) {
        why = 'no thickness — set the body';
      } else {
        // Box and body are both there, so the weight itself is out of range (the band is
        // NULL outside 4–20 mm). That is a bad box weight, not a thin tile.
        why = 'no thickness — check the box weight';
      }
      return Text(why,
          style: TextStyle(fontSize: 11, color: Colors.orange.shade800));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: forked != null
            ? Colors.teal.withValues(alpha: 0.10)
            : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
            color: forked != null ? Colors.teal.shade200 : Colors.grey.shade300),
      ),
      child: Text(band,
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: forked != null
                  ? Colors.teal.shade800
                  : Colors.grey.shade800)),
    );
  }

  /// ONE BOX = one brand's row: the name it STAMPS on the box, and how it PACKS it.
  /// Two brands carrying the same product pack independently, which is exactly why
  /// pieces/weight live here and not on the product. Tap to edit the packing.
  Widget _brandBoxRow(LibraryEntry e, String brandId) {
    final name = e.aliases[brandId] ?? '';
    final box = e.boxes[brandId];
    final packing = <String>[
      if ((box?.pieces ?? 0) > 0) '${box!.pieces} pcs',
      if ((box?.weightKg ?? 0) > 0) '${_trimNum(box!.weightKg)} kg',
    ].join(' · ');
    return InkWell(
      onTap: () => _editBox(e),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            _brandNamePill(brandId, name),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                // No packing = no thickness. Say so where it can be fixed.
                packing.isEmpty ? 'set pieces + weight' : packing,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: packing.isEmpty
                        ? Colors.orange.shade800
                        : Colors.grey.shade700),
                overflow: TextOverflow.ellipsis,
              ),
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
    final sub = e.size.replaceAll(' mm', '');
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
  // The stockist's own surface WORDS + the canonical each means. Surface is product
  // identity, so the canonical is what gets stored; the word is what they recognise.
  final List<SurfaceOption> surfaces;
  final List<LibraryEntry> all; // for live duplicate detection
  final LibraryEntry? existing;
  // Brand-first guided add: a new tile arrives pre-filled with the typed name
  // (master + that brand's alias) so the human doesn't re-type. (null = blank.)
  final String? prefillName;
  final String? prefillBrandId;
  const _LibraryEditorScreen(
      {required this.brands,
      required this.sizes,
      required this.surfaces,
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
  // (pieces/box + box weight are NOT here: they are BOX facts, set per brand on the card's
  //  box chip. Thickness is derived from them.)
  final _colourCtrl = TextEditingController();
  final _finishCtrl = TextEditingController();
  String _tileType = tileTypeNames.first;
  // 🔑 DECLARED nominal thickness — part of the product's identity, so it is REQUIRED on a new
  // design and never guessed. Null on the legacy rows that predate CHAPTER 3; editing one of
  // those does not force a value, so an image or name can still be fixed.
  // 🔑 There is NO thickness field, and there must never be one. Thickness is DERIVED —
  // box weight / (pieces x area x density) — and a stockist cannot know "8.5-9.0 mm"; they read
  // PIECES and WEIGHT off the box. Asking them to pick a thickness would invite a guess into the
  // identity key. (docs/THICKNESS_AND_BODY_IDENTITY_PLAN.md)
  //
  // A NEW design has no box, so it would have no thickness and no complete identity. So Add-design
  // asks for the three things that ARE on the box — tile type, box weight, pieces — and the
  // thickness falls out of them the moment it saves. On EDIT these are hidden: by then several
  // brands may pack the same print differently, and this form has one value for all of them, so
  // writing it would flatten every brand's packing. The card's per-brand BOX CHIP owns them.
  final _piecesCtrl = TextEditingController();
  final _weightCtrl = TextEditingController();
  String _stockType = 'Uncertain';
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

  /// The SURFACE is part of the product's identity: "Glossy Ant Bianco" and "Matt Ant
  /// Bianco" are two different products made from one print. So the editor asks for it,
  /// and it is saved as identity — not left empty.
  ///
  /// (This replaces the old rule that "a print carries no surface and this editor never
  /// asks for one". The product key is now
  /// `(stockist, lower(master_design_name), size, surface_type)`.)
  /// The ADMIN CANONICAL — this is the identity, and what is stored as `surface_type`.
  String _surface = '';

  /// The stockist's own WORD for it ("RAINDROP"), stored as `surface_label`. Display
  /// only, never a key — keying on it would wedge Add Stock against the product index.
  String _surfaceWord = '';

  String get _surfaceToSave => _surface;

  /// Their own words, each carrying the canonical it means. **'None' is NOT offered** —
  /// a tile always has a surface. 'None' was never one, it was "we don't know yet"
  /// wearing one's clothes, and since surface is part of the product key it produced a
  /// phantom product sitting beside the real one. (my_surface_options excludes it.)
  List<SurfaceOption> get _surfaceOptions => widget.surfaces;

  /// The option currently selected, matched on their WORD first (a product may carry a
  /// word whose canonical several words share) and on the canonical otherwise — an
  /// older product has a surface_type but no word yet.
  SurfaceOption? get _selectedSurface {
    for (final o in _surfaceOptions) {
      if (_surfaceWord.isNotEmpty &&
          o.label.trim().toLowerCase() == _surfaceWord.trim().toLowerCase()) {
        return o;
      }
    }
    for (final o in _surfaceOptions) {
      if (_surface.isNotEmpty &&
          o.canonical.trim().toLowerCase() == _surface.trim().toLowerCase()) {
        return o;
      }
    }
    return null;
  }

  // The SAME product already in the library, or null. Identity = master name + size +
  // SURFACE. Brand is NOT identity — for an M a different brand is only a different NAME
  // for the same print — so it no longer splits the match. Two surfaces are two products
  // and must NOT flag as duplicates, or the editor would block the very thing the
  // migration exists to allow.
  LibraryEntry? get _dupMatch {
    final name = _master.text.trim().toLowerCase();
    if (name.isEmpty || _size.isEmpty) return null;
    for (final e in widget.all) {
      if (e.id == widget.existing?.id) continue;
      if (e.masterName.trim().toLowerCase() != name || e.size != _size) continue;
      if (e.surfaceType.trim().toLowerCase() != _surface.trim().toLowerCase()) {
        continue; // a different surface is a different product, not a duplicate
      }
      return e;
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
      _tileType = tileTypeNames.contains(e.tileType) ? e.tileType : tileTypeNames.first;
      _stockType = _stockTypes.contains(e.stockType) ? e.stockType : 'Uncertain';
      final surf = e.surfaceType.trim();
      _surface = (surf.isEmpty || surf.toLowerCase() == 'none') ? '' : surf;
      // Their word for it, if this product already carries one. Blank is fine: the
      // dropdown then falls back to matching on the canonical.
      _surfaceWord = e.surfaceLabel.trim();
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
  }


  @override
  void dispose() {
    _master.dispose();
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
            ? '"${dup.masterName}" (${dup.size} · $_surface) already exists. There '
                'is no new brand name to add.\n\nTo stock it in a different surface, '
                'pick that surface — it is a separate product.'
            : '"${dup.masterName}" (${dup.size} · $_surface) already exists. Add your '
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
    // A tile always has a surface, and it is part of the product's identity — so it
    // cannot be skipped. 'None' no longer exists.
    if (_surface.trim().isEmpty ||
        _surface.trim().toLowerCase() == 'none') {
      setState(() => _error = 'Pick a surface — it is part of the design.');
      return;
    }
    // A new design must arrive with its box facts, because the THICKNESS derives from them and
    // thickness is part of the identity. Without them the product has no complete identity.
    if (widget.existing == null) {
      final pcs = int.tryParse(_piecesCtrl.text.trim()) ?? 0;
      final kg = double.tryParse(_weightCtrl.text.trim()) ?? 0;
      if (pcs <= 0) {
        setState(() => _error = 'Enter the pieces per box — the thickness is worked out from it.');
        return;
      }
      if (kg <= 0) {
        setState(() => _error = 'Enter the box weight — the thickness is worked out from it.');
        return;
      }
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
    try {
      // pieces/weight are NOT sent from here. They are BOX facts (product × brand) and each
      // brand may pack differently — this form has one value for the whole product, so sending
      // it would flatten every brand's packing into a single number. The Library card's BOX
      // CHIP owns them, per brand.
      //
      // Thickness IS sent: it is the DECLARED nominal and part of the product's identity. The
      // figure derived from the box is only evidence.
      // (docs/THICKNESS_AND_BODY_IDENTITY_PLAN.md)
      final id = await _data.upsertLibraryMaster(
        id: widget.existing?.id,
        size: _size,
        masterName: master,
        imageUrl: _imageUrl,
        brandId: _targetBrandId,
        aliases: aliases,
        surfaceType: _surfaceToSave,
        stockType: _stockType,
        tileType: _tileType,
        // Only used when CREATING — they seed the product's first box, and the server derives the
        // thickness from them. Ignored on edit (the per-brand box chip owns the packing).
        piecesPerBox: widget.existing == null
            ? int.tryParse(_piecesCtrl.text.trim())
            : null,
        boxWeightKg: widget.existing == null
            ? double.tryParse(_weightCtrl.text.trim())
            : null,
        colour: _colourCtrl.text.trim(),
        finishLabel: _finishCtrl.text.trim(),
      );
      // Their WORD for the surface. library_upsert_master only carries the canonical
      // (surface_type = identity); this is what puts "RAINDROP" on the card beside it,
      // and it cascades the word onto every holding of the product. Only when they
      // actually have a word of their own — for a surface they don't, the word IS the
      // admin name and there is nothing to record.
      if (_surfaceWord.isNotEmpty &&
          _surfaceWord.trim().toLowerCase() != _surfaceToSave.trim().toLowerCase()) {
        await _data.setLibrarySurface(id, _surfaceToSave, label: _surfaceWord);
      }
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
                    ? 'Already in your library at this surface — saving adds your '
                        'brand name to it'
                    : 'Your internal name for this tile',
                border: const OutlineInputBorder(),
                errorText: (_isDuplicate && currentStockistBusinessType != 'M')
                    ? 'You already have "${_master.text.trim()}" at this size '
                        'in $_surface'
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
        // Surface IS identity: the same print in Glossy and in Matt are two products.
        // REQUIRED — there is no 'None'. (product identity migration)
        //
        // Offered in the stockist's OWN words — "RAINDROP (Sugar)" — because that is
        // what is stamped on their boxes. The word is saved as surface_label; the
        // canonical beside it is what actually keys the product.
        DropdownButtonFormField<SurfaceOption>(
          initialValue: _selectedSurface,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Surface',
            isDense: true,
            border: const OutlineInputBorder(),
            errorText: _surface.trim().isEmpty ? 'Pick a surface' : null,
            helperText: 'The same print in another surface is a different product — '
                'add it separately.',
            helperMaxLines: 2,
          ),
          hint: const Text('Pick a surface'),
          items: _surfaceOptions
              .map((s) => DropdownMenuItem(
                  value: s, child: Text(_surfaceOptionText(s))))
              .toList(),
          onChanged: (v) => setState(() {
            if (v == null) return;
            _surface = v.canonical;
            _surfaceWord = v.label;
            _dirty = true;
          }),
        ),
        const SizedBox(height: 12),
        _dropdown('Tile type', tileTypeNames, _tileType,
            (v) => setState(() {
                  _tileType = v ?? _tileType;
                  _dirty = true;
                })),
        const SizedBox(height: 12),
        // 🔑 NEW design only: the two facts printed on the box. The THICKNESS is worked out from
        // them (weight / (pieces × area × density)) and is never asked for — a stockist reads
        // pieces and weight off the box, they do not know "8.5–9.0 mm".
        //
        // Hidden when editing: by then the print may be boxed by several brands that pack it
        // differently, and this form has one value for all of them. The card's per-brand BOX CHIP
        // owns them from that point on.
        if (widget.existing == null) ...[
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _piecesCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Pieces / box',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() => _dirty = true),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _weightCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Box weight (kg)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() => _dirty = true),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // The thickness, falling out of what they just typed — the same formula the server
          // uses, so what they see here is what gets stored.
          Builder(builder: (_) {
            final band = thicknessRangeLabel(
                _size,
                int.tryParse(_piecesCtrl.text.trim()) ?? 0,
                double.tryParse(_weightCtrl.text.trim()) ?? 0,
                _tileType);
            return Text(
              band == null
                  ? 'Thickness is worked out from the pieces and box weight.'
                  : 'Thickness: $band',
              style: TextStyle(
                fontSize: 12,
                fontWeight: band == null ? FontWeight.normal : FontWeight.w600,
                color: band == null
                    ? Colors.grey.shade600
                    : Colors.teal.shade700,
              ),
            );
          }),
          const SizedBox(height: 12),
        ],
        _dropdown('Restock type', _stockTypes, _stockType,
            (v) => setState(() {
                  _stockType = v ?? _stockType;
                  _dirty = true;
                })),
        const SizedBox(height: 12),
        // Pieces / box + box weight are NOT here any more. They are BOX facts (product ×
        // brand) — the same print may ship 4/box under one brand and 6/box under another —
        // and this form has only one value for the whole product, so it could not express
        // that. They live on the Library card's BOX CHIP, per brand. Thickness is derived
        // from them and never typed. (docs/BOX_AND_DERIVED_THICKNESS_PLAN.md)
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Row(children: [
            Icon(Icons.inventory_2_outlined,
                size: 15, color: Colors.grey.shade600),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  'Pieces / box, box weight and thickness are set per BRAND — tap the box '
                  'chip on this design in your Library.',
                  style:
                      TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
            ),
          ]),
        ),
        const SizedBox(height: 12),
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
