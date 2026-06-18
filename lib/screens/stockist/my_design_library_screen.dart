import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/brand.dart';
import '../../models/library_entry.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
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
                  Text(e.masterName,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 14)),
                  Text(e.size.replaceAll(' mm', ''),
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  if (e.aliases.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: e.aliases.entries.map((a) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: _navy.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('${_brandName(a.key)}: ${a.value}',
                              style: const TextStyle(
                                  fontSize: 11, color: _navy)),
                        );
                      }).toList(),
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
  // True once the user edits the master name by hand — until then it mirrors the
  // default brand's name (locked rule: first upload master name = brand-1 name).
  bool _masterTouched = false;
  String? _error;

  bool get _isEdit => widget.existing != null;
  Brand get _defaultBrand => widget.brands.first;

  // Another master already uses this name + size (live warning before saving;
  // the server also blocks it).
  bool get _isDuplicate {
    final name = _master.text.trim().toLowerCase();
    if (name.isEmpty || _size.isEmpty) return false;
    return widget.all.any((e) =>
        e.id != widget.existing?.id &&
        e.masterName.trim().toLowerCase() == name &&
        e.size == _size);
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
    } else if (widget.sizes.isNotEmpty) {
      _size = widget.sizes.first;
    }
    _master.addListener(() {
      if (_master.text != (widget.existing?.masterName ?? '')) _masterTouched = true;
      if (mounted) setState(() {}); // refresh the live duplicate hint
    });
  }

  @override
  void dispose() {
    _master.dispose();
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
      await _data.upsertLibraryMaster(
        id: widget.existing?.id,
        size: _size,
        masterName: master,
        imageUrl: _imageUrl,
        aliases: aliases,
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
