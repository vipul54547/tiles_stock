import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/supabase_data_service.dart';
import '../../services/stock_service.dart';
import '../../services/cloudinary_service.dart';
import '../../models/choice_state.dart';
import '../../models/tile_design.dart';
import '../../models/stock_catalog.dart';
import '../../utils/tile_sizes.dart';
import '../../utils/tile_types.dart';
import '../../utils/finishes.dart';
import '../../widgets/save_bar.dart';
import '../../widgets/unsaved_changes.dart';

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

  final _nameCtrl      = TextEditingController();
  final _qtyCtrl       = TextEditingController();
  final _priceCtrl     = TextEditingController();
  final _piecesCtrl    = TextEditingController();
  final _weightCtrl    = TextEditingController();
  final _thicknessCtrl = TextEditingController();
  final _colourCtrl    = TextEditingController();
  // Stockist's own wording for the chosen finish — learned as a surface_alias so
  // future PDF uploads carrying this wording auto-align to the admin finish.
  final _finishAliasCtrl = TextEditingController();

  String _size      = kAllowedSizes.first;
  String _surface   = 'Matt';
  String _tileType  = kTileTypes.first;
  String _quality   = 'Premium';
  String _stockType = 'Regular';

  List<String> _surfaces = kFinishes;   // replaced by admin master list on load
  List<String> _sizes    = kAllowedSizes; // replaced by admin master list on load
  List<StockCatalog> _catalogs = []; // the stockist's catalogs
  String? _catalogId; // which catalog this design belongs to
  final _qualities  = ['Premium', 'Standard'];
  final _stockTypes = ['Both', 'Regular', 'One Time'];

  List<String> _existingImageUrls = []; // loaded from DB in edit mode
  List<String> _pickedPaths       = []; // newly picked local files
  bool _pageLoading = false;
  bool _saving      = false;
  bool _processingDialogShown = false;
  bool _dirty       = false; // unsaved edits → pinned Save bar + exit guard

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
    if (isEdit) await _loadExisting();
  }

  // The stockist's catalogs; default a NEW design to the first public catalog.
  Future<void> _loadCatalogs() async {
    if (currentStockistUUID.isEmpty) return;
    final cats = await _service.getCatalogs(currentStockistUUID);
    if (!mounted) return;
    setState(() {
      _catalogs = cats.where((c) => c.isActive).toList();
      if (!isEdit) {
        for (final c in _catalogs) {
          if (!c.isPrivate) { _catalogId = c.id; break; }
        }
        _catalogId ??= _catalogs.isEmpty ? null : _catalogs.first.id;
      }
    });
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
    _nameCtrl.dispose();      _qtyCtrl.dispose();
    _priceCtrl.dispose();     _piecesCtrl.dispose();
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
    _nameCtrl.text      = d.name;
    _qtyCtrl.text       = d.boxQuantity.toString();
    _priceCtrl.text     = d.boxPrice.toString();
    _piecesCtrl.text    = d.piecesPerBox.toString();
    _weightCtrl.text    = d.boxWeightKg.toString();
    _thicknessCtrl.text = d.thicknessMm.toString();
    _colourCtrl.text    = d.colour;
    _surface            = _surfaces.contains(d.surfaceType) ? d.surfaceType : _surfaces.first;
    _tileType           = kTileTypes.contains(d.tileType)   ? d.tileType   : kTileTypes.first;
    _quality            = _qualities.contains(d.quality)    ? d.quality    : _qualities.first;
    _stockType          = _stockTypes.contains(d.stockType) ? d.stockType  : _stockTypes.first;
    _existingImageUrls  = List.from(d.faceImageUrls);
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

  // ── Image picker ──────────────────────────────────────────────────────────

  final _picker = ImagePicker();

  // Ask the stockist whether to take a photo or pick from the gallery, then
  // run the matching picker. This is where a stockist adds a tile photo for a
  // design that came from a PDF without one.
  Future<void> _chooseImageSource() async {
    final src = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera, color: Color(0xFF1B4F72)),
              title: const Text('Take photo'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: Color(0xFF1B4F72)),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
          ],
        ),
      ),
    );
    if (src == 'camera') {
      await _takePhoto();
    } else if (src == 'gallery') {
      await _pickImages();
    }
  }

  Future<void> _takePhoto() async {
    try {
      final x = await _picker.pickImage(
          source: ImageSource.camera, maxWidth: 2000, imageQuality: 85);
      if (x == null || !mounted) return;
      setState(() {
        _pickedPaths = [x.path];
        _existingImageUrls = []; // replace existing with the new photo
        _dirty = true;
      });
    } catch (e) {
      if (mounted) _snack('Could not open camera: $e', Colors.red);
    }
  }

  Future<void> _pickImages() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (res != null) {
      setState(() {
        _pickedPaths = res.files
            .where((f) => f.path != null)
            .map((f) => f.path!)
            .toList();
        _existingImageUrls = []; // replace existing images with new pick
        _dirty = true;
      });
    }
  }

  // ── Save (add or update) ──────────────────────────────────────────────────

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (currentStockistUUID.isEmpty) {
      _snack('Session error — please login again.', Colors.red);
      return;
    }

    setState(() => _saving = true);

    // Only show the "uploading to server" dialog when there are new photos to
    // upload — a plain field-only save doesn't hit the image server.
    if (_pickedPaths.isNotEmpty) _showProcessing();

    // Upload any newly picked images to Cloudinary
    final newUrls = <String>[];
    for (final path in _pickedPaths) {
      final url = await CloudinaryService.uploadImage(path);
      if (url != null) newUrls.add(url);
    }
    final finalUrls = newUrls.isNotEmpty ? newUrls : _existingImageUrls;

    bool ok;
    if (isEdit) {
      // box_quantity is intentionally omitted here — in edit mode stock only
      // changes through Recount (adjustment), dispatch, or add-stock, so saving
      // other fields never silently rewrites the count.
      ok = await _service.updateDesign(widget.designId!, {
        'name':          _nameCtrl.text.trim(),
        'size':          _size,
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
        'box_price':     double.tryParse(_priceCtrl.text)     ?? 0,
        'face_image_urls': finalUrls,
        if (_catalogId != null) 'catalog_id': _catalogId,
      });
    } else {
      final id = await _service.addDesign(
        stockistUUID:  currentStockistUUID,
        name:          _nameCtrl.text.trim(),
        size:          _size,
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
        boxPrice:      double.tryParse(_priceCtrl.text)     ?? 0,
        faceImageUrls: finalUrls,
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

    // Contribute a newly added photo to the shared design-image library (first
    // writer wins), so the next stockist's Excel/PDF import of the same design
    // (name + size) auto-fills this picture. This is what makes a manually
    // snapped photo fill everyone's blank rows.
    if (ok && newUrls.isNotEmpty) {
      await _service.contributeDesignImage(
        name: _nameCtrl.text.trim(),
        size: _size,
        imageUrl: newUrls.first,
        source: 'camera',
        stockistUUID: currentStockistUUID,
      );
    }

    if (!mounted) return;
    _hideProcessing();
    setState(() {
      _saving = false;
      if (ok) _dirty = false; // saved → let the pop through the exit guard
    });

    _snack(
        ok
            ? 'Design saved! Your tile photo is now live.'
            : 'Failed to save. Please try again.',
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
            'Delete "${_nameCtrl.text.trim()}"?\n\n'
            'This will remove the design and all its stock history.'),
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

  // Blocking "uploading to server" dialog, shown while newly captured tile
  // photos are being uploaded so the stockist knows the work is in progress
  // (and not to close the app). Dismissed by [_hideProcessing] when done.
  void _showProcessing() {
    _processingDialogShown = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Uploading your tile photo…',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    SizedBox(height: 6),
                    Text(
                      'Saving the image to the server. Please keep the app '
                      'open — this can take a little longer on a slow '
                      'connection.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
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

  void _hideProcessing() {
    if (_processingDialogShown) {
      Navigator.of(context, rootNavigator: true).pop();
      _processingDialogShown = false;
    }
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
        title: Text(isEdit ? 'Edit Design' : 'Add New Design'),
        actions: [
          if (isEdit)
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: 'Stock history',
              onPressed: _saving
                  ? null
                  : () => context.push(
                        '/stockist/stock/history/${widget.designId}/'
                        '${Uri.encodeComponent(_nameCtrl.text.trim())}',
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
                  _buildImagePicker(),
                  const SizedBox(height: 8),
                  _field(_nameCtrl, 'Design Name', required: true),
                  if (_catalogs.length > 1) _buildCatalogPicker(),
                  _buildSizePicker(),
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
                  _field(_priceCtrl, 'Box Price (₹)', numeric: true, required: true),
                ],
              ),
            ),
          ),
    );
  }

  // ── Image picker widget ───────────────────────────────────────────────────

  Widget _buildImagePicker() {
    final hasImages = _existingImageUrls.isNotEmpty || _pickedPaths.isNotEmpty;
    final ratio = aspectRatioFromSize(_size); // width / height (0.5 = 1:2)
    final portrait = ratio < 0.95;
    return GestureDetector(
      onTap: _chooseImageSource,
      child: LayoutBuilder(
        builder: (ctx, c) {
          final w = c.maxWidth - 16; // minus padding
          // Portrait tiles are rotated to landscape so the wide preview area is
          // used instead of leaving large empty side margins.
          var imgH = portrait ? w * ratio : w / ratio;
          imgH = imgH.clamp(140.0, 260.0);
          final imgW = portrait ? w : imgH * ratio;
          return Container(
            width: double.infinity,
            height: hasImages ? imgH + 16 : 160,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(
                  color: hasImages ? const Color(0xFF1B4F72) : Colors.grey),
              borderRadius: BorderRadius.circular(8),
            ),
            child: hasImages
                ? Stack(
                    children: [
                      Center(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: SizedBox(
                            width: imgW,
                            height: imgH,
                            child: _previewImage(portrait),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: TextButton.icon(
                          onPressed: _chooseImageSource,
                          icon: const Icon(Icons.edit, size: 14),
                          label: const Text('Change'),
                          style: TextButton.styleFrom(
                            backgroundColor: Colors.black.withValues(alpha: 0.5),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                          ),
                        ),
                      ),
                    ],
                  )
                : const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_photo_alternate_outlined,
                          size: 48, color: Colors.grey),
                      SizedBox(height: 8),
                      Text('Tap to add a photo — camera or gallery',
                          style: TextStyle(color: Colors.grey)),
                    ],
                  ),
          );
        },
      ),
    );
  }

  // First image, rotated 90° for portrait tiles so it shows horizontally.
  Widget _previewImage(bool portrait) {
    final image = _pickedPaths.isNotEmpty
        ? Image.file(File(_pickedPaths.first), fit: BoxFit.cover)
        : Image.network(_existingImageUrls.first, fit: BoxFit.cover);
    return portrait ? RotatedBox(quarterTurns: 1, child: image) : image;
  }

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
                      child: Text(
                          '${c.name}${c.isPrivate ? '  (private)' : ''}')))
                  .toList(),
              onChanged: (v) => setState(() {
                _catalogId = v ?? _catalogId;
                _dirty = true;
              }),
            ),
          ),
        ],
      ),
    );
  }

  // ── Size picker ───────────────────────────────────────────────────────────

  Widget _buildSizePicker() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Tile Size',
              style: TextStyle(fontSize: 13, color: Colors.grey)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _sizes.map((s) {
              final selected = _size == s;
              final r = aspectRatioFromSize(s);
              final label = s.replaceAll(' mm', '');
              final rLabel = ratioLabel(s);
              final iconW = r >= 0.95 ? 16.0 : (r > 0.63 ? 12.0 : 10.0);
              final iconH = r >= 0.95 ? 16.0 : (r > 0.63 ? 18.0 : 20.0);
              return GestureDetector(
                onTap: () => setState(() { _size = s; _dirty = true; }),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected
                        ? const Color(0xFF1B4F72)
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: selected
                          ? const Color(0xFF1B4F72)
                          : Colors.grey.shade300,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: iconW,
                        height: iconH,
                        decoration: BoxDecoration(
                          color: selected
                              ? Colors.white.withValues(alpha: 0.25)
                              : const Color(0xFF1B4F72).withValues(alpha: 0.08),
                          border: Border.all(
                            color: selected
                                ? Colors.white
                                : const Color(0xFF1B4F72),
                            width: 1.5,
                          ),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(label,
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: selected
                                      ? Colors.white
                                      : Colors.grey.shade800)),
                          Text(rLabel,
                              style: TextStyle(
                                  fontSize: 10,
                                  color: selected
                                      ? Colors.white70
                                      : Colors.grey.shade500)),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
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
