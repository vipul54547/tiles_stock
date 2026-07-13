import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../services/pdf_import_service.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../models/tile_design.dart';
import '../../models/tile_size.dart';
import '../../models/stock_catalog.dart';
import '../../models/brand.dart';
import '../../models/library_entry.dart';
import '../../models/choice_state.dart';
import '../../utils/tile_sizes.dart';
import '../../utils/tile_types.dart';
import '../../utils/finishes.dart';
import '../../utils/dispose_after_frame.dart';

// Quality grades a stockist can assign to an uploaded batch.
const List<String> kQualities = ['Standard', 'Premium'];

// Design Stock Type = a design's FUTURE-availability outlook (can this same design
// be re-ordered again later?). Quality gates the options: Standard/seconds can never
// be 'Continuous' (not reliably reproduced). Default is always 'Uncertain'.
const List<String> _premiumStockTypes    = ['Continuous', 'One Time', 'Uncertain'];
const List<String> _nonPremiumStockTypes = ['One Time', 'Uncertain'];
List<String> stockTypesForQuality(String quality) =>
    quality == 'Premium' ? _premiumStockTypes : _nonPremiumStockTypes;

// ── Resolved row ─────────────────────────────────────────────────────────────
// Produced after matching PDF rows to existing designs.

class _Resolved {
  final PdfDesignRow row;
  final TileDesign? match; // non-null → update existing; null → create new
  String rawKey;           // normalised original PDF finish word (for learning).
  // Mutable: a single-surface PDF carries no finish word, so the stockist may
  // type their own in the Map-Finishes step, which becomes the key to learn.

  String? uploadedUrl; // cached Cloudinary URL so a retry never re-uploads.

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
  /// Catalog chosen at the Upload tap (Public / Most Exclusive). Pre-selects the
  /// upload target; null falls back to the default public catalog.
  final String? initialCatalogId;
  const UploadStockScreen({super.key, this.initialCatalogId});
  @override
  State<UploadStockScreen> createState() => _State();
}

class _State extends State<UploadStockScreen> {
  final _pdfService  = PdfImportService();
  final _dataSvc     = SupabaseDataService();
  String _batchId    = ''; // idempotency key per parsed PDF (reused on retry)

  PdfImportResult?   _parsed;
  List<_Resolved>    _rows      = [];
  // This stockist's OWN Design Library photos matched for the preview
  // (name+size → url, scoped to the upload brand). Shown as the thumbnail for
  // rows the PDF carried no image for; never borrows another stockist's photo.
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
  String _tileType     = tileTypeNames.first;
  double _boxWeightKg  = 0;
  int    _piecesPerBox = 0;
  String _stockType    = 'Uncertain'; // gated by quality (whole batch); default Uncertain

  // Admin's live master finish list + this stockist's learned aliases. Loaded
  // once so every parsed row can be aligned to an official finish (and the
  // surface picker offers exactly the admin's finishes, not a hardcoded list).
  List<String>        _finishes = kFinishes;     // fallback until loaded
  List<String>        _sizes    = kAllowedSizes;  // admin master, loaded once
  List<TileSize>      _tileSizes = [];           // full size rows (with aliases)
  List<StockCatalog>  _catalogs  = [];           // default-brand stock lists only
  String?             _catalogId;                // chosen upload target catalog
  Map<String, String> _aliases  = {};            // normalisedRaw → finish name
  // Multi-brand: PDF upload is the DEFAULT brand's only ([[project_stockist_library]]
  // decision #5 — other brands import via Excel). The library + contributions are
  // scoped to this brand.
  String?             _defaultBrandId;
  List<LibraryEntry>  _library  = [];            // this stockist's own master designs
  // True when the screen was opened from a non-default brand's list — PDF isn't
  // allowed there, so we show a "use Excel" block instead of the picker.
  bool _brandBlocked = false;
  bool _configLoaded = false;
  // M stockists: a PDF builds the picture library only (no stock rows).
  bool _isM = false;

  // Brand the current upload writes to: the chosen list's brand, else default.
  String? get _uploadBrandId {
    for (final c in _catalogs) {
      if (c.id == _catalogId) return c.brandId ?? _defaultBrandId;
    }
    return _defaultBrandId;
  }

  @override
  void initState() {
    super.initState();
    _catalogId = widget.initialCatalogId; // chosen at the Upload tap
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
      final brands = currentStockistUUID.isEmpty
          ? <Brand>[]
          : await _dataSvc.getMyBrands();
      final library = currentStockistUUID.isEmpty
          ? <LibraryEntry>[]
          : await _dataSvc.getMyLibrary();
      final profile = await _dataSvc.getMyProfile();
      if (!mounted) return;
      _isM = (profile?['business_type'] ?? '').toString() == 'M';
      final defaultBrand = brands.where((b) => b.isDefault).toList();
      final defaultBrandId = defaultBrand.isEmpty ? null : defaultBrand.first.id;
      final active = catalogs.where((c) => c.isActive).toList();
      // PDF upload is the default brand's only. Restrict the target lists, and
      // flag a block when the screen was opened from another brand's list.
      bool isDefaultCat(StockCatalog c) =>
          c.brandId == null || c.brandId == defaultBrandId;
      final entry = active.where((c) => c.id == widget.initialCatalogId).toList();
      setState(() {
        if (names.isNotEmpty) _finishes = names;
        if (sizeNames.isNotEmpty) _sizes = sizeNames;
        _tileSizes = tileSizes;
        _defaultBrandId = defaultBrandId;
        _library = library;
        _catalogs = active.where(isDefaultCat).toList();
        _brandBlocked =
            entry.isNotEmpty && !isDefaultCat(entry.first);
        // Keep the chosen list only if it's a default-brand one; else default.
        if (_catalogId == null || !_catalogs.any((c) => c.id == _catalogId)) {
          _catalogId = _defaultCatalogId();
        }
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

  // A normalised size key so a library master at the same size matches even if
  // the stored format differs slightly (mirrors the Excel importer).
  String _sizeKey(String s) => s.toLowerCase().replaceAll(RegExp(r'[^0-9x]'), '');

  // Builds a (name+size → own image url) map from this stockist's library for the
  // current upload brand + size. Keyed by [designImageKey] so the existing row
  // lookups work unchanged. Includes both the master name and the brand alias so
  // a row matches whichever name the PDF used.
  Map<String, String> _ownLibImages() {
    final brand = _uploadBrandId;
    final out = <String, String>{};
    for (final e in _library) {
      if (e.imageUrl.isEmpty) continue;
      if (_sizeKey(e.size) != _sizeKey(_size)) continue;
      final names = <String>{e.masterName};
      final alias = brand == null ? null : e.aliases[brand];
      if (alias != null && alias.isNotEmpty) names.add(alias);
      for (final n in names) {
        out[designImageKey(n, _size)] = e.imageUrl;
      }
    }
    return out;
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

    // Reject rule: a design row with no name has no identity (name is the match
    // key), so it can't be imported. Drop those rows; reject the WHOLE PDF only
    // when nothing named remains.
    final beforeCount = parsed.designs.length;
    parsed.designs.removeWhere((d) => d.name.trim().isEmpty);
    final skippedNameless = beforeCount - parsed.designs.length;
    if (parsed.designs.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('No designs found'),
          content: const Text(
              'This PDF has no design names to import. A design needs a name — '
              'it identifies the tile. Please check the file and try again.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
      setState(() { _filename = ''; });
      return;
    }

    // Confirm size / quality / tile type / expected count before importing. The
    // filename only pre-fills size (when recognised); a wrong filename is caught
    // here rather than silently importing every design with the wrong details.
    final ok = await _confirmDetails(parsed, skippedNameless: skippedNameless);
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

    // Match each row against THIS stockist's own library (by the upload brand's
    // design name / master name + size) so the preview shows their own photo for
    // rows the PDF had no image for. Never borrows another stockist's photo.
    final lib = _ownLibImages();

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
      _batchId = const Uuid().v4(); // one idempotency key per parsed PDF
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

  // Confirm size + quality + tile type before importing. The hard-required
  // fields (size, quality, tile type) are shown EMPTY so a forgotten field is
  // never silently saved as a real value. Returns false if cancelled.
  Future<bool> _confirmDetails(PdfImportResult parsed,
      {int skippedNameless = 0}) async {
    // Pre-fill size ONLY when the filename's size is recognised; otherwise leave
    // it empty and force a conscious pick (no silent fallback-to-first).
    final resolved = resolveCanonicalSize(parsed.size, _tileSizes);
    final parsedSize = resolved ?? normaliseSize(parsed.size);
    String? size = _sizes.contains(parsedSize) ? parsedSize : null;
    String? quality;   // empty + required (Economy removed → Standard/Premium)
    String? tileType;  // empty + required (drives the thickness calc)
    String? stockType; // disabled until quality chosen, then soft Uncertain
    bool showErrors = false; // reveal red "Required" after a failed Continue
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
          // Red "Required" helper under a hard field still empty after a try.
          Widget reqError(bool show) => show
              ? Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('Required — please select',
                      style:
                          TextStyle(fontSize: 11, color: Colors.red.shade700)))
              : const SizedBox.shrink();
          return AlertDialog(
            title: const Text('Confirm Upload Details'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('File: $_filename',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  if (skippedNameless > 0) ...[
                    const SizedBox(height: 6),
                    Text(
                        '$skippedNameless row(s) had no design name and were skipped.',
                        style: TextStyle(
                            fontSize: 11, color: Colors.orange.shade800)),
                  ],
                  const SizedBox(height: 14),
                  // Which stock list this upload goes into — only when the
                  // stockist has more than one list.
                  if (_catalogs.length > 1) ...[
                    const Text('Add to stock list',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                    DropdownButton<String>(
                      isExpanded: true,
                      value: _catalogId,
                      items: _catalogs
                          .map((c) => DropdownMenuItem(
                              value: c.id, child: Text(c.name)))
                          .toList(),
                      onChanged: (v) =>
                          setLocal(() => _catalogId = v ?? _catalogId),
                    ),
                    const SizedBox(height: 12),
                  ],
                  // Size — HARD required (empty unless the filename was recognised)
                  const Text('Tile size',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: size,
                    hint: const Text('Select size (required)'),
                    items: _sizes
                        .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                        .toList(),
                    onChanged: (v) => setLocal(() => size = v),
                  ),
                  if (size == null && parsed.size.isNotEmpty)
                    Text('⚠ Filename size "${parsed.size}" not recognised — '
                        'please pick the correct size.',
                        style: TextStyle(
                            fontSize: 11, color: Colors.orange.shade800)),
                  reqError(showErrors && size == null),
                  const SizedBox(height: 12),
                  // Quality — HARD required, empty (Economy removed)
                  const Text('Quality',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: quality,
                    hint: const Text('Select quality (required)'),
                    items: kQualities
                        .map((q) =>
                            DropdownMenuItem(value: q, child: Text(q)))
                        .toList(),
                    onChanged: (v) => setLocal(() {
                      quality = v;
                      // Quality gates + UNLOCKS stock type; keep it valid and
                      // soft-default to Uncertain.
                      if (quality != null &&
                          (stockType == null ||
                              !stockTypesForQuality(quality!)
                                  .contains(stockType))) {
                        stockType = 'Uncertain';
                      }
                    }),
                  ),
                  reqError(showErrors && quality == null),
                  const SizedBox(height: 12),
                  // Tile type (body) — HARD required, empty
                  const Text('Tile type',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: tileType,
                    hint: const Text('Select tile type (required)'),
                    items: tileTypeNames
                        .map((t) =>
                            DropdownMenuItem(value: t, child: Text(t)))
                        .toList(),
                    onChanged: (v) => setLocal(() => tileType = v),
                  ),
                  reqError(showErrors && tileType == null),
                  const SizedBox(height: 12),
                  // Design Stock Type — soft default Uncertain, DISABLED until a
                  // quality is chosen (its options are quality-gated).
                  const Text('Design Stock Type',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: stockType,
                    hint: Text(quality == null
                        ? 'Select quality first'
                        : 'Select stock type'),
                    items: quality == null
                        ? const <DropdownMenuItem<String>>[]
                        : stockTypesForQuality(quality!)
                            .map((t) =>
                                DropdownMenuItem(value: t, child: Text(t)))
                            .toList(),
                    onChanged: quality == null
                        ? null
                        : (v) => setLocal(() => stockType = v ?? stockType),
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
                    // Needs size + tile type; both may still be empty
                    // (hard-required), so show nothing until they're set.
                    if (size == null || tileType == null) {
                      return const SizedBox(height: 6);
                    }
                    final sqft = sqftPerBox(size!, pcs);
                    final tRange = thicknessRangeLabel(size!, pcs, wt, tileType!);
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
                  // Hard-required fields must be chosen — reveal errors + block.
                  if (size == null || quality == null || tileType == null) {
                    setLocal(() => showErrors = true);
                    return;
                  }
                  _size = size!;
                  _quality = quality!;
                  _tileType = tileType!;
                  _stockType = stockType ?? 'Uncertain';
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

    // This stockist's OWN library photos (brand + size scoped), to fill rows
    // whose PDF carried no photo. Never borrows across stockists. Freshly
    // uploaded PDF photos are contributed back to the library on new-design adds.
    final libImages = _libImages;
    final brandId = _uploadBrandId;

    // ── Phase A: resolve images (non-transactional). Upload each PDF photo to
    // Cloudinary once (cached on the row so a retry never re-uploads), or fall
    // back to this stockist's own library photo. We only fetch a photo when the
    // row actually needs one — a new design, or an existing one with no image yet.
    Future<String?> resolveImage(_Resolved r) async {
      final needs = !r.isUpdate || r.match!.faceImageUrls.isEmpty;
      if (!needs) return null;
      if (r.uploadedUrl != null) return r.uploadedUrl;
      if (r.row.imageBytes != null) {
        setState(() => _loadingStep = 'Uploading image for ${r.row.name}…');
        final res = await CloudinaryService.uploadImageBytes(
          r.row.imageBytes!,
          filename: '${r.row.name.replaceAll(' ', '_')}.jpg',
        );
        if (res.ok) { imagesUploaded++; r.uploadedUrl = res.url; return res.url; }
        imagesFailed++; lastImageError = res.error; return null;
      }
      final libUrl = libImages[designImageKey(r.row.name, _size)];
      if (libUrl != null) imagesFromLibrary++;
      return libUrl;
    }

    final thick =
        approxThicknessMm(_size, _piecesPerBox, _boxWeightKg, _tileType) ?? 0;

    // ── Phase B: build ONE atomic batch payload. The DB find-or-creates each
    // design, adds stock and grows the Library (master + brand alias + photo,
    // first-writer-wins) in a single transaction — never a half-import, and a
    // reused batch id can't double-add on retry. design_id honours THIS screen's
    // (fuzzy) match so a previewed "update" stays an update.
    final rows = <Map<String, dynamic>>[];
    for (final r in _rows) {
      final url = await resolveImage(r);
      rows.add(<String, dynamic>{
        'name': r.row.name,
        'size': _size,
        'quality': _quality,
        'surface': r.row.surface,
        'surface_label': (r.row.surfaceRaw != null &&
                r.row.surfaceRaw!.trim().isNotEmpty)
            ? r.row.surfaceRaw!.trim()
            : r.row.surface,
        'qty': r.row.quantity,
        'stock_type': _stockType,
        'tile_type': _tileType,
        'pieces_per_box': _piecesPerBox,
        'box_weight_kg': _boxWeightKg,
        'thickness_mm': thick,
        if (url != null) 'image_url': url,
        if (r.row.finishLabel != null && r.row.finishLabel!.trim().isNotEmpty)
          'finish_label': r.row.finishLabel!.trim(),
        if (r.isUpdate) 'design_id': r.match!.id,
      });
    }

    setState(() => _loadingStep = 'Saving to your catalogue…');
    if (_batchId.isEmpty) _batchId = const Uuid().v4();
    try {
      final res = await _dataSvc.importStockBatch(
        batchId: _batchId,
        catalogId: _catalogId,
        brandId: brandId,
        pdfFilename: _filename,
        rows: rows,
        libraryOnly: _isM, // M PDF = build the picture library only, no stock
      );
      created = (res['created'] as num?)?.toInt() ?? 0;
      updated = (res['updated'] as num?)?.toInt() ?? 0;
    } catch (e) {
      if (!mounted) return;
      setState(() { _importing = false; _loadingStep = ''; });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Nothing was saved — $e. Please try again.'),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 6),
      ));
      return;
    }

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
    // Name the destination stock list so the stockist knows where it landed.
    StockCatalog? cat;
    for (final c in _catalogs) {
      if (c.id == _catalogId) { cat = c; break; }
    }
    final catNote = cat == null ? '' : '\nUploaded to "${cat.name}".';
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
      body: _brandBlocked
          ? _buildBrandBlocked()
          : (_loading || _importing)
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

  // ── Brand-blocked notice ──────────────────────────────────────────────────
  // PDF upload is the default brand's only ([[project_stockist_library]] #5).
  // When opened from another brand's list, send the stockist to Excel instead.
  Widget _buildBrandBlocked() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.picture_as_pdf_outlined,
                  size: 56, color: Colors.grey.shade400),
              const SizedBox(height: 16),
              const Text('PDF upload is for your main brand only',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              Text(
                'Other brands add stock by Excel — their photos come from your '
                'Design Library. Import an Excel list for this brand instead.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  context.push('/stockist/stock/import-excel',
                      extra: widget.initialCatalogId);
                },
                icon: const Icon(Icons.table_view_rounded),
                label: const Text('Import Excel instead'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2E7D32),
                    foregroundColor: Colors.white),
              ),
            ],
          ),
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
                  setState(() { _parsed = null; _rows = []; _filename = ''; _libImages = {}; _batchId = ''; }),
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
      // Add the system nav-bar inset so the button clears the Android nav
      // buttons under edge-to-edge (targetSdk 36). See edge-to-edge convention.
      padding: EdgeInsets.fromLTRB(
          16, 12, 16, 20 + MediaQuery.viewPaddingOf(context).bottom),
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
