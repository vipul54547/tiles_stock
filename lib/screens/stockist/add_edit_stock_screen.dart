import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../services/supabase_data_service.dart';
import '../../services/stock_service.dart';
import '../../services/cloudinary_service.dart';
import '../../models/choice_state.dart';
import '../../models/tile_design.dart';
import '../../models/stock_catalog.dart';
import '../../models/brand.dart';
import '../../models/library_entry.dart';
import '../../widgets/save_bar.dart';
import '../../widgets/unsaved_changes.dart';
import 'edit_design_image_screen.dart';

// Add/Edit a stock design. After the identity-vs-stock split this screen is
// STOCK-ONLY: a design's identity (name, size, photo, surface, tile type,
// pieces, weight, thickness, colour, finish, base stock type) lives on its
// master in the Design Library and is edited ONLY there. The only things set
// here are the stock list, the quality and the box quantity. A new design is
// created by picking a Library master (its identity is shown read-only).
class AddEditStockScreen extends StatefulWidget {
  final String? designId;
  /// In add mode, the stock list to default to (its brand). Lets the dashboard
  /// open Add already pointed at the brand the stockist was viewing.
  final String? initialCatalogId;
  const AddEditStockScreen({super.key, this.designId, this.initialCatalogId});
  @override
  State<AddEditStockScreen> createState() => _State();
}

class _State extends State<AddEditStockScreen> {
  final _formKey = GlobalKey<FormState>();
  final _service = SupabaseDataService();
  final _stockSvc = StockService();
  bool get isEdit => widget.designId != null;

  final _qtyCtrl = TextEditingController();

  // Identity (read-only here — sourced from the Library master).
  String _designName = '';
  String _size       = '';
  String _imageUrl   = '';
  String _surface    = 'None';
  String _tileType   = '';
  String _colour     = '';
  String? _finishLabel;
  int    _pieces     = 0;
  double _weight     = 0;
  double _thickness  = 0;
  // Base restock nature on the master; displayed effective value is clamped by
  // the chosen quality.
  String _stockTypeBase = 'Uncertain';

  // Stock (editable here).
  String _quality   = 'Premium';

  List<StockCatalog> _catalogs = [];
  String? _catalogId;
  String? _defaultBrandId;
  List<Brand> _brands = [];

  String _brandNameOf(StockCatalog c) {
    final m = _brands.where((b) => b.id == c.brandId).toList();
    return m.isEmpty ? '' : m.first.name;
  }

  List<LibraryEntry> _masters = [];
  LibraryEntry? _selectedMaster;
  final _qualities = ['Premium', 'Standard'];

  bool _pageLoading = false;
  bool _saving      = false;
  bool _dirty       = false;

  // The brand this design belongs to (its list's brand, else default).
  String? get _designBrandId {
    for (final c in _catalogs) {
      if (c.id == _catalogId) return c.brandId ?? _defaultBrandId;
    }
    return _defaultBrandId;
  }

  // A master's design name under the current list's brand (alias), else its name.
  String _nameForBrand(LibraryEntry m) {
    final b = _designBrandId;
    final alias = b == null ? null : m.aliases[b];
    return (alias != null && alias.trim().isNotEmpty) ? alias.trim() : m.masterName;
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _loadCatalogs();
    if (!isEdit) await _loadMasters();
    if (isEdit) await _loadExisting();
  }

  Future<void> _loadCatalogs() async {
    if (currentStockistUUID.isEmpty) return;
    final cats = await _service.getCatalogs(currentStockistUUID);
    final brands = await _service.getMyBrands();
    if (!mounted) return;
    final def = brands.where((b) => b.isDefault).toList();
    setState(() {
      _brands = brands;
      _defaultBrandId = def.isEmpty ? null : def.first.id;
      _catalogs = cats.where((c) => c.isActive).toList();
      if (!isEdit) {
        final initial = widget.initialCatalogId;
        if (initial != null && _catalogs.any((c) => c.id == initial)) {
          _catalogId ??= initial;
        }
        _catalogId ??= _catalogs.isEmpty ? null : _catalogs.first.id;
      }
    });
  }

  Future<void> _loadMasters() async {
    final masters = await _service.getMyLibrary();
    if (!mounted) return;
    setState(() => _masters = masters);
  }

  @override
  void dispose() {
    _qtyCtrl.dispose();
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
    _fillFromDesign(design);
    setState(() => _pageLoading = false);
  }

  void _fillFromDesign(TileDesign d) {
    _designName    = d.name;
    _size          = d.size;
    _imageUrl      = d.faceImageUrls.isEmpty ? '' : d.faceImageUrls.first;
    _surface       = d.surfaceType;
    _tileType      = d.tileType;
    _colour        = d.colour;
    _finishLabel   = d.finishLabel;
    _pieces        = d.piecesPerBox;
    _weight        = d.boxWeightKg;
    _thickness     = d.thicknessMm;
    _stockTypeBase = d.stockType; // already effective at the row's quality
    _qtyCtrl.text  = d.boxQuantity.toString();
    _quality       = _qualities.contains(d.quality) ? d.quality : _qualities.first;
    if (d.catalogId != null && _catalogs.any((c) => c.id == d.catalogId)) {
      _catalogId = d.catalogId;
    }
  }

  void _fillFromMaster(LibraryEntry m) {
    _size          = m.size;
    _imageUrl      = m.imageUrl;
    _designName    = _nameForBrand(m);
    _surface       = m.surfaceType;
    _tileType      = m.tileType;
    _colour        = m.colour;
    _finishLabel   = m.finishLabel;
    _pieces        = m.piecesPerBox;
    _weight        = m.boxWeightKg;
    _thickness     = m.thicknessMm;
    _stockTypeBase = m.stockType;
  }

  // ── Library master picker (add mode) ───────────────────────────────────────

  void _selectMaster(LibraryEntry m) {
    setState(() {
      _selectedMaster = m;
      _fillFromMaster(m);
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
      await context.push('/stockist/library');
      await _loadMasters();
      return;
    }
    _selectMaster(picked);
  }

  // ── Change image (edit mode) ───────────────────────────────────────────────
  Future<void> _openImageEditor() async {
    final newUrl = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => EditDesignImageScreen(
          presentImageUrl: _imageUrl,
          designName: _designName,
          size: _size,
        ),
      ),
    );
    if (!mounted || newUrl == null || newUrl.isEmpty || newUrl == _imageUrl) {
      return;
    }
    setState(() => _saving = true);
    final master = _findMasterForDesign(await _service.getMyLibrary());
    if (!mounted) return;
    if (master == null) {
      setState(() => _saving = false);
      _snack('Could not find this design in your Library.', Colors.red);
      return;
    }
    try {
      // Only the image is changed — identity params are left null so the
      // master's other attributes are untouched.
      await _service.upsertLibraryMaster(
        id: master.id,
        size: master.size,
        masterName: master.masterName,
        imageUrl: newUrl,
        brandId: master.brandId.isNotEmpty ? master.brandId : _designBrandId,
        aliases: master.aliases,
      );
      if (!mounted) return;
      setState(() {
        _imageUrl = newUrl;
        _saving = false;
      });
      _snack('Image updated.', Colors.green);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Could not update image: $e', Colors.red);
    }
  }

  LibraryEntry? _findMasterForDesign(List<LibraryEntry> lib) {
    final b = _designBrandId;
    final wantName = _designName.trim().toLowerCase();
    final wantSize = _size.trim().toLowerCase();
    for (final e in lib) {
      if (e.size.trim().toLowerCase() != wantSize) continue;
      if (b != null && e.brandId.isNotEmpty && e.brandId != b) continue;
      if (e.masterName.trim().toLowerCase() == wantName) return e;
      final a = b == null ? null : e.aliases[b];
      if (a != null && a.trim().toLowerCase() == wantName) return e;
    }
    return null;
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
      // Only stock attributes are saved here: quality + (re-)assigned list.
      // Quantity is changed via Recount; identity is edited in the Library.
      ok = await _service.updateDesign(widget.designId!, {
        'quality': _quality,
        if (_catalogId != null) 'catalog_id': _catalogId,
      });
    } else {
      final master = _selectedMaster!;
      final name = _nameForBrand(master); // brand may have changed since pick
      final id = await _service.addDesign(
        stockistUUID: currentStockistUUID,
        name:         name,
        size:         master.size,
        quality:      _quality,
        boxQuantity:  int.tryParse(_qtyCtrl.text) ?? 0,
        libraryId:    master.id,
        catalogId:    _catalogId,
      );
      ok = id != null;
    }

    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _dirty = false;
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
      if (ok) _dirty = false;
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
      bottomNavigationBar: (_pageLoading || (!isEdit && _selectedMaster == null))
          ? null
          : SaveBar(
              label: isEdit ? 'Update Design' : 'Add Design',
              onPressed: _save,
              saving: _saving,
              dirty: _dirty,
            ),
      appBar: AppBar(
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
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                      16, 16, 16, 16 + MediaQuery.of(context).viewPadding.bottom),
                  children: [
                    isEdit ? _buildIdentityCard() : _buildMasterPicker(),
                    if (isEdit || _selectedMaster != null) ...[
                      const SizedBox(height: 16),
                      if (_catalogs.length > 1) _buildCatalogPicker(),
                      _buildQualityPicker(),
                      const SizedBox(height: 16),
                      _buildQtyField(),
                    ] else
                      Padding(
                        padding: const EdgeInsets.only(top: 24),
                        child: Row(
                          children: [
                            Icon(Icons.arrow_upward,
                                size: 16, color: Colors.grey.shade500),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                  'Pick a design from your Library above, then enter '
                                  'its quantity. New designs are added in the Library.',
                                  style: TextStyle(
                                      fontSize: 12.5, color: Colors.grey.shade600)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
    );
  }

  // ── Identity card (read-only; edit mode + after picking in add mode) ───────
  Widget _buildIdentityCard() {
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
          _buildDetailChips(),
          const SizedBox(height: 8),
          if (isEdit)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _openImageEditor,
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                label: const Text('Change image'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF1B4F72),
                  side: const BorderSide(color: Color(0xFF1B4F72)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.lock_outline, size: 13, color: Colors.grey.shade500),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                    'These details are set in your Design Library.',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
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

  // Read-only chips summarising the master's identity attributes.
  Widget _buildDetailChips() {
    final eff = effectiveStockType(_stockTypeBase, _quality);
    final chips = <String>[
      if (_surface.isNotEmpty && _surface != 'None') _surface,
      if (_tileType.isNotEmpty) _tileType,
      if (_finishLabel != null && _finishLabel!.isNotEmpty) _finishLabel!,
      if (_colour.isNotEmpty) _colour,
      if (_pieces > 0) '$_pieces pcs/box',
      if (_weight > 0) '${_weight.toStringAsFixed(_weight % 1 == 0 ? 0 : 1)} kg',
      if (_thickness > 0) '~${_thickness.toStringAsFixed(1)} mm',
      if (eff.isNotEmpty) eff,
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: chips
            .map((c) => Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Text(c,
                      style: TextStyle(
                          fontSize: 11.5, color: Colors.grey.shade700)),
                ))
            .toList(),
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
                    Text('Its name, size, photo and details come from the Library',
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
    return Column(
      children: [
        _buildIdentityCard(),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
              onPressed: _openMasterPicker,
              child: const Text('Change design')),
        ),
      ],
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
                      value: c.id,
                      child: Text(_brands.length > 1 &&
                              _brandNameOf(c).isNotEmpty
                          ? '${_brandNameOf(c)} · ${c.name}'
                          : c.name)))
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
                onTap: () => setState(() {
                  _quality = q;
                  _dirty = true;
                }),
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

  // ── Quantity ──────────────────────────────────────────────────────────────
  // Add mode: a normal editable Box Quantity field (the opening stock).
  // Edit mode: read-only — stock is changed through Recount so every change is
  // logged as an adjustment. Tapping opens the recount dialog.
  Widget _buildQtyField() {
    if (!isEdit) {
      return TextFormField(
        controller: _qtyCtrl,
        keyboardType: TextInputType.number,
        onChanged: (_) {
          if (!_dirty) setState(() => _dirty = true);
        },
        validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
        decoration: const InputDecoration(
            labelText: 'Box Quantity', border: OutlineInputBorder()),
      );
    }
    return InkWell(
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
