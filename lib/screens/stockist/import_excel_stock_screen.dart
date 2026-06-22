import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import 'package:excel/excel.dart' hide Border, BorderStyle;
import 'package:cached_network_image/cached_network_image.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../models/tile_design.dart';
import '../../models/tile_size.dart';
import '../../models/brand.dart';
import '../../models/library_entry.dart';
import '../../models/dna.dart';
import '../../utils/finishes.dart';
import '../../utils/tile_sizes.dart';
import '../../utils/tile_types.dart';
import '../../models/choice_state.dart';

// Bulk stock import from an Excel (.xlsx) list — for stockists who keep a plain
// spreadsheet (design, size, quality, boxes) instead of a PDF with images.
//
// Core idea ("image once, quantity many times"): a stock line (P_Stock holding) is
// keyed by Name + Size + Quality + Surface. A row that matches all four UPDATES the
// box quantity and reuses the design's existing photo — no image/PDF parsing. Any
// row that doesn't match is added as a NEW holding (a different surface is simply a
// different stock line, never a "conflict"). Surface is aligned to the admin
// finishes first via Map Finishes (which also learns the alias).
class ImportExcelStockScreen extends StatefulWidget {
  /// Brand chosen at the Upload tap; upload fills P_Stock for this brand (lists are
  /// curated separately). Null falls back to the default brand.
  final String? initialBrandId;
  const ImportExcelStockScreen({super.key, this.initialBrandId});
  @override
  State<ImportExcelStockScreen> createState() => _ImportExcelStockScreenState();
}

// Header synonyms → the logical field. Matched case-insensitively against the
// sheet's header row, so a stockist's own column wording/order works.
const Map<String, List<String>> _headerSynonyms = {
  'name':     ['name', 'design', 'design name', 'designname', 'product', 'item', 'article'],
  'size':     ['size', 'tile size', 'dimension', 'dimensions'],
  'quality':  ['quality', 'qality', 'qualty', 'grade', 'grd'],
  'qty':      ['qty', 'quantity', 'box', 'boxes', 'box qty', 'box quantity', 'stock', 'stock qty', 'no of box', 'nos', 'pcs box'],
  'surface':  ['surface', 'finish', 'surface type', 'finish type', 'surface finish'],
  'tiletype': ['tile type', 'type', 'body', 'body type', 'tiletype'],
  'weight':   ['weight', 'box weight', 'box weight (kg)', 'weight kg', 'wt', 'weight/box'],
  'pieces':   ['pieces', 'pieces/box', 'pcs', 'pcs/box', 'pieces per box', 'piece', 'pc'],
  'colour':   ['colour', 'color', 'shade'],
};

// Combined sheet: a master-design column links the per-brand name columns. The
// brand columns themselves are matched by the brand's own name (not a synonym).
// Kept master-specific so it never clobbers the generic 'name' column above.
const List<String> _masterHeaders = [
  'master', 'master name', 'master design', 'master design name',
  'master_design', 'masterdesign',
];

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
  String action = 'skip'; // 'update' | 'new' | 'map' | 'skip'
  bool include = true;    // unchecked = excluded from import
  bool isNewDesign = false; // name+size not yet in the library (needs identity)
  // New design missing compulsory identity (tile type / pieces / weight) — blocks
  // Save until filled (in-app) or the row is excluded. Existing designs skip this.
  bool get needsFill =>
      isNewDesign &&
      (tileType.trim().isEmpty || (pieces ?? 0) <= 0 || (weight ?? 0) <= 0);
  // Combined sheet (brand-name columns): the per-brand names on this row and the
  // master name, written into the Library during the same import. mapOnly = the
  // chosen brand has no name here (tile not sold under it) → map, but no stock.
  Map<String, String> brandNames = {}; // brandId -> design name on this row
  String masterName = '';
  bool mapOnly = false;
  // Auto-detected Design DNA on this row: attributeId -> raw value words (a
  // column whose header matched a DNA attribute name). Resolved on import.
  Map<String, List<String>> dna = {};

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
  String _batchId = ''; // idempotency key per parsed file (reused on retry)

  List<_XlsRow> _rows = [];
  // This stockist's OWN Design Library photos matched for the preview
  // (name+size → url), scoped to the target list's brand. Excel carries no
  // images, so this is the only photo per row; never borrows across stockists.
  Map<String, String> _libImages = {};
  List<LibraryEntry> _library = []; // this stockist's own master designs
  final Set<String> _libKeys = {};  // name|size of existing library designs (+aliases)
  // Quantity mode: false = Add only (top-up); true = Update & keep (set to file).
  bool _overwrite = false;
  String? _defaultBrandId;
  bool _parsed = false;
  bool _importing = false;
  bool _loading = false;
  bool _combined = false; // sheet had brand-name columns → also map the Library
  String _filename = '';
  String _blockError = ''; // header / file-level problem
  int _done = 0;

  // Admin config + this stockist's data.
  List<String> _finishes = kFinishes;
  List<String> _sizes = kAllowedSizes;
  List<TileSize> _tileSizes = []; // full size rows (with inch/feet aliases)
  String? _brandId; // chosen brand — upload fills P_Stock for it (no list target)
  String _brandName = '';
  Map<String, String> _aliases = {};
  List<TileDesign> _existing = [];
  List<Brand> _brands = []; // for labelling each brand-name column
  List<DnaAttribute> _dnaAttrs = []; // DNA catalog (for auto-detecting columns)
  List<String> _dnaDetected = []; // names of DNA columns found in this sheet

  // A brand's name by id, for the per-row mapping chips ('?' when unknown).
  String _brandLabel(String id) {
    final m = _brands.where((b) => b.id == id).toList();
    return m.isEmpty ? '?' : m.first.name;
  }

  @override
  void initState() {
    super.initState();
    _brandId = widget.initialBrandId; // chosen at the Upload tap
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
      final brands = currentStockistUUID.isEmpty
          ? <Brand>[]
          : await _dataSvc.getMyBrands();
      _brands = brands;
      _library = currentStockistUUID.isEmpty
          ? <LibraryEntry>[]
          : await _dataSvc.getMyLibrary();
      // Existing library identities (name|size, master + aliases) → tells us which
      // rows are brand-new designs (and so must carry tile type / pieces / weight).
      _libKeys
        ..clear()
        ..addAll([
          for (final e in _library) ...[
            '${e.masterName.trim().toLowerCase()}|${_sizeKey(e.size)}',
            for (final a in e.aliases.values)
              '${a.trim().toLowerCase()}|${_sizeKey(e.size)}',
          ]
        ]);
      _dnaAttrs = currentStockistUUID.isEmpty
          ? <DnaAttribute>[]
          : await _dataSvc.dnaCatalog();
      final def = brands.where((b) => b.isDefault).toList();
      _defaultBrandId = def.isEmpty ? null : def.first.id;
      // Resolve the chosen brand (default brand fallback). Upload fills P_Stock.
      if (brands.isNotEmpty) {
        final brand = brands.firstWhere((b) => b.id == _brandId,
            orElse: () => brands.firstWhere((b) => b.isDefault,
                orElse: () => brands.first));
        _brandId = brand.id;
        _brandName = brand.name;
      }
      if (names.isNotEmpty) _finishes = names;
      if (sizeNames.isNotEmpty) _sizes = sizeNames;
      _tileSizes = tileSizes;
    } catch (_) {/* keep fallbacks */}
  }

  // Brand the import writes to (chosen at the Upload tap).
  String? get _uploadBrandId => _brandId ?? _defaultBrandId;

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

  String _normHeader(String h) =>
      h.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  String _sizeKey(String s) => s.toLowerCase().replaceAll(RegExp(r'[^0-9x]'), '');

  // Tolerant of stockists' spelling: anything starting 'pr' (premium / primium /
  // pramium / premeum / pre / prm) → Premium; 'st' / 'ec' or containing 'second'
  // → Standard; else '' (unknown → row error).
  String _normQuality(String raw) {
    final q = raw.trim().toLowerCase();
    if (q.isEmpty) return '';
    if (q.startsWith('pr')) return 'Premium';
    if (q.startsWith('st') || q.startsWith('ec') || q.contains('second')) {
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

    // Detect each fixed logical column by header synonym.
    final header =
        sheet.rows.first.map((c) => _normHeader(c?.value?.toString() ?? '')).toList();
    final colOf = <String, int>{};
    _headerSynonyms.forEach((field, syns) {
      colOf[field] = header.indexWhere((h) => syns.contains(h));
    });
    final masterCol = header.indexWhere((h) => _masterHeaders.contains(h));

    // Combined sheet: any remaining header matching one of this stockist's brand
    // names becomes that brand's design-name column. The CHOSEN upload brand's
    // column supplies the stock design name; ALL brand columns are written into
    // the Library (name mapping) during the same import.
    final usedCols = {
      ...colOf.values.where((i) => i >= 0),
      if (masterCol >= 0) masterCol,
    };
    final brandCols = <int, String>{}; // colIndex -> brandId
    for (var i = 0; i < header.length; i++) {
      if (usedCols.contains(i) || header[i].isEmpty) continue;
      final b = _brands.where((br) => _normHeader(br.name) == header[i]).toList();
      if (b.isNotEmpty) brandCols[i] = b.first.id;
    }
    final hasBrandCols = brandCols.isNotEmpty;
    final chosenBrandId = _uploadBrandId;
    int? chosenBrandCol;
    brandCols.forEach((i, bid) { if (bid == chosenBrandId) chosenBrandCol = i; });

    // Auto-detect Design DNA columns: any still-unused header that matches a DNA
    // attribute's name (free-text attributes like Range are skipped — they have
    // no canonical values to resolve to). The cell value is the raw DNA word(s),
    // resolved on import via dna_resolve (canonical name OR a learned alias).
    final dnaUsed = {...usedCols, ...brandCols.keys};
    final dnaCols = <int, DnaAttribute>{}; // colIndex -> attribute
    for (final attr in _dnaAttrs) {
      if (attr.isFreeText) continue;
      final h = _normHeader(attr.name);
      if (h.isEmpty) continue;
      final i = header.indexWhere((x) => x == h);
      if (i >= 0 && !dnaUsed.contains(i)) {
        dnaCols[i] = attr;
        dnaUsed.add(i);
      }
    }
    _dnaDetected = dnaCols.values.map((a) => a.name).toList();

    // A design-name source must exist: the chosen brand's column, a master
    // column, or a generic name column. 'name' isn't required on a combined
    // sheet where a brand/master column already supplies it.
    final nameCol = colOf['name'] ?? -1;
    final hasNameSource =
        chosenBrandCol != null || masterCol >= 0 || nameCol >= 0;

    final missing = ['size', 'quality', 'qty', 'tiletype']
        .where((f) => (colOf[f] ?? -1) < 0)
        .toList();
    if (!hasNameSource) missing.insert(0, 'name');
    if (missing.isNotEmpty) {
      final names = {
        'name': 'Design Name (or a brand / master column)', 'size': 'Size',
        'quality': 'Quality', 'qty': 'Box Quantity', 'tiletype': 'Tile Type',
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
    String cellAt(List<Data?> row, int i) {
      if (i < 0 || i >= row.length) return '';
      return row[i]?.value?.toString().trim() ?? '';
    }

    final parsed = <_XlsRow>[];
    for (var r = 1; r < sheet.rows.length; r++) {
      final row = sheet.rows[r];
      final blank = row.every((c) =>
          c == null || c.value == null || c.value.toString().trim().isEmpty);
      if (blank) continue;

      // Per-brand names on this row (blank cells dropped).
      final brandNames = <String, String>{};
      brandCols.forEach((i, bid) {
        final v = cellAt(row, i);
        if (v.isNotEmpty) brandNames[bid] = v;
      });
      final masterVal = masterCol >= 0 ? cellAt(row, masterCol) : '';
      final chosenName =
          chosenBrandCol != null ? cellAt(row, chosenBrandCol!) : '';
      final nameVal = cell(row, 'name');
      // Stock design name = chosen brand's name, else master, else generic name.
      final stockName = chosenName.isNotEmpty
          ? chosenName
          : (masterVal.isNotEmpty ? masterVal : nameVal);
      // Library master name = master col, else chosen brand's name, else the
      // first brand name present, else the generic name.
      final masterName = masterVal.isNotEmpty
          ? masterVal
          : (chosenName.isNotEmpty
              ? chosenName
              : (brandNames.isNotEmpty ? brandNames.values.first : nameVal));

      final xls = _XlsRow(
        rowNum: r + 1,
        name: stockName,
        sizeRaw: cell(row, 'size'),
        qualityRaw: cell(row, 'quality'),
        surfaceRaw: cell(row, 'surface'),
        tileType: cell(row, 'tiletype'),
        colour: cell(row, 'colour'),
        qty: _toInt(cell(row, 'qty')) ?? -1,
        pieces: _toInt(cell(row, 'pieces')),
        weight: _toDouble(cell(row, 'weight')),
      );
      xls.brandNames = brandNames;
      xls.masterName = masterName;
      // Auto-detected DNA: split each cell on comma/slash so multi-value
      // attributes (e.g. Colour) carry several words; blanks dropped.
      dnaCols.forEach((i, attr) {
        final raw = cellAt(row, i);
        if (raw.isEmpty) return;
        final words = raw
            .split(RegExp(r'[,/]'))
            .map((w) => w.trim())
            .where((w) => w.isNotEmpty)
            .toList();
        if (words.isNotEmpty) xls.dna[attr.id] = words;
      });
      // No name under the chosen brand but other brands named → map only (can't
      // make stock for a brand this tile isn't sold under).
      xls.mapOnly = hasBrandCols && chosenName.isEmpty && brandNames.isNotEmpty;
      parsed.add(xls);
    }

    if (parsed.isEmpty) {
      setState(() => _blockError = 'No data rows found (only a header?).');
      return;
    }
    _combined = hasBrandCols;

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

  // Canonical admin size for a raw size cell, or '' when not in the size list.
  String _resolveSize(String raw) =>
      resolveCanonicalSize(raw, _tileSizes) ??
      _sizes.firstWhere((s) => _sizeKey(s) == _sizeKey(raw), orElse: () => '');

  // Validate required fields/values; align each finish to an admin finish.
  void _validateAndResolve(List<_XlsRow> rows) {
    for (final r in rows) {
      // Map-only rows (combined sheet, chosen brand blank) just need size +
      // master + brand names for the Library mapping — skip the stock fields.
      if (r.mapOnly) {
        if (r.sizeRaw.isEmpty) { r.error = 'Missing size'; continue; }
        final mz = _resolveSize(r.sizeRaw);
        if (mz.isEmpty) { r.error = "Size '${r.sizeRaw}' is not in your size list"; continue; }
        r.size = mz;
        if (r.masterName.trim().isEmpty) { r.error = 'Missing design name'; continue; }
        continue;
      }
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
      // Brand-new design? (name+size not yet in the library.) Only new designs must
      // carry identity (tile type / pieces / weight); existing designs already have
      // it. A new design left blank is NOT an error — it's a "needs fill" row that
      // blocks Save until completed or excluded (see needsFill).
      r.isNewDesign =
          !_libKeys.contains('${r.name.trim().toLowerCase()}|${_sizeKey(r.size)}');
      // Tile type: validate the wording if given; never block on blank here.
      if (r.tileType.trim().isNotEmpty) {
        final tt = kTileTypes.firstWhere(
            (t) => t.toLowerCase() == r.tileType.trim().toLowerCase(),
            orElse: () => '');
        if (tt.isEmpty) { r.error = "Unknown tile type '${r.tileType}'"; continue; }
        r.tileType = tt;
      } else {
        r.tileType = '';
      }

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

  String _surfKey(String s) =>
      s.trim().isEmpty ? 'none' : s.trim().toLowerCase();

  // A holding is keyed by Name + Size + Quality + Surface (surface is a stock-line
  // dimension on P_Stock). Match all four → update; otherwise → new. A different
  // surface is simply a different stock line, never a "conflict".
  void _computeActions(List<_XlsRow> rows) {
    for (final r in rows) {
      if (!r.valid) { r.action = 'skip'; continue; }
      if (r.mapOnly) { r.action = 'map'; continue; }
      final needle = r.name.trim().toLowerCase();
      final surf = _surfKey(r.surface);
      final matches = _existing.where((d) =>
          d.name.trim().toLowerCase() == needle &&
          _sizeKey(d.size) == _sizeKey(r.size) &&
          d.quality == r.quality &&
          _surfKey(d.surfaceType) == surf).toList();
      if (matches.isEmpty) {
        r.match = null;
        r.action = 'new';
      } else {
        r.match = matches.first;
        r.action = 'update';
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

    final willImport = toDo.length;
    setState(() { _importing = true; _done = 0; });

    // Excel carries no photos — fill them from THIS stockist's own Design Library
    // (by the target brand's design name / master name + size). Never borrows.
    final libImages = _ownLibImages();
    final brandId = _uploadBrandId;

    // Build ONE atomic batch payload (no per-row loop of writes). Combined-sheet
    // rows write the master + all brand aliases into the Library inline; plain
    // rows opt out of the Library (skip_master) and just create/update the
    // design — preserving the old behaviour exactly. Map-only rows carry qty 0
    // (library mapping, no stock). force_new replays the stockist's "add as new"
    // choice on a finish conflict; update_surface replays a finish correction.
    int mapped = 0, news = 0, imagesFromLibrary = 0;
    final rows = <Map<String, dynamic>>[];
    final learned = <String, String>{};

    for (final r in toDo) {
      final isCombined =
          _combined && r.masterName.trim().isNotEmpty && r.brandNames.isNotEmpty;
      final aliasJson = r.brandNames.entries
          .where((e) => e.value.trim().isNotEmpty)
          .map((e) => {'brand_id': e.key, 'name': e.value.trim()})
          .toList();

      // Map-only row (chosen brand doesn't sell this tile) → Library only.
      if (r.mapOnly) {
        rows.add(<String, dynamic>{
          'name': r.masterName.trim(),
          'master_name': r.masterName.trim(),
          'size': r.size,
          'aliases': aliasJson,
          'qty': 0,
          if (r.dna.isNotEmpty) 'dna': r.dna,
        });
        mapped++;
        continue;
      }

      final libUrl = libImages[designImageKey(r.name, r.size)];

      // The holding is resolved server-side by (library, quality, surface), so the
      // client just sends the row's fields — no force_new / conflict flags needed.
      final row = <String, dynamic>{
        'name': r.name,
        'size': r.size,
        'quality': r.quality,
        'surface': r.surface,
        'colour': r.colour,
        'qty': r.qty,
        'stock_type': 'Uncertain',
        'tile_type': kTileTypes.contains(r.tileType) ? r.tileType : '',
        'pieces_per_box': r.pieces ?? 0,
        'box_weight_kg': r.weight ?? 0,
        'thickness_mm': approxThicknessMm(
                r.size, r.pieces ?? 0, r.weight ?? 0,
                kTileTypes.contains(r.tileType)
                    ? r.tileType
                    : kTileTypes.first) ??
            0,
        if (libUrl != null) 'image_url': libUrl,
        if (r.surfaceRaw.trim().isNotEmpty) 'finish_label': r.surfaceRaw.trim(),
      };
      final hasDna = r.dna.isNotEmpty;
      if (isCombined) {
        row['master_name'] = r.masterName.trim();
        row['aliases'] = aliasJson;
        mapped++;
      } else if (!hasDna && !r.isNewDesign) {
        // EXISTING plain design, no DNA → leave the Library untouched. A NEW design
        // must keep skip_master OFF so its identity (tile type/pieces/weight) is set.
        row['skip_master'] = true;
      }
      // A plain row WITH DNA keeps skip_master off so a master exists to tag it.
      if (hasDna) row['dna'] = r.dna;
      rows.add(row);

      if (libUrl != null) imagesFromLibrary++;
      if (r.action == 'new') news++;
      // Remember the finish wording → chosen finish for next time.
      if (r.rawKey.isNotEmpty && r.surface != 'None') learned[r.rawKey] = r.surface;
    }

    // ONE atomic, idempotent call — never half-saves, and a reused batch id can't
    // double-add on retry (the DB rolls the whole thing back on any failure).
    if (_batchId.isEmpty) _batchId = const Uuid().v4();
    Map<String, dynamic> res;
    try {
      res = await _dataSvc.importStockBatch(
        batchId: _batchId,
        catalogId: null, // upload fills P_Stock; lists are curated separately
        brandId: brandId,
        pdfFilename: _filename,
        rows: rows,
        mode: _overwrite ? 'replace_keep' : 'add',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _importing = false);
      _snack('Nothing was saved — $e. Please try again.', Colors.red);
      return;
    }

    // Learn finish alignments AFTER the import (idempotent upserts, safe outside
    // the transaction — they don't add stock so they can't double-apply).
    for (final e in learned.entries) {
      await _dataSvc.upsertSurfaceAlias(currentStockistUUID, e.key, e.value);
    }

    if (!mounted) return;
    setState(() { _importing = false; _done = willImport; });
    final created = (res['created'] as num?)?.toInt() ?? news;
    final updated = (res['updated'] as num?)?.toInt() ?? 0;
    final dnaTagged = (res['dna_tagged'] as num?)?.toInt() ?? 0;
    final libNote = imagesFromLibrary > 0
        ? ' · $imagesFromLibrary photos from library'
        : '';
    final mapNote = mapped > 0 ? ' · $mapped mapped to library' : '';
    final dnaNote = dnaTagged > 0 ? ' · $dnaTagged DNA tagged' : '';
    final brandNote = _brandName.isEmpty ? '' : ' → $_brandName';
    _snack(
        'Done — $updated updated, $created new$mapNote$dnaNote$libNote$brandNote. '
        'Add designs to a stock list to show buyers.',
        Colors.green);
    if (updated + created + mapped > 0) Navigator.of(context).pop();
  }

  void _reset() => setState(() {
        _rows = []; _parsed = false; _blockError = ''; _done = 0; _filename = '';
        _libImages = {}; _combined = false; _batchId = ''; _dnaDetected = [];
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
        // Bottom inset clears the system nav bar so the "Browse" button at the
        // end isn't tucked under it (edge-to-edge).
        padding: EdgeInsets.fromLTRB(
            20, 20, 20, 20 + MediaQuery.viewPaddingOf(context).bottom),
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
      ('Design Name', 'required — or a brand / master column', true),
      ('Size', 'required — must match your sizes', true),
      ('Quality', 'required — Premium / Standard', true),
      ('Box Quantity', 'required — the boxes to add', true),
      ('Tile Type', 'required — the tile body type', true),
      ('Surface / Finish', 'optional — mapped after upload', false),
      ('Box Weight', 'optional — for thickness', false),
      ('Pieces/Box', 'optional — for sq.ft', false),
      ('Colour', 'optional', false),
      ('Master design name', 'optional — links your brands in the Library', false),
      ('<Brand name> columns', 'optional — one per brand; the design name under '
          'each. The chosen brand\'s name becomes the stock; all are mapped.', false),
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
    final maps = _rows.where((r) => r.valid && r.action == 'map').length;
    final skipped = _rows.where((r) => !r.valid).length;
    final willImport = _rows.where((r) => r.valid && r.include).length;
    // New designs still missing identity → block Save until filled or excluded.
    final incomplete =
        _rows.where((r) => r.valid && r.include && r.needsFill).length;
    final allDone = !_importing && _done > 0 && _done >= willImport;

    return Column(
      children: [
        // Destination = the chosen brand's stock (P_Stock). Lists are curated
        // separately, so there's no list picker here.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          alignment: Alignment.centerLeft,
          child: Text(
              'Adding to: ${_brandName.isEmpty ? 'your stock' : _brandName} · your stock',
              style: const TextStyle(fontSize: 12, color: Color(0xFF1B4F72))),
        ),
        // Quantity mode — Add only (top-up) vs Update & keep (set to file numbers).
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Row(children: [
            Expanded(
                child: _modeBtn('Add only', 'top-up boxes', !_overwrite,
                    () => setState(() => _overwrite = false))),
            const SizedBox(width: 8),
            Expanded(
                child: _modeBtn('Update & keep', 'set to file numbers', _overwrite,
                    () => setState(() => _overwrite = true))),
          ]),
        ),
        if (incomplete > 0)
          Container(
            width: double.infinity,
            color: const Color(0xFFFFF3E0),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
                '$incomplete new design${incomplete == 1 ? '' : 's'} need Tile Type, '
                'Pieces and Box Weight. Fill them below (or untick the row) to import.',
                style: TextStyle(fontSize: 11.5, color: Colors.orange.shade900)),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: const Color(0xFF1B4F72).withValues(alpha: 0.06),
          child: Row(
            children: [
              _chip('$updates', 'Update', const Color(0xFF1B4F72)),
              const SizedBox(width: 10),
              _chip('$news', 'New', const Color(0xFF2E7D32)),
              if (maps > 0) ...[
                const SizedBox(width: 10),
                _chip('$maps', 'Map only', const Color(0xFF6A1B9A)),
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
                  onPressed:
                      (willImport > 0 && incomplete == 0) ? _startImport : null,
                  icon: const Icon(Icons.upload_rounded, size: 16),
                  label: Text(incomplete > 0
                      ? 'Fill $incomplete to import'
                      : 'Import $willImport'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1B4F72),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.grey.shade300),
                ),
            ],
          ),
        ),
        if (_dnaDetected.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: const Color(0xFF6A1B9A).withValues(alpha: 0.06),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome,
                    size: 15, color: Color(0xFF6A1B9A)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Design DNA columns detected: ${_dnaDetected.join(', ')} '
                    '— values will be tagged automatically.',
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF6A1B9A)),
                  ),
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
    } else if (r.action == 'new') {
      border = Colors.green.shade200; bg = const Color(0xFFE8F5E9);
      tag = 'NEW'; tagColor = const Color(0xFF2E7D32);
    } else if (r.action == 'map') {
      border = const Color(0xFFE1BEE7); bg = const Color(0xFFF3E5F5);
      tag = 'MAP'; tagColor = const Color(0xFF6A1B9A);
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
            r.mapOnly
                ? '${r.size.isNotEmpty ? r.size : r.sizeRaw}  ·  map only (not sold under this brand)'
                : [
                    if (r.size.isNotEmpty) r.size else r.sizeRaw,
                    if (r.quality.isNotEmpty) r.quality else r.qualityRaw,
                    if (r.qty >= 0) '${r.qty} boxes',
                    if (r.surfaceRaw.trim().isNotEmpty) r.surface,
                  ].join('  ·  '),
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
          // Combined sheet: show the per-brand names this row maps into the
          // Library, so the stockist can verify the cross-brand link.
          if (r.valid && r.brandNames.isNotEmpty) ...[
            const SizedBox(height: 5),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: r.brandNames.entries
                  .map((a) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF6A1B9A).withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('${_brandLabel(a.key)}: ${a.value}',
                            style: const TextStyle(
                                fontSize: 10.5, color: Color(0xFF6A1B9A))),
                      ))
                  .toList(),
            ),
          ],
          // New design → identity (tile type / pieces / weight) is compulsory and
          // editable here. Existing designs skip this (identity already set).
          if (r.valid && r.include && r.isNewDesign) ...[
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                flex: 4,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('tt_${r.rowNum}'),
                  initialValue:
                      kTileTypes.contains(r.tileType) ? r.tileType : null,
                  isExpanded: true,
                  decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Tile type',
                      border: OutlineInputBorder()),
                  items: kTileTypes
                      .map((t) => DropdownMenuItem(
                          value: t,
                          child:
                              Text(t, style: const TextStyle(fontSize: 12))))
                      .toList(),
                  onChanged: _importing
                      ? null
                      : (v) => setState(() => r.tileType = v ?? ''),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                flex: 3,
                child: TextFormField(
                  key: ValueKey('pc_${r.rowNum}'),
                  initialValue: (r.pieces ?? 0) > 0 ? '${r.pieces}' : '',
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Pieces',
                      border: OutlineInputBorder()),
                  onChanged: (v) =>
                      setState(() => r.pieces = int.tryParse(v.trim())),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                flex: 3,
                child: TextFormField(
                  key: ValueKey('wt_${r.rowNum}'),
                  initialValue: (r.weight ?? 0) > 0 ? '${r.weight}' : '',
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Weight kg',
                      border: OutlineInputBorder()),
                  onChanged: (v) =>
                      setState(() => r.weight = double.tryParse(v.trim())),
                ),
              ),
            ]),
            if (r.needsFill)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                    'New design — fill tile type, pieces and weight (or untick).',
                    style: TextStyle(
                        fontSize: 10.5,
                        color: Colors.orange.shade800,
                        fontWeight: FontWeight.w600)),
              ),
          ],
          if (!r.valid) ...[
            const SizedBox(height: 4),
            Text(r.error!,
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.red.shade700,
                    fontWeight: FontWeight.w600)),
          ],
        ],
      ),
    );
  }

  // Segmented Add-only / Update&keep button for the quantity mode.
  Widget _modeBtn(String title, String sub, bool sel, VoidCallback onTap) {
    return GestureDetector(
      onTap: _importing ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: sel ? const Color(0xFF1B4F72) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: sel ? const Color(0xFF1B4F72) : Colors.grey.shade300),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                    color: sel ? Colors.white : Colors.black87)),
            Text(sub,
                style: TextStyle(
                    fontSize: 10,
                    color: sel ? Colors.white70 : Colors.grey)),
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
