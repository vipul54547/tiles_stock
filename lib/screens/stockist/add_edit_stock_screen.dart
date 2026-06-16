import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../services/supabase_data_service.dart';
import '../../services/stock_service.dart';
import '../../services/cloudinary_service.dart';
import '../../models/choice_state.dart';
import '../../models/tile_design.dart';
import '../../models/stock_catalog.dart';
import '../../models/library_entry.dart';
import '../../utils/tile_sizes.dart';
import '../../utils/tile_types.dart';
import '../../utils/finishes.dart';
import '../../widgets/save_bar.dart';
import '../../widgets/unsaved_changes.dart';

// Add/Edit a stock design. Per [[project_stockist_library]] decision #7 this
// screen is QUANTITY-ONLY: a design's identity (name, size, photo) lives in the
// stockist's Design Library and is edited ONLY there. A new design is created by
// picking a Library master (its name/size/photo are copied in); everything else
// here is stock attributes (boxes, quality, finish, list…).
class AddEditStockScreen extends StatefulWidget {
  final String? designId;
  const AddEditStockScreen({super.key, this.designId});
  @override
  State<AddEditStockScreen> createState() => _State();
}

class _State extends State<AddEditStockScreen> {
  final _formKey = GlobalKey<FormState>();
  final _service = SupabaseDataService();
  final _stockSvc = StockService();
  bool get isEdit => widget.designId != null;

  final _qtyCtrl       = TextEditingController();
  final _piecesCtrl    = TextEditingController();
  final _weightCtrl    = TextEditingController();
  final _thicknessCtrl = TextEditingController();
  final _colourCtrl    = TextEditingController();
  // Stockist's own wording for the chosen finish — learned as a surface_alias so
  // future PDF uploads carrying this wording auto-align to the admin finish.
  final _finishAliasCtrl = TextEditingController();

  // Identity (name / size / photo) — sourced from the Library, NOT edited here.
  String _designName = '';
  String _size       = kAllowedSizes.first;
  String _imageUrl   = '';

  String _surface   = 'Matt';
  String _tileType  = kTileTypes.first;
  String _quality   = 'Premium';
  String _stockType = 'Regular';

  List<String> _surfaces = kFinishes;   // replaced by admin master list on load
  List<String> _sizes    = kAllowedSizes; // replaced by admin master list on load
  List<StockCatalog> _catalogs = []; // the stockist's catalogs
  String? _catalogId; // which catalog this design belongs to
  String? _defaultBrandId; // fallback brand for legacy catalogs with no brand
  List<LibraryEntry> _masters = []; // this stockist's library, for the add picker
  LibraryEntry? _selectedMaster;    // add mode: the chosen master
  final _qualities  = ['Premium', 'Standard'];
  final _stockTypes = ['Both', 'Regular', 'One Time'];

  bool _pageLoading = false;
  bool _saving      = false;
  bool _dirty       = false; // unsaved edits → pinned Save bar + exit guard

  // The brand this design belongs to (its list's brand, else default). Used to
  // resolve a master's per-brand design name.
  String? get _designBrandId {
    for (final c in _catalogs) {
      if (c.id == _catalogId) return c.brandId ?? _defaultBrandId;
    }
    return _defaultBrandId;
  }

  // A master's design name under the current list's brand (alias), else its
  // master name.
  String _nameForBrand(LibraryEntry m) {
    final b = _designBrandId;
    final alias = b == null ? null : m.aliases[b];
    return (alias != null && alias.trim().isNotEmpty) ? alias.trim() : m.masterName;
  }

  // Marks the form dirty on user edits. Ignored during the initial load/_fill
  // so prefilling an existing design doesn't count as a change.
  void _markDirty() {
    if (!_pageLoading && !_dirty) setState(() => _dirty = true);
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _loadSurfaces();
    await _loadSizes();
    await _loadCatalogs();
    if (!isEdit) await _loadMasters();
    if (isEdit) await _loadExisting();
  }

  // The stockist's stock lists; default a NEW design to the first list.
  Future<void> _loadCatalogs() async {
    if (currentStockistUUID.isEmpty) return;
    final cats = await _service.getCatalogs(currentStockistUUID);
    final brands = await _service.getMyBrands();
    if (!mounted) return;
    final def = brands.where((b) => b.isDefault).toList();
    setState(() {
      _defaultBrandId = def.isEmpty ? null : def.first.id;
      _catalogs = cats.where((c) => c.isActive).toList();
      if (!isEdit) {
        _catalogId ??= _catalogs.isEmpty ? null : _catalogs.first.id;
      }
    });
  }

  // The Library masters available to pick from when adding a new design.
  Future<void> _loadMasters() async {
    final masters = await _service.getMyLibrary();
    if (!mounted) return;
    setState(() => _masters = masters);
  }

  // Use the admin's live size list so the picker matches the master.
  Future<void> _loadSizes() async {
    try {
      final names = await _service.getActiveSizeNames();
      if (names.isNotEmpty && mounted) {
        setState(() {
          _sizes = names;
          if (!_sizes.contains(_size)) _size = _sizes.first;
        });
      }
    } catch (_) {
      // keep kAllowedSizes fallback
    }
  }

  // Use the admin's live finish list so the dropdown matches what stockists
  // align their PDFs to. Falls back to kFinishes if the fetch fails.
  Future<void> _loadSurfaces() async {
    try {
      final types = await _service.getSurfaceTypes(activeOnly: true);
      final names = types.map((t) => t.name).toList();
      if (names.isNotEmpty && mounted) {
        setState(() {
          _surfaces = names;
          if (!_surfaces.contains(_surface)) _surface = _surfaces.first;
        });
      }
    } catch (_) {
      // keep kFinishes fallback
    }
  }

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _piecesCtrl.dispose();
    _weightCtrl.dispose();    _thicknessCtrl.dispose();
    _colourCtrl.dispose();    _finishAliasCtrl.dispose();
    super.dispose();
  }

  // ── Load existing design ──────────────────────────────────────────────────

  Future<void> _loadExisting() async {
    setState(() => _pageLoading = true);
    final design = await _service.getDesignById(widget.designId!);
    if (!mounted) return;
    if (design == null) {
      setState(() => _pageLoading = false);
      return;
    }
    _fill(design);
    setState(() => _pageLoading = false);
  }

  void _fill(TileDesign d) {
    _designName         = d.name;
    _qtyCtrl.text       = d.boxQuantity.toString();
    _piecesCtrl.text    = d.piecesPerBox.toString();
    _weightCtrl.text    = d.boxWeightKg.toString();
    _thicknessCtrl.text = d.thicknessMm.toString();
    _colourCtrl.text    = d.colour;
    _surface            = _surfaces.contains(d.surfaceType) ? d.surfaceType : _surfaces.first;
    _tileType           = kTileTypes.contains(d.tileType)   ? d.tileType   : kTileTypes.first;
    _quality            = _qualities.contains(d.quality)    ? d.quality    : _qualities.first;
    _stockType          = _stockTypes.contains(d.stockType) ? d.stockType  : _stockTypes.first;
    _imageUrl           = d.faceImageUrls.isEmpty ? '' : d.faceImageUrls.first;
    // Preselect this design's catalog (only if it's still an active catalog).
    if (d.catalogId != null && _catalogs.any((c) => c.id == d.catalogId)) {
      _catalogId = d.catalogId;
    }

    // Match stored size to allowed list (handles old wrong formats too)
    final key = d.size
        .replaceAll(RegExp(r'[^0-9x]', caseSensitive: false), '')
        .toLowerCase();
    _size = _sizes.firstWhere(
      (s) => s.replaceAll(RegExp(r'[^0-9x]', caseSensitive: false), '').toLowerCase() == key,
      orElse: () => _sizes.isEmpty ? d.size : _sizes.first,
    );
  }

  // ── Library master picker (add mode) ───────────────────────────────────────

  void _selectMaster(LibraryEntry m) {
    setState(() {
      _selectedMaster = m;
      _size = m.size;
      _imageUrl = m.imageUrl;
      _designName = _nameForBrand(m);
      _dirty = true;
    });
  }

  Future<void> _openMasterPicker() async {
    final picked = await showModalBottomSheet<LibraryEntry>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _MasterPickerSheet(
        masters: _masters,
        brandId: _designBrandId,
        nameForBrand: _nameForBrand,
      ),
    );
    if (!mounted) return;
    if (picked == null) return;
    if (identical(picked, _addToLibrarySentinel)) {
      // Send them to the Library to add a master, then reload the picker list.
      await context.push('/stockist/library');
      await _loadMasters();
      return;
    }
    _selectMaster(picked);
  }

  // ── Save (add or update) ──────────────────────────────────────────────────

  Future<void> _save() async {
    if (currentStockistUUID.isEmpty) {
      _snack('Session error — please login again.', Colors.red);
      return;
    }
    if (!isEdit && _selectedMaster == null) {
      _snack('Pick a design from your Library first.', Colors.red);
      return;
    }
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);

    bool ok;
    if (isEdit) {
      // Identity (name / size / photo) is intentionally omitted — it's edited
      // only in the Library. box_quantity is omitted too (changed via Recount /
      // dispatch / add-stock). Only stock attributes are saved here.
      ok = await _service.updateDesign(widget.designId!, {
        'surface_type':  _surface,
        'tile_type':     _tileType,
        'quality':       _quality,
        'colour':        _colourCtrl.text.trim(),
        'stock_type':    _stockType,
        'pieces_per_box': int.tryParse(_piecesCtrl.text)   ?? 0,
        'box_weight_kg': double.tryParse(_weightCtrl.text)    ?? 0,
        'thickness_mm':  approxThicknessMm(_size,
                int.tryParse(_piecesCtrl.text) ?? 0,
                double.tryParse(_weightCtrl.text) ?? 0, _tileType) ?? 0,
        if (_catalogId != null) 'catalog_id': _catalogId,
      });
    } else {
      final master = _selectedMaster!;
      final name = _nameForBrand(master); // brand may have changed since pick
      final id = await _service.addDesign(
        stockistUUID:  currentStockistUUID,
        name:          name,
        size:          master.size,
        surfaceType:   _surface,
        tileType:      _tileType,
        quality:       _quality,
        colour:        _colourCtrl.text.trim(),
        stockType:     _stockType,
        boxQuantity:   int.tryParse(_qtyCtrl.text)       ?? 0,
        piecesPerBox:  int.tryParse(_piecesCtrl.text)    ?? 0,
        boxWeightKg:   double.tryParse(_weightCtrl.text)    ?? 0,
        thicknessMm:   approxThicknessMm(_size,
                int.tryParse(_piecesCtrl.text) ?? 0,
                double.tryParse(_weightCtrl.text) ?? 0, _tileType) ?? 0,
        faceImageUrls: master.imageUrl.isNotEmpty ? [master.imageUrl] : const [],
        catalogId:     _catalogId,
      );
      ok = id != null;
    }

    // Learn the stockist's own finish wording -> chosen admin finish, so future
    // PDF uploads carrying this wording auto-align (mirrors the upload screen).
    final aliasRaw = _finishAliasCtrl.text.trim();
    if (ok && aliasRaw.isNotEmpty && _surface != 'None') {
      await _service.upsertSurfaceAlias(currentStockistUUID, aliasRaw, _surface);
    }

    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _dirty = false; // saved → let the pop through the exit guard
    });

    _snack(ok ? 'Design saved.' : 'Failed to save. Please try again.',
        ok ? Colors.green : Colors.red);
    if (ok) context.pop();
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Design?'),
        content: Text(
            'Delete "$_designName"?\n\n'
            'This removes the design and its stock history. Its entry in your '
            'Design Library is kept.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete',
                  style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);
    final ok = await _service.deleteDesign(widget.designId!);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _dirty = false; // deleted → allow the pop through the exit guard
    });

    _snack(ok ? 'Design deleted.' : 'Delete failed.', ok ? Colors.green : Colors.red);
    if (ok) context.pop();
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: _pageLoading
          ? null
          : SaveBar(
              label: isEdit ? 'Update Design' : 'Add Design',
              onPressed: _save,
              saving: _saving,
              dirty: _dirty,
            ),
      appBar: AppBar(
        // maybePop (not pop) so the unsaved-changes guard can intercept.
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text(isEdit ? 'Edit Stock' : 'Add New Design'),
        actions: [
          if (isEdit)
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: 'Stock history',
              onPressed: _saving
                  ? null
                  : () => context.push(
                        '/stockist/stock/history/${widget.designId}/'
                        '${Uri.encodeComponent(_designName)}',
                      ),
            ),
          if (isEdit)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              tooltip: 'Delete design',
              onPressed: _saving ? null : _confirmDelete,
            ),
        ],
      ),
      body: _pageLoading
          ? const Center(child: CircularProgressIndicator())
          : UnsavedChangesGuard(
              isDirty: _dirty,
              child: Form(
              key: _formKey,
              onChanged: _markDirty,
              child: ListView(
                // Bottom inset clears the system nav bar so the "Add Design"
                // button is never hidden under it.
                padding: EdgeInsets.fromLTRB(
                    16, 16, 16, 16 + MediaQuery.of(context).viewPadding.bottom),
                children: [
                  isEdit ? _buildIdentityReadonly() : _buildMasterPicker(),
                  const SizedBox(height: 12),
                  if (_catalogs.length > 1) _buildCatalogPicker(),
                  _buildSurfaceSection(),
                  const SizedBox(height: 12),
                  _buildDropdown('Tile Type', kTileTypes, _tileType,
                      (v) => setState(() { _tileType = v!; _dirty = true; })),
                  const SizedBox(height: 12),
                  _buildQualityPicker(),
                  const SizedBox(height: 12),
                  _buildStockTypePicker(),
                  const SizedBox(height: 12),
                  _field(_colourCtrl, 'Colour (optional)'),
                  Row(children: [
                    Expanded(child: _field(_piecesCtrl, 'Pieces/Box',
                        numeric: true, required: true)),
                    const SizedBox(width: 12),
                    Expanded(child: _buildQtyField()),
                  ]),
                  Row(children: [
                    Expanded(child: _field(_weightCtrl, 'Box Weight (kg)',
                        numeric: true, required: true)),
                    const SizedBox(width: 12),
                    Expanded(child: _buildThicknessField()),
                  ]),
                ],
              ),
            ),
          ),
    );
  }

  // ── Identity: read-only (edit mode) ────────────────────────────────────────
  // Name / size / photo live in the Library; show them, link out to edit there.
  Widget _buildIdentityReadonly() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _identityThumb(),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_designName.isEmpty ? '(unnamed)' : _designName,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(_size.replaceAll(' mm', ''),
                        style: TextStyle(
                            fontSize: 12.5, color: Colors.grey.shade600)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.lock_outline, size: 13, color: Colors.grey.shade500),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                    'Name, size & photo are set in your Design Library.',
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey.shade600)),
              ),
              TextButton(
                onPressed: () => context.push('/stockist/library'),
                child: const Text('Edit in Library'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Master picker (add mode) ───────────────────────────────────────────────
  Widget _buildMasterPicker() {
    if (_selectedMaster == null) {
      return InkWell(
        onTap: _openMasterPicker,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF1B4F72), width: 1.5),
          ),
          child: const Row(
            children: [
              Icon(Icons.collections_bookmark_outlined,
                  color: Color(0xFF1B4F72)),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Choose design from your Library',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1B4F72))),
                    SizedBox(height: 2),
                    Text('Its name, size and photo come from the Library',
                        style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Color(0xFF1B4F72)),
            ],
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1B4F72).withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1B4F72).withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          _identityThumb(),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_designName.isEmpty ? '(unnamed)' : _designName,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(height: 2),
                Text(_size.replaceAll(' mm', ''),
                    style:
                        TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
              ],
            ),
          ),
          TextButton(onPressed: _openMasterPicker, child: const Text('Change')),
        ],
      ),
    );
  }

  Widget _identityThumb() => ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 56,
          height: 56,
          child: _imageUrl.isEmpty
              ? Container(
                  color: Colors.grey.shade100,
                  child: Icon(Icons.image_outlined, color: Colors.grey.shade400))
              : CachedNetworkImage(
                  imageUrl: CloudinaryService.thumbUrl(_imageUrl, width: 160),
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(color: Colors.grey.shade200),
                  errorWidget: (_, __, ___) =>
                      Container(color: Colors.grey.shade200)),
        ),
      );

  // ── Catalog picker (Father & Child) ───────────────────────────────────────

  Widget _buildCatalogPicker() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Stock Catalogue',
              style: TextStyle(fontSize: 13, color: Colors.grey)),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade400),
              borderRadius: BorderRadius.circular(8),
            ),
            child: DropdownButton<String>(
              value: _catalogId,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              items: _catalogs
                  .map((c) => DropdownMenuItem(
                      value: c.id, child: Text(c.name)))
                  .toList(),
              onChanged: (v) => setState(() {
                _catalogId = v ?? _catalogId;
                // The list's brand may change the design's name (alias).
                if (_selectedMaster != null) {
                  _designName = _nameForBrand(_selectedMaster!);
                }
                _dirty = true;
              }),
            ),
          ),
        ],
      ),
    );
  }

  // ── Quality picker ────────────────────────────────────────────────────────

  Widget _buildQualityPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Quality',
            style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 6),
        Row(
          children: _qualities.map((q) {
            final sel = _quality == q;
            final Color bg, fg;
            final IconData icon;
            if (q == 'Premium') {
              bg = const Color(0xFFFFF8E1);
              fg = const Color(0xFFF9A825);
              icon = Icons.star_rounded;
            } else {
              bg = const Color(0xFFE3F2FD);
              fg = const Color(0xFF1565C0);
              icon = Icons.verified_outlined;
            }
            return Expanded(
              child: GestureDetector(
                onTap: () => setState(() { _quality = q; _dirty = true; }),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    color: sel ? fg : bg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: fg, width: sel ? 2 : 1),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, size: 16, color: sel ? Colors.white : fg),
                      const SizedBox(width: 6),
                      Text(q,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: sel ? Colors.white : fg)),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  // ── Stock type picker ─────────────────────────────────────────────────────

  Widget _buildStockTypePicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Stock Type',
            style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 6),
        Row(
          children: _stockTypes.map((type) {
            final sel = _stockType == type;
            final icon = type == 'Regular'
                ? Icons.autorenew
                : type == 'Both'
                    ? Icons.layers_outlined
                    : Icons.looks_one_outlined;
            return Expanded(
              child: GestureDetector(
                onTap: () => setState(() { _stockType = type; _dirty = true; }),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
                  decoration: BoxDecoration(
                    color: sel ? const Color(0xFF1B4F72) : Colors.grey[100],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color:
                            sel ? const Color(0xFF1B4F72) : Colors.grey.shade300),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon,
                          size: 16,
                          color: sel ? Colors.white : Colors.grey.shade600),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(type,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color:
                                    sel ? Colors.white : Colors.grey.shade700)),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  // Surface Type = the canonical admin finish stored on the design. Beneath it,
  // an OPTIONAL field lets the stockist type their own wording for this finish;
  // on save it's learned as a surface_alias so future PDF uploads with that
  // wording auto-align to the chosen finish (same mechanism as Upload Stock).
  Widget _buildSurfaceSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildDropdown('Surface Type', _surfaces, _surface,
            (v) => setState(() { _surface = v!; _dirty = true; })),
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: TextFormField(
            controller: _finishAliasCtrl,
            decoration: InputDecoration(
              labelText: 'Your name for this finish (optional)',
              helperText: 'Maps your wording to "$_surface" so future PDF '
                  'uploads using it auto-align.',
              helperMaxLines: 2,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDropdown(String label, List<String> items, String value,
      void Function(String?) onChange) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: DropdownButtonFormField<String>(
        initialValue: value,
        decoration: InputDecoration(
            labelText: label, border: const OutlineInputBorder()),
        items: items
            .map((s) => DropdownMenuItem(value: s, child: Text(s)))
            .toList(),
        onChanged: onChange,
      ),
    );
  }

  // Thickness is DERIVED (not entered): a 0.5 mm band computed from size,
  // pieces/box, box weight and tile type. Read-only, and recomputes live as the
  // weight/pieces fields (and tile-type/size, via setState) change.
  Widget _buildThicknessField() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: ListenableBuilder(
        listenable: Listenable.merge([_weightCtrl, _piecesCtrl]),
        builder: (_, __) {
          final pcs = int.tryParse(_piecesCtrl.text.trim()) ?? 0;
          final wt = double.tryParse(_weightCtrl.text.trim()) ?? 0;
          final range = thicknessRangeLabel(_size, pcs, wt, _tileType);
          return InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Thickness (approx)',
              border: OutlineInputBorder(),
            ),
            child: Text(
              range ?? 'enter weight & pieces',
              style: TextStyle(
                  color: range == null ? Colors.grey : Colors.black87),
            ),
          );
        },
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String label,
      {bool required = false, bool numeric = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: ctrl,
        keyboardType: numeric ? TextInputType.number : TextInputType.text,
        validator: required
            ? (v) => v!.trim().isEmpty ? 'Required' : null
            : null,
        decoration: InputDecoration(
            labelText: label, border: const OutlineInputBorder()),
      ),
    );
  }

  // Add mode: a normal editable Box Quantity field (the opening stock).
  // Edit mode: read-only — stock is changed through Recount so every change is
  // logged as an adjustment. Tapping opens the recount dialog.
  Widget _buildQtyField() {
    if (!isEdit) {
      return _field(_qtyCtrl, 'Box Quantity', numeric: true, required: true);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: InkWell(
        onTap: _saving ? null : _showRecountDialog,
        borderRadius: BorderRadius.circular(4),
        child: InputDecorator(
          decoration: const InputDecoration(
            labelText: 'Box Quantity',
            helperText: 'Tap to recount',
            border: OutlineInputBorder(),
            suffixIcon: Icon(Icons.fact_check_outlined),
          ),
          child: Text(_qtyCtrl.text.isEmpty ? '0' : _qtyCtrl.text,
              style: const TextStyle(fontSize: 16)),
        ),
      ),
    );
  }

  static const _recountReasons = [
    'Miscount',
    'Damaged',
    'Lost / theft',
    'Found extra',
    'Return',
    'Other',
  ];

  // Recount: the stockist enters the physically-counted boxes; we record the
  // difference as an adjustment and update the design's stock.
  Future<void> _showRecountDialog() async {
    final current = int.tryParse(_qtyCtrl.text) ?? 0;
    final countCtrl = TextEditingController(text: '$current');
    final noteCtrl = TextEditingController();
    String reason = _recountReasons.first;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final entered = int.tryParse(countCtrl.text);
          final delta = (entered ?? current) - current;
          return AlertDialog(
            title: const Text('Recount stock'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('System count: $current boxes',
                      style: const TextStyle(color: Colors.grey)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: countCtrl,
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    onChanged: (_) => setD(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Actual boxes counted',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (entered != null && delta != 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        delta > 0
                            ? 'Adds $delta box${delta == 1 ? '' : 'es'}'
                            : 'Removes ${-delta} box${-delta == 1 ? '' : 'es'}',
                        style: TextStyle(
                            color: delta > 0
                                ? Colors.green.shade700
                                : Colors.red.shade700,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: reason,
                    decoration: const InputDecoration(
                      labelText: 'Reason',
                      border: OutlineInputBorder(),
                    ),
                    items: _recountReasons
                        .map((r) =>
                            DropdownMenuItem(value: r, child: Text(r)))
                        .toList(),
                    onChanged: (v) => setD(() => reason = v ?? reason),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: noteCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Note (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () async {
                  final n = int.tryParse(countCtrl.text);
                  if (n == null || n < 0) {
                    _snack('Enter a valid count', Colors.red);
                    return;
                  }
                  if (n == current) {
                    Navigator.pop(ctx, false);
                    _snack('No change — count is the same.', Colors.grey);
                    return;
                  }
                  final ok = await _stockSvc.adjustStock(
                    designId:    widget.designId!,
                    newQuantity: n,
                    reason:      reason,
                    note:        noteCtrl.text.trim(),
                  );
                  if (!ctx.mounted) return;
                  Navigator.pop(ctx, ok);
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );

    if (saved == true && mounted) {
      final n = int.tryParse(countCtrl.text) ?? current;
      setState(() => _qtyCtrl.text = '$n');
      _snack('Stock recounted to $n boxes.', Colors.green);
    }
  }
}

// Sentinel returned by the picker sheet to mean "go add a new master".
const LibraryEntry _addToLibrarySentinel =
    LibraryEntry(id: '__add__', size: '', masterName: '');

// Bottom sheet to pick a Library master (with search) when adding stock.
class _MasterPickerSheet extends StatefulWidget {
  final List<LibraryEntry> masters;
  final String? brandId;
  final String Function(LibraryEntry) nameForBrand;
  const _MasterPickerSheet(
      {required this.masters, required this.brandId, required this.nameForBrand});
  @override
  State<_MasterPickerSheet> createState() => _MasterPickerSheetState();
}

class _MasterPickerSheetState extends State<_MasterPickerSheet> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final list = widget.masters.where((m) {
      if (q.isEmpty) return true;
      final hay = '${m.masterName} ${m.aliases.values.join(' ')} ${m.size}'
          .toLowerCase();
      return hay.contains(q);
    }).toList();
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (_, scroll) => Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: TextField(
                autofocus: false,
                onChanged: (v) => setState(() => _q = v),
                decoration: InputDecoration(
                  hintText: 'Search your library…',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.add, color: Color(0xFF1B4F72)),
              title: const Text('Add a new design to your Library',
                  style: TextStyle(
                      color: Color(0xFF1B4F72), fontWeight: FontWeight.w600)),
              onTap: () => Navigator.pop(context, _addToLibrarySentinel),
            ),
            const Divider(height: 1),
            Expanded(
              child: widget.masters.isEmpty
                  ? const Center(
                      child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                          'Your Design Library is empty.\nAdd a design there '
                          'first, then add its stock here.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey)),
                    ))
                  : ListView.separated(
                      controller: scroll,
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final m = list[i];
                        final name = widget.nameForBrand(m);
                        return ListTile(
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: SizedBox(
                              width: 44,
                              height: 44,
                              child: m.imageUrl.isEmpty
                                  ? Container(
                                      color: Colors.grey.shade100,
                                      child: Icon(Icons.image_outlined,
                                          size: 18,
                                          color: Colors.grey.shade400))
                                  : CachedNetworkImage(
                                      imageUrl: CloudinaryService.thumbUrl(
                                          m.imageUrl,
                                          width: 120),
                                      fit: BoxFit.cover,
                                      placeholder: (_, __) => Container(
                                          color: Colors.grey.shade200),
                                      errorWidget: (_, __, ___) => Container(
                                          color: Colors.grey.shade200)),
                            ),
                          ),
                          title: Text(name,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(m.size.replaceAll(' mm', ''),
                              style: const TextStyle(fontSize: 12)),
                          onTap: () => Navigator.pop(context, m),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
