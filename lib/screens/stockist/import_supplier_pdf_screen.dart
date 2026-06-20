import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../services/pdf_import_service.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../models/stock_catalog.dart';
import '../../models/choice_state.dart';
import '../../utils/tile_sizes.dart';
import '../../utils/tile_types.dart';
import '../../utils/finishes.dart';
import '../../widgets/upload_mode.dart';

// ─────────────────────────────────────────────────────────────────────────────
// T/W (Trader / Wholesaler = "importer") supplier-PDF importer.
//
// Importers ingest an ARBITRARY external supplier PDF/Excel — not produced by our
// app, often image-less, in whatever layout the upstream maker uses. So unlike the
// M (manufacturer) structured-PDF flow (upload_stock_screen), this is a
// MAPPING-ASSISTED PREVIEW: the parser pre-fills a best-effort table, then the
// stockist confirms/corrects every field before anything is committed.
//
// Two decoupled phases (project_tw_pdf_upload_flow):
//   Phase 1 — BUILD THE LIBRARY (always runs, never blocks): scrape design_name +
//             size for every design → match/create a master (key = name+size, never
//             duplicated). Image stored if present, else filled later. T/W masters
//             are independent: the design name IS the master name, no cross-brand
//             mapping (project_actor_types).
//   Ask     — Quality (Premium / Standard / Both) + Surface present? (Yes / No).
//   Phase 2 — ENTER STOCK (can reject; the Library is already built and kept):
//             quantity is a number (0/blank → bypass that row; none anywhere →
//             reject stock); quality fuzzy-matched; surface scraped or None.
// ─────────────────────────────────────────────────────────────────────────────

// Nothing is written until the final Save (one atomic batch). mode (pick upload
// mode + guarded confirm) → pick → edit (names/sizes) → ask (quality / surface /
// tile type / pieces / weight) → stock (quantities) → review (Save / Cancel) →
// done. Cancel/back before Save writes NOTHING.
enum _Phase { mode, pick, edit, dedupe, ask, stock, review, done }

// One set of rows in the parsed PDF that share a name + size — the machine can't
// tell if they're the SAME design (duplicate line) or DIFFERENT designs that
// happen to share a name; the stockist decides, using the photos.
class _DupGroup {
  final String key;
  final List<_ImpRow> rows;
  bool keepBoth = false;   // false = same design (merge) · true = different (rename)
  _ImpRow? chosen;         // the photo/row to keep when merging
  _DupGroup(this.key, this.rows) {
    chosen = rows.firstWhere((r) => r.imageBytes != null, orElse: () => rows.first);
  }
}

enum _QualityMode { premium, standard, both }

// Step 2 is a guided wizard — one full-screen question per sub-step. Instruction
// pages (tileSame / surfaceInPdf) ask a Yes/No FIRST and never show the options;
// the options appear on the following page only after the answer.
enum _AskStep {
  quality,
  tileSame,      // "Is the whole PDF one tile type?" (Yes/No, no options shown)
  tilePick,      // pick the one tile type (only if tileSame == Yes)
  tileBlocked,   // "split the PDF" dead-end (only if tileSame == No)
  pieces,
  weight,
  surfaceInPdf,  // "Is the surface in this PDF?" (Yes/No, no options shown)
  surfaceChoice, // one-surface-for-all / all-None (only if surfaceInPdf == No)
}

/// Fuzzy-map free supplier text to our canonical quality. 'second(s)' folds into
/// Standard. Anything premium-ish → Premium; everything else → Standard.
String canonQuality(String raw) {
  final t = raw.toLowerCase().trim();
  if (t.contains('prem') || t.contains('prim') || t == 'prm' || t == 'pre') {
    return 'Premium';
  }
  return 'Standard'; // std / standard / standerd / second / seconds / unknown
}

class _ImpRow {
  String name;
  String size;
  final Uint8List? imageBytes; // photo from the PDF (null = none)
  bool include = true; // include this design when building the Library

  // Set during Phase 1 commit, reused in Phase 2 so we never re-upload.
  String? masterId;
  String? uploadedUrl; // Cloudinary URL of the PDF photo, once uploaded
  String? libImageUrl; // this stockist's existing Library image, if any

  // Phase 2 (stock) fields.
  final TextEditingController qtyCtrl;
  String quality; // used only when the batch quality mode is "Both"
  String surface; // used only when the PDF carries surfaces

  _ImpRow({
    required this.name,
    required this.size,
    this.imageBytes,
    int qty = 0,
    this.surface = 'None',
    this.quality = 'Standard',
  }) : qtyCtrl = TextEditingController(text: qty > 0 ? '$qty' : '');

  /// Parsed quantity from the (editable) field. 0/blank/'-' → bypass stock.
  int get qty {
    final t = qtyCtrl.text.trim();
    if (t.isEmpty || t == '-') return 0;
    return int.tryParse(t.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
  }

  void dispose() => qtyCtrl.dispose();
}

class ImportSupplierPdfScreen extends StatefulWidget {
  /// The stock list chosen at the Upload tap. Fixes the brand (a list belongs to
  /// exactly one brand). Null falls back to the stockist's first list.
  final String? initialCatalogId;
  const ImportSupplierPdfScreen({super.key, this.initialCatalogId});

  @override
  State<ImportSupplierPdfScreen> createState() => _ImportSupplierPdfScreenState();
}

class _ImportSupplierPdfScreenState extends State<ImportSupplierPdfScreen> {
  final _pdfService = PdfImportService();
  final _dataSvc = SupabaseDataService();

  _Phase _phase = _Phase.mode;
  UploadMode? _mode; // chosen in the mode phase, confirmed via guarded dialog
  bool _busy = false;
  String _busyStep = '';
  String _filename = '';

  // Idempotency key for this import — generated once when a PDF is parsed and
  // REUSED across Save retries, so a retried Save (e.g. after a lost reply) can
  // never double-add. A new PDF gets a fresh id.
  String _batchId = '';

  // Live processing readout — shown in the overlay so the stockist always sees
  // WHERE the stock is going (Brand · List) and that it's actually working.
  final Stopwatch _watch = Stopwatch();
  Timer? _ticker;
  double? _progress; // 0..1 determinate; null = indeterminate
  String _progressDetail = '';

  // Brand / list context (the brand is fixed by the chosen list).
  String? _catalogId;
  String? _brandId;
  String _catalogName = '';
  String _brandName = '';

  // Master sizes the admin allows (for the per-row size dropdown).
  List<String> _sizes = kAllowedSizes;

  // Working set.
  final List<_ImpRow> _rows = [];
  String _docSize = kAllowedSizes.first; // applied to all rows in Phase 1

  // Ask-step answers.
  _QualityMode _qualityMode = _QualityMode.standard;
  bool _surfacePresent = false;

  // Step 2 wizard cursor + the two Yes/No answers (null = not answered yet, so the
  // Yes/No buttons start unhighlighted).
  _AskStep _askStep = _AskStep.quality;
  bool? _sameTileType;   // answer to "Is the whole PDF one tile type?"
  bool? _surfaceInPdfAns; // answer to "Is the surface in this PDF?"

  // Same-name duplicate groups in the parsed PDF, resolved on the dedupe page.
  final List<_DupGroup> _dupGroups = [];

  // Tile Type (compulsory, single per PDF). _tileTypeSel holds the single chosen
  // type (a set so the existing _tileType getter keeps working).
  final Set<String> _tileTypeSel = {};

  // Pieces per box (compulsory, single-for-batch): 1–8 or a custom number.
  int? _piecesSel; // 1..8, or null when "Custom" is chosen
  bool _piecesCustom = false;
  final TextEditingController _customPiecesCtrl = TextEditingController();

  // Box weight (kg, compulsory) — feeds the derived thickness.
  final TextEditingController _boxWeightCtrl = TextEditingController();

  // Surface, when NOT in the PDF: optionally one surface for the whole list.
  bool _singleSurface = false;
  String _singleSurfaceValue = 'None';

  // Outcome counters (Phase 2).
  int _builtMasters = 0;
  int _createdDesigns = 0;
  int _updatedDesigns = 0;
  int _stockRows = 0;
  int _bypassed = 0;

  @override
  void initState() {
    super.initState();
    _catalogId = widget.initialCatalogId;
    _loadConfig();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _customPiecesCtrl.dispose();
    _boxWeightCtrl.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  // ── Step-2 resolved values ───────────────────────────────────────────────────
  String? get _tileType =>
      _tileTypeSel.length == 1 ? _tileTypeSel.first : null;

  int get _piecesPerBox => _piecesCustom
      ? (int.tryParse(_customPiecesCtrl.text.trim()) ?? 0)
      : (_piecesSel ?? 0);

  double get _boxWeightKg =>
      double.tryParse(_boxWeightCtrl.text.trim()) ?? 0;

  // Distinct admin sizes among the kept rows — >1 means a multi-size PDF, which
  // can't carry one tile type / pieces / weight, so it builds the Library only.
  Set<String> get _keptSizes => _kept.map((r) => r.size.trim()).toSet();
  bool get _isMultiSize => _keptSizes.length > 1;

  // Start a timed processing pass: resets + starts the elapsed clock and ticks
  // the UI every second so the timer in the overlay counts up live.
  void _beginProcessing(String step) {
    _watch
      ..reset()
      ..start();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    setState(() {
      _busy = true;
      _busyStep = step;
      _progress = null;
      _progressDetail = '';
    });
  }

  void _endProcessing() {
    _ticker?.cancel();
    _ticker = null;
    _watch.stop();
    if (mounted) {
      setState(() {
        _busy = false;
        _busyStep = '';
        _progress = null;
        _progressDetail = '';
      });
    }
  }

  String get _elapsed {
    final s = _watch.elapsed.inSeconds;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:'
        '${(s % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _loadConfig() async {
    if (currentStockistUUID.isEmpty) return;
    setState(() => _busy = true);
    try {
      final cats = await _dataSvc.getCatalogs(currentStockistUUID);
      final sizes = await _dataSvc.getActiveSizeNames();
      if (sizes.isNotEmpty) _sizes = sizes;
      // Resolve the chosen list → its brand.
      StockCatalog? cat;
      for (final c in cats) {
        if (c.id == _catalogId) {
          cat = c;
          break;
        }
      }
      cat ??= cats.isNotEmpty ? cats.first : null;
      if (cat != null) {
        _catalogId = cat.id;
        _brandId = cat.brandId;
        _catalogName = cat.name;
      }
      if (_brandId != null) {
        final brands = await _dataSvc.getMyBrands();
        for (final b in brands) {
          if (b.id == _brandId) {
            _brandName = b.name;
            break;
          }
        }
      }
      if (_sizes.isNotEmpty) _docSize = _sizes.first;
    } catch (_) {
      // Non-fatal — the picker still works with fallbacks.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Phase 0 → 1: pick + parse ────────────────────────────────────────────────
  Future<void> _pickFile() async {
    if (_brandId == null) {
      _toast('Pick a brand & stock list first.', error: true);
      return;
    }
    FilePickerResult? res;
    try {
      res = await FilePicker.platform
          .pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    } catch (_) {}
    if (res == null || res.files.isEmpty) return;

    final name = res.files.first.name;
    final path = res.files.first.path;
    _filename = name;
    _beginProcessing('Reading PDF…');

    final parsed = await _pdfService.parsePdf(name, path);
    if (!mounted) return;

    // Reject documents that aren't stock lists at all (quotation / invoice / etc.)
    // before the stockist wastes time editing junk rows.
    if (parsed.looksNonStock) {
      _endProcessing();
      setState(() => _filename = '');
      await _alert('This doesn’t look like a stock list',
          'This PDF looks like a quotation, invoice or another document — not a '
          'tile stock report. Please upload your supplier’s stock list PDF '
          '(designs with their sizes and box quantities).');
      return;
    }

    // Drop nameless rows (a design needs a name — it's the identity key). Reject
    // the WHOLE PDF only when nothing named remains.
    parsed.designs.removeWhere((d) => d.name.trim().isEmpty);
    if (parsed.designs.isEmpty) {
      _endProcessing();
      setState(() => _filename = '');
      await _alert('No designs found',
          'This PDF has no design names to import. A design needs a name — it '
          'identifies the tile. Please check the file and try again.');
      return;
    }

    // Seed the working rows. The parser gives a best-effort table; the stockist
    // corrects it. Size defaults to the parser's document size when recognised,
    // else the admin's first master size.
    final parsedSize = _normaliseSize(parsed.size);
    _docSize = parsedSize ?? (_sizes.isNotEmpty ? _sizes.first : _docSize);
    for (final r in _rows) {
      r.dispose();
    }
    _rows
      ..clear()
      ..addAll(parsed.designs.map((d) => _ImpRow(
            name: d.name.trim(),
            size: _docSize,
            imageBytes: d.imageBytes,
            qty: d.quantity,
            surface: d.surface,
            // Seed each row's quality from the PDF (per-row grade if the layout
            // carries one, e.g. PRE/STD, else the document quality). Used when
            // the batch mode is "Both"; uniform modes override it on save.
            quality: canonQuality(d.qualityRaw ?? parsed.quality),
          )));

    _endProcessing();
    if (!mounted) return;
    _batchId = const Uuid().v4(); // one idempotency key per parsed PDF
    setState(() => _phase = _Phase.edit);
  }

  /// Map the parser's "600x1200 mm" style to one of the admin's master sizes if
  /// it matches; otherwise null (let the stockist choose).
  String? _normaliseSize(String raw) {
    final clean = raw.replaceAll(' mm', '').trim().toLowerCase();
    for (final s in _sizes) {
      if (s.toLowerCase().replaceAll(' mm', '').trim() == clean) return s;
    }
    return null;
  }

  // Rows the stockist kept (ticked + named) — the set this import will act on.
  List<_ImpRow> get _kept =>
      _rows.where((r) => r.include && r.name.trim().isNotEmpty).toList();

  // Edit (names/sizes) → Ask. A multi-size PDF can't carry one tile type / pieces
  // / weight, so it builds the Library only (the genuine reason is shown) and the
  // stockist finishes each design's detail in the Library. NOTHING is written here.
  void _goToAsk() {
    if (_kept.isEmpty) {
      _toast('Tick at least one design to import.', error: true);
      return;
    }
    // Same-name rows in the file? The stockist must resolve them first — the name
    // alone can't tell same-design-twice from two-different-designs.
    final dups = _findDuplicates();
    if (dups.isNotEmpty) {
      setState(() {
        _dupGroups
          ..clear()
          ..addAll(dups);
        _phase = _Phase.dedupe;
      });
      return;
    }
    _proceedAfterEdit();
  }

  // Edit/dedupe resolved → multi-size check → Step 2 wizard.
  void _proceedAfterEdit() {
    if (_isMultiSize) {
      _confirmMultiSizeLibraryOnly();
      return;
    }
    setState(() {
      _askStep = _AskStep.quality; // restart the wizard at the first question
      _phase = _Phase.ask;
    });
  }

  // Group the kept rows by name + size; any group of 2+ is a duplicate to resolve.
  List<_DupGroup> _findDuplicates() {
    final byKey = <String, List<_ImpRow>>{};
    for (final r in _kept) {
      final key = '${r.name.trim().toLowerCase()}|${r.size.trim().toLowerCase()}';
      (byKey[key] ??= []).add(r);
    }
    return [
      for (final e in byKey.entries)
        if (e.value.length > 1) _DupGroup(e.key, e.value)
    ];
  }

  // "Go ahead" on the dedupe page: apply each group's choice, then continue.
  void _applyDedupe() {
    // For "keep both" groups every row must end up with a distinct name.
    for (final g in _dupGroups) {
      if (!g.keepBoth) continue;
      final seen = <String>{};
      for (final r in g.rows) {
        final n = r.name.trim().toLowerCase();
        if (n.isEmpty) {
          _toast('Give every design a name.', error: true);
          return;
        }
        if (!seen.add('$n|${r.size.trim().toLowerCase()}')) {
          _toast('Two designs still share a name — make each one different.',
              error: true);
          return;
        }
      }
    }
    // Merge the "same design" groups: keep the chosen photo's row, fold the others'
    // boxes into it, drop them from the import.
    for (final g in _dupGroups) {
      if (g.keepBoth) continue;
      final carrier = g.chosen ?? g.rows.first;
      var sum = carrier.qty;
      for (final r in g.rows) {
        if (identical(r, carrier)) continue;
        sum += r.qty;
        r.include = false;
      }
      carrier.include = true;
      carrier.qtyCtrl.text = sum > 0 ? '$sum' : '';
    }
    // A keep-both rename may have created a NEW clash with another group — re-check.
    if (_findDuplicates().isNotEmpty) {
      setState(() {
        _dupGroups
          ..clear()
          ..addAll(_findDuplicates());
      });
      _toast('Some names still clash — please fix them.', error: true);
      return;
    }
    _proceedAfterEdit();
  }

  // ── Step 2 wizard navigation ─────────────────────────────────────────────────
  // One full-screen question per sub-step. "Next" advances the option pages;
  // Yes/No pages advance via their own handlers. Back walks the chain in reverse.

  void _askBack() {
    switch (_askStep) {
      case _AskStep.quality:
        setState(() => _phase = _Phase.edit);
      case _AskStep.tileSame:
        setState(() => _askStep = _AskStep.quality);
      case _AskStep.tilePick:
      case _AskStep.tileBlocked:
        setState(() => _askStep = _AskStep.tileSame);
      case _AskStep.pieces:
        setState(() => _askStep = _AskStep.tilePick);
      case _AskStep.weight:
        setState(() => _askStep = _AskStep.pieces);
      case _AskStep.surfaceInPdf:
        setState(() => _askStep = _AskStep.weight);
      case _AskStep.surfaceChoice:
        setState(() => _askStep = _AskStep.surfaceInPdf);
    }
  }

  // "Next" on the option pages (validates that page, then advances).
  void _askNext() {
    switch (_askStep) {
      case _AskStep.quality:
        setState(() => _askStep = _AskStep.tileSame);
      case _AskStep.tilePick:
        if (_tileType == null) {
          _toast('Pick one tile type to continue.', error: true);
          return;
        }
        setState(() => _askStep = _AskStep.pieces);
      case _AskStep.pieces:
        if (_piecesPerBox <= 0) {
          _toast('Enter how many tiles are in one box.', error: true);
          return;
        }
        setState(() => _askStep = _AskStep.weight);
      case _AskStep.weight:
        if (_boxWeightKg <= 0) {
          _toast('Enter the box weight in kg.', error: true);
          return;
        }
        setState(() => _askStep = _AskStep.surfaceInPdf);
      case _AskStep.surfaceChoice:
        _enterStock();
      case _AskStep.tileSame:
      case _AskStep.surfaceInPdf:
      case _AskStep.tileBlocked:
        break; // these pages advance via Yes/No or have no Next
    }
  }

  void _answerTileSame(bool same) {
    setState(() {
      _sameTileType = same;
      if (!same) _tileTypeSel.clear();
      _askStep = same ? _AskStep.tilePick : _AskStep.tileBlocked;
    });
  }

  void _answerSurfaceInPdf(bool inPdf) {
    setState(() {
      _surfaceInPdfAns = inPdf;
      _surfacePresent = inPdf;
    });
    if (inPdf) {
      _enterStock(); // surfaces are set per-design in Step 3
    } else {
      setState(() => _askStep = _AskStep.surfaceChoice);
    }
  }

  // Wizard done → Step 3 (Quantities). Re-checks the compulsory gates defensively
  // and resolves the document-wide surface for the "not in PDF" branch.
  void _enterStock() {
    if (_tileType == null) {
      setState(() => _askStep = _AskStep.tileSame);
      return;
    }
    if (_piecesPerBox <= 0) {
      setState(() => _askStep = _AskStep.pieces);
      return;
    }
    if (_boxWeightKg <= 0) {
      setState(() => _askStep = _AskStep.weight);
      return;
    }
    if (!_surfacePresent) {
      final s = _singleSurface ? _singleSurfaceValue : 'None';
      for (final r in _rows) {
        r.surface = s;
      }
    }
    setState(() => _phase = _Phase.stock);
  }

  // Multi-size PDF: never rejected — the Library is already built (Step 1). We
  // explain why bulk stock can't run, then save the Library only and point the
  // stockist to finish each design's detail there (compulsory fields stay
  // compulsory in the Library editor).
  Future<void> _confirmMultiSizeLibraryOnly() async {
    final sizes = (_keptSizes.toList()..sort()).join(', ');
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Multiple sizes in this PDF'),
        content: Text(
            'This PDF has more than one size ($sizes). Tile type, pieces per box '
            'and weight can’t be set in bulk across different sizes, so stock '
            'can’t be added here.\n\nWe’ll add all ${_kept.length} designs to your '
            'Library (names, sizes and photos). Then open each one in your Library '
            'to add its tile type, quantity and packing — the required fields are '
            'still required there.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Back')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Build Library only')),
        ],
      ),
    );
    if (go == true) _save(libraryOnly: true);
  }

  // Stock → Review (read-only confirm with Save / Cancel).
  void _goToReview() => setState(() => _phase = _Phase.review);

  String _qualityOf(_ImpRow r) {
    switch (_qualityMode) {
      case _QualityMode.premium:
        return 'Premium';
      case _QualityMode.standard:
        return 'Standard';
      case _QualityMode.both:
        return r.quality;
    }
  }

  // ── SAVE — the ONLY write. Upload images (best-effort, safe to retry), then
  //    ONE atomic batch call that builds library + creates designs + adds stock
  //    all-or-nothing. Cancel/back before this writes nothing. ───────────────────
  Future<void> _save({bool libraryOnly = false}) async {
    final kept = _kept;
    if (kept.isEmpty) return;
    _beginProcessing('Saving…');

    // 1) Upload any PDF photos to Cloudinary first. These are idempotent
    //    (first-writer-wins on the master) so a retry never harms anything.
    for (var i = 0; i < kept.length; i++) {
      final r = kept[i];
      if (mounted) {
        setState(() {
          _progress = (i + 1) / (kept.length + 1);
          _progressDetail = 'Preparing ${r.name} (${i + 1} of ${kept.length})';
        });
      }
      if (r.imageBytes != null && r.uploadedUrl == null) {
        setState(() => _progressDetail = 'Uploading image for ${r.name}…');
        final up = await CloudinaryService.uploadImageBytes(
          r.imageBytes!,
          filename: '${r.name.trim().replaceAll(' ', '_')}.jpg',
        );
        if (up.ok) r.uploadedUrl = up.url;
      }
    }

    // 2) Build the batch payload. A multi-size library-only save carries no stock
    //    or packing (qty 0, no tile type / pieces / weight) — the stockist finishes
    //    each design in the Library. The single-size flow stamps the batch tile
    //    type + pieces + weight and the server-irrelevant derived thickness.
    final pieces = _piecesPerBox;
    final weight = _boxWeightKg;
    final tileType = _tileType ?? '';
    final rows = kept.map((r) {
      final thick = (!libraryOnly && pieces > 0 && weight > 0)
          ? approxThicknessMm(r.size.trim(), pieces, weight, tileType)
          : null;
      return <String, dynamic>{
        'name': r.name.trim(),
        'size': r.size.trim(),
        'quality': _qualityOf(r),
        'surface': libraryOnly ? 'None' : r.surface,
        'qty': libraryOnly ? 0 : r.qty,
        if (r.uploadedUrl != null) 'image_url': r.uploadedUrl,
        'stock_type': 'Uncertain',
        if (!libraryOnly) ...{
          'tile_type': tileType,
          'pieces_per_box': pieces,
          'box_weight_kg': weight,
          if (thick != null) 'thickness_mm': thick,
        },
      };
    }).toList();

    if (mounted) {
      setState(() {
        _progress = null; // server transaction — indeterminate
        _progressDetail = 'Saving to your catalogue…';
      });
    }

    // 3) ONE atomic, idempotent call. A reused batch id can't double-add.
    try {
      final res = await _dataSvc.importStockBatch(
        batchId: _batchId,
        catalogId: _catalogId,
        brandId: _brandId,
        pdfFilename: _filename,
        rows: rows,
        // Library-only (multi-size) never zeroes existing stock → force 'add'.
        mode: libraryOnly ? 'add' : (_mode?.api ?? 'add'),
      );
      _endProcessing();
      if (!mounted) return;
      _builtMasters = (res['masters'] as num?)?.toInt() ?? 0;
      _createdDesigns = (res['created'] as num?)?.toInt() ?? 0;
      _updatedDesigns = (res['updated'] as num?)?.toInt() ?? 0;
      _stockRows = (res['stock_rows'] as num?)?.toInt() ?? 0;
      _bypassed = kept.where((r) => r.qty <= 0).length;
      setState(() => _phase = _Phase.done);
    } catch (e) {
      _endProcessing();
      if (!mounted) return;
      // Nothing was saved (the transaction rolled back) — they can retry safely.
      await _alert('Could not save',
          'Nothing was saved, so your stock is unchanged.\n\n${_friendlyError(e)}'
          '\n\nYou can fix the issue and try Save again.');
    }
  }

  // Turn a raw database/network error into something a stockist can act on.
  String _friendlyError(Object e) {
    final raw = e.toString();
    if (raw.contains('stock_in_quantity_added_check') ||
        raw.contains('quantity_added')) {
      return 'A design’s box count didn’t add up (it can’t be zero or less). '
          'Please re-check the quantities and try again.';
    }
    if (raw.contains('SocketException') ||
        raw.contains('Failed host lookup') ||
        raw.contains('timed out')) {
      return 'It looks like the internet connection dropped. Reconnect and try '
          'Save again.';
    }
    if (raw.contains('violates') || raw.contains('constraint')) {
      return 'Some of the details didn’t pass a check. Please review the designs '
          'and try again.';
    }
    // Fall back to the message field of a PostgrestException, not the whole dump.
    final m = RegExp(r'message:\s*([^,)]+)').firstMatch(raw);
    return m != null ? m.group(1)!.trim() : 'Something went wrong while saving.';
  }

  // ── helpers ──────────────────────────────────────────────────────────────────
  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade700 : const Color(0xFF2E7D32),
    ));
  }

  Future<void> _alert(String title, String body) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  // ── build ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Import supplier PDF'),
        backgroundColor: const Color(0xFF1B4F72),
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Stack(
          children: [
            _bodyForPhase(),
            if (_busy) _processingOverlay(),
          ],
        ),
      ),
    );
  }

  // Full-screen busy overlay that keeps the destination (Brand · List) pinned and
  // shows a live progress bar + elapsed timer, so the stockist always sees WHERE
  // the stock is going and that it's working.
  Widget _processingOverlay() {
    return Container(
      color: Colors.black.withValues(alpha: 0.45),
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 32),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_busyStep.isEmpty ? 'Working…' : _busyStep,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 12),
              // Destination — pinned so they see where it lands while it runs.
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFE3F2FD),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Adding to',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade700)),
                    const SizedBox(height: 3),
                    Text(
                        'Brand  ·  ${_brandName.isEmpty ? '—' : _brandName}',
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1B4F72))),
                    Text('List   ·  ${_catalogName.isEmpty ? '—' : _catalogName}',
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1B4F72))),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 7,
                  backgroundColor: Colors.grey.shade200,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(_progressDetail,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade700)),
                  ),
                  if (_watch.isRunning || _watch.elapsed.inSeconds > 0)
                    Text(_elapsed,
                        style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.bold,
                            fontFeatures: [FontFeature.tabularFigures()])),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bodyForPhase() {
    switch (_phase) {
      case _Phase.mode:
        return _modeBody();
      case _Phase.pick:
        return _pickBody();
      case _Phase.edit:
        return _editBody();
      case _Phase.dedupe:
        return _dedupeBody();
      case _Phase.ask:
        return _askBody();
      case _Phase.stock:
        return _stockBody();
      case _Phase.review:
        return _reviewBody();
      case _Phase.done:
        return _doneBody();
    }
  }

  Widget _contextChip() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFE3F2FD),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(Icons.storefront, size: 16, color: Color(0xFF1B4F72)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Brand: ${_brandName.isEmpty ? '—' : _brandName}'
                '   ·   List: ${_catalogName.isEmpty ? '—' : _catalogName}',
                style: const TextStyle(fontSize: 12.5, color: Color(0xFF1B4F72)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Step 1a — choose the upload mode, then a guarded 5-second confirm that names
  // the exact brand + list. Only on confirm do we move on to pick the PDF.
  Future<void> _pickMode(UploadMode m) async {
    final ok = await showUploadModeConfirm(context, m, _brandName, _catalogName);
    if (!ok || !mounted) return;
    setState(() {
      _mode = m;
      _phase = _Phase.pick;
    });
  }

  Widget _modeBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _contextChip(),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('How should this upload change your stock?',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('Pick one — we’ll confirm before anything changes.',
              style: TextStyle(fontSize: 12.5, color: Colors.black54)),
        ),
        for (final m in UploadMode.values)
          Card(
            margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: ListTile(
              leading: Icon(m.icon,
                  color: m.isDestructive
                      ? Colors.red.shade700
                      : const Color(0xFF1B4F72)),
              title: Text(m.label,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(m.short, style: const TextStyle(fontSize: 12)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _pickMode(m),
            ),
          ),
        const Spacer(),
      ],
    );
  }

  Widget _pickBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _contextChip(),
        if (_mode != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text('Mode · ${_mode!.label}',
                style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1B4F72))),
          ),
        const Spacer(),
        const Icon(Icons.upload_file, size: 64, color: Color(0xFF1B4F72)),
        const SizedBox(height: 12),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 28),
          child: Text(
            'Import your supplier’s stock PDF. We read it as best we can, then '
            'you confirm every design before anything is saved.\n\n'
            'Step 1 builds your Design Library (names + sizes + any photos). '
            'Step 2 adds the stock quantities.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: Colors.black54),
          ),
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: ElevatedButton.icon(
            onPressed: _pickFile,
            icon: const Icon(Icons.picture_as_pdf),
            label: const Text('Pick supplier PDF'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1B4F72),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        const Spacer(),
      ],
    );
  }

  Widget _editBody() {
    return Column(
      children: [
        _contextChip(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text('Step 1 · Designs',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ),
              Text('${_rows.length} designs',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ],
          ),
        ),
        // Doc-wide size — most supplier PDFs are a single size per file.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Row(
            children: [
              const Text('Size for all: ', style: TextStyle(fontSize: 13)),
              DropdownButton<String>(
                value: _sizes.contains(_docSize) ? _docSize : null,
                hint: const Text('Pick'),
                items: _sizes
                    .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  setState(() {
                    _docSize = v;
                    for (final r in _rows) {
                      r.size = v;
                    }
                  });
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text('name + size identify each design',
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10.5, color: Colors.grey.shade500)),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: _rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) => _libraryRow(_rows[i]),
          ),
        ),
        _bottomBar(
          label: 'Next  (${_kept.length})',
          onTap: _goToAsk,
        ),
      ],
    );
  }

  // ── Step 1b · resolve same-name duplicates ───────────────────────────────────
  Widget _dedupeBody() {
    return Column(
      children: [
        _contextChip(),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text('Step 1b · Same name found',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
              'These designs share a name in your PDF. The same name can mean the '
              'same design twice, or two different designs. Look at the photos and '
              'decide for each one.',
              style: TextStyle(fontSize: 12.5, color: Colors.black54)),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextButton.icon(
              onPressed:
                  _busy ? null : () => setState(() => _phase = _Phase.edit),
              icon: const Icon(Icons.arrow_back, size: 18),
              label: const Text('Back to designs (fix a wrong name or size)'),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            itemCount: _dupGroups.length,
            itemBuilder: (_, i) => _dupGroupCard(_dupGroups[i]),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(children: [
              OutlinedButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red.shade700,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 14)),
                child: const Text('Cancel upload'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _busy ? null : _applyDedupe,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1B4F72),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  child: const Text('Go ahead'),
                ),
              ),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _dupGroupCard(_DupGroup g) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('“${g.rows.first.name.trim()}”  ·  ${g.rows.first.size}',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 10),
            if (!g.keepBoth) ...[
              // SAME design — pick which photo to keep; the rest fold in.
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final r in g.rows) _dupPhotoChoice(g, r),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                  'These are the SAME design — the chosen photo is kept and the '
                  'boxes are added together.',
                  style:
                      TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => g.keepBoth = true),
                  icon: const Icon(Icons.call_split, size: 18),
                  label: const Text('Different designs — keep both'),
                ),
              ),
            ] else ...[
              // DIFFERENT designs — keep both, give each a unique name.
              for (final r in g.rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _thumb(r),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextFormField(
                          initialValue: r.name,
                          decoration: const InputDecoration(
                              isDense: true,
                              labelText: 'Design name',
                              border: OutlineInputBorder()),
                          onChanged: (v) => r.name = v,
                        ),
                      ),
                    ],
                  ),
                ),
              Text('Give each design a different name so they stay separate.',
                  style:
                      TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => g.keepBoth = false),
                  icon: const Icon(Icons.merge_type, size: 18),
                  label: const Text('Same design — merge instead'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // A selectable photo tile in the "same design" resolver.
  Widget _dupPhotoChoice(_DupGroup g, _ImpRow r) {
    final sel = identical(g.chosen, r);
    return InkWell(
      onTap: () => setState(() => g.chosen = r),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          border: Border.all(
              color: sel ? const Color(0xFF1B4F72) : Colors.grey.shade300,
              width: sel ? 2.5 : 1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            SizedBox(width: 64, height: 64, child: _thumbLarge(r)),
            const SizedBox(height: 4),
            Icon(sel ? Icons.check_circle : Icons.circle_outlined,
                size: 18,
                color: sel ? const Color(0xFF1B4F72) : Colors.grey.shade400),
          ],
        ),
      ),
    );
  }

  Widget _thumbLarge(_ImpRow r) {
    if (r.imageBytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.memory(r.imageBytes!, fit: BoxFit.cover),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(Icons.image_not_supported_outlined,
          size: 24, color: Colors.grey.shade400),
    );
  }

  Widget _thumb(_ImpRow r) {
    if (r.imageBytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.memory(r.imageBytes!,
            width: 46, height: 46, fit: BoxFit.cover),
      );
    }
    if (r.libImageUrl != null && r.libImageUrl!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: CachedNetworkImage(
            imageUrl: r.libImageUrl!,
            width: 46,
            height: 46,
            fit: BoxFit.cover),
      );
    }
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(Icons.image_not_supported_outlined,
          size: 20, color: Colors.grey.shade400),
    );
  }

  // Small coloured pill used for inline validation hints (e.g. red "no stock").
  Widget _flag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 9.5, fontWeight: FontWeight.bold, color: color)),
      );

  Widget _libraryRow(_ImpRow r) {
    final noName = r.name.trim().isEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Checkbox(
            value: r.include,
            onChanged: (v) => setState(() => r.include = v ?? true),
          ),
          _thumb(r),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  initialValue: r.name,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: 'Design name',
                    border: const OutlineInputBorder(),
                    enabledBorder: noName
                        ? OutlineInputBorder(
                            borderSide:
                                BorderSide(color: Colors.red.shade300))
                        : null,
                  ),
                  onChanged: (v) => setState(() => r.name = v),
                ),
                if (noName)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: _flag('Needs a name', Colors.red.shade600),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 110,
            child: DropdownButtonFormField<String>(
              initialValue: _sizes.contains(r.size) ? r.size : null,
              isExpanded: true,
              decoration: const InputDecoration(
                  isDense: true, border: OutlineInputBorder()),
              items: _sizes
                  .map((s) => DropdownMenuItem(
                      value: s,
                      child: Text(s, style: const TextStyle(fontSize: 12))))
                  .toList(),
              onChanged: (v) => setState(() => r.size = v ?? r.size),
            ),
          ),
        ],
      ),
    );
  }

  // ── Step 2 wizard — one full-screen question per page ────────────────────────
  String _askStepTitle(_AskStep s) {
    switch (s) {
      case _AskStep.quality:
        return 'Quality';
      case _AskStep.tileSame:
      case _AskStep.tilePick:
      case _AskStep.tileBlocked:
        return 'Tile type';
      case _AskStep.pieces:
        return 'Pieces per box';
      case _AskStep.weight:
        return 'Box weight';
      case _AskStep.surfaceInPdf:
      case _AskStep.surfaceChoice:
        return 'Surface / finish';
    }
  }

  int _askPhaseNum(_AskStep s) {
    switch (s) {
      case _AskStep.quality:
        return 1;
      case _AskStep.tileSame:
      case _AskStep.tilePick:
      case _AskStep.tileBlocked:
        return 2;
      case _AskStep.pieces:
        return 3;
      case _AskStep.weight:
        return 4;
      case _AskStep.surfaceInPdf:
      case _AskStep.surfaceChoice:
        return 5;
    }
  }

  Widget _askBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _contextChip(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: Text('Step 2 · ${_askStepTitle(_askStep)}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ),
              Text('${_askPhaseNum(_askStep)} of 5',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: _askPage(),
          ),
        ),
        _askNav(),
      ],
    );
  }

  Widget _askPage() {
    switch (_askStep) {
      case _AskStep.quality:
        return ListView(children: [
          _askHeading('What grade is the stock in this PDF?'),
          _askHelp('Choose Premium or Standard if the whole PDF is one grade. '
              'Choose “Both” only if the PDF itself shows a grade next to each '
              'design — you can correct each one later.'),
          const SizedBox(height: 18),
          _bigChoice('Premium', _qualityMode == _QualityMode.premium,
              () => setState(() => _qualityMode = _QualityMode.premium)),
          _bigChoice('Standard', _qualityMode == _QualityMode.standard,
              () => setState(() => _qualityMode = _QualityMode.standard)),
          _bigChoice('Both — the grade is written in the PDF',
              _qualityMode == _QualityMode.both,
              () => setState(() => _qualityMode = _QualityMode.both)),
        ]);

      case _AskStep.tileSame:
        return ListView(children: [
          _askHeading('Is the whole PDF the same tile type?'),
          _askHelp('Tiles have a body type — like PGVT & GVT, Porcelain, Ceramic, '
              'Full Body, DC or Colour Body. This app saves one tile type per PDF.\n\n'
              'If every tile in this file is the SAME type, tap Yes — you’ll pick '
              'which one on the next screen. If the file mixes different types, tap No.'),
          const SizedBox(height: 24),
          _yesNo(
              selected: _sameTileType,
              onYes: () => _answerTileSame(true),
              onNo: () => _answerTileSame(false)),
        ]);

      case _AskStep.tilePick:
        return ListView(children: [
          _askHeading('Which tile type is it?'),
          _askHelp('Pick the one body type that matches every tile in this PDF.'),
          const SizedBox(height: 16),
          for (final t in kTileTypes)
            _bigChoice(t, _tileTypeSel.contains(t),
                () => setState(() => _tileTypeSel
                  ..clear()
                  ..add(t))),
        ]);

      case _AskStep.tileBlocked:
        return ListView(children: [
          _askHeading('Please split this PDF first'),
          _askHelp('This app saves one tile type per upload, but you said this PDF '
              'has more than one.\n\nSplit the PDF so each file has only ONE tile '
              'type, then upload them one at a time.\n\nTap Back if you want to '
              'change your answer.'),
          const SizedBox(height: 16),
          Center(
            child: Icon(Icons.call_split,
                size: 64, color: Colors.grey.shade400),
          ),
        ]);

      case _AskStep.pieces:
        return ListView(children: [
          _askHeading('How many tiles are in one box?'),
          _askHelp('This is the same for the whole PDF. Tap a number, or Custom '
              'for any other count.'),
          const SizedBox(height: 18),
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (var n = 1; n <= 8; n++)
              _numChip('$n', !_piecesCustom && _piecesSel == n,
                  () => setState(() {
                        _piecesCustom = false;
                        _piecesSel = n;
                      })),
            _numChip('Custom', _piecesCustom, () => setState(() {
                  _piecesCustom = true;
                  _piecesSel = null;
                })),
          ]),
          if (_piecesCustom)
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: SizedBox(
                width: 170,
                child: TextField(
                  controller: _customPiecesCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Pieces / box',
                      border: OutlineInputBorder()),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ),
        ]);

      case _AskStep.weight:
        final thickLabel =
            (_tileType != null && _piecesPerBox > 0 && _boxWeightKg > 0)
                ? thicknessRangeLabel(
                    _docSize, _piecesPerBox, _boxWeightKg, _tileType!)
                : null;
        return ListView(children: [
          _askHeading('What does one box weigh?'),
          _askHelp('Enter the weight of a single box in kilograms. Same for the '
              'whole PDF.'),
          const SizedBox(height: 18),
          SizedBox(
            width: 200,
            child: TextField(
              controller: _boxWeightCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Weight / box',
                  suffixText: 'kg',
                  border: OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (thickLabel != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text('Approx. thickness: $thickLabel',
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1B4F72))),
            ),
        ]);

      case _AskStep.surfaceInPdf:
        return ListView(children: [
          _askHeading('Does this PDF show each tile’s surface / finish?'),
          _askHelp('Surface means the finish — like Glossy, Matt or Carving. '
              'If the PDF lists a surface next to each design, tap Yes and you’ll '
              'set them on the next screen. If it doesn’t, tap No.'),
          const SizedBox(height: 24),
          _yesNo(
              selected: _surfaceInPdfAns,
              onYes: () => _answerSurfaceInPdf(true),
              onNo: () => _answerSurfaceInPdf(false)),
        ]);

      case _AskStep.surfaceChoice:
        return ListView(children: [
          _askHeading('Is the whole list one surface?'),
          _askHelp('Since the surface isn’t in the PDF, choose one finish for every '
              'design, or save them all as “None” and set surfaces later.'),
          const SizedBox(height: 16),
          _bigChoice('Yes — one surface for all designs', _singleSurface,
              () => setState(() => _singleSurface = true)),
          _bigChoice('No — save them all as “None”', !_singleSurface,
              () => setState(() => _singleSurface = false)),
          if (_singleSurface)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: DropdownButtonFormField<String>(
                initialValue: _surfaceOptions.contains(_singleSurfaceValue)
                    ? _singleSurfaceValue
                    : 'None',
                decoration: const InputDecoration(
                    labelText: 'Surface for all',
                    border: OutlineInputBorder()),
                items: _surfaceOptions
                    .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                    .toList(),
                onChanged: (v) =>
                    setState(() => _singleSurfaceValue = v ?? 'None'),
              ),
            ),
        ]);
    }
  }

  // Bottom navigation for the wizard. Yes/No pages (tileSame, surfaceInPdf) and the
  // dead-end tileBlocked page have no Next — they advance via their own buttons.
  Widget _askNav() {
    final hasNext = _askStep != _AskStep.tileSame &&
        _askStep != _AskStep.surfaceInPdf &&
        _askStep != _AskStep.tileBlocked;
    final nextLabel =
        _askStep == _AskStep.surfaceChoice ? 'Continue to stock' : 'Next';
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            OutlinedButton(
              onPressed: _busy ? null : _askBack,
              style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 14)),
              child: const Text('Back'),
            ),
            const SizedBox(width: 12),
            if (hasNext)
              Expanded(
                child: ElevatedButton(
                  onPressed: _busy ? null : _askNext,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1B4F72),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  child: Text(nextLabel),
                ),
              )
            else
              const Spacer(),
          ],
        ),
      ),
    );
  }

  // ── Wizard page primitives ───────────────────────────────────────────────────
  Widget _askHeading(String t) => Text(t,
      style: const TextStyle(
          fontSize: 19, fontWeight: FontWeight.bold, height: 1.25));

  Widget _askHelp(String t) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(t,
            style: TextStyle(
                fontSize: 14, height: 1.4, color: Colors.grey.shade700)),
      );

  // A large tappable radio-style option row.
  Widget _bigChoice(String label, bool sel, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            decoration: BoxDecoration(
              color: sel ? const Color(0xFFE3F2FD) : Colors.white,
              border: Border.all(
                  color: sel ? const Color(0xFF1B4F72) : Colors.grey.shade300,
                  width: sel ? 2 : 1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Icon(
                  sel
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: sel ? const Color(0xFF1B4F72) : Colors.grey,
                  size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: sel ? FontWeight.w600 : FontWeight.w500)),
              ),
            ]),
          ),
        ),
      );

  Widget _numChip(String label, bool sel, VoidCallback onTap) =>
      ChoiceChip(label: Text(label), selected: sel, onSelected: (_) => onTap());

  Widget _yesNo(
          {required VoidCallback onYes,
          required VoidCallback onNo,
          bool? selected}) =>
      Row(children: [
        Expanded(child: _ynBtn('Yes', selected == true, onYes)),
        const SizedBox(width: 12),
        Expanded(child: _ynBtn('No', selected == false, onNo)),
      ]);

  Widget _ynBtn(String label, bool sel, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 22),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: sel ? const Color(0xFF1B4F72) : Colors.white,
            border: Border.all(color: const Color(0xFF1B4F72), width: 1.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: sel ? Colors.white : const Color(0xFF1B4F72))),
        ),
      );

  Widget _stockBody() {
    final shown = _kept; // excludes rows merged away in the dedupe step
    final withQty = shown.where((r) => r.qty > 0).length;
    return Column(
      children: [
        _contextChip(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text('Step 3 · Quantities',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ),
              Text('$withQty with qty',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text('Blank or 0 quantity = added to your Library only, no '
              'stock. Nothing is saved until you Save on the next screen.',
              style: TextStyle(fontSize: 11.5, color: Colors.black54)),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: shown.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) => _stockRow(shown[i]),
          ),
        ),
        _bottomBar(label: 'Review', onTap: _goToReview),
      ],
    );
  }

  // Read-only confirm. NOTHING is written until Save; Cancel/back writes nothing.
  Widget _reviewBody() {
    final kept = _kept;
    final withQty = kept.where((r) => r.qty > 0).toList();
    final premium =
        withQty.where((r) => _qualityOf(r) == 'Premium').length;
    final standard = withQty.length - premium;
    return Column(
      children: [
        _contextChip(),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Step 4 · Review & Save',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F8E9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('This will save:',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13.5)),
                    const SizedBox(height: 8),
                    _reviewLine('Designs added to Library', kept.length),
                    _reviewLine('Designs getting stock', withQty.length),
                    if (_qualityMode == _QualityMode.both) ...[
                      _reviewLine('  · Premium', premium),
                      _reviewLine('  · Standard', standard),
                    ],
                    _reviewLine(
                        'Library-only (no quantity)', kept.length - withQty.length),
                    const Divider(height: 18),
                    _reviewLine('Mode', _mode?.label ?? 'Add only', isText: true),
                    _reviewLine('Tile type', _tileType ?? '—', isText: true),
                    _reviewLine('Pieces / box',
                        _piecesPerBox > 0 ? '$_piecesPerBox' : '—',
                        isText: true),
                    _reviewLine('Box weight',
                        _boxWeightKg > 0 ? '$_boxWeightKg kg' : '—',
                        isText: true),
                    _reviewLine('Brand', _brandName, isText: true),
                    _reviewLine('Stock list', _catalogName, isText: true),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                  'Nothing is saved yet. Press Save to write it all at once, or '
                  'Cancel to go back and fix anything. If you leave now, nothing '
                  'is saved.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        _busy ? null : () => setState(() => _phase = _Phase.stock),
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D32),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _reviewLine(String label, Object value, {bool isText = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
              child: Text(label, style: const TextStyle(fontSize: 13))),
          Text(isText ? (value.toString().isEmpty ? '—' : value.toString()) : '$value',
              style: const TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _stockRow(_ImpRow r) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _thumb(r),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13.5)),
                    Row(
                      children: [
                        Text(r.size,
                            style: TextStyle(
                                fontSize: 11.5, color: Colors.grey.shade600)),
                        if (r.qty <= 0) ...[
                          const SizedBox(width: 6),
                          _flag('No stock · Library only', Colors.red.shade600),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 76,
                child: TextField(
                  controller: r.qtyCtrl,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: 'Boxes',
                    border: const OutlineInputBorder(),
                    enabledBorder: r.qty <= 0
                        ? OutlineInputBorder(
                            borderSide:
                                BorderSide(color: Colors.red.shade300))
                        : null,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
          if (_qualityMode == _QualityMode.both || _surfacePresent)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 56),
              child: Row(
                children: [
                  if (_qualityMode == _QualityMode.both) ...[
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: r.quality,
                        isExpanded: true,
                        decoration: const InputDecoration(
                            isDense: true,
                            labelText: 'Quality',
                            border: OutlineInputBorder()),
                        items: const [
                          DropdownMenuItem(
                              value: 'Standard', child: Text('Standard')),
                          DropdownMenuItem(
                              value: 'Premium', child: Text('Premium')),
                        ],
                        onChanged: (v) =>
                            setState(() => r.quality = v ?? r.quality),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (_surfacePresent)
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue:
                            _surfaceOptions.contains(r.surface) ? r.surface : 'None',
                        isExpanded: true,
                        decoration: const InputDecoration(
                            isDense: true,
                            labelText: 'Surface',
                            border: OutlineInputBorder()),
                        items: _surfaceOptions
                            .map((s) => DropdownMenuItem(
                                value: s,
                                child: Text(s,
                                    style: const TextStyle(fontSize: 12))))
                            .toList(),
                        onChanged: (v) =>
                            setState(() => r.surface = v ?? r.surface),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<String> get _surfaceOptions => ['None', ...kFinishes];

  Widget _doneBody() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.task_alt, size: 64, color: Color(0xFF2E7D32)),
          const SizedBox(height: 16),
          const Text('Import complete',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 16),
          _summaryLine('Library designs built', _builtMasters),
          _summaryLine('New designs created', _createdDesigns),
          _summaryLine('Existing designs restocked', _updatedDesigns),
          _summaryLine('Stock rows added', _stockRows),
          _summaryLine('Skipped (no quantity)', _bypassed),
          const SizedBox(height: 16),
          // Gentle, non-blocking nudge — DNA is optional but powers buyer search.
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFE3F2FD),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome,
                    size: 18, color: Color(0xFF1B4F72)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      'Tip: add DNA tags (colour, look, finish…) to your designs '
                      'to make them easy for buyers to find.',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade800)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => context.pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1B4F72),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text('Done'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryLine(String label, int n) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 14)),
          Text('$n',
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _bottomBar({required String label, required VoidCallback onTap}) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _busy ? null : onTap,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1B4F72),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: Text(label),
          ),
        ),
      ),
    );
  }
}
