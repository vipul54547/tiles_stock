import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../services/pdf_import_service.dart';
import '../../services/stock_service.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../models/tile_design.dart';
import '../../models/tile_size.dart';
import '../../models/stock_catalog.dart';
import '../../models/choice_state.dart';
import '../../utils/tile_sizes.dart';
import '../../utils/tile_types.dart';
import '../../utils/finishes.dart';
import '../../utils/dispose_after_frame.dart';

// Quality grades a stockist can assign to an uploaded batch.
const List<String> kQualities = ['Standard', 'Premium', 'Economy'];

// Stock types a stockist can assign to an uploaded batch. 'Both' = the designs
// are sold as regular AND one-time stock (shows under either buyer filter).
const List<String> kUploadStockTypes = ['Both', 'Regular', 'One Time'];

// ── Resolved row ─────────────────────────────────────────────────────────────
// Produced after matching PDF rows to existing designs.

class _Resolved {
  final PdfDesignRow row;
  final TileDesign? match; // non-null → update existing; null → create new
  String rawKey;           // normalised original PDF finish word (for learning).
  // Mutable: a single-surface PDF carries no finish word, so the stockist may
  // type their own in the Map-Finishes step, which becomes the key to learn.

  _Resolved(this.row, this.match, {this.rawKey = ''});

  bool get isUpdate => match != null;
  int get newTotal  => isUpdate ? match!.boxQuantity + row.quantity : row.quantity;
}

// One distinct PDF surface word in the bulk finish-mapping step: the raw label
// shown to the stockist, the standard finish they map it to, and how many
// designs share it.
class _FinishGroup {
  final String label;  // raw finish word from the PDF (display)
  String choice;       // chosen standard finish (admin surface_type)
  // The stockist's own finish wording, typed via "Add manually" when the PDF
  // carried no finish (single-surface layout). Null = manual entry not in use.
  // When set, it becomes the stockist-side label + the alias-learning key.
  String? manualLabel;
  int count = 0;
  _FinishGroup({required this.label, required this.choice});
}

class UploadStockScreen extends StatefulWidget {
  const UploadStockScreen({super.key});
  @override
  State<UploadStockScreen> createState() => _State();
}

class _State extends State<UploadStockScreen> {
  final _pdfService  = PdfImportService();
  final _stockSvc    = StockService();
  final _dataSvc     = SupabaseDataService();

  PdfImportResult?   _parsed;
  List<_Resolved>    _rows      = [];
  // Shared-library photos matched for the preview (name+size → url). Shown as the
  // thumbnail for rows the PDF carried no image for, so the stockist sees the
  // auto-matched picture before importing.
  Map<String, String> _libImages = {};
  bool  _loading   = false;
  bool  _importing = false;
  String _filename    = '';
  String _loadingStep = '';

  // Stockist-confirmed details (filename is only a default; the stockist's
  // choice is the source of truth, guarding against wrongly-named files).
  String _size     = kAllowedSizes.first;
  String _quality  = 'Standard';
  int?   _expectedCount; // designs the stockist expects → checksum vs parsed
  // Body type + per-box weight/pieces the stockist confirms for the whole batch
  // (constant per size). Used to save real values and derive sqft + thickness.
  String _tileType     = kTileTypes.first;
  double _boxWeightKg  = 0;
  int    _piecesPerBox = 0;
  String _stockType    = 'Both'; // One Time / Regular / Both (whole batch)

  // Admin's live master finish list + this stockist's learned aliases. Loaded
  // once so every parsed row can be aligned to an official finish (and the
  // surface picker offers exactly the admin's finishes, not a hardcoded list).
  List<String>        _finishes = kFinishes;     // fallback until loaded
  List<String>        _sizes    = kAllowedSizes;  // admin master, loaded once
  List<TileSize>      _tileSizes = [];           // full size rows (with aliases)
  List<StockCatalog>  _catalogs  = [];           // stockist's stock catalogs
  String?             _catalogId;                // chosen upload target catalog
  Map<String, String> _aliases  = {};            // normalisedRaw → finish name
  bool _configLoaded = false;

  @override
  void initState() {
    super.initState();
    _ensureConfig();
  }

  // Pull the admin finish list + stockist aliases. Safe to call repeatedly.
  Future<void> _ensureConfig() async {
    if (_configLoaded) return;
    try {
      final types = await _dataSvc.getSurfaceTypes(activeOnly: true);
      final names = types.map((t) => t.name).toList();
      final tileSizes = await _dataSvc.getTileSizes(activeOnly: true);
      final sizeNames = tileSizes.map((s) => s.name).toList();
      final catalogs = currentStockistUUID.isEmpty
          ? <StockCatalog>[]
          : await _dataSvc.getCatalogs(currentStockistUUID);
      final aliases = currentStockistUUID.isEmpty
          ? <String, String>{}
          : await _dataSvc.getSurfaceAliases(currentStockistUUID);
      if (!mounted) return;
      setState(() {
        if (names.isNotEmpty) _finishes = names;
        if (sizeNames.isNotEmpty) _sizes = sizeNames;
        _tileSizes = tileSizes;
        _catalogs = catalogs.where((c) => c.isActive).toList();
        // Default to the first public catalog (the usual marketplace stock).
        _catalogId ??= _defaultCatalogId();
        _aliases = aliases;
        _configLoaded = true;
      });
    } catch (_) {
      // Keep the kFinishes fallback; alignment still works, just no aliases.
    }
  }

  // Aligns a parsed row's finish to the admin master list:
  //   1. a learned alias for the raw PDF word wins (the stockist's past choice)
  //   2. otherwise keep the parser's guess if it's an official finish
  //   3. otherwise fall back to 'None'
  // Returns the normalised raw key so the caller can later learn from it.
  String _alignSurface(PdfDesignRow row) {
    final rawKey = normalizeSurfaceRaw(
        row.surfaceRaw ?? row.finishLabel ?? row.surface);
    final aliased = _aliases[rawKey];
    if (aliased != null && _finishes.contains(aliased)) {
      row.surface = aliased;
    } else if (!_finishes.contains(row.surface)) {
      row.surface = _finishes.contains('None') ? 'None' : row.surface;
    }
    return rawKey;
  }

  // The stockist's own finish wording from the PDF (full raw text preferred),
  // for display next to the mapped admin finish. Null if the PDF had none.
  String? _pdfFinishOf(PdfDesignRow row) {
    final raw = row.surfaceRaw ?? row.finishLabel;
    return (raw != null && raw.isNotEmpty) ? raw : null;
  }

  // ── Pick file + auto-process ──────────────────────────────────────────────

  Future<void> _pickFile() async {
    FilePickerResult? res;
    try {
      res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );
    } catch (_) {}
    if (res == null || res.files.isEmpty) return;

    final name     = res.files.first.name;
    final filePath = res.files.first.path;
    setState(() { _loading = true; _filename = name; _loadingStep = 'Reading PDF…'; });

    // Parse PDF in background isolate (UI stays responsive for any file size)
    final parsed = await _pdfService.parsePdf(name, filePath);
    setState(() { _loading = false; _loadingStep = ''; });
    if (!mounted) return;

    // Confirm size / quality / expected design count before importing. The
    // filename only pre-fills these; a wrong filename is caught here rather
    // than silently importing every design with the wrong size/quality.
    final ok = await _confirmDetails(parsed);
    if (!ok) { setState(() { _filename = ''; }); return; }

    // Make sure the admin finish list + aliases are loaded before aligning.
    await _ensureConfig();

    // Load existing designs for this stockist
    setState(() { _loading = true; _loadingStep = 'Matching designs…'; });
    final existing = currentStockistUUID.isEmpty
        ? <TileDesign>[]
        : await _dataSvc.getDesignsByStockist(currentStockistUUID);

    // Auto-resolve each PDF row: align its finish to the admin master list
    // (applying any learned alias) and match it to an existing design.
    final rows = parsed.designs.map((row) {
      final rawKey = _alignSurface(row);
      final match  = _findMatch(row.name, existing);
      return _Resolved(row, match, rawKey: rawKey);
    }).toList();

    // Look up shared-library photos so the preview can show an auto-matched
    // picture for rows the PDF had no image for. Text-only query (URLs); the
    // thumbnails themselves load lazily, only for visible rows.
    final lib = await _dataSvc
        .lookupDesignImages([for (final r in rows) (r.row.name, _size)]);

    setState(() { _loading = false; _loadingStep = ''; _libImages = lib; });
    if (!mounted) return;

    // Bulk finish-mapping step: map each UNIQUE PDF surface word to a standard
    // finish once (applies to all designs sharing it) instead of editing every
    // design row. Pre-filled with the auto-alignment / learned aliases.
    final mapped = await _mapFinishesStep(rows);
    if (!mapped) { setState(() { _filename = ''; }); return; }

    setState(() {
      _parsed = parsed;
      _rows   = rows;
    });
  }

  // Shows the "Map your PDF finishes → standard finishes" dialog. Groups rows by
  // their normalised raw surface word, lets the stockist pick the official
  // finish for each group via a dropdown, then applies the choice to every row
  // in that group. Returns false if cancelled.
  Future<bool> _mapFinishesStep(List<_Resolved> rows) async {
    // Group by raw key; remember a display label, the current choice and count.
    final groups = <String, _FinishGroup>{};
    for (final r in rows) {
      // Show the stockist's full PDF finish wording (e.g. "Endless Glossy"),
      // not the truncated/mapped name, so they recognise their own naming.
      final raw = (r.row.surfaceRaw != null && r.row.surfaceRaw!.isNotEmpty)
          ? r.row.surfaceRaw!
          : (r.row.finishLabel != null && r.row.finishLabel!.isNotEmpty)
              ? r.row.finishLabel!
              : r.row.surface;
      // A single-surface PDF carried no finish word, so the raw label is just
      // 'None'. Show a clearer prompt instead, since this one group sets the
      // finish for the whole document.
      final label =
          raw.trim().toLowerCase() == 'none' ? 'All designs (no finish in PDF)' : raw;
      // Keep the initial choice in sync with what the dropdown can display:
      // if the row's finish isn't in the admin list (e.g. 'None' on a
      // single-surface PDF), fall back to the first admin finish so an untouched
      // dropdown applies exactly what the stockist sees.
      final initialChoice = _finishes.contains(r.row.surface)
          ? r.row.surface
          : (_finishes.isNotEmpty ? _finishes.first : r.row.surface);
      final g = groups.putIfAbsent(
          r.rawKey, () => _FinishGroup(label: label, choice: initialChoice));
      g.count++;
    }
    if (groups.isEmpty) return true;

    final keys = groups.keys.toList();
    // One text field per group for the "Add manually" path (stockist's own
    // finish wording). Disposed after the dialog closes.
    final manualCtrls = {
      for (final k in keys) k: TextEditingController(text: groups[k]!.manualLabel ?? ''),
    };
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Map Finishes'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Match each finish from your PDF to a standard finish. '
                  'This applies to all designs with that finish.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 12),
                const Row(
                  children: [
                    Expanded(
                        flex: 5,
                        child: Text('Your PDF finish',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey))),
                    Expanded(
                        flex: 5,
                        child: Text('Standard finish',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey))),
                  ],
                ),
                const Divider(),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: keys.map((k) {
                        final g = groups[k]!;
                        final showManual = g.manualLabel != null;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    flex: 5,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(showManual ? 'Your finish name' : g.label,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w600,
                                                fontSize: 13)),
                                        if (showManual)
                                          TextField(
                                            controller: manualCtrls[k],
                                            style: const TextStyle(fontSize: 13),
                                            decoration: const InputDecoration(
                                              isDense: true,
                                              hintText: 'e.g. Endless Glossy',
                                            ),
                                            onChanged: (v) => g.manualLabel = v,
                                          )
                                        else
                                          Text(
                                              '${g.count} tile${g.count == 1 ? '' : 's'}',
                                              style: const TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.grey)),
                                      ],
                                    ),
                                  ),
                                  const Icon(Icons.arrow_forward,
                                      size: 14, color: Colors.grey),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    flex: 5,
                                    child: DropdownButton<String>(
                                      value: _finishes.contains(g.choice)
                                          ? g.choice
                                          : _finishes.first,
                                      isExpanded: true,
                                      underline: const SizedBox.shrink(),
                                      items: _finishes
                                          .map((f) => DropdownMenuItem(
                                              value: f, child: Text(f)))
                                          .toList(),
                                      onChanged: (v) {
                                        if (v != null) {
                                          setLocal(() => g.choice = v);
                                        }
                                      },
                                    ),
                                  ),
                                ],
                              ),
                              // Toggle the free-text entry so a stockist can name
                              // a finish their PDF didn't carry, then align it to
                              // a standard finish via the dropdown above.
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  style: TextButton.styleFrom(
                                      padding: EdgeInsets.zero,
                                      minimumSize: const Size(0, 28),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap),
                                  onPressed: () => setLocal(() => g.manualLabel =
                                      showManual ? null : manualCtrls[k]!.text),
                                  icon: Icon(showManual ? Icons.close : Icons.edit,
                                      size: 14),
                                  label: Text(
                                      showManual ? 'Cancel' : 'Add manually',
                                      style: const TextStyle(fontSize: 11)),
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
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
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1B4F72),
                  foregroundColor: Colors.white),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );

    disposeAfterFrame(manualCtrls.values.toList());
    if (result != true) return false;

    // Apply each group's chosen finish to every row that shares its raw key.
    // When the stockist typed their own wording ("Add manually"), record it as
    // the row's finish text and re-key the row so that wording → chosen finish
    // is what gets learned for next time.
    for (final r in rows) {
      final g = groups[r.rawKey];
      if (g == null) continue;
      r.row.surface = g.choice;
      final manual = g.manualLabel?.trim() ?? '';
      if (manual.isNotEmpty) {
        r.row.surfaceRaw = manual;
        r.rawKey = normalizeSurfaceRaw(manual);
      }
    }
    return true;
  }

  // The default upload target: the first active public catalog, else the first.
  String? _defaultCatalogId() {
    for (final c in _catalogs) {
      if (!c.isPrivate) return c.id;
    }
    return _catalogs.isEmpty ? null : _catalogs.first.id;
  }

  // Ask the stockist to confirm size + quality (defaulted from the filename)
  // and enter how many designs they expect. Returns false if cancelled.
  Future<bool> _confirmDetails(PdfImportResult parsed) async {
    // Pre-fill size from the filename/data. First map any inch/feet trade name
    // (e.g. "12x18", "2x4") to its canonical mm size via the admin alias list,
    // then fall back to a plain mm normalisation.
    final resolved = resolveCanonicalSize(parsed.size, _tileSizes);
    final parsedSize = resolved ?? normaliseSize(parsed.size);
    _size = _sizes.contains(parsedSize) ? parsedSize : _sizes.first;
    _quality = kQualities.contains(parsed.quality) ? parsed.quality : 'Standard';
    final countCtrl =
        TextEditingController(text: parsed.designs.length.toString());
    final weightCtrl =
        TextEditingController(text: _boxWeightKg > 0 ? '$_boxWeightKg' : '');
    final piecesCtrl =
        TextEditingController(text: _piecesPerBox > 0 ? '$_piecesPerBox' : '');

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final parsedCount = parsed.designs.length;
          final entered = int.tryParse(countCtrl.text.trim());
          final countMismatch = entered != null && entered != parsedCount;
          return AlertDialog(
            title: const Text('Confirm Upload Details'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('File: $_filename',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 14),
                  // Catalog (which stock this upload goes into) — only when the
                  // stockist has more than the default catalog.
                  if (_catalogs.length > 1) ...[
                    const Text('Add to catalog',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                    DropdownButton<String>(
                      isExpanded: true,
                      value: _catalogId,
                      items: _catalogs
                          .map((c) => DropdownMenuItem(
                              value: c.id,
                              child: Text(
                                  '${c.name}${c.isPrivate ? '  (private)' : ''}')))
                          .toList(),
                      onChanged: (v) =>
                          setLocal(() => _catalogId = v ?? _catalogId),
                    ),
                    const SizedBox(height: 12),
                  ],
                  // Size
                  const Text('Tile size',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: _size,
                    items: _sizes
                        .map((s) => DropdownMenuItem(
                            value: s, child: Text(s.replaceAll(' mm', ' mm'))))
                        .toList(),
                    onChanged: (v) => setLocal(() => _size = v ?? _size),
                  ),
                  if (!_sizes.contains(parsedSize))
                    Text('⚠ Filename size "${parsed.size}" not recognised — '
                        'please pick the correct size.',
                        style: TextStyle(
                            fontSize: 11, color: Colors.orange.shade800)),
                  const SizedBox(height: 12),
                  // Quality
                  const Text('Quality',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: _quality,
                    items: kQualities
                        .map((q) =>
                            DropdownMenuItem(value: q, child: Text(q)))
                        .toList(),
                    onChanged: (v) => setLocal(() => _quality = v ?? _quality),
                  ),
                  const SizedBox(height: 12),
                  // Tile type (body)
                  const Text('Tile type',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: _tileType,
                    items: kTileTypes
                        .map((t) =>
                            DropdownMenuItem(value: t, child: Text(t)))
                        .toList(),
                    onChanged: (v) => setLocal(() => _tileType = v ?? _tileType),
                  ),
                  const SizedBox(height: 12),
                  // Stock type
                  const Text('Stock type',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: _stockType,
                    items: kUploadStockTypes
                        .map((t) =>
                            DropdownMenuItem(value: t, child: Text(t)))
                        .toList(),
                    onChanged: (v) => setLocal(() => _stockType = v ?? _stockType),
                  ),
                  const SizedBox(height: 12),
                  // Box weight + pieces/box (numbers)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Box weight (kg)',
                                style: TextStyle(
                                    fontSize: 12, fontWeight: FontWeight.w600)),
                            TextField(
                              controller: weightCtrl,
                              keyboardType: const TextInputType.numberWithOptions(
                                  decimal: true),
                              onChanged: (_) => setLocal(() {}),
                              decoration: const InputDecoration(isDense: true),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Pieces / box',
                                style: TextStyle(
                                    fontSize: 12, fontWeight: FontWeight.w600)),
                            TextField(
                              controller: piecesCtrl,
                              keyboardType: TextInputType.number,
                              onChanged: (_) => setLocal(() {}),
                              decoration: const InputDecoration(isDense: true),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  // Live derived sqft/box + thickness range preview.
                  Builder(builder: (_) {
                    final pcs = int.tryParse(piecesCtrl.text.trim()) ?? 0;
                    final wt = double.tryParse(weightCtrl.text.trim()) ?? 0;
                    final sqft = sqftPerBox(_size, pcs);
                    final tRange = thicknessRangeLabel(_size, pcs, wt, _tileType);
                    if (sqft == null && tRange == null) {
                      return const SizedBox(height: 6);
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (sqft != null)
                            Text('Sq.ft / box: ${sqft.toStringAsFixed(2)}',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade700)),
                          if (tRange != null) ...[
                            Text('Thickness: $tRange (approx)',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade700)),
                            Text(kEmbossThicknessNote,
                                style: TextStyle(
                                    fontSize: 10,
                                    fontStyle: FontStyle.italic,
                                    color: Colors.grey.shade500)),
                          ],
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 12),
                  // Expected design count (checksum)
                  const Text('Number of designs (expected)',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  TextField(
                    controller: countCtrl,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setLocal(() {}),
                    decoration: const InputDecoration(isDense: true),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    countMismatch
                        ? '⚠ PDF parsed $parsedCount designs, but you expect '
                            '$entered. Check for missing/extra rows before saving.'
                        : 'PDF parsed $parsedCount designs.',
                    style: TextStyle(
                        fontSize: 11,
                        color: countMismatch
                            ? Colors.orange.shade800
                            : Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  _expectedCount = int.tryParse(countCtrl.text.trim());
                  _boxWeightKg = double.tryParse(weightCtrl.text.trim()) ?? 0;
                  _piecesPerBox = int.tryParse(piecesCtrl.text.trim()) ?? 0;
                  Navigator.pop(ctx, true);
                },
                child: const Text('Continue'),
              ),
            ],
          );
        },
      ),
    );
    disposeAfterFrame([countCtrl, weightCtrl, piecesCtrl]);
    return result ?? false;
  }

  // Case-insensitive name matching: exact first, then contains.
  TileDesign? _findMatch(String pdfName, List<TileDesign> existing) {
    final needle = pdfName.trim().toLowerCase();
    // Exact match
    for (final d in existing) {
      if (d.name.trim().toLowerCase() == needle) return d;
    }
    // Partial match (either side contains the other)
    for (final d in existing) {
      final hay = d.name.trim().toLowerCase();
      if (hay.contains(needle) || needle.contains(hay)) return d;
    }
    return null;
  }

  // ── Confirm: auto-process all rows ───────────────────────────────────────

  Future<void> _confirm() async {
    if (_parsed == null || currentStockistUUID.isEmpty) return;
    setState(() { _importing = true; _loadingStep = 'Saving designs…'; });

    int updated = 0;
    int created = 0;
    int imagesUploaded = 0;
    int imagesFailed   = 0;
    int imagesFromLibrary = 0;
    String? lastImageError;

    // Shared design-image library: photos contributed by earlier imports (from
    // any stockist), keyed by (name + size). Used to fill rows whose PDF had no
    // photo, and freshly-uploaded photos are contributed back below.
    final libImages = await _dataSvc.lookupDesignImages(
        [for (final r in _rows) (r.row.name, _size)]);
    final contributions = <({String name, String size, String url})>[];

    // Upload a tile photo extracted from the PDF. Tracks success/failure
    // counts and remembers the last error so we can surface it to the user.
    Future<String?> uploadPhoto(PdfDesignRow row) async {
      if (row.imageBytes == null) return null;
      setState(() => _loadingStep = 'Uploading image for ${row.name}…');
      final res = await CloudinaryService.uploadImageBytes(
        row.imageBytes!,
        filename: '${row.name.replaceAll(' ', '_')}.jpg',
      );
      if (res.ok) {
        imagesUploaded++;
        return res.url;
      }
      imagesFailed++;
      lastImageError = res.error;
      return null;
    }

    // Resolve a row's photo: upload the one extracted from the PDF (and queue it
    // to enrich the shared library), or fall back to a library image when the
    // PDF carried none for this design.
    Future<String?> resolvePhoto(PdfDesignRow row) async {
      if (row.imageBytes != null) {
        final url = await uploadPhoto(row);
        if (url != null) {
          contributions.add((name: row.name, size: _size, url: url));
        }
        return url;
      }
      final libUrl = libImages[designImageKey(row.name, _size)];
      if (libUrl != null) imagesFromLibrary++;
      return libUrl;
    }

    for (final r in _rows) {
      if (r.isUpdate) {
        // Existing design — add the new stock quantity…
        final ok = await _stockSvc.addStock(
          designId:     r.match!.id,
          stockistUUID: currentStockistUUID,
          quantity:     r.row.quantity,
          pdfFilename:  _filename,
          size:         _size,
          quality:      _quality,
        );
        if (ok) updated++;

        // …and backfill a photo if the design has none yet — from the PDF or,
        // failing that, the shared library.
        if (r.match!.faceImageUrls.isEmpty) {
          final url = await resolvePhoto(r.row);
          if (url != null) {
            await _dataSvc.updateDesign(r.match!.id, {
              'face_image_urls': [url],
            });
          }
        }
      } else {
        // New design — resolve image (PDF photo or library), then create.
        final url = await resolvePhoto(r.row);
        final imageUrls = url != null ? [url] : <String>[];

        final newId = await _dataSvc.addDesign(
          stockistUUID:  currentStockistUUID,
          name:          r.row.name,
          size:          _size,
          surfaceType:   r.row.surface,
          quality:       _quality,
          colour:        '',
          stockType:     _stockType,
          boxQuantity:   0,
          piecesPerBox:  _piecesPerBox,
          boxWeightKg:   _boxWeightKg,
          thicknessMm:
              approxThicknessMm(_size, _piecesPerBox, _boxWeightKg, _tileType) ?? 0,
          boxPrice:      0,
          tileType:      _tileType,
          faceImageUrls: imageUrls,
          finishLabel:   r.row.finishLabel,
          catalogId:     _catalogId,
        );
        if (newId != null) {
          final ok = await _stockSvc.addStock(
            designId:     newId,
            stockistUUID: currentStockistUUID,
            quantity:     r.row.quantity,
            pdfFilename:  _filename,
            size:         _size,
            quality:      _quality,
          );
          if (ok) created++;
        }
      }
    }

    // Enrich the shared library with every photo this import uploaded, so the
    // next stockist's Excel/PDF (even one with no images) can reuse them.
    await _dataSvc.contributeDesignImages(contributions,
        source: 'pdf', stockistUUID: currentStockistUUID);

    // Learn finish alignments: remember each raw PDF surface word → the finish
    // it ended up as, so the next PDF from this stockist auto-aligns. Deduped
    // (last choice wins); 'None' and empty keys are not worth remembering.
    final learned = <String, String>{};
    for (final r in _rows) {
      if (r.rawKey.isEmpty || r.row.surface == 'None') continue;
      learned[r.rawKey] = r.row.surface;
    }
    for (final e in learned.entries) {
      await _dataSvc.upsertSurfaceAlias(currentStockistUUID, e.key, e.value);
    }

    setState(() { _importing = false; _loadingStep = ''; });
    if (!mounted) return;

    final total = updated + created;
    final libNote = imagesFromLibrary > 0
        ? ' · $imagesFromLibrary from library'
        : '';
    final imageNote =
        imagesUploaded > 0 ? ' · $imagesUploaded photos added$libNote' : libNote;
    // Make the destination catalog explicit (public = live in market, private =
    // link-only) so the stockist always knows where the upload landed.
    StockCatalog? cat;
    for (final c in _catalogs) {
      if (c.id == _catalogId) { cat = c; break; }
    }
    final catNote = cat == null
        ? ''
        : '\nUploaded to "${cat.name}"'
            '${cat.isPrivate ? ' (private — link only).' : ' (public — live in marketplace).'}';
    // If photos were extracted but none uploaded, the upload itself is failing
    // (e.g. Cloudinary preset not set to "unsigned") — tell the user why.
    final failNote = imagesFailed > 0
        ? '\n$imagesFailed photo(s) failed to upload'
            '${lastImageError != null ? ': $lastImageError' : ''}.'
        : '';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(total > 0
          ? '$updated updated, $created new designs$imageNote.$catNote$failNote'
          : 'Nothing was processed. Please try again.$failNote'),
      backgroundColor: total > 0
          ? (imagesFailed > 0 ? Colors.orange.shade800 : const Color(0xFF2E7D32))
          : Colors.red,
      duration: Duration(seconds: imagesFailed > 0 ? 6 : 4),
    ));

    if (total > 0) Navigator.of(context).pop();
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
        title: const Text('Upload Stock PDF'),
      ),
      body: (_loading || _importing)
          ? _buildLoading()
          : _parsed == null
              ? _buildPicker()
              : Column(
                  children: [
                    _buildFileBar(),
                    _buildStatsBar(),
                    _buildCountWarning(),
                    Expanded(child: _buildSummaryList()),
                    _buildBottomBar(),
                  ],
                ),
    );
  }

  // ── Loading ───────────────────────────────────────────────────────────────

  Widget _buildLoading() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(_loadingStep,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            Text(
              'Large PDFs may take 5–15 seconds.\nThe screen will not freeze.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
          ],
        ),
      );

  // ── Picker ────────────────────────────────────────────────────────────────

  Widget _buildPicker() => Center(
        child: GestureDetector(
          onTap: _pickFile,
          child: Container(
            margin: const EdgeInsets.all(32),
            padding: const EdgeInsets.all(40),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFF1B4F72), width: 2),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.upload_file, size: 64, color: Color(0xFF1B4F72)),
                SizedBox(height: 16),
                Text('Select PDF File',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1B4F72))),
                SizedBox(height: 8),
                Text('Tap to choose stock report PDF',
                    style: TextStyle(color: Colors.grey)),
                SizedBox(height: 4),
                Text('Example: 800X1600 STANDARD.pdf',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
                SizedBox(height: 2),
                Text('       or 600X1200 PREMIUM.pdf',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
              ],
            ),
          ),
        ),
      );

  // ── File info bar ─────────────────────────────────────────────────────────

  Widget _buildFileBar() => Container(
        width: double.infinity,
        color: const Color(0xFF1B4F72).withValues(alpha: 0.08),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.picture_as_pdf, color: Color(0xFF1B4F72)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_filename,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text(
                    'Size: $_size  ·  Quality: $_quality',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () =>
                  setState(() { _parsed = null; _rows = []; _filename = ''; _libImages = {}; }),
              child: const Text('Change'),
            ),
          ],
        ),
      );

  // ── Count checksum warning ────────────────────────────────────────────────
  // Surfaced when the stockist's expected design count differs from what the
  // parser found — a hint that a design row was missed or duplicated.

  Widget _buildCountWarning() {
    final expected = _expectedCount;
    if (expected == null || expected == _rows.length) {
      return const SizedBox.shrink();
    }
    final fewer = _rows.length < expected;
    return Container(
      width: double.infinity,
      color: Colors.orange.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 18, color: Colors.orange.shade800),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'You expected $expected designs, but the PDF parsed '
              '${_rows.length}. ${fewer ? 'A design may be missing' : 'There may be an extra row'} '
              '— review before saving.',
              style: TextStyle(fontSize: 12, color: Colors.orange.shade900),
            ),
          ),
        ],
      ),
    );
  }

  // ── Stats bar ─────────────────────────────────────────────────────────────

  Widget _buildStatsBar() {
    final updateCount = _rows.where((r) => r.isUpdate).length;
    final createCount = _rows.where((r) => !r.isUpdate).length;
    final totalBoxes  = _rows.fold(0, (s, r) => s + r.row.quantity);
    final imgCount   = _parsed?.imageCount   ?? 0;
    final rawLines   = _parsed?.rawLineCount ?? 0;
    final digitLines = _parsed?.digitLines   ?? 0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: Colors.white,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _stat('${_rows.length}', 'Designs', const Color(0xFF1B4F72)),
              _divider(),
              _stat('$updateCount', 'Update', const Color(0xFF2E7D32)),
              _divider(),
              _stat('$createCount', 'New', const Color(0xFF6A1B9A)),
              _divider(),
              _stat('$totalBoxes', 'Boxes', Colors.orange.shade700),
              _divider(),
              _stat('$imgCount', 'Photos', imgCount > 0 ? Colors.teal : Colors.red.shade300),
            ],
          ),
        ),
        // Debug row — shows raw text stats to diagnose parsing issues
        Container(
          width: double.infinity,
          color: Colors.grey.shade100,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            'Debug: $rawLines lines in PDF text · $digitLines start with digit',
            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  Widget _divider() =>
      Container(width: 1, height: 30, color: Colors.grey.shade200);

  Widget _stat(String value, String label, Color color) => Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: color)),
          Text(label,
              style: const TextStyle(fontSize: 9, color: Colors.grey)),
        ],
      );

  // ── Summary list ──────────────────────────────────────────────────────────

  Widget _buildSummaryList() {
    final updates = _rows.where((r) =>  r.isUpdate).toList();
    final creates = _rows.where((r) => !r.isUpdate).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      children: [
        // UPDATE section
        if (updates.isNotEmpty) ...[
          _sectionHeader(
            '${updates.length} designs — add to existing stock',
            Icons.add_circle_outline,
            const Color(0xFF2E7D32),
            const Color(0xFFE8F5E9),
          ),
          const SizedBox(height: 6),
          ...updates.map(_buildUpdateRow),
          const SizedBox(height: 14),
        ],

        // CREATE section
        if (creates.isNotEmpty) ...[
          _sectionHeader(
            '${creates.length} new designs — will be created',
            Icons.add_box_outlined,
            const Color(0xFF6A1B9A),
            const Color(0xFFF3E5F5),
          ),
          const SizedBox(height: 6),
          ...creates.map(_buildCreateRow),
        ],
      ],
    );
  }

  Widget _sectionHeader(
      String title, IconData icon, Color fg, Color bg) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: fg.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: fg)),
            ),
          ],
        ),
      );

  // Update row: existing stock + incoming boxes = new total
  // Tile photo shown for visual verification only. Priority: the photo extracted
  // from the PDF, else a shared-library photo auto-matched by name+size (loaded
  // lazily, small), else a placeholder (the stockist can add one later from the
  // design). Photo management happens inside the design on the edit screen.
  Widget _thumb(PdfDesignRow row) {
    final libUrl = row.imageBytes == null
        ? _libImages[designImageKey(row.name, _size)]
        : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 46,
        height: 46,
        child: row.imageBytes != null
            ? Image.memory(row.imageBytes!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => _thumbPlaceholder())
            : (libUrl != null
                ? CachedNetworkImage(
                    imageUrl: CloudinaryService.thumbUrl(libUrl, width: 120),
                    fit: BoxFit.cover,
                    placeholder: (_, __) => _thumbPlaceholder(),
                    errorWidget: (_, __, ___) => _thumbPlaceholder())
                : _thumbPlaceholder()),
      ),
    );
  }

  Widget _thumbPlaceholder() => Container(
        color: Colors.grey.shade100,
        alignment: Alignment.center,
        child: Icon(Icons.image_outlined, size: 18, color: Colors.grey.shade400),
      );

  Widget _buildUpdateRow(_Resolved r) => Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Row(
          children: [
            _thumb(r.row),
            const SizedBox(width: 10),
            Expanded(
              child: Text(r.row.name,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13),
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            Text('${r.match!.boxQuantity}',
                style: TextStyle(
                    fontSize: 12, color: Colors.grey.shade600)),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Icon(Icons.add, size: 14, color: Color(0xFF2E7D32)),
            ),
            Text('${r.row.quantity}',
                style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF2E7D32),
                    fontWeight: FontWeight.bold)),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Icon(Icons.arrow_forward, size: 14, color: Colors.grey),
            ),
            Text('${r.newTotal} boxes',
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1B4F72))),
          ],
        ),
      );

  // Create row: new design with editable surface chip
  Widget _buildCreateRow(_Resolved r) => Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Row(
          children: [
            _thumb(r.row),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Tap the name to correct a mis-extracted design name.
                  GestureDetector(
                    onTap: () => _editName(r.row),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(r.row.name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 13),
                              overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.edit,
                            size: 11, color: Colors.grey.shade500),
                      ],
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text('${r.row.quantity} boxes',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade600)),
                  // The stockist's own finish wording straight from the PDF, so
                  // they can compare it against the mapped admin finish (chip).
                  if (_pdfFinishOf(r.row) != null) ...[
                    const SizedBox(height: 2),
                    Text('PDF finish: ${_pdfFinishOf(r.row)}',
                        style: const TextStyle(
                            fontSize: 11,
                            fontStyle: FontStyle.italic,
                            color: Color(0xFF6A1B9A)),
                        overflow: TextOverflow.ellipsis),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Mapped admin finish — tap to change.
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Text('Standard finish',
                    style: TextStyle(fontSize: 9, color: Colors.grey)),
                const SizedBox(height: 2),
                GestureDetector(
                  onTap: () => _pickSurface(r.row),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6A1B9A).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: const Color(0xFF6A1B9A).withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(r.row.surface,
                            style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF6A1B9A),
                                fontWeight: FontWeight.w600)),
                        const SizedBox(width: 4),
                        const Icon(Icons.edit,
                            size: 10, color: Color(0xFF6A1B9A)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );

  // Surface picker bottom sheet for new designs
  Future<void> _pickSurface(PdfDesignRow row) async {
    await showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSurface) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              margin: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Text('Select Surface Type',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            const Divider(height: 1),
            ..._finishes.map((s) => ListTile(
                  title: Text(s),
                  trailing: row.surface == s
                      ? const Icon(Icons.check_rounded,
                          color: Color(0xFF6A1B9A))
                      : null,
                  onTap: () {
                    setState(() => row.surface = s);
                    Navigator.pop(ctx);
                  },
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // Edit a new design's name before import (corrects mis-extracted names).
  Future<void> _editName(PdfDesignRow row) async {
    final ctrl = TextEditingController(text: row.name);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit design name'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(isDense: true),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    disposeAfterFrame([ctrl]);
    final name = result?.trim();
    if (name != null && name.isNotEmpty) setState(() => row.name = name);
  }

  // ── Bottom bar ────────────────────────────────────────────────────────────

  Widget _buildBottomBar() {
    final total = _rows.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Colors.grey.withValues(alpha: 0.2), blurRadius: 8),
        ],
      ),
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: ElevatedButton.icon(
          onPressed: (_importing || total == 0) ? null : _confirm,
          icon: _importing
              ? const SizedBox(
                  width: 18, height: 18,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2))
              : const Icon(Icons.check_circle_outline),
          label: Text(
            _importing
                ? 'Processing…'
                : total == 0
                    ? 'No designs found in PDF'
                    : 'Confirm All ($total designs)',
            style: const TextStyle(fontSize: 15),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1B4F72),
            foregroundColor: Colors.white,
            disabledBackgroundColor: Colors.grey.shade300,
          ),
        ),
      ),
    );
  }
}
