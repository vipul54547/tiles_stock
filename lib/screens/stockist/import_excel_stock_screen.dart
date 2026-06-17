import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' hide Border, BorderStyle;
import 'package:cached_network_image/cached_network_image.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../services/stock_service.dart';
import '../../models/tile_design.dart';
import '../../models/tile_size.dart';
import '../../models/stock_catalog.dart';
import '../../models/brand.dart';
import '../../models/library_entry.dart';
import '../../utils/finishes.dart';
import '../../utils/tile_sizes.dart';
import '../../utils/tile_types.dart';
import '../../models/choice_state.dart';

// Bulk stock import from an Excel (.xlsx) list — for stockists who keep a plain
// spreadsheet (design, size, quality, boxes) instead of a PDF with images.
//
// Core idea ("image once, quantity many times"): a design is identified by
// Name + Size + Quality. A matched row just UPDATES the box quantity and reuses
// the design's existing photo — no image/PDF parsing. Unmatched rows are added
// as new designs (no photo, added later). Surface/Finish is OPTIONAL: aligned to
// the admin finishes after upload (Map Finishes), blank keeps the existing
// finish, and a finish that differs from the existing one is flagged as a
// conflict for the stockist to resolve.
class ImportExcelStockScreen extends StatefulWidget {
  /// Catalog chosen at the Upload tap; null falls back to the default public one.
  final String? initialCatalogId;
  const ImportExcelStockScreen({super.key, this.initialCatalogId});
  @override
  State<ImportExcelStockScreen> createState() => _ImportExcelStockScreenState();
}

// Header synonyms → the logical field. Matched case-insensitively against the
// sheet's header row, so a stockist's own column wording/order works.
const Map<String, List<String>> _headerSynonyms = {
  'name':     ['name', 'design', 'design name', 'designname', 'product', 'item', 'article'],
  'size':     ['size', 'tile size', 'dimension', 'dimensions'],
  'quality':  ['quality', 'grade', 'grd'],
  'qty':      ['qty', 'quantity', 'box', 'boxes', 'box qty', 'box quantity', 'stock', 'stock qty', 'no of box', 'nos', 'pcs box'],
  'surface':  ['surface', 'finish', 'surface type', 'finish type', 'surface finish'],
  'tiletype': ['tile type', 'type', 'body', 'body type', 'tiletype'],
  'weight':   ['weight', 'box weight', 'box weight (kg)', 'weight kg', 'wt', 'weight/box'],
  'pieces':   ['pieces', 'pieces/box', 'pcs', 'pcs/box', 'pieces per box', 'piece', 'pc'],
  'colour':   ['colour', 'color', 'shade'],
};

// One parsed spreadsheet row + its resolution against existing stock.
class _XlsRow {
  final int rowNum;
  String name, sizeRaw, qualityRaw, surfaceRaw, tileType, colour;
  int qty;
  int? pieces;
  double? weight;

  String? error;          // non-null → invalid, skipped from import
  String size = '';       // canonical master size (after validation)
  String quality = '';    // normalised 'Premium' | 'Standard'
  String surface = 'None'; // resolved admin finish (after Map Finishes)
  String rawKey = '';     // normalised raw surface for alias learning
  TileDesign? match;      // matched existing design (name+size+quality)
  String action = 'skip'; // 'update' | 'new' | 'conflict' | 'skip'
  bool conflictAsNew = false; // conflict: true=add as new design, false=correct finish
  bool include = true;    // unchecked = excluded from import

  _XlsRow({
    required this.rowNum,
    required this.name,
    required this.sizeRaw,
    required this.qualityRaw,
    required this.surfaceRaw,
    required this.tileType,
    required this.colour,
    required this.qty,
    required this.pieces,
    required this.weight,
  });

  bool get valid => error == null;
}

class _ImportExcelStockScreenState extends State<ImportExcelStockScreen> {
  final _dataSvc = SupabaseDataService();
  final _stockSvc = StockService();

  List<_XlsRow> _rows = [];
  // This stockist's OWN Design Library photos matched for the preview
  // (name+size → url), scoped to the target list's brand. Excel carries no
  // images, so this is the only photo per row; never borrows across stockists.
  Map<String, String> _libImages = {};
  List<LibraryEntry> _library = []; // this stockist's own master designs
  String? _defaultBrandId;
  bool _parsed = false;
  bool _importing = false;
  bool _loading = false;
  String _filename = '';
  String _blockError = ''; // header / file-level problem
  int _done = 0;

  // Admin config + this stockist's data.
  List<String> _finishes = kFinishes;
  List<String> _sizes = kAllowedSizes;
  List<TileSize> _tileSizes = []; // full size rows (with inch/feet aliases)
  List<StockCatalog> _catalogs = []; // stockist's catalogs (upload target)
  String? _catalogId; // chosen target catalog
  Map<String, String> _aliases = {};
  List<TileDesign> _existing = [];
  List<Brand> _brands = []; // for labelling each list with its brand

  // A catalogue's brand name (multi-brand), so the target picker is unambiguous.
  String _brandNameOf(StockCatalog c) {
    final m = _brands.where((b) => b.id == c.brandId).toList();
    return m.isEmpty ? '' : m.first.name;
  }

  @override
  void initState() {
    super.initState();
    _catalogId = widget.initialCatalogId; // chosen at the Upload tap
  }

  void _snack(String m, [Color? c]) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), backgroundColor: c));

  // ── Pick & parse ───────────────────────────────────────────────────────────

  Future<void> _pickAndParse() async {
    final res = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['xlsx'], withData: true);
    if (res == null || res.files.single.bytes == null) return;
    _filename = res.files.single.name;
    setState(() { _loading = true; _blockError = ''; });
    await _loadConfig();
    await _parseBytes(res.files.single.bytes!);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadConfig() async {
    try {
      final types = await _dataSvc.getSurfaceTypes(activeOnly: true);
      final names = types.map((t) => t.name).toList();
      final tileSizes = await _dataSvc.getTileSizes(activeOnly: true);
      final sizeNames = tileSizes.map((s) => s.name).toList();
      _aliases = currentStockistUUID.isEmpty
          ? {}
          : await _dataSvc.getSurfaceAliases(currentStockistUUID);
      _existing = currentStockistUUID.isEmpty
          ? []
          : await _dataSvc.getDesignsByStockist(currentStockistUUID);
      final catalogs = currentStockistUUID.isEmpty
          ? <StockCatalog>[]
          : await _dataSvc.getCatalogs(currentStockistUUID);
      final brands = currentStockistUUID.isEmpty
          ? <Brand>[]
          : await _dataSvc.getMyBrands();
      _brands = brands;
      _library = currentStockistUUID.isEmpty
          ? <LibraryEntry>[]
          : await _dataSvc.getMyLibrary();
      final def = brands.where((b) => b.isDefault).toList();
      _defaultBrandId = def.isEmpty ? null : def.first.id;
      if (names.isNotEmpty) _finishes = names;
      if (sizeNames.isNotEmpty) _sizes = sizeNames;
      _tileSizes = tileSizes;
      _catalogs = catalogs.where((c) => c.isActive).toList();
      _catalogId ??= _defaultCatalogId();
    } catch (_) {/* keep fallbacks */}
  }

  // Brand the import writes to: the chosen list's brand, else the default brand.
  String? get _uploadBrandId {
    for (final c in _catalogs) {
      if (c.id == _catalogId) return c.brandId ?? _defaultBrandId;
    }
    return _defaultBrandId;
  }

  // (name+size → own image url) map from this stockist's library for the target
  // list's brand, across all sizes present. Keyed by [designImageKey]; includes
  // the master name and the brand alias so a row matches whichever name was used.
  // Never borrows another stockist's photo.
  Map<String, String> _ownLibImages() {
    final brand = _uploadBrandId;
    final out = <String, String>{};
    for (final e in _library) {
      if (e.imageUrl.isEmpty) continue;
      final names = <String>{e.masterName};
      final alias = brand == null ? null : e.aliases[brand];
      if (alias != null && alias.isNotEmpty) names.add(alias);
      for (final n in names) {
        out[designImageKey(n, e.size)] = e.imageUrl;
      }
    }
    return out;
  }

  // Default import target: first active public catalog, else the first.
  String? _defaultCatalogId() {
    for (final c in _catalogs) {
      if (!c.isPrivate) return c.id;
    }
    return _catalogs.isEmpty ? null : _catalogs.first.id;
  }

  String _normHeader(String h) =>
      h.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  String _sizeKey(String s) => s.toLowerCase().replaceAll(RegExp(r'[^0-9x]'), '');

  // 'PRE'/'premium' → Premium, 'std'/'economy' → Standard, else '' (unknown).
  String _normQuality(String raw) {
    final q = raw.trim().toLowerCase();
    if (q.isEmpty) return '';
    if (q.startsWith('prem') || q == 'pre' || q == 'prm') return 'Premium';
    if (q.startsWith('stand') || q == 'std' || q == 'eco' || q == 'economy') {
      return 'Standard';
    }
    return ''; // unrecognised
  }

  int? _toInt(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    return int.tryParse(t) ?? double.tryParse(t)?.round();
  }

  double? _toDouble(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }

  Future<void> _parseBytes(List<int> bytes) async {
    final Excel book;
    try {
      book = Excel.decodeBytes(bytes);
    } catch (e) {
      setState(() => _blockError = 'Could not read the Excel file.');
      return;
    }
    if (book.tables.isEmpty) {
      setState(() => _blockError = 'The file has no sheets.');
      return;
    }
    final sheet = book.tables[book.tables.keys.first]!;
    if (sheet.rows.isEmpty) {
      setState(() => _blockError = 'The sheet is empty.');
      return;
    }

    // Detect each logical column by header synonym.
    final header =
        sheet.rows.first.map((c) => _normHeader(c?.value?.toString() ?? '')).toList();
    final colOf = <String, int>{};
    _headerSynonyms.forEach((field, syns) {
      colOf[field] = header.indexWhere((h) => syns.contains(h));
    });

    // Required columns must be present.
    final missing = ['name', 'size', 'quality', 'qty']
        .where((f) => (colOf[f] ?? -1) < 0)
        .toList();
    if (missing.isNotEmpty) {
      final names = {
        'name': 'Design Name', 'size': 'Size',
        'quality': 'Quality', 'qty': 'Box Quantity',
      };
      setState(() => _blockError =
          'Missing required column(s): ${missing.map((m) => names[m]).join(', ')}.'
          '\nAdd a header row with these columns and try again.');
      return;
    }

    String cell(List<Data?> row, String field) {
      final i = colOf[field] ?? -1;
      if (i < 0 || i >= row.length) return '';
      return row[i]?.value?.toString().trim() ?? '';
    }

    final parsed = <_XlsRow>[];
    for (var r = 1; r < sheet.rows.length; r++) {
      final row = sheet.rows[r];
      final blank = row.every((c) =>
          c == null || c.value == null || c.value.toString().trim().isEmpty);
      if (blank) continue;
      parsed.add(_XlsRow(
        rowNum: r + 1,
        name: cell(row, 'name'),
        sizeRaw: cell(row, 'size'),
        qualityRaw: cell(row, 'quality'),
        surfaceRaw: cell(row, 'surface'),
        tileType: cell(row, 'tiletype'),
        colour: cell(row, 'colour'),
        qty: _toInt(cell(row, 'qty')) ?? -1,
        pieces: _toInt(cell(row, 'pieces')),
        weight: _toDouble(cell(row, 'weight')),
      ));
    }

    if (parsed.isEmpty) {
      setState(() => _blockError = 'No data rows found (only a header?).');
      return;
    }

    _validateAndResolve(parsed);

    // Map any finishes present in the file to admin finishes before computing
    // conflicts (blank-finish rows skip this).
    final ok = await _mapFinishesStep(parsed);
    if (!ok) return; // cancelled

    _computeActions(parsed);

    // Auto-match this stockist's OWN library photos by name+size so the preview
    // shows a picture for each row (Excel carries none). Local lookup; thumbnails
    // load lazily for visible rows. Never borrows another stockist's photo.
    setState(() {
      _rows = parsed; _parsed = true; _done = 0; _libImages = _ownLibImages();
    });
  }

  // Validate required fields/values; align each finish to an admin finish.
  void _validateAndResolve(List<_XlsRow> rows) {
    for (final r in rows) {
      if (r.name.isEmpty) { r.error = 'Missing design name'; continue; }
      if (r.sizeRaw.isEmpty) { r.error = 'Missing size'; continue; }
      // Map any inch/feet trade name (12x18, 2x4 …) to its canonical mm size via
      // the admin alias list; else fall back to a direct mm match.
      final sz = resolveCanonicalSize(r.sizeRaw, _tileSizes) ??
          _sizes.firstWhere(
              (s) => _sizeKey(s) == _sizeKey(r.sizeRaw),
              orElse: () => '');
      if (sz.isEmpty) { r.error = "Size '${r.sizeRaw}' is not in your size list"; continue; }
      r.size = sz;
      if (r.qualityRaw.isEmpty) { r.error = 'Missing quality'; continue; }
      final q = _normQuality(r.qualityRaw);
      if (q.isEmpty) { r.error = "Unknown quality '${r.qualityRaw}'"; continue; }
      r.quality = q;
      if (r.qty < 0) { r.error = 'Missing / invalid box quantity'; continue; }

      // Align finish via learned alias (only matters when a finish is given).
      if (r.surfaceRaw.trim().isNotEmpty) {
        r.rawKey = normalizeSurfaceRaw(r.surfaceRaw);
        final aliased = _aliases[r.rawKey];
        if (aliased != null && _finishes.contains(aliased)) {
          r.surface = aliased;
        } else if (_finishes.contains(r.surfaceRaw.trim())) {
          r.surface = r.surfaceRaw.trim();
        } else {
          r.surface = _finishes.contains('None') ? 'None' : (_finishes.isNotEmpty ? _finishes.first : 'None');
        }
      }
    }
  }

  // Match by Name + Size + Quality; decide update / new / conflict.
  void _computeActions(List<_XlsRow> rows) {
    for (final r in rows) {
      if (!r.valid) { r.action = 'skip'; continue; }
      final needle = r.name.trim().toLowerCase();
      final matches = _existing.where((d) =>
          d.name.trim().toLowerCase() == needle &&
          _sizeKey(d.size) == _sizeKey(r.size) &&
          d.quality == r.quality).toList();
      final hasFinish = r.surfaceRaw.trim().isNotEmpty;
      if (matches.isEmpty) {
        r.match = null;
        r.action = 'new';
        if (!hasFinish) r.surface = _finishes.contains('None') ? 'None' : r.surface;
      } else {
        r.match = matches.first;
        if (!hasFinish) {
          r.surface = r.match!.surfaceType; // blank = keep existing
          r.action = 'update';
        } else if (r.surface == r.match!.surfaceType) {
          r.action = 'update';
        } else {
          r.action = 'conflict'; // finish differs from existing
        }
      }
    }
  }

  // ── Map Finishes (only for finishes actually present in the file) ───────────

  Future<bool> _mapFinishesStep(List<_XlsRow> rows) async {
    final groups = <String, _FinishGroup>{}; // rawKey → group
    for (final r in rows) {
      if (!r.valid || r.surfaceRaw.trim().isEmpty) continue;
      final initial = _finishes.contains(r.surface)
          ? r.surface
          : (_finishes.isNotEmpty ? _finishes.first : r.surface);
      final g = groups.putIfAbsent(
          r.rawKey, () => _FinishGroup(label: r.surfaceRaw.trim(), choice: initial));
      g.count++;
    }
    if (groups.isEmpty) return true; // nothing to map

    final keys = groups.keys.toList();
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
                    'Match each finish from your file to a standard finish. '
                    'Applies to every design with that finish.',
                    style: TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: keys.map((k) {
                        final g = groups[k]!;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 5,
                                child: Text('${g.label}  (${g.count})',
                                    style: const TextStyle(fontSize: 13)),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                flex: 5,
                                child: DropdownButton<String>(
                                  isExpanded: true,
                                  value: _finishes.contains(g.choice)
                                      ? g.choice
                                      : _finishes.first,
                                  items: _finishes
                                      .map((f) => DropdownMenuItem(
                                          value: f, child: Text(f)))
                                      .toList(),
                                  onChanged: (v) =>
                                      setLocal(() => g.choice = v ?? g.choice),
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
                child: const Text('Apply')),
          ],
        ),
      ),
    );
    if (result != true) return false;
    // Apply each group's chosen finish to its rows.
    for (final r in rows) {
      if (!r.valid || r.surfaceRaw.trim().isEmpty) continue;
      final g = groups[r.rawKey];
      if (g != null) r.surface = g.choice;
    }
    return true;
  }

  // ── Import ───────────────────────────────────────────────────────────────

  Future<void> _startImport() async {
    if (currentStockistUUID.isEmpty) { _snack('Session error — login again.', Colors.red); return; }
    final toDo = _rows.where((r) => r.valid && r.include).toList();
    if (toDo.isEmpty) { _snack('Nothing to import.'); return; }

    setState(() { _importing = true; _done = 0; });
    int updated = 0, created = 0, finishFixed = 0, imagesFromLibrary = 0;
    final learned = <String, String>{};

    // Excel carries no photos — fill them from THIS stockist's own Design Library
    // (by the target brand's design name / master name + size). Never borrows.
    final libImages = _ownLibImages();

    for (final r in toDo) {
      final libUrl = libImages[designImageKey(r.name, r.size)];
      final addAsNew = r.action == 'new' || (r.action == 'conflict' && r.conflictAsNew);
      if (addAsNew) {
        final newId = await _dataSvc.addDesign(
          stockistUUID: currentStockistUUID,
          name: r.name,
          size: r.size,
          surfaceType: r.surface,
          quality: r.quality,
          colour: r.colour,
          stockType: 'None',
          boxQuantity: 0,
          piecesPerBox: r.pieces ?? 0,
          boxWeightKg: r.weight ?? 0,
          thicknessMm: approxThicknessMm(
                  r.size, r.pieces ?? 0, r.weight ?? 0,
                  kTileTypes.contains(r.tileType) ? r.tileType : kTileTypes.first) ??
              0,
          tileType: kTileTypes.contains(r.tileType) ? r.tileType : '',
          faceImageUrls: libUrl != null ? [libUrl] : const [],
          finishLabel: r.surfaceRaw.trim().isEmpty ? null : r.surfaceRaw.trim(),
          catalogId: _catalogId,
        );
        if (newId != null) {
          if (libUrl != null) imagesFromLibrary++;
          final ok = await _stockSvc.addStock(
            designId: newId, stockistUUID: currentStockistUUID,
            quantity: r.qty, pdfFilename: _filename, size: r.size, quality: r.quality);
          if (ok) created++;
        }
      } else {
        // Update existing: correct the finish if the stockist chose to, then
        // add the new stock quantity (image + history preserved).
        if (r.action == 'conflict' && !r.conflictAsNew &&
            r.surface != r.match!.surfaceType) {
          await _dataSvc.updateDesign(r.match!.id, {'surface_type': r.surface});
          finishFixed++;
        }
        // Backfill a photo from the library if this design still has none.
        if (libUrl != null && r.match!.faceImageUrls.isEmpty) {
          await _dataSvc.updateDesign(r.match!.id, {'face_image_urls': [libUrl]});
          imagesFromLibrary++;
        }
        final ok = await _stockSvc.addStock(
          designId: r.match!.id, stockistUUID: currentStockistUUID,
          quantity: r.qty, pdfFilename: _filename, size: r.size, quality: r.quality);
        if (ok) updated++;
      }
      // Remember the finish wording → chosen finish for next time.
      if (r.rawKey.isNotEmpty && r.surface != 'None') learned[r.rawKey] = r.surface;
      setState(() => _done++);
    }

    for (final e in learned.entries) {
      await _dataSvc.upsertSurfaceAlias(currentStockistUUID, e.key, e.value);
    }

    if (!mounted) return;
    setState(() => _importing = false);
    final fixNote = finishFixed > 0 ? ' · $finishFixed finish corrected' : '';
    final libNote =
        imagesFromLibrary > 0 ? ' · $imagesFromLibrary photos from library' : '';
    StockCatalog? cat;
    for (final c in _catalogs) {
      if (c.id == _catalogId) { cat = c; break; }
    }
    final catNote = cat == null ? '' : ' → "${cat.name}"';
    _snack('Done — $updated updated, $created new$fixNote$libNote$catNote.',
        Colors.green);
    if (updated + created > 0) Navigator.of(context).pop();
  }

  void _reset() => setState(() {
        _rows = []; _parsed = false; _blockError = ''; _done = 0; _filename = ''; _libImages = {};
      });

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Import Stock from Excel'),
        actions: [
          if (_parsed)
            TextButton.icon(
              onPressed: _importing ? null : _reset,
              icon: const Icon(Icons.refresh, color: Colors.white),
              label: const Text('Reset', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _parsed
              ? _buildReview()
              : _buildIntro(),
    );
  }

  Widget _buildIntro() => SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: [Color(0xFF1B4F72), Color(0xFF2E86C1)]),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.table_view_rounded, color: Colors.white, size: 36),
                  SizedBox(height: 8),
                  Text('Import stock list',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.bold)),
                  SizedBox(height: 4),
                  Text('Upload an .xlsx with your designs. Matched designs get '
                      'their box quantity updated (photo kept); new ones are '
                      'added without a photo (add it later).',
                      style: TextStyle(color: Colors.white70, fontSize: 12.5)),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const Text('Columns',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 8),
            _colTable(),
            if (_blockError.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFEBEE),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Text(_blockError,
                    style: TextStyle(color: Colors.red.shade800, fontSize: 12.5)),
              ),
            ],
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: OutlinedButton.icon(
                onPressed: _pickAndParse,
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('Browse & Pick Excel (.xlsx)',
                    style: TextStyle(fontSize: 15)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF1B4F72),
                  side: const BorderSide(color: Color(0xFF1B4F72), width: 1.5),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _colTable() {
    const cols = [
      ('Design Name', 'required', true),
      ('Size', 'required — must match your sizes', true),
      ('Quality', 'required — Premium / Standard', true),
      ('Box Quantity', 'required — the boxes to add', true),
      ('Surface / Finish', 'optional — mapped after upload', false),
      ('Tile Type', 'optional', false),
      ('Box Weight', 'optional — for thickness', false),
      ('Pieces/Box', 'optional — for sq.ft', false),
      ('Colour', 'optional', false),
    ];
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade200),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: cols
            .map((c) => Container(
                  decoration: BoxDecoration(
                      border:
                          Border(top: BorderSide(color: Colors.grey.shade100))),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  child: Row(
                    children: [
                      Expanded(
                          flex: 4,
                          child: Text(c.$1,
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF1B4F72),
                                  fontWeight: FontWeight.w600))),
                      Expanded(
                          flex: 6,
                          child: Text(c.$2,
                              style: const TextStyle(fontSize: 11))),
                      SizedBox(
                        width: 58,
                        child: c.$3
                            ? const Icon(Icons.check_circle_rounded,
                                color: Color(0xFF2E7D32), size: 16)
                            : Text('optional',
                                style: TextStyle(
                                    fontSize: 9, color: Colors.grey.shade500)),
                      ),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
  }

  Widget _buildReview() {
    final updates = _rows.where((r) => r.valid && r.action == 'update').length;
    final news = _rows.where((r) => r.valid && r.action == 'new').length;
    final conflicts = _rows.where((r) => r.valid && r.action == 'conflict').length;
    final skipped = _rows.where((r) => !r.valid).length;
    final willImport = _rows.where((r) => r.valid && r.include).length;
    final allDone = !_importing && _done > 0 && _done >= willImport;

    return Column(
      children: [
        // Which catalog this import goes into (only when there's a choice).
        if (_catalogs.length > 1)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                const Text('Add to: ', style: TextStyle(fontSize: 12)),
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: _catalogId,
                    items: _catalogs
                        .map((c) => DropdownMenuItem(
                            value: c.id,
                            child: Text(
                                '${_brands.length > 1 && _brandNameOf(c).isNotEmpty ? '${_brandNameOf(c)} · ' : ''}${c.name}${c.isPrivate ? '  (private)' : ''}',
                                style: const TextStyle(fontSize: 13))))
                        .toList(),
                    onChanged: _importing
                        ? null
                        : (v) => setState(() {
                              _catalogId = v ?? _catalogId;
                              // Switching list may switch brand → refresh which
                              // own-library photos apply.
                              _libImages = _ownLibImages();
                            }),
                  ),
                ),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: const Color(0xFF1B4F72).withValues(alpha: 0.06),
          child: Row(
            children: [
              _chip('$updates', 'Update', const Color(0xFF1B4F72)),
              const SizedBox(width: 10),
              _chip('$news', 'New', const Color(0xFF2E7D32)),
              if (conflicts > 0) ...[
                const SizedBox(width: 10),
                _chip('$conflicts', 'Conflict', Colors.orange.shade800),
              ],
              if (skipped > 0) ...[
                const SizedBox(width: 10),
                _chip('$skipped', 'Skipped', Colors.red),
              ],
              const Spacer(),
              if (_importing)
                Text('$_done/$willImport',
                    style: const TextStyle(fontWeight: FontWeight.bold))
              else if (allDone)
                const Icon(Icons.check_circle_rounded,
                    color: Color(0xFF2E7D32))
              else
                ElevatedButton.icon(
                  onPressed: willImport > 0 ? _startImport : null,
                  icon: const Icon(Icons.upload_rounded, size: 16),
                  label: Text('Import $willImport'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1B4F72),
                      foregroundColor: Colors.white),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.fromLTRB(
                12, 12, 12, 12 + MediaQuery.viewPaddingOf(context).bottom),
            itemCount: _rows.length,
            itemBuilder: (_, i) => _rowCard(_rows[i]),
          ),
        ),
      ],
    );
  }

  Widget _chip(String v, String l, Color c) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(v,
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: c)),
          Text(l, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      );

  // Auto-matched shared-library photo for this row (by name+size), loaded lazily
  // and small; a placeholder when no library photo exists yet.
  Widget _libThumb(_XlsRow r) {
    final url = _libImages[designImageKey(r.name, r.size)];
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 40,
        height: 40,
        child: url != null
            ? CachedNetworkImage(
                imageUrl: CloudinaryService.thumbUrl(url, width: 120),
                fit: BoxFit.cover,
                placeholder: (_, __) => _thumbPlaceholder(),
                errorWidget: (_, __, ___) => _thumbPlaceholder())
            : _thumbPlaceholder(),
      ),
    );
  }

  Widget _thumbPlaceholder() => Container(
        color: Colors.grey.shade100,
        alignment: Alignment.center,
        child: Icon(Icons.image_outlined, size: 16, color: Colors.grey.shade400),
      );

  Widget _rowCard(_XlsRow r) {
    final Color border, bg;
    String tag;
    Color tagColor;
    if (!r.valid) {
      border = Colors.red.shade200; bg = const Color(0xFFFFEBEE);
      tag = 'SKIP'; tagColor = Colors.red;
    } else if (r.action == 'conflict') {
      border = Colors.orange.shade300; bg = const Color(0xFFFFF3E0);
      tag = 'CONFLICT'; tagColor = Colors.orange.shade800;
    } else if (r.action == 'new') {
      border = Colors.green.shade200; bg = const Color(0xFFE8F5E9);
      tag = 'NEW'; tagColor = const Color(0xFF2E7D32);
    } else {
      border = Colors.blue.shade100; bg = const Color(0xFFE3F2FD);
      tag = 'UPDATE'; tagColor = const Color(0xFF1B4F72);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (r.valid) ...[ _libThumb(r), const SizedBox(width: 8) ],
              if (r.valid)
                Checkbox(
                  value: r.include,
                  visualDensity: VisualDensity.compact,
                  onChanged: _importing
                      ? null
                      : (v) => setState(() => r.include = v ?? true),
                ),
              Expanded(
                child: Text(r.name.isEmpty ? '(no name)' : r.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
                    overflow: TextOverflow.ellipsis),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: tagColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(tag,
                    style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: tagColor)),
              ),
              const SizedBox(width: 6),
              Text('Row ${r.rowNum}',
                  style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            [
              if (r.size.isNotEmpty) r.size else r.sizeRaw,
              if (r.quality.isNotEmpty) r.quality else r.qualityRaw,
              if (r.qty >= 0) '${r.qty} boxes',
              if (r.surfaceRaw.trim().isNotEmpty) r.surface,
            ].join('  ·  '),
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
          if (!r.valid) ...[
            const SizedBox(height: 4),
            Text(r.error!,
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.red.shade700,
                    fontWeight: FontWeight.w600)),
          ],
          if (r.valid && r.action == 'conflict') ...[
            const SizedBox(height: 6),
            Text(
                'Exists as "${r.match!.surfaceType}", your file says "${r.surface}".',
                style: TextStyle(fontSize: 11, color: Colors.orange.shade900)),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: _conflictChoice(r, false,
                      'Correct finish', '→ ${r.surface}'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _conflictChoice(r, true,
                      'Different design', 'add as new'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _conflictChoice(_XlsRow r, bool asNew, String title, String sub) {
    final selected = r.conflictAsNew == asNew;
    return GestureDetector(
      onTap: _importing ? null : () => setState(() => r.conflictAsNew = asNew),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1B4F72) : Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: selected ? const Color(0xFF1B4F72) : Colors.grey.shade300),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: selected ? Colors.white : Colors.black87)),
            Text(sub,
                style: TextStyle(
                    fontSize: 10,
                    color: selected ? Colors.white70 : Colors.grey)),
          ],
        ),
      ),
    );
  }
}

class _FinishGroup {
  final String label;
  String choice;
  int count = 0;
  _FinishGroup({required this.label, required this.choice});
}
