import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../models/choice_state.dart';
import '../../models/tile_design.dart';
import '../../utils/tile_sizes.dart';
import '../../utils/finishes.dart';

class AddEditStockScreen extends StatefulWidget {
  final String? designId;
  const AddEditStockScreen({super.key, this.designId});
  @override
  State<AddEditStockScreen> createState() => _State();
}

class _State extends State<AddEditStockScreen> {
  final _formKey = GlobalKey<FormState>();
  final _service = SupabaseDataService();
  bool get isEdit => widget.designId != null;

  final _nameCtrl      = TextEditingController();
  final _qtyCtrl       = TextEditingController();
  final _priceCtrl     = TextEditingController();
  final _piecesCtrl    = TextEditingController();
  final _weightCtrl    = TextEditingController();
  final _thicknessCtrl = TextEditingController();
  final _colourCtrl    = TextEditingController();

  String _size      = kAllowedSizes.first;
  String _surface   = 'Matt';
  String _quality   = 'Premium';
  String _stockType = 'Regular';

  List<String> _surfaces = kFinishes;   // replaced by admin master list on load
  final _qualities  = ['Premium', 'Standard'];
  final _stockTypes = ['Regular', 'One Time'];

  List<String> _existingImageUrls = []; // loaded from DB in edit mode
  List<String> _pickedPaths       = []; // newly picked local files
  bool _pageLoading = false;
  bool _saving      = false;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _loadSurfaces();
    if (isEdit) await _loadExisting();
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
    _colourCtrl.dispose();
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
    _quality            = _qualities.contains(d.quality)    ? d.quality    : _qualities.first;
    _stockType          = _stockTypes.contains(d.stockType) ? d.stockType  : _stockTypes.first;
    _existingImageUrls  = List.from(d.faceImageUrls);

    // Match stored size to allowed list (handles old wrong formats too)
    final key = d.size
        .replaceAll(RegExp(r'[^0-9x]', caseSensitive: false), '')
        .toLowerCase();
    _size = kAllowedSizes.firstWhere(
      (s) => s.replaceAll(RegExp(r'[^0-9x]', caseSensitive: false), '').toLowerCase() == key,
      orElse: () => kAllowedSizes.first,
    );
  }

  // ── Image picker ──────────────────────────────────────────────────────────

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

    // Upload any newly picked images to Cloudinary
    final newUrls = <String>[];
    for (final path in _pickedPaths) {
      final url = await CloudinaryService.uploadImage(path);
      if (url != null) newUrls.add(url);
    }
    final finalUrls = newUrls.isNotEmpty ? newUrls : _existingImageUrls;

    bool ok;
    if (isEdit) {
      ok = await _service.updateDesign(widget.designId!, {
        'name':          _nameCtrl.text.trim(),
        'size':          _size,
        'surface_type':  _surface,
        'quality':       _quality,
        'colour':        _colourCtrl.text.trim(),
        'stock_type':    _stockType,
        'box_quantity':  int.tryParse(_qtyCtrl.text)       ?? 0,
        'pieces_per_box': int.tryParse(_piecesCtrl.text)   ?? 0,
        'box_weight_kg': double.tryParse(_weightCtrl.text)    ?? 0,
        'thickness_mm':  double.tryParse(_thicknessCtrl.text) ?? 0,
        'box_price':     double.tryParse(_priceCtrl.text)     ?? 0,
        'face_image_urls': finalUrls,
      });
    } else {
      final id = await _service.addDesign(
        stockistUUID:  currentStockistUUID,
        name:          _nameCtrl.text.trim(),
        size:          _size,
        surfaceType:   _surface,
        quality:       _quality,
        colour:        _colourCtrl.text.trim(),
        stockType:     _stockType,
        boxQuantity:   int.tryParse(_qtyCtrl.text)       ?? 0,
        piecesPerBox:  int.tryParse(_piecesCtrl.text)    ?? 0,
        boxWeightKg:   double.tryParse(_weightCtrl.text)    ?? 0,
        thicknessMm:   double.tryParse(_thicknessCtrl.text) ?? 0,
        boxPrice:      double.tryParse(_priceCtrl.text)     ?? 0,
        faceImageUrls: finalUrls,
      );
      ok = id != null;
    }

    setState(() => _saving = false);
    if (!mounted) return;

    _snack(ok ? 'Design saved!' : 'Failed to save. Please try again.',
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
    setState(() => _saving = false);
    if (!mounted) return;

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
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(isEdit ? 'Edit Design' : 'Add New Design'),
        actions: [
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
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildImagePicker(),
                  const SizedBox(height: 8),
                  _field(_nameCtrl, 'Design Name', required: true),
                  _buildSizePicker(),
                  _buildDropdown('Surface Type', _surfaces, _surface,
                      (v) => setState(() => _surface = v!)),
                  const SizedBox(height: 16),
                  _buildQualityPicker(),
                  const SizedBox(height: 16),
                  _buildStockTypePicker(),
                  const SizedBox(height: 16),
                  _field(_colourCtrl, 'Colour', required: true),
                  Row(children: [
                    Expanded(child: _field(_piecesCtrl, 'Pieces/Box',
                        numeric: true, required: true)),
                    const SizedBox(width: 12),
                    Expanded(child: _field(_qtyCtrl, 'Box Quantity',
                        numeric: true, required: true)),
                  ]),
                  Row(children: [
                    Expanded(child: _field(_weightCtrl, 'Box Weight (kg)',
                        numeric: true, required: true)),
                    const SizedBox(width: 12),
                    Expanded(child: _field(_thicknessCtrl, 'Thickness (mm)',
                        numeric: true, required: true)),
                  ]),
                  _field(_priceCtrl, 'Box Price (₹)', numeric: true, required: true),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: _saving ? null : _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1B4F72),
                        foregroundColor: Colors.white,
                      ),
                      child: _saving
                          ? const CircularProgressIndicator(color: Colors.white)
                          : Text(isEdit ? 'Update Design' : 'Add Design',
                              style: const TextStyle(fontSize: 16)),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  // ── Image picker widget ───────────────────────────────────────────────────

  Widget _buildImagePicker() {
    final hasImages = _existingImageUrls.isNotEmpty || _pickedPaths.isNotEmpty;
    return GestureDetector(
      onTap: _pickImages,
      child: Container(
        height: 160,
        decoration: BoxDecoration(
          border: Border.all(
              color: hasImages ? const Color(0xFF1B4F72) : Colors.grey),
          borderRadius: BorderRadius.circular(8),
        ),
        child: hasImages
            ? Stack(
                children: [
                  ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(8),
                    itemCount: _pickedPaths.isNotEmpty
                        ? _pickedPaths.length
                        : _existingImageUrls.length,
                    itemBuilder: (_, i) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: _pickedPaths.isNotEmpty
                              ? Image.file(File(_pickedPaths[i]),
                                  width: 120, height: 144,
                                  fit: BoxFit.cover)
                              : Image.network(_existingImageUrls[i],
                                  width: 120, height: 144,
                                  fit: BoxFit.cover),
                        ),
                      );
                    },
                  ),
                  Positioned(
                    bottom: 8,
                    right: 8,
                    child: TextButton.icon(
                      onPressed: _pickImages,
                      icon: const Icon(Icons.edit, size: 14),
                      label: const Text('Change'),
                      style: TextButton.styleFrom(
                        backgroundColor:
                            Colors.black.withValues(alpha: 0.5),
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
                  Text('Tap to add design images',
                      style: TextStyle(color: Colors.grey)),
                ],
              ),
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
            children: kAllowedSizes.map((s) {
              final selected = _size == s;
              final r = aspectRatioFromSize(s);
              final label = s.replaceAll(' mm', '');
              final rLabel = ratioLabel(s);
              final iconW = r >= 0.95 ? 16.0 : (r > 0.63 ? 12.0 : 10.0);
              final iconH = r >= 0.95 ? 16.0 : (r > 0.63 ? 18.0 : 20.0);
              return GestureDetector(
                onTap: () => setState(() => _size = s),
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
        const SizedBox(height: 8),
        Row(
          children: _qualities.map((q) {
            final sel = _quality == q;
            final Color bg, fg;
            final IconData icon;
            if (q == 'Premium') {
              bg   = const Color(0xFFFFF8E1);
              fg   = const Color(0xFFF9A825);
              icon = Icons.star_rounded;
            } else {
              bg   = const Color(0xFFE3F2FD);
              fg   = const Color(0xFF1565C0);
              icon = Icons.verified_outlined;
            }
            return Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _quality = q),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: sel ? fg : bg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: fg, width: sel ? 2 : 1),
                    boxShadow: sel
                        ? [BoxShadow(
                              color: fg.withValues(alpha: 0.25),
                              blurRadius: 6)]
                        : [],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 22, color: sel ? Colors.white : fg),
                      const SizedBox(height: 6),
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
        const SizedBox(height: 8),
        Row(
          children: _stockTypes.map((type) => Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _stockType = type),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: _stockType == type
                      ? const Color(0xFF1B4F72)
                      : Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: _stockType == type
                          ? const Color(0xFF1B4F72)
                          : Colors.grey),
                ),
                child: Column(
                  children: [
                    Icon(
                      type == 'Regular'
                          ? Icons.autorenew
                          : Icons.looks_one_outlined,
                      color: _stockType == type
                          ? Colors.white
                          : Colors.grey,
                    ),
                    const SizedBox(height: 4),
                    Text(type,
                        style: TextStyle(
                            color: _stockType == type
                                ? Colors.white
                                : Colors.grey,
                            fontWeight: FontWeight.bold)),
                    Text(
                        type == 'Regular'
                            ? 'Always available'
                            : 'Limited stock',
                        style: TextStyle(
                            fontSize: 10,
                            color: _stockType == type
                                ? Colors.white70
                                : Colors.grey)),
                  ],
                ),
              ),
            ),
          )).toList(),
        ),
      ],
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

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
}
