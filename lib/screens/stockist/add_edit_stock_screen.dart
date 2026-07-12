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
  /// In add mode (M), the brand to stock these boxes under — defaults to the brand
  /// the dashboard was filtered to. Stock is per-brand. (project_per_brand_stock)
  final String? initialBrandId;
  const AddEditStockScreen(
      {super.key, this.designId, this.initialCatalogId, this.initialBrandId});
  @override
  State<AddEditStockScreen> createState() => _State();
}

class _State extends State<AddEditStockScreen> {
  final _formKey = GlobalKey<FormState>();
  final _service = SupabaseDataService();
  final _stockSvc = StockService();
  bool get isEdit => widget.designId != null;

  final _qtyCtrl = TextEditingController();
  final _controlCtrl = TextEditingController();

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

  // Edit mode: the lists this design may be published in + which are ticked.
  // (membership — stocklist-output)
  List<Map<String, dynamic>> _lists = [];
  final Set<String> _memberIds = {};

  List<StockCatalog> _catalogs = [];
  String? _catalogId;
  String? _defaultBrandId;
  // M only: the brand these boxes are stocked under (stock is per-brand). Drives
  // the alias name shown + the holding's brand. (project_per_brand_stock)
  String? _selectedBrandId;
  bool get _isM => currentStockistBusinessType == 'M';
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

  // The brand this design belongs to. M: the explicitly-picked brand (stock is
  // per-brand). Else the list's brand, else the default brand.
  String? get _designBrandId {
    if (_selectedBrandId != null) return _selectedBrandId;
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
      // M: stock is per-brand → default the brand picker to the dashboard's brand,
      // else the default brand. (Non-M: brand comes from the master.)
      if (_isM && !isEdit) {
        _selectedBrandId ??= widget.initialBrandId ??
            (brands.any((b) => b.id == widget.initialBrandId)
                ? widget.initialBrandId
                : _defaultBrandId);
      }
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
    _controlCtrl.dispose();
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
    final lists = await _service.getDesignLists(widget.designId!);
    if (!mounted) return;
    setState(() {
      _lists = lists;
      _memberIds
        ..clear()
        ..addAll(lists
            .where((l) => l['member'] == true)
            .map((l) => l['catalog_id'].toString()));
      _pageLoading = false;
    });
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
    _qtyCtrl.text     = d.boxQuantity.toString();
    _controlCtrl.text = d.controlQuantity.toString();
    _quality          = _qualities.contains(d.quality) ? d.quality : _qualities.first;
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
    if (!isEdit && _catalogId == null) {
      _snack('Create a stock list first — go to Manage Lists.', Colors.red);
      return;
    }
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);

    try {
      if (isEdit) {
        // Quality + which lists this design is published in (membership). Quantity
        // is changed via Recount; identity is edited in the Library.
        await _service.updateDesign(widget.designId!, {'quality': _quality});
        await _service.setDesignLists(widget.designId!, _memberIds.toList());
        final cQty = int.tryParse(_controlCtrl.text.trim()) ?? 0;
        await _service.setControlQuantities(
            [(id: widget.designId!, controlQuantity: cQty)]);
      } else {
        final master = _selectedMaster!;
        await _service.addDesign(
          libraryId:    master.id,
          quality:      _quality,
          boxQuantity:  int.tryParse(_qtyCtrl.text) ?? 0,
          catalogId:    _catalogId, // publishes the design into this list (membership)
          brandId:      _isM ? _designBrandId : null, // M: stock is per-brand
          surface:      master.surfaceType,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Could not save: $e', Colors.red);
      return;
    }

    if (!mounted) return;
    setState(() {
      _saving = false;
      _dirty  = false;
    });

    _snack('Design saved.', Colors.green);
    context.pop();
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
    try {
      await _service.deleteDesign(widget.designId!);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Delete failed: $e', Colors.red);
      return;
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _dirty  = false;
    });

    _snack('Design deleted.', Colors.green);
    context.pop();
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
                      // M: pick the brand these boxes are (stock is per-brand).
                      if (!isEdit && _isM && _brands.length > 1)
                        _buildBrandPicker(),
                      // List picker only when adding — it chooses which list the
                      // new design is published into. Membership of an existing
                      // design is managed on the list, not here.
                      if (!isEdit && _catalogs.isNotEmpty) _buildCatalogPicker(),
                      _buildQualityPicker(),
                      const SizedBox(height: 16),
                      _buildQtyField(),
                      if (isEdit) ...[
                        const SizedBox(height: 16),
                        _buildControlQtyField(),
                        const SizedBox(height: 20),
                        _buildListsSection(),
                      ],
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
      // Entry point = type the design's name. Matching library designs surface
      // live (so an existing tile is reused, not duplicated); "create new" only
      // shows when nothing matches.
      return _InlineMasterSearch(
        masters: _masters,
        nameForBrand: _nameForBrand,
        onPick: _selectMaster,
        onCreateNew: () async {
          await context.push('/stockist/library');
          if (!mounted) return;
          await _loadMasters();
        },
      );
    }
    return Column(
      children: [
        _buildIdentityCard(),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
              onPressed: () => setState(() => _selectedMaster = null),
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

  // ── Brand picker (M add mode) ──────────────────────────────────────────────
  // Stock is per-brand for M: the same tile under ANUJ vs KHAKHI is separate
  // boxes. Picking the brand here sets the holding's brand + the alias name shown.
  Widget _buildBrandPicker() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Brand (which boxes are these?)',
              style: TextStyle(fontSize: 13, color: Colors.grey)),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade400),
              borderRadius: BorderRadius.circular(8),
            ),
            child: DropdownButton<String>(
              value: _selectedBrandId,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              items: _brands
                  .map((b) => DropdownMenuItem(
                      value: b.id, child: Text(b.name)))
                  .toList(),
              onChanged: (v) => setState(() {
                _selectedBrandId = v ?? _selectedBrandId;
                // The brand changes the design's name (alias).
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

  // ── Published-in lists (membership; edit mode) ─────────────────────────────
  Widget _buildListsSection() {
    final multiBrand =
        _lists.map((l) => l['brand_id']).toSet().length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Show in lists',
            style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 2),
        Text(
            _lists.isEmpty
                ? 'No lists available for this design’s brand yet.'
                : 'Pick which of your stock lists show this design to buyers.',
            style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
        const SizedBox(height: 6),
        if (_lists.isNotEmpty)
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                for (var i = 0; i < _lists.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  // A CONDITION-BASED ("auto") list fills itself from its own
                  // conditions — it has no hand-picked membership. Ticking it
                  // used to write a row the list never reads: a silent no-op.
                  // Show whether the design currently MATCHES, and lock it.
                  // (project_permanent_temporary_lists)
                  Builder(builder: (_) {
                    final auto = _lists[i]['auto'] == true;
                    final id = _lists[i]['catalog_id'].toString();
                    final brand =
                        (_lists[i]['brand_name']?.toString() ?? '').trim();
                    final sub = <String>[
                      if (multiBrand && brand.isNotEmpty) brand,
                      if (auto)
                        _memberIds.contains(id)
                            ? 'Auto list — matches its conditions'
                            : 'Auto list — does not match its conditions',
                    ].join(' · ');
                    return CheckboxListTile(
                      dense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 12),
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _memberIds.contains(id),
                      title: Text(_lists[i]['name']?.toString() ?? '',
                          style: TextStyle(
                              fontSize: 14,
                              color: auto ? Colors.grey.shade600 : null)),
                      subtitle: sub.isEmpty
                          ? null
                          : Text(sub, style: const TextStyle(fontSize: 11)),
                      secondary: auto
                          ? Icon(Icons.bolt,
                              size: 16, color: Colors.orange.shade700)
                          : null,
                      // null = locked. Membership here is the conditions.
                      onChanged: auto
                          ? null
                          : (v) {
                              setState(() {
                                if (v == true) {
                                  _memberIds.add(id);
                                } else {
                                  _memberIds.remove(id);
                                }
                                _dirty = true;
                              });
                            },
                    );
                  }),
                ],
              ],
            ),
          ),
        if (_lists.isNotEmpty && _memberIds.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Icon(Icons.visibility_off_outlined,
                    size: 14, color: Colors.orange.shade700),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                      'Not in any list — buyers won’t see this design until you '
                      'tick a list.',
                      style: TextStyle(
                          fontSize: 11.5, color: Colors.orange.shade800)),
                ),
              ],
            ),
          ),
      ],
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

  Widget _buildControlQtyField() {
    final pQty = int.tryParse(_qtyCtrl.text) ?? 0;
    final cQty = int.tryParse(_controlCtrl.text) ?? 0;
    final fQty = (pQty - cQty).clamp(0, pQty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          controller: _controlCtrl,
          keyboardType: TextInputType.number,
          onChanged: (_) => setState(() => _dirty = true),
          decoration: InputDecoration(
            labelText: 'Hide from dealers (boxes)',
            helperText: 'Dealers will see $fQty box${fQty == 1 ? '' : 'es'} (F = P − this)',
            border: const OutlineInputBorder(),
            suffixIcon: const Icon(Icons.visibility_off_outlined),
          ),
        ),
      ],
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

// Inline "search-or-create" entry used when ADDING stock (no master picked
// yet): type the design name -> matching library designs surface live (so an
// existing tile is reused, not duplicated); "create new" only shows when
// nothing matches. Replaces the old modal "Choose design from your Library".
class _InlineMasterSearch extends StatefulWidget {
  final List<LibraryEntry> masters;
  final String Function(LibraryEntry) nameForBrand;
  final void Function(LibraryEntry) onPick;
  final Future<void> Function() onCreateNew;
  const _InlineMasterSearch({
    required this.masters,
    required this.nameForBrand,
    required this.onPick,
    required this.onCreateNew,
  });
  @override
  State<_InlineMasterSearch> createState() => _InlineMasterSearchState();
}

class _InlineMasterSearchState extends State<_InlineMasterSearch> {
  static const _navy = Color(0xFF1B4F72);
  final _ctrl = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final typed = _ctrl.text.trim();
    final q = _q.trim().toLowerCase();
    final results = q.isEmpty
        ? const <LibraryEntry>[]
        : widget.masters.where((m) {
            final hay =
                '${m.masterName} ${m.aliases.values.join(' ')} ${m.size}'
                    .toLowerCase();
            return hay.contains(q);
          }).toList();
    final exact = q.isNotEmpty &&
        widget.masters.any((m) =>
            m.masterName.trim().toLowerCase() == q ||
            m.aliases.values.any((v) => v.trim().toLowerCase() == q));
    final shown = results.take(8).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("What's this design called?",
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 2),
        Text(
            "Type the name on the box. Any brand's name works - if it's already "
            "in your Library, we'll find it.",
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        const SizedBox(height: 10),
        TextField(
          controller: _ctrl,
          onChanged: (v) => setState(() => _q = v),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 20),
            hintText: 'Design name',
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        const SizedBox(height: 12),
        if (q.isEmpty)
          _createTile('Add a brand-new design')
        else ...[
          if (shown.isNotEmpty) ...[
            Text('Already in your Library',
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade600)),
            const SizedBox(height: 2),
            ...shown.map(_resultTile),
            if (results.length > shown.length)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                    '+${results.length - shown.length} more - keep typing to '
                    'narrow',
                    style:
                        TextStyle(fontSize: 11.5, color: Colors.grey.shade500)),
              ),
            const SizedBox(height: 10),
          ] else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('No match in your Library.',
                  style:
                      TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
            ),
          if (!exact)
            _createTile(typed.isEmpty
                ? 'Add a brand-new design'
                : 'Create new design "$typed"'),
        ],
      ],
    );
  }

  Widget _resultTile(LibraryEntry m) => InkWell(
        onTap: () => widget.onPick(m),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: m.imageUrl.isEmpty
                      ? Container(
                          color: Colors.grey.shade100,
                          child: Icon(Icons.image_outlined,
                              size: 18, color: Colors.grey.shade400))
                      : CachedNetworkImage(
                          imageUrl: CloudinaryService.thumbUrl(m.imageUrl,
                              width: 120),
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
                    Text(widget.nameForBrand(m),
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14)),
                    Text(m.size.replaceAll(' mm', ''),
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade600)),
                  ],
                ),
              ),
              const Icon(Icons.add_circle_outline, color: _navy),
            ],
          ),
        ),
      );

  Widget _createTile(String label) => InkWell(
        onTap: () => widget.onCreateNew(),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _navy, width: 1.4),
          ),
          child: Row(
            children: [
              const Icon(Icons.add, color: _navy),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, color: _navy)),
              ),
              const Icon(Icons.chevron_right, color: _navy),
            ],
          ),
        ),
      );
}
