import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/library_entry.dart';
import '../../models/brand.dart';
import '../../models/choice_state.dart';
import '../../utils/finishes.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../widgets/save_bar.dart';

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

  /// The GLAZE this run was printed on. Chosen here, not read off the design:
  /// the library holds the print ("Satva White"), the factory runs it on Matt or
  /// Glossy or Carving. (project_per_brand_surface_mode)
  final String surface;
  int qty;
  _Entry({
    required this.master,
    required this.brandId,
    required this.brandName,
    required this.quality,
    required this.surface,
    required this.qty,
  });

  /// Same design + brand + quality + SURFACE = the same holding. Must match
  /// stock_add_holding's lookup, or two glazes of one print merge into one row.
  String get key => '${master.id}|${brandId ?? ''}|$quality|$surface';
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
  String _selSurface = '';
  final _qtyCtrl = TextEditingController();

  /// Admin's live finish list, 'None' excluded — a tile always has a glaze.
  List<String> _surfaces = const [];

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
    super.dispose();
  }

  Future<void> _load() async {
    final masters = await _svc.getMyLibrary();
    final brands = await _svc.getMyBrands();
    final profile = await _svc.getMyProfile();
    final surfaces = await _loadSurfaceNames();
    if (!mounted) return;
    setState(() {
      _masters = masters;
      _brands = brands;
      _stockistUsesSurface =
          (profile?['surface_mode'] ?? 'in_name').toString() == 'attribute';
      _surfaces = surfaces;
      _loading = false;
    });
  }

  Future<List<String>> _loadSurfaceNames() async {
    try {
      final types = await _svc.getSurfaceTypes(activeOnly: true);
      return types
          .map((t) => t.name)
          .where((n) => n.trim().isNotEmpty && n.toLowerCase() != 'none')
          .toList();
    } catch (_) {
      return kFinishes.where((f) => f.toLowerCase() != 'none').toList();
    }
  }

  String _brandNameOf(String? id) {
    if (id == null) return '';
    final m = _brands.where((b) => b.id == id).toList();
    return m.isEmpty ? '' : m.first.name;
  }

  // ── Surface / glaze (project_per_brand_surface_mode) ──────────────────────
  // The library holds the PRINT; the glaze is chosen HERE, when the tile is
  // made. Whether we ask for it is the FACTORY's convention:
  //   M   → the stockist IS the factory; its brands are alternate names for the
  //         same print, so one setting covers them all.
  //   T/W → each carried brand IS a different factory → per-brand.

  Brand? _brandById(String? id) {
    if (id == null || id.isEmpty) return null;
    final m = _brands.where((b) => b.id == id).toList();
    return m.isEmpty ? null : m.first;
  }

  bool _usesSurface(LibraryEntry m, String? brandId) {
    if (_isM) return _stockistUsesSurface;
    final id = (brandId != null && brandId.isNotEmpty) ? brandId : m.brandId;
    return _brandById(id)?.usesSurface ?? false;
  }

  /// Whether the CURRENT selection needs a glaze picked.
  bool get _selNeedsSurface =>
      _selMaster != null && _usesSurface(_selMaster!, _isM ? _selBrandId : null);

  /// What goes on the holding. Attribute → the stockist's pick. In-name → the
  /// glaze is inside the design name, so fall back to whatever the importer put
  /// on the print (unchanged behaviour; 'None' when it never had one).
  String get _surfaceForEntry {
    if (_selNeedsSurface) return _selSurface.trim();
    final legacy = _selMaster?.surfaceType.trim() ?? '';
    return legacy.isEmpty ? 'None' : legacy;
  }

  static String _shown(String s) {
    final t = s.trim();
    return t.isEmpty || t.toLowerCase() == 'none' ? '' : t;
  }

  /// Any row in the running list carries a real glaze → show the SURFACE column.
  bool get _showSurfaceCol => _entries.any((e) => _shown(e.surface).isNotEmpty);

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
                                  // A print has no glaze — size only.
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
    if (chosen != null) {
      setState(() {
        _selMaster = chosen;
        // For M, default the brand to the master's own brand if none picked.
        if (_isM && _selBrandId == null && chosen.brandId.isNotEmpty) {
          _selBrandId = chosen.brandId;
        }
      });
    }
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
    // The glaze is what this run was printed on — it can't be guessed.
    if (_selNeedsSurface && _selSurface.trim().isEmpty) {
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
      qty: qty,
    );
    final idx = _entries.indexWhere((x) => x.key == e.key);
    if (idx >= 0) {
      _resolveDuplicate(idx, e);
      return;
    }
    setState(() {
      _entries.add(e);
      _resetRow();
    });
  }

  // Same design+brand+quality already in the list: show BOTH quantities and let
  // the stockist Remove one (discard the new) or Add both (sum into one row).
  Future<void> _resolveDuplicate(int existingIdx, _Entry incoming) async {
    final existing = _entries[existingIdx];
    final label =
        '${_displayName(existing.master, existing.brandId)} · '
        '${_shown(existing.surface).isNotEmpty ? '${_shown(existing.surface)} · ' : ''}'
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
      final payload = _entries
          .map((e) => {
                'library_id': e.master.id,
                'quality': e.quality,
                'quantity': e.qty,
                'brand_id': e.brandId,
                'surface': e.surface,
              })
          .toList();
      final res = await _svc.addInventoryBatch(payload);
      if (!mounted) return;
      final count = (res['count'] as num?)?.toInt() ?? _entries.length;
      final boxes = (res['boxes'] as num?)?.toInt() ?? _totalBoxes;
      _snack('Added $count design${count == 1 ? '' : 's'} · $boxes boxes.');
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
                                  '${_shown(e.surface).isNotEmpty ? ' · ${_shown(e.surface)}' : ''}'
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

  Widget _desktopEntryBar() {
    final sizeText =
        _selMaster == null ? '—' : _selMaster!.size.replaceAll(' mm', '');
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (_isM) ...[
              _hField('Brand',
                  _hSelect(
                      _selBrandId == null
                          ? 'Select brand'
                          : _brandNameOf(_selBrandId),
                      _pickBrand,
                      _selBrandId == null),
                  width: 150),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: _hField(
                  'Design',
                  _hSelect(
                      _selMaster == null
                          ? 'Search & select design'
                          : _displayName(_selMaster!, _isM ? _selBrandId : null),
                      _pickDesign,
                      _selMaster == null)),
            ),
            const SizedBox(width: 12),
            _hField('Size (auto)', _hReadonly(sizeText), width: 110),
            const SizedBox(width: 12),
            if (_selNeedsSurface) ...[
              _hField('Surface *', _surfaceDropdown(), width: 150),
              const SizedBox(width: 12),
            ],
            _hField('Quality', _qualityDropdown(), width: 140),
            const SizedBox(width: 12),
            _hField('Qty (boxes)', _qtyField(), width: 100),
            const SizedBox(width: 12),
            SizedBox(
              height: 44,
              child: ElevatedButton.icon(
                onPressed: _addEntry,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: _green, foregroundColor: Colors.white),
              ),
            ),
            const SizedBox(width: 8),
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

  Widget _hField(String label, Widget child, {double? width}) {
    final col = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
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

  Widget _hSelect(String value, VoidCallback onTap, bool placeholder) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade400),
            borderRadius: BorderRadius.circular(8)),
        child: Row(
          children: [
            Expanded(
              child: Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      color:
                          placeholder ? Colors.grey.shade500 : Colors.black87)),
            ),
            Icon(Icons.arrow_drop_down, color: Colors.grey.shade600),
          ],
        ),
      ),
    );
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

  // Required, never auto-filled — the glaze is a fact about the production run.
  Widget _surfaceDropdown() => Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
            border: Border.all(
                color: _selSurface.isEmpty
                    ? Colors.red.shade300
                    : Colors.grey.shade400),
            borderRadius: BorderRadius.circular(8)),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _surfaces.contains(_selSurface) ? _selSurface : null,
            hint: Text('Select',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
            isExpanded: true,
            isDense: true,
            style: const TextStyle(fontSize: 13, color: Colors.black87),
            items: _surfaces
                .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                .toList(),
            onChanged: (v) => setState(() => _selSurface = v ?? _selSurface),
          ),
        ),
      );

  Widget _qualityDropdown() => Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade400),
            borderRadius: BorderRadius.circular(8)),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _selQuality,
            isExpanded: true,
            isDense: true,
            style: const TextStyle(fontSize: 13, color: Colors.black87),
            items: const [
              DropdownMenuItem(value: 'Premium', child: Text('Premium')),
              DropdownMenuItem(value: 'Standard', child: Text('Standard')),
            ],
            onChanged: (v) => setState(() => _selQuality = v ?? _selQuality),
          ),
        ),
      );

  Widget _qtyField() => SizedBox(
        height: 44,
        child: TextField(
          controller: _qtyCtrl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
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
        surface: _shown(e.surface).isEmpty ? '—' : _shown(e.surface),
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
            // The glaze is chosen here, when the tile is made.
            if (_selNeedsSurface) ...[
              const SizedBox(height: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Surface *',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  _surfaceDropdown(),
                ],
              ),
            ],
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Quantity',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      TextField(
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
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _addEntry,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add'),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: _navy,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12)),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _addNewDesign,
                  icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                  label: const Text('New design'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: _navy,
                      padding: const EdgeInsets.symmetric(
                          vertical: 12, horizontal: 10)),
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
                      if (_shown(e.surface).isNotEmpty) _shown(e.surface),
                      if (e.brandName?.isNotEmpty == true) e.brandName!,
                      e.quality,
                    ].join(' · '),
                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
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
