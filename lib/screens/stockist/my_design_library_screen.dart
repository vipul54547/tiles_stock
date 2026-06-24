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
        onPressed: () => _openEditor(),
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
                        child: Text(e.masterName,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 14)),
                      ),
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
                  ),
                  Text(e.size.replaceAll(' mm', ''),
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600)),
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
                    tooltip: 'Merge a duplicate into this',
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

/// Full-page editor for one master design: image, size, master name, and the
/// design name under each brand. The only place these are editable.
class _LibraryEditorScreen extends StatefulWidget {
  final List<Brand> brands;
  final List<String> sizes;
  final List<LibraryEntry> all; // for live duplicate detection
  final LibraryEntry? existing;
  const _LibraryEditorScreen(
      {required this.brands,
      required this.sizes,
      required this.all,
      this.existing});
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

  // A duplicate = the SAME tile already in the library (live warning; the server
  // also blocks it). M: brand-AGNOSTIC — one tile is one box across all brands,
  // keyed by name+size+SURFACE. T/W: brand silo (name+size within the brand).
  bool get _isDuplicate {
    final name = _master.text.trim().toLowerCase();
    if (name.isEmpty || _size.isEmpty) return false;
    final isM = currentStockistBusinessType == 'M';
    final surf = _surface.trim().isEmpty ? 'none' : _surface.trim().toLowerCase();
    return widget.all.any((e) =>
        e.id != widget.existing?.id &&
        e.masterName.trim().toLowerCase() == name &&
        e.size == _size &&
        (isM
            ? (e.surfaceType.trim().isEmpty
                    ? 'none'
                    : e.surfaceType.trim().toLowerCase()) ==
                surf
            : e.brandId == _targetBrandId));
  }

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
    } else if (widget.sizes.isNotEmpty) {
      _size = widget.sizes.first;
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
    if (_isDuplicate) {
      setState(() => _error =
          'This tile "$master" ($_size) is already in your library — open it '
          'from the list to add another brand\'s name.');
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
                labelText: 'Master design name',
                helperText: 'Your internal name for this tile',
                border: const OutlineInputBorder(),
                errorText: _isDuplicate
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
