import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
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
import '../../utils/business_types.dart';
import '../../utils/tile_types.dart';
import '../../models/choice_state.dart';
import '../../widgets/upload_mode.dart';

// Bulk stock import from an Excel (.xlsx) list — for stockists who keep a plain
// spreadsheet (design, size, quality, boxes) instead of a PDF with images.
//
// Core idea ("image once, quantity many times"): a stock line (P_Stock holding) is
// keyed by Name + Size + Quality + Surface. A row that matches all four UPDATES the
// box quantity and reuses the design's existing photo — no image/PDF parsing. Any
// row that doesn't match is added as a NEW holding (a different surface is simply a
// different stock line, never a "conflict"). Surface is aligned to the admin
// finishes first via Map Finishes (which also learns the alias).
/// TWO DOORS. An import either BUILDS PRODUCTS or ADDS STOCK — never both.
///
/// This one screen backs both, because the parsing, the brand matching and the
/// review table are identical; only the purpose differs, and the purpose decides
/// which of the two mutually-exclusive server modes runs.
///
///   • [ImportPurpose.products] → `library_only`. Creates the print + product +
///     box. Imports NO stock. The identity columns (surface, tile type,
///     pieces/box, weight) are COMPULSORY on every row: this sheet is what makes
///     the product, so a blank one would make an incomplete product.
///   • [ImportPurpose.stock] → `match_only`. Adds quantities to products that
///     ALREADY exist. Creates NO product: a row that matches nothing is reported
///     back as unmatched, never minted.
///
/// Before 14 Jul 2026 the stock importer did both, so an unrecognised name
/// silently minted a product with surface `Special`, a NULL body and no box.
/// That is where the 444 incomplete rows came from.
enum ImportPurpose { products, stock }

class ImportExcelStockScreen extends StatefulWidget {
  /// Brand chosen at the Upload tap; upload fills P_Stock for this brand (lists are
  /// curated separately). Null falls back to the default brand.
  final String? initialBrandId;

  /// Which door this is. See [ImportPurpose].
  final ImportPurpose purpose;

  const ImportExcelStockScreen({
    super.key,
    this.initialBrandId,
    this.purpose = ImportPurpose.stock,
  });
  @override
  State<ImportExcelStockScreen> createState() => _ImportExcelStockScreenState();
}

// Header synonyms → the logical field. Matched case-insensitively against the
// sheet's header row, so a stockist's own column wording/order works.
const Map<String, List<String>> _headerSynonyms = {
  'name':     ['name', 'design', 'design name', 'designname', 'product', 'item', 'article',
               'desing', 'desing name'], // common typo (n/g swap)
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
  'master_design', 'masterdesign', 'master design brand',
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
  String surface = '';    // resolved admin finish (after Map Finishes); '' = the sheet gave none
  String rawKey = '';     // normalised raw surface for alias learning
  TileDesign? match;      // matched existing design (name+size+quality)
  String action = 'skip'; // 'update' | 'new' | 'map' | 'skip'
  bool include = true;    // unchecked = excluded from import
  bool editing = false;   // per-cell editor expanded for this row
  bool isNewDesign = false; // name+size not yet in the library (needs identity)
  // This row came through the PRODUCT door, so it is going to CREATE a product.
  bool productDoor = false;
  // A row that will create a product must carry the whole identity: the surface and
  // the body it is keyed on, and the box the thickness is derived from. Blank is not
  // an error — it is a "needs fill" row that blocks Save until it is completed in-app
  // or excluded.
  //
  // On the STOCK door this is always false: a stock row creates no product, so it
  // needs no identity. It only has to MATCH one.
  bool get needsFill =>
      productDoor &&
      (surface.trim().isEmpty ||
          tileType.trim().isEmpty ||
          (pieces ?? 0) <= 0 ||
          (weight ?? 0) <= 0);
  // Combined sheet (brand-name columns): the per-brand names on this row and the
  // master name, written into the Library during the same import. mapOnly = the
  // chosen brand has no name here (tile not sold under it) → map, but no stock.
  Map<String, String> brandNames = {}; // brandId -> design name on this row
  String masterName = '';
  bool mapOnly = false;
  // Auto-detected Design DNA on this row: attributeId -> raw value words (a
  // column whose header matched a DNA attribute name). Resolved on import.
  Map<String, List<String>> dna = {};
  // Per-row brand id for Option 2/3 stock-direct formats (brand determined
  // from column header or Brand col value, not from a global app selection).
  String? rowBrandId;

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

  /// The PRODUCT door. Everything that differs between the two imports hangs off
  /// this one getter.
  bool get _products => widget.purpose == ImportPurpose.products;

  List<_XlsRow> _rows = [];
  // This stockist's OWN Design Library photos matched for the preview
  // (name+size → url), scoped to the target list's brand. Excel carries no
  // images, so this is the only photo per row; never borrows across stockists.
  Map<String, String> _libImages = {};
  List<LibraryEntry> _library = []; // this stockist's own master designs
  final Set<String> _libKeys = {};  // name|size of existing library designs (+aliases)
  // Quantity mode, chosen on the Review screen (with the stock decision), not
  // up-front. "Fully new" also asks whether to wipe just this brand or all of
  // them (_wipeAllBrands), since a single Excel batch's rows can span several
  // brands (M's combined sheets) while p_brand_id is one fallback brand only.
  UploadMode _mode = UploadMode.add;
  bool _wipeAllBrands = false;
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
  // _finishes = the ADMIN canonicals. This is what a row RESOLVES to and what gets
  // stored as surface_type (product identity), so the Map-surfaces step and the
  // resolver both work in these.
  List<String> _finishes = kFinishes;
  // _surfaceWords = the stockist's OWN words for those surfaces ("Raindrop"), each
  // falling back to the admin name where they have no word of their own. This is
  // what they see — in the template dropdown and in the row editor — because it is
  // what is written on their boxes. It is display-only and never a key: the word is
  // resolved back to a canonical on the way in. (my_surface_options)
  List<String> _surfaceWords = kFinishes;
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
  bool _perRowBrand = false; // Option 2/3 stock direct: brand per row, no global selection
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
    _brandId = widget.initialBrandId;
    _loadConfig().then((_) { if (mounted) setState(() {}); });
  }

  void _snack(String m, [Color? c]) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), backgroundColor: c));

  // ── Pick & parse ───────────────────────────────────────────────────────────

  // T/W multi-brand: download Option 2 (brand cols) or Option 3 (Brand value col).
  Future<void> _downloadTWTemplate({required bool option2}) async {
    setState(() => _downloading = true);
    try {
      await _loadConfig();
      final List<int> bytes;
      final String label;
      if (option2) {
        bytes = ExcelTemplateService.buildTWOption2Template(
          sizes: _sizes, surfaceWords: _surfaceWords,
          tileTypes: tileTypeNames, brands: _brands,
        );
        label = 'brand_cols';
      } else {
        bytes = ExcelTemplateService.buildTWOption3Template(
          sizes: _sizes, surfaceWords: _surfaceWords,
          tileTypes: tileTypeNames, brands: _brands,
        );
        label = 'brand_value';
      }
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save stock template',
        fileName: 'tiles_stock_${label}_template.xlsx',
        type: FileType.custom,
        allowedExtensions: const ['xlsx'],
        bytes: Uint8List.fromList(bytes),
      );
      if (!mounted) return;
      if (path != null) {
        if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
          await File(path).writeAsBytes(bytes);
        }
        _snack('Template saved. Fill it, then upload it here.', Colors.green);
      }
    } catch (e) {
      if (mounted) _snack('Could not create template — $e', Colors.red);
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  // M multi-brand: download Option 2 (brand cols) or Option 3 (Master+Brand+Name).
  Future<void> _downloadMTemplate({required bool option2}) async {
    setState(() => _downloading = true);
    try {
      await _loadConfig();
      final List<int> bytes;
      final String label;
      if (option2) {
        bytes = ExcelTemplateService.buildStockTemplate(
          multiBrand: true,
          sizes: _sizes, surfaceWords: _surfaceWords,
          tileTypes: tileTypeNames, dnaAttrs: _dnaAttrs, brands: _brands,
        );
        label = 'brand_cols';
      } else {
        bytes = ExcelTemplateService.buildMOption3Template(
          sizes: _sizes, surfaceWords: _surfaceWords,
          tileTypes: tileTypeNames, brands: _brands,
        );
        label = 'brand_value';
      }
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save stock template',
        fileName: 'tiles_stock_m_${label}_template.xlsx',
        type: FileType.custom,
        allowedExtensions: const ['xlsx'],
        bytes: Uint8List.fromList(bytes),
      );
      if (!mounted) return;
      if (path != null) {
        if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
          await File(path).writeAsBytes(bytes);
        }
        _snack('Template saved. Fill it, then upload it here.', Colors.green);
      }
    } catch (e) {
      if (mounted) _snack('Could not create template — $e', Colors.red);
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

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
        surfaceWords: _surfaceWords,
        tileTypes: tileTypeNames,
        dnaAttrs: _dnaAttrs,
        brands: _brands,
        products: _products,
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
        if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
          await File(path).writeAsBytes(bytes);
        }
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
    try {
      await _loadConfig();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _blockError = 'Could not load your surfaces, sizes and brands — $e';
      });
      return;
    }
    await _parseBytes(res.files.single.bytes!);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadConfig() async {
    try {
      final types = await _dataSvc.getSurfaceTypes(activeOnly: true);
      final names = types.map((t) => t.name).toList();
      // The stockist's own word per surface, admin name where they have none.
      // De-duplicated: two of their words can carry the same display text, and a
      // dropdown (Flutter's and Excel's) needs its values distinct.
      final opts = await _dataSvc.getMySurfaceOptions();
      final seenWords = <String>{};
      final surfaceWords = <String>[];
      for (final o in opts) {
        final w = o.label.trim();
        if (w.isNotEmpty && seenWords.add(w)) surfaceWords.add(w);
      }
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
      if (surfaceWords.isNotEmpty) _surfaceWords = surfaceWords;
      _tileSizes = tileSizes;
    } catch (_) {
      // Never swallow this. The fallbacks are stale constants: a template built on
      // them carries the wrong sizes, the wrong surfaces and no brands at all, yet
      // looks perfectly normal. Silence here is exactly how a 'None' surface — a
      // value the DB refuses — reached a stockist's template. Callers surface it.
      rethrow;
    }
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
      if (_perRowBrand) {
        // Per-row brand (Option 2/3): include all brand aliases so any brand's
        // design name can resolve to the existing library image.
        names.addAll(e.aliases.values.where((v) => v.isNotEmpty));
      } else {
        final alias = brand == null ? null : e.aliases[brand];
        if (alias != null && alias.isNotEmpty) names.add(alias);
      }
      for (final n in names) {
        out[designImageKey(n, e.size)] = e.imageUrl;
      }
    }
    return out;
  }

  // Underscores/hyphens fold to spaces too — real stockist files use
  // "Design_Name", "Design-Name", "Design Name" interchangeably.
  String _normHeader(String h) => h
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[_\-\s]+'), ' ')
      .trim();

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
      // The reader rejects some valid-but-unusual .xlsx (e.g. inline-string files
      // that certain exporters produce). Re-saving from Excel/Sheets rewrites the
      // file cleanly — so give the stockist that fix instead of a dead-end.
      setState(() => _blockError =
          "Couldn't read this Excel file — it may be saved in an unusual format. "
          'Open it in Excel or Google Sheets, choose Save As → .xlsx, then upload '
          'it again.');
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
    // Option 3-M (M multi-brand stock direct): Master Design + Brand value col + Design Name.
    if (_isMOption3Format(header)) {
      await _parseMOption3Format(sheet, header);
      return;
    }
    // Option 3-TW (T/W multi-brand stock direct): Brand value col + Design Name.
    if (_isOption3Format(header)) {
      await _parseOption3Format(sheet, header);
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
    // Tile Type is NOT a required column: a quantity-only / restock sheet (all
    // existing designs) needs no identity, and a NEW design without it is caught
    // per-row by needsFill (filled in-app or excluded) — same as pieces/weight.
    // The PRODUCT sheet carries no quantity at all — not a Quality/Qty pair, not the
    // wide Premium/Standard pair. Demanding them would block every valid design sheet.
    final missing = [
      'size',
      if (!_products && !wideQty) 'quality',
      if (!_products && !wideQty) 'qty',
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

      // A GHOST ROW. The all-cells-empty check above doesn't catch these: a cell that
      // was typed into and then cleared, or one left holding a stray style, keeps the
      // row alive in the .xlsx forever. It names nothing and sizes nothing, so it says
      // nothing — drop it silently rather than reporting "Missing design name" against
      // a row the stockist never filled in. A row with a name but no size is still a
      // real mistake and still surfaces as an error.
      if (masterVal.isEmpty &&
          chosenName.isEmpty &&
          nameVal.isEmpty &&
          brandNames.isEmpty &&
          cell(row, 'size').isEmpty) {
        continue;
      }

      // Option 2 (stock direct): brand cols present → brand is per-row, not
      // global. M uses master col as name (brand-agnostic library key); T/W
      // uses the one filled brand col value. Library mapping is separate.
      final bool isAuthor = isAuthorType(currentStockistBusinessType);
      final String stockName;
      final String masterName;
      final bool mapOnly;
      String? perRowBrandId;
      if (hasBrandCols) {
        final filledList = brandNames.entries.toList();
        stockName = isAuthor
            ? (masterVal.isNotEmpty ? masterVal : nameVal)
            : (filledList.isNotEmpty
                ? filledList.first.value
                : (masterVal.isNotEmpty ? masterVal : nameVal));
        masterName = masterVal.isNotEmpty ? masterVal : stockName;
        mapOnly = false;
        perRowBrandId = filledList.length == 1 ? filledList.first.key : null;
      } else {
        stockName = chosenName.isNotEmpty
            ? chosenName
            : (masterVal.isNotEmpty ? masterVal : nameVal);
        masterName = masterVal.isNotEmpty
            ? masterVal
            : (chosenName.isNotEmpty
                ? chosenName
                : (brandNames.isNotEmpty ? brandNames.values.first : nameVal));
        // mapOnly = "the chosen brand doesn't sell this tile → map the name, add no
        // stock". It is a STOCK-door idea, and its payload deliberately omits the
        // identity block. On the PRODUCT door that would be the old bug back again: a
        // design created with no surface, no body and no box. Every product row carries
        // its full identity, whichever brand's cell happens to be filled.
        mapOnly = !_products &&
            hasBrandCols &&
            chosenName.isEmpty &&
            brandNames.isNotEmpty;
        perRowBrandId = null;
      }

      // Shared fields, parsed once per sheet row (a wide-mode row may fan out
      // into a Premium + a Standard holding that share all of these).
      final sizeRaw = cell(row, 'size');
      final surfaceRaw = cell(row, 'surface');
      final tileType = cell(row, 'tiletype');
      final colour = cell(row, 'colour');
      final pieces = _toInt(cell(row, 'pieces'));
      final weight = _toDouble(cell(row, 'weight'));
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
      if (_products) {
        // The PRODUCT door. One sheet row = one design, and it never fans out into
        // holdings, because it carries no quantity to fan out with.
        parts.add((quality: '', qty: 0));
      } else if (mapOnly) {
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
        // Stock direct: don't show combined-mapping chips; brand tracked via rowBrandId
        xls.brandNames = hasBrandCols ? {} : brandNames;
        xls.masterName = masterName;
        xls.mapOnly = mapOnly;
        xls.rowBrandId = perRowBrandId;
        // Option 2 validation: exactly 1 brand col must be filled per row
        if (hasBrandCols && brandNames.length != 1) {
          xls.error = brandNames.isEmpty
              ? 'No brand column filled — fill exactly one brand column'
              : 'Only 1 brand column per row (${brandNames.length} filled)';
        }
        // Each sub-row gets its own DNA copy (the Map-DNA step mutates per row).
        xls.dna = {
          for (final e in dna.entries) e.key: List<String>.from(e.value)
        };
        parsed.add(xls);
      }
    }

    if (parsed.isEmpty) {
      setState(() => _blockError = 'No data rows found (only a header?).');
      return;
    }
    _combined = false; // stock direct: library mapping is separate
    _perRowBrand = hasBrandCols;
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
    // Optional identity columns — read when present so new ENTRY designs carry
    // tile type / pieces / weight from the sheet (no manual per-row fill).
    final ttCol = idx(_headerSynonyms['tiletype']!);
    final pcCol = idx(_headerSynonyms['pieces']!);
    final wtCol = idx(_headerSynonyms['weight']!);

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
      final bid = brandMap[_cleanBrandVal(cellAt(row, brandValCol))];
      // "Don't import" → drop the row entirely (no qty, surface or brand from it).
      if (bid == _kSkip) continue;
      final sz = _cleanSize(cellAt(row, sizeCol));
      final key = '${dn.toLowerCase()}|${_sizeKey(sz)}';
      final a = agg.putIfAbsent(key, () => _EntryAgg(name: dn, size: sz));
      if (preCol >= 0) a.premium += _toInt(cellAt(row, preCol)) ?? 0;
      if (stdCol >= 0) a.standard += _toInt(cellAt(row, stdCol)) ?? 0;
      if (catCol >= 0 && a.surface.isEmpty) a.surface = cellAt(row, catCol).trim();
      // Take the first non-empty identity value seen across the design's batch.
      if (ttCol >= 0 && a.tileType.isEmpty) a.tileType = cellAt(row, ttCol).trim();
      if (pcCol >= 0 && a.pieces == null) a.pieces = _toInt(cellAt(row, pcCol));
      if (wtCol >= 0 && a.weight == null) a.weight = _toDouble(cellAt(row, wtCol));
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
          tileType: a.tileType,
          colour: '',
          qty: qty,
          pieces: a.pieces,
          weight: a.weight,
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

  // ── Option 3 (T/W multi-brand stock direct) ─────────────────────────────────
  // Brand value col + Design Name col. Brand col value matched to known brands
  // per row. No master-design concept for T/W — design name IS the master.

  // M Option 3: Master Design col + Brand value col + Design Name col.
  bool _isMOption3Format(List<String> header) {
    if (_isEntryFormat(header)) return false;
    if (header.any((h) => _brands.any((b) => _normHeader(b.name) == h))) return false;
    final hasMasterCol = header.any((h) => _masterHeaders.contains(h));
    final hasBrandCol  = header.any((h) => _brandColHeaders.contains(h));
    final hasNameCol   = header.any((h) => _headerSynonyms['name']!.contains(h));
    return hasMasterCol && hasBrandCol && hasNameCol;
  }

  // T/W Option 3: Brand value col + Design Name col (no Master Design col).
  bool _isOption3Format(List<String> header) {
    if (_isEntryFormat(header)) return false;
    if (header.any((h) => _brands.any((b) => _normHeader(b.name) == h))) return false;
    if (header.any((h) => _masterHeaders.contains(h))) return false; // M Option 3 handles this
    final hasBrandCol = header.any((h) => _brandColHeaders.contains(h));
    final hasNameCol  = header.any((h) => _headerSynonyms['name']!.contains(h));
    return hasBrandCol && hasNameCol;
  }

  Future<void> _parseOption3Format(Sheet sheet, List<String> header) async {
    final brandCol = header.indexWhere((h) => _brandColHeaders.contains(h));
    final nameCol = header.indexWhere((h) =>
        _headerSynonyms['name']!.contains(h) || _masterHeaders.contains(h));
    final sizeCol = header.indexWhere((h) => _headerSynonyms['size']!.contains(h));
    final qualCol = header.indexWhere((h) => _headerSynonyms['quality']!.contains(h));
    final qtyCol  = header.indexWhere((h) => _headerSynonyms['qty']!.contains(h));
    final surfCol = header.indexWhere((h) => _headerSynonyms['surface']!.contains(h));
    final ttCol   = header.indexWhere((h) => _headerSynonyms['tiletype']!.contains(h));
    final pcCol   = header.indexWhere((h) => _headerSynonyms['pieces']!.contains(h));
    final wtCol   = header.indexWhere((h) => _headerSynonyms['weight']!.contains(h));
    final premCol = header.indexWhere((h) => _premiumQtyHeaders.contains(h));
    final stdCol  = header.indexWhere((h) => _standardQtyHeaders.contains(h));
    final wideQty = premCol >= 0 || stdCol >= 0;

    if (sizeCol < 0) {
      setState(() => _blockError = 'Missing required column: Size.');
      return;
    }
    if (!wideQty && (qualCol < 0 || qtyCol < 0)) {
      setState(() => _blockError =
          'Missing required columns: Quality and Box Quantity (or Premium/Standard).');
      return;
    }

    String cellAt(List<Data?> row, int i) {
      if (i < 0 || i >= row.length) return '';
      return row[i]?.value?.toString().trim() ?? '';
    }

    // Brand name → brand_id lookup (case-insensitive)
    final brandLookup = <String, String>{
      for (final b in _brands) _normHeader(b.name): b.id,
    };

    final parsed = <_XlsRow>[];
    for (var r = 1; r < sheet.rows.length; r++) {
      final row = sheet.rows[r];
      final blank = row.every((c) =>
          c == null || c.value == null || c.value.toString().trim().isEmpty);
      if (blank) continue;

      final brandVal = cellAt(row, brandCol);
      final brandId  = brandLookup[_normHeader(brandVal)];
      final stockName = cellAt(row, nameCol);
      final sizeRaw   = cellAt(row, sizeCol);
      final surfRaw   = surfCol >= 0 ? cellAt(row, surfCol) : '';
      final tileType  = ttCol >= 0  ? cellAt(row, ttCol)  : '';
      final pieces    = pcCol >= 0  ? _toInt(cellAt(row, pcCol))    : null;
      final weight    = wtCol >= 0  ? _toDouble(cellAt(row, wtCol)) : null;

      final parts = <({String quality, int qty})>[];
      if (wideQty) {
        if (premCol >= 0) {
          final v = cellAt(row, premCol);
          if (v.isNotEmpty) parts.add((quality: 'Premium', qty: _toInt(v) ?? -1));
        }
        if (stdCol >= 0) {
          final v = cellAt(row, stdCol);
          if (v.isNotEmpty) parts.add((quality: 'Standard', qty: _toInt(v) ?? -1));
        }
      } else {
        parts.add((
          quality: cellAt(row, qualCol),
          qty: _toInt(cellAt(row, qtyCol)) ?? -1,
        ));
      }

      for (final part in parts) {
        final xls = _XlsRow(
          rowNum: r + 1,
          name: stockName,
          sizeRaw: sizeRaw,
          qualityRaw: part.quality,
          surfaceRaw: surfRaw,
          tileType: tileType,
          colour: '',
          qty: part.qty,
          pieces: pieces,
          weight: weight,
        );
        xls.masterName = stockName;
        xls.mapOnly = false;
        xls.rowBrandId = brandId;
        if (stockName.isEmpty) {
          xls.error = 'Missing design name';
        } else if (brandVal.isEmpty) {
          xls.error = 'No brand value — fill the Brand column';
        } else if (brandId == null) {
          xls.error = "Unknown brand '$brandVal' — not in your brand list";
        }
        parsed.add(xls);
      }
    }

    if (parsed.isEmpty) {
      setState(() => _blockError = 'No data rows found (only a header?).');
      return;
    }

    _combined = false;
    _perRowBrand = true;
    _wideQty = wideQty;

    _validateAndResolve(parsed);
    final ok = await _mapFinishesStep(parsed);
    if (!ok) return;
    final okDna = await _mapDnaStep(parsed);
    if (!okDna) return;
    _computeActions(parsed);
    setState(() {
      _rows = parsed; _parsed = true; _done = 0; _libImages = _ownLibImages();
    });
  }

  // ── M Option 3 (M multi-brand stock direct) ────────────────────────────────
  // Master Design col (library key) + Brand value col + Design Name col.

  Future<void> _parseMOption3Format(Sheet sheet, List<String> header) async {
    final masterColIdx = header.indexWhere((h) => _masterHeaders.contains(h));
    final brandColIdx  = header.indexWhere((h) => _brandColHeaders.contains(h));
    final nameColIdx   = header.indexWhere((h) => _headerSynonyms['name']!.contains(h));
    final sizeCol      = header.indexWhere((h) => _headerSynonyms['size']!.contains(h));
    final qualCol      = header.indexWhere((h) => _headerSynonyms['quality']!.contains(h));
    final qtyCol       = header.indexWhere((h) => _headerSynonyms['qty']!.contains(h));
    final surfCol      = header.indexWhere((h) => _headerSynonyms['surface']!.contains(h));
    final ttCol        = header.indexWhere((h) => _headerSynonyms['tiletype']!.contains(h));
    final pcCol        = header.indexWhere((h) => _headerSynonyms['pieces']!.contains(h));
    final wtCol        = header.indexWhere((h) => _headerSynonyms['weight']!.contains(h));
    final premCol      = header.indexWhere((h) => _premiumQtyHeaders.contains(h));
    final stdCol       = header.indexWhere((h) => _standardQtyHeaders.contains(h));
    final wideQty      = premCol >= 0 || stdCol >= 0;

    if (sizeCol < 0) {
      setState(() => _blockError = 'Missing required column: Size.');
      return;
    }
    if (!wideQty && (qualCol < 0 || qtyCol < 0)) {
      setState(() => _blockError =
          'Missing required columns: Quality and Box Quantity (or Premium/Standard).');
      return;
    }

    String cellAt(List<Data?> row, int i) {
      if (i < 0 || i >= row.length) return '';
      return row[i]?.value?.toString().trim() ?? '';
    }

    final brandLookup = <String, String>{
      for (final b in _brands) _normHeader(b.name): b.id,
    };

    final parsed = <_XlsRow>[];
    for (var r = 1; r < sheet.rows.length; r++) {
      final row = sheet.rows[r];
      final blank = row.every((c) =>
          c == null || c.value == null || c.value.toString().trim().isEmpty);
      if (blank) continue;

      final masterDesign = masterColIdx >= 0 ? cellAt(row, masterColIdx) : '';
      final brandVal     = cellAt(row, brandColIdx);
      final brandId      = brandLookup[_normHeader(brandVal)];
      final designName   = nameColIdx >= 0 ? cellAt(row, nameColIdx) : '';
      final sizeRaw      = cellAt(row, sizeCol);
      final surfRaw      = surfCol >= 0 ? cellAt(row, surfCol) : '';
      final tileType     = ttCol >= 0 ? cellAt(row, ttCol) : '';
      final pieces       = pcCol >= 0 ? _toInt(cellAt(row, pcCol)) : null;
      final weight       = wtCol >= 0 ? _toDouble(cellAt(row, wtCol)) : null;

      // Library key = Master Design name; fall back to Design Name if blank.
      final stockName = masterDesign.isNotEmpty ? masterDesign : designName;

      final parts = <({String quality, int qty})>[];
      if (wideQty) {
        if (premCol >= 0) {
          final v = cellAt(row, premCol);
          if (v.isNotEmpty) parts.add((quality: 'Premium', qty: _toInt(v) ?? -1));
        }
        if (stdCol >= 0) {
          final v = cellAt(row, stdCol);
          if (v.isNotEmpty) parts.add((quality: 'Standard', qty: _toInt(v) ?? -1));
        }
      } else {
        parts.add((
          quality: cellAt(row, qualCol),
          qty: _toInt(cellAt(row, qtyCol)) ?? -1,
        ));
      }

      for (final part in parts) {
        final xls = _XlsRow(
          rowNum: r + 1,
          name: stockName,
          sizeRaw: sizeRaw,
          qualityRaw: part.quality,
          surfaceRaw: surfRaw,
          tileType: tileType,
          colour: '',
          qty: part.qty,
          pieces: pieces,
          weight: weight,
        );
        xls.masterName = stockName;
        xls.mapOnly = false;
        xls.rowBrandId = brandId;
        if (stockName.isEmpty) {
          xls.error = 'Missing master design name';
        } else if (brandVal.isEmpty) {
          xls.error = 'No brand value — fill the Brand column';
        } else if (brandId == null) {
          xls.error = "Unknown brand '$brandVal' — not in your brand list";
        }
        parsed.add(xls);
      }
    }

    if (parsed.isEmpty) {
      setState(() => _blockError = 'No data rows found (only a header?).');
      return;
    }

    _combined = false;
    _perRowBrand = true;
    _wideQty = wideQty;

    _validateAndResolve(parsed);
    final ok = await _mapFinishesStep(parsed);
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
  static const _kSkip = '__skip__';
  Future<Map<String, String>?> _mapBrandValues(List<String> values) async {
    if (values.isEmpty) return {};
    // value → chosen ('__skip__', '__create__', or an existing brand id).
    // Default: match an existing brand by name, else "Don't import" — creating a
    // brand can hit the 5-brand cap, and unmatched values are often stray data
    // (e.g. a design name in the wrong column), not real brands.
    final choice = <String, String>{};
    for (final v in values) {
      final m = _brands
          .where((b) => b.name.trim().toLowerCase() == v.trim().toLowerCase())
          .toList();
      choice[v] = m.isEmpty ? _kSkip : m.first.id;
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
                    'create it. Designs are filed under the brand you pick. '
                    'Unknown values default to “Don’t import”, so their rows are '
                    'skipped.',
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
                                    const DropdownMenuItem(
                                        value: _kSkip,
                                        child: Text('🚫 Don’t import',
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.black54))),
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
      if (entry.value == _kSkip) {
        result[entry.key] = _kSkip; // pass through; rows with it are dropped
      } else if (entry.value == _kCreateBrand) {
        try {
          final id = await _dataSvc.createBrand(entry.key);
          if (id.isEmpty) throw 'no id';
          result[entry.key] = id;
        } catch (e) {
          // A brand-cap hit is the common case — guide instead of dumping the raw
          // exception, and don't lose the whole import to one stray value.
          final capped = e.toString().toLowerCase().contains('limit');
          if (mounted) {
            _snack(
                capped
                    ? 'You’ve reached the 5-brand limit. Set “${entry.key}” to '
                        '“Don’t import” or map it to an existing brand, then try again.'
                    : 'Could not create brand “${entry.key}” — $e',
                Colors.red);
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
      // The PRODUCT door has no quality and no quantity — there is no stock on that
      // sheet at all, so neither is a column and neither can be "missing". Only the
      // stock door validates them.
      if (!_products) {
        if (r.qualityRaw.isEmpty) { r.error = 'Missing quality'; continue; }
        final q = _normQuality(r.qualityRaw);
        if (q.isEmpty) { r.error = "Unknown quality '${r.qualityRaw}'"; continue; }
        r.quality = q;
        if (r.qty < 0) { r.error = 'Missing / invalid box quantity'; continue; }
      }
      r.productDoor = _products;
      // Brand-new design? (name+size not yet in the library — master name OR any brand
      // alias.) On the PRODUCT door that is the normal case, and the row must carry the
      // full identity (see needsFill).
      r.isNewDesign =
          !_libKeys.contains('${r.name.trim().toLowerCase()}|${_sizeKey(r.size)}');
      // On the STOCK door a design we don't have is not something we invent — that is
      // exactly how the 444 surface-less, body-less, box-less products got made. Catch it
      // HERE, in the review, rather than letting the server report it back as unmatched.
      if (!_products && r.isNewDesign && !r.mapOnly) {
        r.error = "Not in your Library — import the design first";
        continue;
      }
      // Tile type: validate the wording if given; never block on blank here.
      if (r.tileType.trim().isNotEmpty) {
        final tt = tileTypeNames.firstWhere(
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
          // An unmapped word can no longer fall back to 'None' — a tile always has a
          // surface, and the DB refuses 'None'. Fall back to the first active finish; the
          // Map-Finishes step is where the human corrects it.
          r.surface = _finishes.isNotEmpty ? _finishes.first : '';
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
        // PRODUCT door: the surface is identity, so it is compulsory — needsFill already
        // blocked a blank one, and surfaceForImport is the last-resort 'Special'.
        //
        // STOCK door: send the word ONLY if the sheet actually gave one, because there it
        // does not DESCRIBE the row, it CHOOSES which product the row means. Defaulting a
        // blank to 'Special' here would filter the match against a surface the product
        // hasn't got and leave every row unmatched. Blank = "the product knows its own
        // surface, inherit it" — which is what the server does.
        'surface': _products
            ? surfaceForImport(r.surface)
            : (r.surface.trim().isEmpty ? null : r.surface.trim()),
        'surface_label': r.surfaceRaw.trim(),
        'colour': r.colour,
        'qty': r.qty,
        'stock_type': 'Uncertain',
        'tile_type': tileTypeNames.contains(r.tileType) ? r.tileType : '',
        'pieces_per_box': r.pieces ?? 0,
        'box_weight_kg': r.weight ?? 0,
        'thickness_mm': approxThicknessMm(
                r.size, r.pieces ?? 0, r.weight ?? 0,
                tileTypeNames.contains(r.tileType)
                    ? r.tileType
                    : tileTypeNames.first) ??
            0,
        if (libUrl != null) 'image_url': libUrl,
        // surface_label now carries the stockist's word; no separate finish_label.
      };
      final hasDna = r.dna.isNotEmpty;
      if (isCombined) {
        row['master_name'] = r.masterName.trim();
        row['aliases'] = aliasJson;
        mapped++;
      } else if (!_products && !hasDna && !r.isNewDesign) {
        // EXISTING plain design, no DNA → leave the Library untouched. A NEW design
        // must keep skip_master OFF so its identity (tile type/pieces/weight) is set.
        //
        // Never on the PRODUCT door: writing the identity IS that sheet's job, and a
        // re-import is how a corrected box weight (and so the thickness) gets in.
        row['skip_master'] = true;
      }
      // A plain row WITH DNA keeps skip_master off so a master exists to tag it.
      if (hasDna) row['dna'] = r.dna;
      // Stock-direct (Option 2/3): the row's filled brand column sets the HOLDING's
      // brand — for BOTH M (per-brand stock) and T/W. Passed as a per-row brand_id
      // so the holding lands under that brand, not the global upload brand.
      // (project_per_brand_stock)
      if (_perRowBrand && r.rowBrandId != null) {
        row['brand_id'] = r.rowBrandId;
        // T/W: also record the brand's design name (brand silo lib lookup). M keeps
        // its existing alias from the library — don't overwrite it here.
        if (isImporterType(currentStockistBusinessType) &&
            row['aliases'] == null) {
          row['aliases'] = [{'brand_id': r.rowBrandId, 'name': r.name.trim()}];
        }
      }
      rows.add(row);

      if (libUrl != null) imagesFromLibrary++;
      if (r.action == 'new') news++;
      // Remember the finish wording → chosen finish for next time.
      if (r.rawKey.isNotEmpty && r.surface.isNotEmpty) learned[r.rawKey] = r.surface;
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
        // The product door imports nothing but products; the stock door creates no
        // product. The server rejects both flags together.
        libraryOnly: _products,
        matchOnly: !_products,
        mode: _products ? UploadMode.add.api : _mode.api,
        // Per-row multi-brand file → wipe exactly the brands it covers;
        // single-brand file → the this-brand / all-brands toggle.
        wipeAllBrands: !_products &&
            _mode == UploadMode.fullyNew &&
            !_perRowBrand &&
            _wipeAllBrands,
        wipeBrandIds: !_products && _mode == UploadMode.fullyNew && _perRowBrand
            ? _fileBrandIds()
            : null,
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
    final masters = (res['masters'] as num?)?.toInt() ?? 0;
    final dnaTagged = (res['dna_tagged'] as num?)?.toInt() ?? 0;
    // Stock door only: rows that matched no product. They were NOT created.
    final unmatched = (res['unmatched'] as num?)?.toInt() ?? 0;
    final libNote = imagesFromLibrary > 0
        ? ' · $imagesFromLibrary photos from library'
        : '';
    final dnaNote = dnaTagged > 0 ? ' · $dnaTagged DNA tagged' : '';
    final brandNote = _brandName.isEmpty ? '' : ' → $_brandName';

    if (_products) {
      _snack(
          'Done — $masters designs in your Library$dnaNote$libNote. '
          'No stock was imported; use Import Stock for that.',
          Colors.green);
      if (masters > 0) Navigator.of(context).pop();
      return;
    }

    final mapNote = mapped > 0 ? ' · $mapped mapped to library' : '';
    if (unmatched > 0) {
      // Never silently minted. Say so plainly, and stay on the screen so he can fix it.
      _snack(
          '$updated updated, $created new$mapNote$libNote$brandNote — but $unmatched '
          "row${unmatched == 1 ? '' : 's'} matched no design and were NOT imported. "
          'Import those designs first, then upload this again.',
          Colors.orange.shade800);
      return;
    }
    _snack(
        'Done — $updated updated, $created new$mapNote$dnaNote$libNote$brandNote. '
        'Add designs to a stock list to show buyers.',
        Colors.green);
    if (updated + created + mapped > 0) Navigator.of(context).pop();
  }

  void _reset() => setState(() {
        _rows = []; _parsed = false; _blockError = ''; _done = 0; _filename = '';
        _libImages = {}; _combined = false; _batchId = ''; _dnaDetected = [];
        _wideQty = false; _perRowBrand = false;
      });

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_products
            ? 'Import Designs from Excel'
            : 'Import Stock from Excel'),
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
            // Template download — multi-brand gets two options; single-brand gets one.
            // The PRODUCT door always gets the one sheet: the Option-2/3 skins are
            // stock-direct shapes (they are built around the quantity columns), and the
            // product sheet has no quantities at all.
            if (!_products && _brands.length > 1) ...[
              const Text('Download blank template',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _downloading ? null : () => isImporterType(currentStockistBusinessType)
                        ? _downloadTWTemplate(option2: true)
                        : _downloadMTemplate(option2: true),
                    icon: const Icon(Icons.view_column_outlined, size: 18),
                    label: const Text('Brand columns', style: TextStyle(fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF6A1B9A),
                      side: const BorderSide(color: Color(0xFF6A1B9A), width: 1.5),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _downloading ? null : () => isImporterType(currentStockistBusinessType)
                        ? _downloadTWTemplate(option2: false)
                        : _downloadMTemplate(option2: false),
                    icon: const Icon(Icons.label_outline, size: 18),
                    label: const Text('Brand + Name col', style: TextStyle(fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF6A1B9A),
                      side: const BorderSide(color: Color(0xFF6A1B9A), width: 1.5),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              Text(
                isImporterType(currentStockistBusinessType)
                    ? 'Brand columns — all brands as headers, fill one per row.\nBrand + Name col — write brand name in a cell per row.'
                    : 'Brand columns — Master Design + brand headers, fill one brand per row.\nBrand + Name col — Master Design + Brand value cell + Design Name per row.',
                style: const TextStyle(fontSize: 11, color: Colors.black54),
              ),
            ] else ...[
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
                      _downloading
                          ? 'Preparing…'
                          : _products
                              ? 'Download blank design sheet'
                              : 'Download blank template',
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
              Text(
                _products
                    ? 'Dropdowns for size, surface, tile type and DNA — pick values '
                        'instead of typing. Every column is compulsory: this sheet '
                        'creates the design.'
                    : 'Pre-filled headers with dropdowns for size, quality, surface, '
                        'tile type and DNA — pick values instead of typing.',
                style: const TextStyle(fontSize: 11, color: Colors.black54),
              ),
            ],
          ],
        ),
      );

  Widget _colTable() {
    // The two doors want two different sheets. The product sheet has no quantity at
    // all and every identity column is compulsory (it is what MAKES the design). The
    // stock sheet has no identity block, because it can no longer create a design —
    // an unknown name is reported, not invented.
    const productCols = [
      ('Design Name', 'required — or a brand / master column', true),
      ('Size', 'required — must match your sizes', true),
      ('Surface / Finish', 'required — two surfaces = two designs', true),
      ('Tile Type', 'required — the body', true),
      ('Pieces/Box', 'required — off the box', true),
      ('Box Weight', 'required — off the box; the thickness comes from it', true),
      ('Master design name', 'optional — links your brands in the Library', false),
      ('<Brand name> columns', 'optional — one per brand; the design name printed '
          'on that brand\'s box.', false),
      ('DNA columns', 'optional — how the tile looks', false),
    ];
    const stockCols = [
      ('Design Name', 'required — must already be in your Library', true),
      ('Size', 'required — must match your sizes', true),
      ('Quality', 'required — Premium / Standard', true),
      ('Box Quantity', 'required — the boxes to add', true),
      ('Surface / Finish', 'only if you stock one name in two surfaces', false),
      ('Master design name', 'optional — links your brands in the Library', false),
      ('<Brand name> columns', 'optional — one per brand; the design name under '
          'each. The chosen brand\'s name becomes the stock; all are mapped.', false),
    ];
    final cols = _products ? productCols : stockCols;
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

  // Distinct brand ids present in the rows that will actually import — the wipe
  // scope for a per-row multi-brand file (Option 2/3).
  List<String> _fileBrandIds() => _rows
      .where((r) => r.valid && r.include && r.rowBrandId != null)
      .map((r) => r.rowBrandId!)
      .toSet()
      .toList();

  // Human names for those brands, for the confirm dialog / inline note.
  String _fileBrandLabel() {
    final ids = _fileBrandIds().toSet();
    final names = _brands.where((b) => ids.contains(b.id)).map((b) => b.name);
    return names.isEmpty ? 'the brands in this file' : names.join(', ');
  }

  // Every mode goes through the same guarded confirm the PDF importer uses
  // (showUploadModeConfirm). "Fully new" scope depends on the file shape:
  //  • per-row multi-brand file → wipe exactly the brands the file covers
  //    (no toggle — a "this brand only" choice is meaningless when the file
  //    already spans several brands);
  //  • single-brand file → the this-brand / all-brands toggle below the chips.
  Future<void> _pickQtyMode(UploadMode m) async {
    if (m == _mode) return;
    final String scopeLabel;
    if (m == UploadMode.fullyNew) {
      scopeLabel = _perRowBrand
          ? _fileBrandLabel()
          : (_wipeAllBrands ? 'ALL your brands' : _brandName);
    } else {
      scopeLabel = _brandName;
    }
    final ok = await showUploadModeConfirm(context, m, scopeLabel);
    if (!ok || !mounted) return;
    setState(() => _mode = m);
  }

  // Switches the wipe scope for the already-selected single-brand "Fully new".
  // Each switch is re-confirmed (same guarded dialog) since it changes what's
  // about to be zeroed. (Only reachable for non-per-row files.)
  Future<void> _pickWipeScope(bool all) async {
    if (all == _wipeAllBrands) return;
    final scopeLabel = all ? 'ALL your brands' : _brandName;
    final ok =
        await showUploadModeConfirm(context, UploadMode.fullyNew, scopeLabel);
    if (!ok || !mounted) return;
    setState(() => _wipeAllBrands = all);
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
        // Destination brand — hidden for stock direct (brand per row), static
        // label for single-brand, dropdown for multi-brand legacy combined.
        if (_perRowBrand)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            alignment: Alignment.centerLeft,
            child: const Text('Brand detected per row from column',
                style: TextStyle(fontSize: 12, color: Color(0xFF6A1B9A))),
          )
        else if (_brands.length <= 1)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            alignment: Alignment.centerLeft,
            child: Text(
                'Adding to: ${_brandName.isEmpty ? 'your stock' : _brandName}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF1B4F72))),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                const Text('Brand:', style: TextStyle(fontSize: 12)),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButton<String>(
                    value: _brandId,
                    isExpanded: true,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    items: _brands
                        .map((b) => DropdownMenuItem(
                            value: b.id,
                            child: Text(b.name,
                                style: const TextStyle(fontSize: 13))))
                        .toList(),
                    onChanged: _importing
                        ? null
                        : (v) {
                            if (v == null) return;
                            final b =
                                _brands.firstWhere((br) => br.id == v);
                            setState(() {
                              _brandId = b.id;
                              _brandName = b.name;
                            });
                          },
                  ),
                ),
              ],
            ),
          ),
        // Quantity mode is chosen HERE, with the stock decision (not up-front) —
        // mirrors the PDF flow. Only affects rows that carry a box quantity.
        // The PRODUCT door has no box quantity to add, replace or keep, so the whole
        // control is meaningless there — and "Fully new" is destructive.
        if (!_products)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 4,
              children: [
                Text('Box numbers:',
                    style:
                        TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
                for (final m in UploadMode.values)
                  ChoiceChip(
                    label: Text(m.label, style: const TextStyle(fontSize: 11.5)),
                    selected: _mode == m,
                    onSelected: _importing ? null : (_) => _pickQtyMode(m),
                    selectedColor: m.isDestructive
                        ? Colors.red.shade700
                        : const Color(0xFF1B4F72),
                    labelStyle: TextStyle(
                        color:
                            _mode == m ? Colors.white : const Color(0xFF1B4F72)),
                  ),
              ],
            ),
          ),
        // Wipe scope — only while "Fully new" is selected.
        //  • Per-row multi-brand file: no toggle — the file already covers
        //    several brands, so it wipes exactly those (shown as a note).
        //  • Single-brand file: this-brand / all-brands toggle, each switch
        //    re-runs the guarded confirm since it changes what gets zeroed.
        if (_mode == UploadMode.fullyNew && _perRowBrand)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 14, color: Colors.red.shade700),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                      'Will refresh stock for the brands in this file '
                      '(${_fileBrandLabel()}); their designs not in the file '
                      'drop to 0. Other brands untouched.',
                      style: TextStyle(
                          fontSize: 11.5, color: Colors.red.shade700)),
                ),
              ],
            ),
          )
        else if (_mode == UploadMode.fullyNew)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 4,
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 14, color: Colors.red.shade700),
                Text('Wipe scope:',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
                ChoiceChip(
                  label: Text(
                      _brandName.isEmpty ? 'This brand only' : '$_brandName only',
                      style: const TextStyle(fontSize: 11.5)),
                  selected: !_wipeAllBrands,
                  onSelected:
                      _importing ? null : (_) => _pickWipeScope(false),
                  selectedColor: const Color(0xFF1B4F72),
                  labelStyle: TextStyle(
                      color: !_wipeAllBrands ? Colors.white : const Color(0xFF1B4F72)),
                ),
                ChoiceChip(
                  label: const Text('All my brands',
                      style: TextStyle(fontSize: 11.5)),
                  selected: _wipeAllBrands,
                  onSelected: _importing ? null : (_) => _pickWipeScope(true),
                  selectedColor: Colors.red.shade700,
                  labelStyle: TextStyle(
                      color: _wipeAllBrands ? Colors.white : Colors.red.shade700),
                ),
              ],
            ),
          ),
        if (incomplete > 0)
          Container(
            width: double.infinity,
            color: const Color(0xFFFFF3E0),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    _products
                        ? '$incomplete design${incomplete == 1 ? '' : 's'} need Surface, '
                            'Tile Type, Pieces and Box Weight. Fill them below (or untick '
                            'the row) to import.'
                        : '$incomplete new design${incomplete == 1 ? '' : 's'} need Tile Type, '
                            'Pieces and Box Weight. Fill them below (or untick the row) to import.',
                    style:
                        TextStyle(fontSize: 11.5, color: Colors.orange.shade900)),
                const SizedBox(height: 3),
                Text(
                    _products
                        ? 'Tip: fill “Surface”, “Tile Type”, “Pieces/Box” and “Weight (kg)” in '
                            'the sheet and they’ll import automatically — no filling needed.'
                        : 'Tip: add “Tile Type”, “Pieces/Box” and “Weight (kg)” columns to your '
                            'file and they’ll import automatically — no filling needed.',
                    style: TextStyle(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                        color: Colors.orange.shade800)),
              ],
            ),
          ),
        // Prominent skipped-rows warning: invalid rows are excluded from the import,
        // so a wrong row (e.g. two brand columns filled) can't slip past unnoticed.
        if (skipped > 0)
          Container(
            width: double.infinity,
            color: const Color(0xFFFFEBEE),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 18, color: Color(0xFFC62828)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      '$skipped row${skipped == 1 ? '' : 's'} will be SKIPPED (invalid) and '
                      'will NOT import. Scroll down — the red rows show why '
                      '(e.g. more than one brand column filled in a row).',
                      style: TextStyle(
                          fontSize: 11.5,
                          color: Colors.red.shade900,
                          fontWeight: FontWeight.w500)),
                ),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: const Color(0xFF1B4F72).withValues(alpha: 0.06),
          child: Row(
            children: [
              // On the PRODUCT door "Update / New" would read as stock lines. There are
              // none: every row is a design, so count designs.
              if (!_products) ...[
                _chip('$updates', 'Update', const Color(0xFF1B4F72)),
                const SizedBox(width: 10),
                _chip('$news', 'New', const Color(0xFF2E7D32)),
              ] else
                _chip('${updates + news}', 'Designs', const Color(0xFF2E7D32)),
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

  /// The surface as the STOCKIST reads it: their own word from the sheet, with
  /// the admin canonical in brackets — "RAINDROP (Sugar)". Just the word when the
  /// two match, so nothing reads "Matt (Matt)". Showing the bare canonical here
  /// would tell a stockist their sheet said "Sugar" when it said "RAINDROP".
  /// (project_per_brand_surface_mode)
  String _surfaceShown(_XlsRow r) {
    final word = r.surfaceRaw.trim();
    final canonical = r.surface.trim();
    if (canonical.isEmpty || canonical.toLowerCase() == 'none') return word;
    if (word.isEmpty || word.toLowerCase() == canonical.toLowerCase()) {
      return canonical;
    }
    return '$word ($canonical)';
  }

  // One stock line (quality + surface + qty) inside a design group, with its own
  // include checkbox, NEW/UPDATE/SKIP tag and inline editor. Quality is shown
  // prominently so a multi-quality design never reads as a duplicate.
  Widget _qualityLine(_XlsRow r) {
    final st = _rowStyle(r);
    // On the PRODUCT door there is no quality and no box count — showing "(no quality)
    // · 0 boxes" against every design is noise about fields the sheet doesn't have. The
    // surface leads instead, because it is the identity fact the row is judged on.
    final rest = [
      if (r.surfaceRaw.trim().isNotEmpty) _surfaceShown(r),
      if (!_products && r.qty >= 0) '${r.qty} boxes',
    ].join('  ·  ');
    final quality = _products
        ? ''
        : (r.quality.isNotEmpty ? r.quality : r.qualityRaw);
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
                        if (!_products)
                          TextSpan(
                              text: quality.isEmpty ? '(no quality)' : quality,
                              style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1B4F72))),
                        if (rest.isNotEmpty)
                          TextSpan(
                              text: _products ? rest : '   $rest',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: _products
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  color: _products
                                      ? const Color(0xFF1B4F72)
                                      : Colors.black54)),
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
        // SURFACE is identity too, and on the product door it is compulsory. A design
        // sheet with a blank Surface cell used to be unfillable: the row was blocked on
        // a surface, and this editor offered no way to give it one. It is deliberately
        // NOT defaulted — he is sitting right here, so ask him.
        if (_products) ...[
          DropdownButtonFormField<String>(
            key: ValueKey('sf_$id'),
            initialValue:
                _finishes.contains(first.surface) ? first.surface : null,
            isExpanded: true,
            decoration: const InputDecoration(
                isDense: true,
                labelText: 'Surface',
                border: OutlineInputBorder()),
            items: _finishes
                .map((s) => DropdownMenuItem(
                    value: s,
                    child: Text(s, style: const TextStyle(fontSize: 12))))
                .toList(),
            onChanged:
                _importing ? null : (v) => setAll((r) => r.surface = v ?? ''),
          ),
          const SizedBox(height: 6),
        ],
        Row(children: [
          Expanded(
            flex: 4,
            child: DropdownButtonFormField<String>(
              key: ValueKey('tt_$id'),
              initialValue:
                  tileTypeNames.contains(first.tileType) ? first.tileType : null,
              isExpanded: true,
              decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Tile type',
                  border: OutlineInputBorder()),
              items: tileTypeNames
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
                _products
                    ? 'New design — fill surface, tile type, pieces and weight (or untick).'
                    : 'New design — fill tile type, pieces and weight (or untick).',
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
    // The stockist's OWN words, same as the template offered them — picking a word
    // writes it to surfaceRaw and _reResolve turns it back into the admin canonical.
    // No 'None': a tile always has a surface, and it is part of the product's identity.
    //
    // Matched on the NORMALISED key, not the literal string: the cell may read
    // "Punch Ghr." while their stored word is "Punchghr". If the row's word still
    // isn't one of theirs (their own spreadsheet, not our template), it is appended
    // so the dropdown can always show what the row actually says — the Map-surfaces
    // step is what teaches it.
    final rawWord = r.surfaceRaw.trim();
    final surfOpts = [..._surfaceWords];
    var curSurfWord = surfOpts.firstWhere(
        (w) => normalizeSurfaceRaw(w) == normalizeSurfaceRaw(rawWord),
        orElse: () => '');
    if (curSurfWord.isEmpty && rawWord.isNotEmpty) {
      surfOpts.add(rawWord);
      curSurfWord = rawWord;
    }
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
                initialValue: curSurfWord.isEmpty ? null : curSurfWord,
                isExpanded: true,
                decoration: dec('Surface'),
                hint: const Text('Pick', style: TextStyle(fontSize: 12)),
                items: surfOpts
                    .map((s) => DropdownMenuItem(
                        value: s,
                        child: Text(s, style: const TextStyle(fontSize: 12))))
                    .toList(),
                onChanged: _importing
                    ? null
                    : (v) {
                        if (v == null) return;
                        // Write the WORD only. _reResolve maps it to the canonical
                        // (surface_type); the word itself is kept as surface_label.
                        r.surfaceRaw = v;
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
  // Optional identity, read from the ENTRY sheet when the manufacturer adds the
  // Tile type / Pieces / Weight columns (so new designs don't need per-row fill).
  String tileType = '';
  int? pieces;
  double? weight;
  final Set<String> brandIds = {};
  _EntryAgg({required this.name, required this.size});
}
