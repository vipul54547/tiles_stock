import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import 'package:excel/excel.dart' hide Border, BorderStyle, TextSpan;
import 'package:cached_network_image/cached_network_image.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../services/excel_template_service.dart';
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
  'weight':   ['weight', 'box weight', 'box weight (kg)', 'weight (kg)', 'weight kg', 'wt', 'weight/box'],
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

// WIDE quantity layout: separate Premium / Standard box-count columns on one row
// (instead of a quality column + single qty). When either is present, each row
// expands into one holding per quality. PRE→Premium, STD→Standard (the only two
// qualities we keep; GOLD/ECO etc. are out of scope).
const List<String> _premiumQtyHeaders = [
  'premium', 'pre', 'prm', 'premium qty', 'premium box', 'premium boxes',
  'premium stock', 'prem',
];
const List<String> _standardQtyHeaders = [
  'standard', 'std', 'standard qty', 'standard box', 'standard boxes',
  'standard stock', 'stand',
];

// M_Stockist desktop-export ("ENTRY.xlsx") shape: a per-ROW brand name lives in
// BoxPack (or Brand), the same design recurs per batch, and grades are wide
// PRE/STD columns. Detected + imported via the dedicated entry path (batch-sum,
// brand-value map). Category there carries the finish.
const List<String> _boxPackHeaders = ['boxpack', 'box pack', 'box_pack'];
const List<String> _brandColHeaders = ['brand', 'brand name', 'company', 'company name'];
const List<String> _categoryHeaders = ['category', 'cat'];

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
  bool editing = false;   // per-cell editor expanded for this row
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
  // The quantity mode is chosen up-front (a dedicated step) BEFORE picking a
  // file, so it never reappears as a toggle on the Review screen.
  bool _modeChosen = false;
  String? _defaultBrandId;
  bool _parsed = false;
  bool _importing = false;
  bool _loading = false;
  bool _downloading = false; // building/saving the blank template
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
  bool _wideQty = false; // sheet had wide Premium/Standard columns (row → 2 holdings)
  // attributeId -> set of already-resolvable words (lowercased): canonical value
  // names + this stockist's learned aliases. A detected DNA word NOT in this set
  // needs the Map-DNA step (else dna_resolve would silently drop it).
  Map<String, Set<String>> _dnaKnown = {};

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

  // Build the blank template (.xlsx with dropdowns) and let the stockist save it.
  // Skin = M (wide brand columns + Premium/Standard) when they run >1 brand, else
  // single-brand. Needs the admin vocab + brands → loads config first.
  Future<void> _downloadTemplate() async {
    setState(() => _downloading = true);
    try {
      await _loadConfig();
      final bytes = ExcelTemplateService.buildStockTemplate(
        multiBrand: _brands.length > 1,
        sizes: _sizes,
        finishes: _finishes,
        tileTypes: kTileTypes,
        dnaAttrs: _dnaAttrs,
        brands: _brands,
      );
      final safeBrand = _brandName.trim().isEmpty
          ? 'stock'
          : _brandName.trim().replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save stock template',
        fileName: 'tiles_${safeBrand}_template.xlsx',
        type: FileType.custom,
        allowedExtensions: const ['xlsx'],
        bytes: Uint8List.fromList(bytes),
      );
      if (!mounted) return;
      if (path != null) {
        _snack('Template saved. Fill it, then upload it here.', Colors.green);
      }
    } catch (e) {
      if (mounted) _snack('Could not create template — $e', Colors.red);
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

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
      // Build the "already resolvable" word set per attribute = canonical value
      // names + this stockist's learned aliases (dna_my_words is {valueId:[word]}).
      // Mirrors dna_resolve's two-step match so the Map-DNA step only surfaces
      // words that would otherwise be dropped.
      _dnaKnown = {for (final a in _dnaAttrs) a.id: <String>{}};
      final valueAttr = <String, String>{}; // valueId -> attributeId
      for (final a in _dnaAttrs) {
        for (final v in a.values) {
          _dnaKnown[a.id]!.add(v.name.trim().toLowerCase());
          valueAttr[v.id] = a.id;
        }
      }
      if (currentStockistUUID.isNotEmpty) {
        final myWords = await _dataSvc.dnaMyWords(); // {valueId: [raw words]}
        myWords.forEach((valueId, words) {
          final attr = valueAttr[valueId];
          if (attr != null) {
            for (final w in words) {
              _dnaKnown[attr]!.add(w.trim().toLowerCase());
            }
          }
        });
      }
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

    // M_Stockist ENTRY format → dedicated batch-sum / brand-value path.
    if (_isEntryFormat(header)) {
      await _parseEntryFormat(sheet, header);
      return;
    }

    // A header that exactly matches a (value-list) Design DNA attribute name
    // belongs to DNA, not to a generic synonym field — e.g. "Colour" is the DNA
    // Colour attribute, NOT the free-text colour field (whose synonyms would
    // otherwise swallow the header and block DNA tagging). Reserve those columns
    // so the synonym matching below skips them and DNA detection claims them.
    final dnaNameCols = <int>{};
    for (final attr in _dnaAttrs) {
      if (attr.isFreeText) continue;
      final h = _normHeader(attr.name);
      if (h.isEmpty) continue;
      final i = header.indexWhere((x) => x == h);
      if (i >= 0) dnaNameCols.add(i);
    }

    final colOf = <String, int>{};
    _headerSynonyms.forEach((field, syns) {
      var idx = -1;
      for (var i = 0; i < header.length; i++) {
        if (dnaNameCols.contains(i)) continue; // reserved for DNA
        if (syns.contains(header[i])) {
          idx = i;
          break;
        }
      }
      colOf[field] = idx;
    });
    final masterCol = header.indexWhere((h) => _masterHeaders.contains(h));

    // Wide Premium/Standard quantity columns (optional). When present, each row
    // becomes one holding per quality and the quality + single-qty columns are
    // no longer required.
    final premCol = header.indexWhere((h) => _premiumQtyHeaders.contains(h));
    final stdCol = header.indexWhere((h) => _standardQtyHeaders.contains(h));
    final wideQty = premCol >= 0 || stdCol >= 0;

    // Combined sheet: any remaining header matching one of this stockist's brand
    // names becomes that brand's design-name column. The CHOSEN upload brand's
    // column supplies the stock design name; ALL brand columns are written into
    // the Library (name mapping) during the same import.
    final usedCols = {
      ...colOf.values.where((i) => i >= 0),
      if (masterCol >= 0) masterCol,
      if (premCol >= 0) premCol,
      if (stdCol >= 0) stdCol,
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

    // In wide mode the quality + single-qty columns are replaced by the
    // Premium/Standard box columns, so they're no longer required.
    final missing = [
      'size',
      if (!wideQty) 'quality',
      if (!wideQty) 'qty',
      'tiletype',
    ].where((f) => (colOf[f] ?? -1) < 0).toList();
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

      // Shared fields, parsed once per sheet row (a wide-mode row may fan out
      // into a Premium + a Standard holding that share all of these).
      final sizeRaw = cell(row, 'size');
      final surfaceRaw = cell(row, 'surface');
      final tileType = cell(row, 'tiletype');
      final colour = cell(row, 'colour');
      final pieces = _toInt(cell(row, 'pieces'));
      final weight = _toDouble(cell(row, 'weight'));
      // No name under the chosen brand but other brands named → map only (can't
      // make stock for a brand this tile isn't sold under).
      final mapOnly = hasBrandCols && chosenName.isEmpty && brandNames.isNotEmpty;
      // Auto-detected DNA: split each cell on comma/slash so multi-value
      // attributes (e.g. Colour) carry several words; blanks dropped.
      final dna = <String, List<String>>{};
      dnaCols.forEach((i, attr) {
        final raw = cellAt(row, i);
        if (raw.isEmpty) return;
        final words = raw
            .split(RegExp(r'[,/]'))
            .map((w) => w.trim())
            .where((w) => w.isNotEmpty)
            .toList();
        if (words.isNotEmpty) dna[attr.id] = words;
      });

      // Quantity parts → one holding per quality. Map-only rows carry no stock;
      // wide mode emits a part for each Premium/Standard column that has a value;
      // otherwise the single quality + qty columns (unchanged behaviour).
      final parts = <({String quality, int qty})>[];
      if (mapOnly) {
        parts.add((quality: '', qty: 0));
      } else if (wideQty) {
        if (premCol >= 0) {
          final v = cellAt(row, premCol);
          if (v.isNotEmpty) parts.add((quality: 'Premium', qty: _toInt(v) ?? -1));
        }
        if (stdCol >= 0) {
          final v = cellAt(row, stdCol);
          if (v.isNotEmpty) {
            parts.add((quality: 'Standard', qty: _toInt(v) ?? -1));
          }
        }
      } else {
        parts.add(
            (quality: cell(row, 'quality'), qty: _toInt(cell(row, 'qty')) ?? -1));
      }

      for (final part in parts) {
        final xls = _XlsRow(
          rowNum: r + 1,
          name: stockName,
          sizeRaw: sizeRaw,
          qualityRaw: part.quality,
          surfaceRaw: surfaceRaw,
          tileType: tileType,
          colour: colour,
          qty: part.qty,
          pieces: pieces,
          weight: weight,
        );
        xls.brandNames = brandNames;
        xls.masterName = masterName;
        // Each sub-row gets its own DNA copy (the Map-DNA step mutates per row).
        xls.dna = {
          for (final e in dna.entries) e.key: List<String>.from(e.value)
        };
        xls.mapOnly = mapOnly;
        parsed.add(xls);
      }
    }

    if (parsed.isEmpty) {
      setState(() => _blockError = 'No data rows found (only a header?).');
      return;
    }
    _combined = hasBrandCols;
    _wideQty = wideQty;

    _validateAndResolve(parsed);

    // Map any finishes present in the file to admin finishes before computing
    // conflicts (blank-finish rows skip this).
    final ok = await _mapFinishesStep(parsed);
    if (!ok) return; // cancelled

    // Align any DNA words that don't already resolve (canonical name or learned
    // alias) to a canonical value, and learn them — so dna_resolve can't drop
    // them on import. Skips entirely when every detected word already resolves.
    final okDna = await _mapDnaStep(parsed);
    if (!okDna) return; // cancelled

    _computeActions(parsed);

    // Auto-match this stockist's OWN library photos by name+size so the preview
    // shows a picture for each row (Excel carries none). Local lookup; thumbnails
    // load lazily for visible rows. Never borrows another stockist's photo.
    setState(() {
      _rows = parsed; _parsed = true; _done = 0; _libImages = _ownLibImages();
    });
  }

  // ── M_Stockist ENTRY.xlsx (batch-sum + per-row brand value) ─────────────────

  // The export shape: a per-row brand name in BoxPack (or Brand), wide PRE/STD
  // grade columns, the same design recurring per batch. Detected by BoxPack +
  // (PRE|STD) + a design-name column.
  bool _isEntryFormat(List<String> header) {
    final hasBoxpack = header.any((h) => _boxPackHeaders.contains(h));
    final hasGrades = header.any((h) =>
        _premiumQtyHeaders.contains(h) || _standardQtyHeaders.contains(h));
    final hasName = header.any((h) => _headerSynonyms['name']!.contains(h));
    return hasBoxpack && hasGrades && hasName;
  }

  // Drop a placeholder brand value ("--", "-", blank).
  String _cleanBrandVal(String s) {
    final t = s.trim();
    return (t.isEmpty || t == '--' || t == '-') ? '' : t;
  }

  // Strip a trailing "(2PCS …)" note from a size cell → "800X1600 (2PCS)" = "800X1600".
  String _cleanSize(String raw) {
    var s = raw.trim();
    final p = s.indexOf('(');
    if (p >= 0) s = s.substring(0, p).trim();
    return s;
  }

  Future<void> _parseEntryFormat(Sheet sheet, List<String> header) async {
    int idx(List<String> syns) => header.indexWhere((h) => syns.contains(h));
    final nameCol = idx(_headerSynonyms['name']!);
    final sizeCol = idx(_headerSynonyms['size']!);
    final catCol = idx(_categoryHeaders);
    final preCol = header.indexWhere((h) => _premiumQtyHeaders.contains(h));
    final stdCol = header.indexWhere((h) => _standardQtyHeaders.contains(h));
    final brandCol = idx(_brandColHeaders);
    final boxpackCol = header.indexWhere((h) => _boxPackHeaders.contains(h));

    String cellAt(List<Data?> row, int i) {
      if (i < 0 || i >= row.length) return '';
      return row[i]?.value?.toString().trim() ?? '';
    }

    final dataRows = <List<Data?>>[];
    for (var r = 1; r < sheet.rows.length; r++) {
      final row = sheet.rows[r];
      final blank = row.every((c) =>
          c == null || c.value == null || c.value.toString().trim().isEmpty);
      if (!blank) dataRows.add(row);
    }
    if (dataRows.isEmpty) {
      setState(() => _blockError = 'No data rows found (only a header?).');
      return;
    }

    // Brand value column = Brand when it has real values, else BoxPack. Confirmed.
    final brandColReal = brandCol >= 0 &&
        dataRows.any((row) => _cleanBrandVal(cellAt(row, brandCol)).isNotEmpty);
    final autoCol = brandColReal
        ? brandCol
        : (boxpackCol >= 0 ? boxpackCol : brandCol);
    final brandValCol = await _confirmBrandColumn(header, brandCol, boxpackCol, autoCol);
    if (brandValCol == null) return; // cancelled

    final brandValues = <String>{};
    for (final row in dataRows) {
      final b = _cleanBrandVal(cellAt(row, brandValCol));
      if (b.isNotEmpty) brandValues.add(b);
    }
    final brandMap = await _mapBrandValues(brandValues.toList()..sort());
    if (brandMap == null) return; // cancelled

    // Sum PRE→Premium, STD→Standard across each design's batch rows; collect the
    // brand faces it was packed under; Category → surface; clean the size note.
    final agg = <String, _EntryAgg>{};
    for (final row in dataRows) {
      final dn = cellAt(row, nameCol).trim();
      if (dn.isEmpty) continue;
      final sz = _cleanSize(cellAt(row, sizeCol));
      final key = '${dn.toLowerCase()}|${_sizeKey(sz)}';
      final a = agg.putIfAbsent(key, () => _EntryAgg(name: dn, size: sz));
      if (preCol >= 0) a.premium += _toInt(cellAt(row, preCol)) ?? 0;
      if (stdCol >= 0) a.standard += _toInt(cellAt(row, stdCol)) ?? 0;
      if (catCol >= 0 && a.surface.isEmpty) a.surface = cellAt(row, catCol).trim();
      final bid = brandMap[_cleanBrandVal(cellAt(row, brandValCol))];
      if (bid != null) a.brandIds.add(bid);
    }

    final parsed = <_XlsRow>[];
    var n = 1;
    for (final a in agg.values) {
      final brandNames = {for (final bid in a.brandIds) bid: a.name};
      void emit(String quality, int qty) {
        if (qty <= 0) return;
        final x = _XlsRow(
          rowNum: n++,
          name: a.name,
          sizeRaw: a.size,
          qualityRaw: quality,
          surfaceRaw: a.surface,
          tileType: '',
          colour: '',
          qty: qty,
          pieces: null,
          weight: null,
        );
        x.brandNames = Map.of(brandNames);
        x.masterName = a.name;
        parsed.add(x);
      }

      emit('Premium', a.premium);
      emit('Standard', a.standard);
    }
    if (parsed.isEmpty) {
      setState(() => _blockError = 'No Premium/Standard stock found in the file.');
      return;
    }

    _combined = true; // each design writes master + brand aliases into the Library
    _wideQty = true; // grades came from wide PRE/STD columns
    _validateAndResolve(parsed);
    final ok = await _mapFinishesStep(parsed); // Category (GLOSSY…) → admin finish
    if (!ok) return;
    final okDna = await _mapDnaStep(parsed);
    if (!okDna) return;
    _computeActions(parsed);
    setState(() {
      _rows = parsed; _parsed = true; _done = 0; _libImages = _ownLibImages();
    });
  }

  // "Which column is the brand?" — auto-picks Brand (if real) else BoxPack, lets
  // the stockist switch. Returns the chosen column index, or null on cancel.
  Future<int?> _confirmBrandColumn(
      List<String> header, int brandCol, int boxpackCol, int autoCol) async {
    final candidates = <int>[
      if (brandCol >= 0) brandCol,
      if (boxpackCol >= 0) boxpackCol,
    ];
    if (candidates.isEmpty) return autoCol;
    var chosen = autoCol >= 0 ? autoCol : candidates.first;
    String label(int i) =>
        (i >= 0 && i < header.length && header[i].isNotEmpty) ? header[i] : 'column ${i + 1}';
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Which column is the brand?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'Each row names the brand this design is packed under. Confirm '
                  'the column that holds it.',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 12),
              DropdownButton<int>(
                isExpanded: true,
                value: chosen,
                items: candidates
                    .map((i) => DropdownMenuItem(value: i, child: Text(label(i))))
                    .toList(),
                onChanged: (v) => setLocal(() => chosen = v ?? chosen),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Continue')),
          ],
        ),
      ),
    );
    return ok == true ? chosen : null;
  }

  // Map each distinct brand value → an existing brand or a new one. Returns
  // { brandValue : brandId }, or null on cancel. New brands are created on Apply.
  static const _kCreateBrand = '__create__';
  Future<Map<String, String>?> _mapBrandValues(List<String> values) async {
    if (values.isEmpty) return {};
    // value → chosen ('__create__' or an existing brand id). Default: match an
    // existing brand by name, else create.
    final choice = <String, String>{};
    for (final v in values) {
      final m = _brands
          .where((b) => b.name.trim().toLowerCase() == v.trim().toLowerCase())
          .toList();
      choice[v] = m.isEmpty ? _kCreateBrand : m.first.id;
    }
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Match brands'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    'Link each brand from your file to one of your brands, or '
                    'create it. Designs are filed under the brand you pick.',
                    style: TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: values.map((v) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 4,
                                child: Text(v,
                                    style: const TextStyle(fontSize: 13)),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                flex: 5,
                                child: DropdownButton<String>(
                                  isExpanded: true,
                                  value: choice[v],
                                  items: [
                                    DropdownMenuItem(
                                        value: _kCreateBrand,
                                        child: Text('➕ Create “$v”',
                                            style: const TextStyle(
                                                fontSize: 12,
                                                color: Color(0xFF2E7D32)))),
                                    ..._brands.map((b) => DropdownMenuItem(
                                        value: b.id,
                                        child: Text(b.name,
                                            style:
                                                const TextStyle(fontSize: 12)))),
                                  ],
                                  onChanged: (val) =>
                                      setLocal(() => choice[v] = val ?? choice[v]!),
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
    if (ok != true) return null;

    // Resolve creates → real brand ids (server enforces the brand limit).
    final result = <String, String>{};
    for (final entry in choice.entries) {
      if (entry.value == _kCreateBrand) {
        try {
          final id = await _dataSvc.createBrand(entry.key);
          if (id.isEmpty) throw 'no id';
          result[entry.key] = id;
        } catch (e) {
          if (mounted) {
            _snack('Could not create brand “${entry.key}” — $e', Colors.red);
          }
          return null; // abort; stockist resolves and re-runs
        }
      } else {
        result[entry.key] = entry.value;
      }
    }
    // Refresh the brand list so newly created brands are known downstream.
    try {
      _brands = await _dataSvc.getMyBrands();
    } catch (_) {/* keep what we have */}
    return result;
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

  // Re-run validation + action matching for a single row after a per-cell edit,
  // so its tag (NEW/UPDATE/SKIP), error and new-design state refresh live. The
  // edit fields write the canonical value straight onto sizeRaw/qualityRaw/
  // surfaceRaw, which re-resolve to themselves.
  void _reResolve(_XlsRow r) {
    r.error = null;
    _validateAndResolve([r]);
    _computeActions([r]);
    setState(() {});
  }

  // ── Map Finishes (only for finishes that don't already resolve) ─────────────
  // Mirrors the DNA step: a finish that already matches an admin finish exactly
  // (or via a learned alias) needs no mapping, so it's skipped. A stockist who
  // picks from the template's Surface dropdown therefore never sees this step;
  // it only surfaces genuine mismatches (their own wording / own spreadsheet).

  Future<bool> _mapFinishesStep(List<_XlsRow> rows) async {
    final groups = <String, _FinishGroup>{}; // rawKey → group
    for (final r in rows) {
      if (!r.valid || r.surfaceRaw.trim().isEmpty) continue;
      final aliased = _aliases[r.rawKey];
      final resolves = (aliased != null && _finishes.contains(aliased)) ||
          _finishes.contains(r.surfaceRaw.trim());
      if (resolves) continue; // already an admin finish — nothing to map
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

  // ── Map Design DNA (only words that don't already resolve) ──────────────────
  // dna_resolve matches a raw word to a canonical value by exact name OR a learned
  // alias; anything else is silently dropped on import. This step surfaces those
  // unresolved words, lets the stockist align each to a canonical value, and LEARNS
  // the alias (dna_learn_alias) BEFORE the import call so dna_resolve then picks it
  // up. Free-text attributes (no fixed value list) are left untouched.
  Future<bool> _mapDnaStep(List<_XlsRow> rows) async {
    final attrById = {for (final a in _dnaAttrs) a.id: a};
    final groups = <String, _DnaMapGroup>{}; // attrId|wordLower → group
    for (final r in rows) {
      if (!r.valid || r.dna.isEmpty) continue;
      r.dna.forEach((attrId, words) {
        final attr = attrById[attrId];
        if (attr == null || attr.isFreeText || attr.values.isEmpty) return;
        for (final w in words) {
          final word = w.trim();
          if (word.isEmpty) continue;
          final lower = word.toLowerCase();
          if (_dnaKnown[attrId]?.contains(lower) ?? false) continue; // resolves
          final g = groups.putIfAbsent(
              '$attrId|$lower',
              () => _DnaMapGroup(
                  attributeId: attrId, attributeName: attr.name, label: word));
          g.count++;
        }
      });
    }
    if (groups.isEmpty) return true; // every DNA word already resolves

    final keys = groups.keys.toList();
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Map Design DNA'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    'Some DNA words from your file don’t match a known value. '
                    'Match each to a standard value so it isn’t lost — we’ll '
                    'remember your wording next time. Leave as Ignore to skip.',
                    style: TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: keys.map((k) {
                        final g = groups[k]!;
                        final attr = attrById[g.attributeId]!;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 5,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(attr.name,
                                        style: const TextStyle(
                                            fontSize: 11, color: Colors.black54)),
                                    Text('${g.label}  (${g.count})',
                                        style: const TextStyle(fontSize: 13)),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                flex: 5,
                                child: DropdownButton<String>(
                                  isExpanded: true,
                                  value: g.choice,
                                  items: [
                                    const DropdownMenuItem(
                                        value: '',
                                        child: Text('— Ignore —',
                                            style: TextStyle(
                                                color: Colors.black45))),
                                    ...attr.values.map((v) => DropdownMenuItem(
                                        value: v.id, child: Text(v.name))),
                                  ],
                                  onChanged: (v) =>
                                      setLocal(() => g.choice = v ?? ''),
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

    // Learn each mapped word NOW (before import) so dna_resolve sees it, and add
    // it to _dnaKnown so a re-run doesn't re-ask. Ignored words are stripped from
    // the rows so they don't linger in the payload.
    final ignored = <String>{}; // 'attrId|wordLower' left as Ignore
    for (final g in groups.values) {
      if (g.choice.isEmpty) {
        ignored.add('${g.attributeId}|${g.label.toLowerCase()}');
        continue;
      }
      await _dataSvc.dnaLearnAlias(g.attributeId, g.label, g.choice);
      _dnaKnown[g.attributeId]?.add(g.label.toLowerCase());
    }
    if (ignored.isNotEmpty) {
      for (final r in rows) {
        if (r.dna.isEmpty) continue;
        r.dna.removeWhere((attrId, words) {
          words.removeWhere(
              (w) => ignored.contains('$attrId|${w.trim().toLowerCase()}'));
          return words.isEmpty;
        });
      }
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
        _wideQty = false; _modeChosen = false; // back to the quantity-mode step
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
          : !_modeChosen
              ? _buildModeStep()
              : _parsed
                  ? _buildReview()
                  : _buildIntro(),
    );
  }

  // Step 1 (before any file): choose how the file's box numbers are applied.
  // Picking one advances to the Browse/import page; the choice is shown read-only
  // on Review, never again as a second toggle.
  Widget _buildModeStep() {
    Widget card(String title, String sub, IconData icon, bool overwrite) =>
        InkWell(
          onTap: () => setState(() {
            _overwrite = overwrite;
            _modeChosen = true;
          }),
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFF1B4F72), width: 1.5),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(children: [
              Icon(icon, color: const Color(0xFF1B4F72), size: 30),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1B4F72))),
                    const SizedBox(height: 3),
                    Text(sub,
                        style: const TextStyle(
                            fontSize: 12.5, color: Colors.black54)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Color(0xFF1B4F72)),
            ]),
          ),
        );

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
          20, 24, 20, 20 + MediaQuery.viewPaddingOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('How should the box numbers be applied?',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          const Text(
              'Pick once before choosing your file. You can change it later '
              'with Reset.',
              style: TextStyle(fontSize: 12.5, color: Colors.black54)),
          const SizedBox(height: 20),
          card('Add only',
              "Top-up — add the file's boxes to what you already have",
              Icons.add_circle_outline, false),
          card('Update & keep',
              "Set — replace each design's boxes with the file's number",
              Icons.sync_alt, true),
        ],
      ),
    );
  }

  Widget _buildIntro() => SingleChildScrollView(
        // Bottom inset clears the system nav bar so the bottom button isn't
        // tucked under it (edge-to-edge).
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
            const SizedBox(height: 14),
            // Chosen quantity mode (read-only) + a way back to the mode step.
            Row(children: [
              Icon(_overwrite ? Icons.sync_alt : Icons.add_circle_outline,
                  size: 18, color: const Color(0xFF1B4F72)),
              const SizedBox(width: 6),
              Text('Mode: ${_overwrite ? 'Update & keep' : 'Add only'}',
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1B4F72))),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() => _modeChosen = false),
                child: const Text('Change'),
              ),
            ]),
            const SizedBox(height: 8),
            // Primary action — Browse — on top.
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                onPressed: _pickAndParse,
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('Browse & Pick Excel (.xlsx)',
                    style: TextStyle(fontSize: 15)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1B4F72),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
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
            const Text('Columns',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 8),
            _colTable(),
            const SizedBox(height: 22),
            // Template download — rarely used — kept at the bottom, secondary.
            SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton.icon(
                onPressed: _downloading ? null : _downloadTemplate,
                icon: _downloading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFF1B4F72)))
                    : const Icon(Icons.download_rounded),
                label: Text(
                    _downloading ? 'Preparing…' : 'Download blank template',
                    style: const TextStyle(fontSize: 14.5)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF1B4F72),
                  side: const BorderSide(color: Color(0xFF1B4F72), width: 1.5),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Pre-filled headers with dropdowns for size, quality, surface, '
              'tile type and DNA — pick values instead of typing.',
              style: TextStyle(fontSize: 11, color: Colors.black54),
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
    // Group rows by design identity (name+size) — identity shown once, a line
    // per quality (see _groupedRows).
    final groups = _groupedRows();

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
        // Quantity mode was chosen up-front — shown read-only here (no toggle).
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Row(children: [
            Icon(_overwrite ? Icons.sync_alt : Icons.add_circle_outline,
                size: 15, color: Colors.grey.shade600),
            const SizedBox(width: 5),
            Text(
                'Mode: ${_overwrite ? 'Update & keep (set to file)' : 'Add only (top-up)'}',
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
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
        if (_wideQty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: const Color(0xFF1B4F72).withValues(alpha: 0.06),
            child: const Row(
              children: [
                Icon(Icons.view_column_outlined,
                    size: 15, color: Color(0xFF1B4F72)),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Premium / Standard columns detected — each row becomes a '
                    'separate Premium and Standard stock line.',
                    style: TextStyle(fontSize: 11, color: Color(0xFF1B4F72)),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.fromLTRB(
                12, 12, 12, 12 + MediaQuery.viewPaddingOf(context).bottom),
            itemCount: groups.length,
            itemBuilder: (_, i) => _groupCard(groups[i]),
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

  // Tag + colours for one stock line (holding) by its resolved action.
  ({String tag, Color color, Color border, Color bg}) _rowStyle(_XlsRow r) {
    if (!r.valid) {
      return (tag: 'SKIP', color: Colors.red,
          border: Colors.red.shade200, bg: const Color(0xFFFFEBEE));
    } else if (r.action == 'new') {
      return (tag: 'NEW', color: const Color(0xFF2E7D32),
          border: Colors.green.shade200, bg: const Color(0xFFE8F5E9));
    } else if (r.action == 'map') {
      return (tag: 'MAP', color: const Color(0xFF6A1B9A),
          border: const Color(0xFFE1BEE7), bg: const Color(0xFFF3E5F5));
    }
    return (tag: 'UPDATE', color: const Color(0xFF1B4F72),
        border: Colors.blue.shade100, bg: const Color(0xFFE3F2FD));
  }

  // Group rows by design identity (name + size) so a design with several
  // qualities (wide Premium/Standard, ENTRY batches) shows as ONE card: the
  // identity (tile type / pieces / weight — same for every quality because it
  // lives on the library, keyed by name+size) is shown and filled once, and each
  // quality is a separate stock line. Order = first appearance.
  List<List<_XlsRow>> _groupedRows() {
    final groups = <String, List<_XlsRow>>{};
    final order = <String>[];
    for (final r in _rows) {
      final key = '${r.name.trim().toLowerCase()}|'
          '${_sizeKey(r.size.isNotEmpty ? r.size : r.sizeRaw)}';
      final g = groups[key];
      if (g == null) {
        groups[key] = [r];
        order.add(key);
      } else {
        g.add(r);
      }
    }
    return [for (final k in order) groups[k]!];
  }

  Widget _groupCard(List<_XlsRow> group) {
    final first = group.first;
    final size = first.size.isNotEmpty ? first.size : first.sizeRaw;
    final hasInvalid = group.any((r) => !r.valid);
    final hasNew = group.any((r) => r.valid && r.action == 'new');
    // Card colour: skip(red) if any line invalid, else new(green) if any new,
    // else the first line's style (update / map).
    final head = hasInvalid
        ? _rowStyle(group.firstWhere((r) => !r.valid))
        : hasNew
            ? _rowStyle(group.firstWhere((r) => r.action == 'new'))
            : _rowStyle(first);
    final isNew = group.any((r) => r.valid && r.isNewDesign);
    final mapOnly = group.every((r) => r.mapOnly);
    final brandNames = group
        .firstWhere((r) => r.brandNames.isNotEmpty, orElse: () => first)
        .brandNames;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: head.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: head.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Design identity (shown ONCE) ──
          Row(
            children: [
              if (!hasInvalid) ...[_libThumb(first), const SizedBox(width: 8)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(first.name.isEmpty ? '(no name)' : first.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13.5),
                        overflow: TextOverflow.ellipsis),
                    Text(size.isEmpty ? '(no size)' : size,
                        style: const TextStyle(
                            fontSize: 11.5, color: Colors.black54)),
                  ],
                ),
              ),
              if (group.length > 1)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B4F72).withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('${group.length} qualities',
                      style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1B4F72))),
                ),
            ],
          ),
          const SizedBox(height: 4),
          // ── One line per quality / stock line ──
          ...group.map(_qualityLine),
          // ── Per-brand names written to the Library (shown ONCE) ──
          if (brandNames.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: brandNames.entries
                  .map((a) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color:
                              const Color(0xFF6A1B9A).withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('${_brandLabel(a.key)}: ${a.value}',
                            style: const TextStyle(
                                fontSize: 10.5, color: Color(0xFF6A1B9A))),
                      ))
                  .toList(),
            ),
          ],
          // ── Identity fields — filled ONCE for the whole design (new only) ──
          if (isNew && !mapOnly) _groupIdentity(group),
        ],
      ),
    );
  }

  // One stock line (quality + surface + qty) inside a design group, with its own
  // include checkbox, NEW/UPDATE/SKIP tag and inline editor. Quality is shown
  // prominently so a multi-quality design never reads as a duplicate.
  Widget _qualityLine(_XlsRow r) {
    final st = _rowStyle(r);
    final rest = [
      if (r.surfaceRaw.trim().isNotEmpty) r.surface,
      if (r.qty >= 0) '${r.qty} boxes',
    ].join('  ·  ');
    final quality = r.quality.isNotEmpty ? r.quality : r.qualityRaw;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 28,
              child: r.valid
                  ? Checkbox(
                      value: r.include,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: _importing
                          ? null
                          : (v) => setState(() => r.include = v ?? true),
                    )
                  : null,
            ),
            Expanded(
              child: r.mapOnly
                  ? const Text('map only (not sold under this brand)',
                      style: TextStyle(fontSize: 12, color: Colors.black54))
                  : Text.rich(
                      TextSpan(children: [
                        TextSpan(
                            text: quality.isEmpty ? '(no quality)' : quality,
                            style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1B4F72))),
                        if (rest.isNotEmpty)
                          TextSpan(
                              text: '   $rest',
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.black54)),
                      ]),
                      overflow: TextOverflow.ellipsis),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: st.color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(st.tag,
                  style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: st.color)),
            ),
            Text('  Row ${r.rowNum}',
                style: const TextStyle(fontSize: 9.5, color: Colors.grey)),
            if (!r.mapOnly && r.valid)
              SizedBox(
                width: 30,
                height: 30,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  iconSize: 17,
                  tooltip: r.editing ? 'Done' : 'Edit this line',
                  icon: Icon(r.editing ? Icons.check : Icons.edit_outlined,
                      color: const Color(0xFF1B4F72)),
                  onPressed: _importing
                      ? null
                      : () => setState(() => r.editing = !r.editing),
                ),
              ),
          ],
        ),
        if (!r.valid)
          Padding(
            padding: const EdgeInsets.only(left: 28, bottom: 2),
            child: Text(r.error ?? 'Invalid row',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.red.shade700,
                    fontWeight: FontWeight.w600)),
          ),
        if (r.editing && !r.mapOnly) _rowEditor(r),
      ],
    );
  }

  // The design's identity — tile type / pieces / weight — shown ONCE and written
  // to EVERY quality line in the group (it lives on the library, keyed by
  // name+size, so it can't differ per quality). Blocks Save until filled.
  Widget _groupIdentity(List<_XlsRow> group) {
    final first = group.first;
    final id = identityHashCode(first);
    void setAll(void Function(_XlsRow) f) =>
        setState(() { for (final r in group) { f(r); } });
    final needsFill = group.any((r) => r.valid && r.include && r.needsFill);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        const Text('Fill once for this design:',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.black54)),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
            flex: 4,
            child: DropdownButtonFormField<String>(
              key: ValueKey('tt_$id'),
              initialValue:
                  kTileTypes.contains(first.tileType) ? first.tileType : null,
              isExpanded: true,
              decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Tile type',
                  border: OutlineInputBorder()),
              items: kTileTypes
                  .map((t) => DropdownMenuItem(
                      value: t,
                      child: Text(t, style: const TextStyle(fontSize: 12))))
                  .toList(),
              onChanged:
                  _importing ? null : (v) => setAll((r) => r.tileType = v ?? ''),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 3,
            child: TextFormField(
              key: ValueKey('pc_$id'),
              initialValue: (first.pieces ?? 0) > 0 ? '${first.pieces}' : '',
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Pieces',
                  border: OutlineInputBorder()),
              onChanged: (v) {
                final n = int.tryParse(v.trim());
                setAll((r) => r.pieces = n);
              },
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 3,
            child: TextFormField(
              key: ValueKey('wt_$id'),
              initialValue: (first.weight ?? 0) > 0 ? '${first.weight}' : '',
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Weight kg',
                  border: OutlineInputBorder()),
              onChanged: (v) {
                final w = double.tryParse(v.trim());
                setAll((r) => r.weight = w);
              },
            ),
          ),
        ]),
        if (needsFill)
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
    );
  }

  // Inline per-cell editor for one row (name / size / quality / surface / boxes).
  // Each field writes the canonical value onto the raw field and re-resolves.
  Widget _rowEditor(_XlsRow r) {
    final id = identityHashCode(r);
    final surfOpts =
        _finishes.contains('None') ? _finishes : <String>['None', ..._finishes];
    const qualities = ['Premium', 'Standard'];
    InputDecoration dec(String label) => InputDecoration(
        isDense: true,
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 10));
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        children: [
          TextFormField(
            key: ValueKey('nm_$id'),
            initialValue: r.name,
            style: const TextStyle(fontSize: 12),
            decoration: dec('Design name'),
            onChanged: (v) {
              r.name = v.trim();
              _reResolve(r);
            },
          ),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey('sz_$id'),
                initialValue: _sizes.contains(r.size) ? r.size : null,
                isExpanded: true,
                decoration: dec('Size'),
                items: _sizes
                    .map((s) => DropdownMenuItem(
                        value: s,
                        child: Text(s, style: const TextStyle(fontSize: 12))))
                    .toList(),
                onChanged: _importing
                    ? null
                    : (v) {
                        if (v == null) return;
                        r.sizeRaw = v;
                        _reResolve(r);
                      },
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey('ql_$id'),
                initialValue:
                    qualities.contains(r.quality) ? r.quality : null,
                isExpanded: true,
                decoration: dec('Quality'),
                items: qualities
                    .map((q) => DropdownMenuItem(
                        value: q,
                        child: Text(q, style: const TextStyle(fontSize: 12))))
                    .toList(),
                onChanged: _importing
                    ? null
                    : (v) {
                        if (v == null) return;
                        r.qualityRaw = v;
                        _reResolve(r);
                      },
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey('sf_$id'),
                initialValue:
                    surfOpts.contains(r.surface) ? r.surface : 'None',
                isExpanded: true,
                decoration: dec('Surface'),
                items: surfOpts
                    .map((s) => DropdownMenuItem(
                        value: s,
                        child: Text(s, style: const TextStyle(fontSize: 12))))
                    .toList(),
                onChanged: _importing
                    ? null
                    : (v) {
                        if (v == null) return;
                        r.surfaceRaw = v == 'None' ? '' : v;
                        r.surface = v;
                        _reResolve(r);
                      },
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: TextFormField(
                key: ValueKey('qt_$id'),
                initialValue: r.qty >= 0 ? '${r.qty}' : '',
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 12),
                decoration: dec('Boxes'),
                onChanged: (v) {
                  r.qty = _toInt(v) ?? -1;
                  _reResolve(r);
                },
              ),
            ),
          ]),
        ],
      ),
    );
  }

  // Segmented Add-only / Update&keep button for the quantity mode.
}

class _FinishGroup {
  final String label;
  String choice;
  int count = 0;
  _FinishGroup({required this.label, required this.choice});
}

class _DnaMapGroup {
  final String attributeId;
  final String attributeName;
  final String label;     // the original raw word from the file
  String choice = '';      // chosen value id; '' = ignore
  int count = 0;
  _DnaMapGroup(
      {required this.attributeId,
      required this.attributeName,
      required this.label});
}

// One M_Stockist design while summing its batch rows: the brand faces it was
// packed under + the running Premium/Standard totals + its finish.
class _EntryAgg {
  final String name;
  final String size;
  int premium = 0;
  int standard = 0;
  String surface = '';
  final Set<String> brandIds = {};
  _EntryAgg({required this.name, required this.size});
}
