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
import '../../models/choice_state.dart';
import '../../utils/tile_sizes.dart';
import '../../utils/tile_types.dart';
import '../../utils/finishes.dart';
import '../../widgets/upload_mode.dart';
import '../../widgets/typewriter_text.dart';

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
// Flow: pick → (skipped) → reveal → sizeAsk → mistakes → edit → dedupe → ask
// (IDENTITY only — builds the library) → stockGate ("also add stock now?") →
// No: save library only · Yes: mode → quality → stock(quantities) → review → done.
enum _Phase { mode, pick, skipped, reveal, sizeAsk, mistakes, edit, dedupe, ask, stockGate, quality, stock, review, done }

// Step-1 (library building): rows that share a name + size but carry DIFFERENT
// photos. By default they're ONE library design (the stockist picks which photo
// represents it; the differing surface/quality rows stay as separate stock lines).
// If they're genuinely different designs the stockist flips "keep both" and renames
// each so they become separate library designs.
class _DupGroup {
  final String key;
  final List<_ImpRow> rows;
  _ImpRow? chosen;       // the row whose photo becomes the library image
  bool keepBoth = false; // true = different designs → rename each to split them
  _DupGroup(this.key, this.rows) {
    chosen = rows.firstWhere((r) => r.imageBytes != null, orElse: () => rows.first);
  }
}

// Step-0: rows identical on ALL of name + size + quality + surface — the SAME stock
// line listed twice = a mistake in the PDF. Resolved by merging (sum the boxes) or
// keeping just one. Distinct from the Step-1 library dedupe (same name + size but a
// different IMAGE / a genuine design question).
class _MistakeGroup {
  final String key;
  final List<_ImpRow> rows;
  _ImpRow? chosen;   // the row to keep (its photo + values)
  bool merge = true; // true = sum the boxes into the kept row; false = keep one
  _MistakeGroup(this.key, this.rows) {
    chosen = rows.firstWhere((r) => r.imageBytes != null, orElse: () => rows.first);
  }
}

// Per-size packing for a MIXED-size PDF — tile type / pieces / weight differ by
// size, so they're asked once per distinct size (instead of once for the batch,
// which only works for a single-size file).
class _SizePacking {
  String? tileType;
  final TextEditingController piecesCtrl = TextEditingController();
  final TextEditingController weightCtrl = TextEditingController();
  int get pieces => int.tryParse(piecesCtrl.text.trim()) ?? 0;
  double get weight => double.tryParse(weightCtrl.text.trim()) ?? 0;
  bool get complete => tileType != null && pieces > 0 && weight > 0;
  void dispose() {
    piecesCtrl.dispose();
    weightCtrl.dispose();
  }
}

// One scraped surface value + how many rows carry it + the admin finish it maps to,
// used by the Map-surfaces step.
class _SurfGroup {
  final String label; // the raw surface as scraped from the PDF
  String choice;      // the admin finish it maps to
  int count = 0;
  _SurfGroup({required this.label, required this.choice});
}

enum _QualityMode { premium, standard, both }

// Step 2 is a guided wizard — one full-screen question per sub-step. Instruction
// pages (tileSame / surfaceInPdf) ask a Yes/No FIRST and never show the options;
// the options appear on the following page only after the answer.
enum _AskStep {
  quality,
  sizePacking,   // per-size tile type + pieces + weight (only when the PDF is MIXED size)
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

  // Step-1: when several rows share a name+size (= one library design) only the
  // chosen row's photo goes to the master; the others skip contributing an image.
  bool contributeImage = true;

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
  /// The brand chosen at the Upload tap. Upload fills P_Stock for this brand; it
  /// no longer targets a stock list (lists are curated separately). Null falls
  /// back to the stockist's default brand.
  final String? initialBrandId;
  const ImportSupplierPdfScreen({super.key, this.initialBrandId});

  @override
  State<ImportSupplierPdfScreen> createState() => _ImportSupplierPdfScreenState();
}

class _ImportSupplierPdfScreenState extends State<ImportSupplierPdfScreen> {
  final _pdfService = PdfImportService();
  final _dataSvc = SupabaseDataService();

  // Entry is the file picker — a PDF always builds the library; the stock-mode
  // question is deferred to the stock branch (after the library is built).
  _Phase _phase = _Phase.pick;
  UploadMode? _mode; // chosen in the stock branch, confirmed via guarded dialog
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

  // Brand context. Upload fills P_Stock for this brand; no stock list is targeted.
  String? _brandId;
  String _brandName = '';
  // Manufacturer + whether we're uploading to the default brand. M on a NON-default
  // brand uses the "create-only" rule: a PDF can only ADD new designs to that brand;
  // designs that already exist under another brand are skipped (link via Excel).
  bool _isM = false;
  bool _isDefaultBrand = true;

  // Master sizes the admin allows (for the size dropdowns).
  List<String> _sizes = kAllowedSizes;

  // Step-1 size question. null = not answered; true = the whole PDF is ONE size
  // (the stockist picks it, applied to all rows); false = MIXED sizes (each row's
  // size is set on the design list). Drives whether the top "Size for all" box shows.
  bool? _oneSize;
  // Mixed sizes chosen but the PDF carries no per-design size → show the "why this
  // can't be imported + what to do" explanation instead of dumping to the home page.
  bool _mixNoSize = false;

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

  // Step-0 exact-duplicate (name+size+quality+surface) groups = PDF mistakes.
  final List<_MistakeGroup> _mistakeGroups = [];

  // name|size keys of designs ALREADY in this stockist's library (master + brand
  // aliases). Step-2 skips the set-once identity questions when the batch adds no
  // brand-new design (existing designs already carry tile type / pieces / weight).
  final Set<String> _libKeys = {};

  // name|size keys this stockist already has under the SELECTED brand (re-uploads
  // of these are fine). Drives the M non-default-brand "create-only" skip rule.
  final Set<String> _libThisBrandKeys = {};
  // Parsed designs skipped because they exist only under ANOTHER brand (M
  // non-default-brand uploads). Shown to the stockist so they know what to link
  // via Excel mapping. (name, size) pairs.
  final List<({String name, String size})> _skippedOtherBrand = [];

  // name|size|quality|surface keys of this stockist's existing P_Stock holdings.
  // When EVERY row in the PDF matches one, it's a pure restock → skip straight to
  // quantities (nothing else to set). Set true on that path for the stock banner.
  final Set<String> _holdingKeys = {};
  bool _restock = false;

  // Tile Type (compulsory, single per PDF). _tileTypeSel holds the single chosen
  // type (a set so the existing _tileType getter keeps working).
  final Set<String> _tileTypeSel = {};

  // Pieces per box (compulsory, single-for-batch): 1–8 or a custom number.
  int? _piecesSel; // 1..8, or null when "Custom" is chosen
  bool _piecesCustom = false;
  final TextEditingController _customPiecesCtrl = TextEditingController();

  // Box weight (kg, compulsory) — feeds the derived thickness.
  final TextEditingController _boxWeightCtrl = TextEditingController();

  // Per-size packing for a MIXED-size PDF (size → tile type/pieces/weight).
  final Map<String, _SizePacking> _sizePacking = {};

  // Live "design reveal" after parse — designs appear one-by-one (non-interactive)
  // with a new/already-in-library signal so the stockist absorbs what's happening.
  int _revealCount = 0;
  Timer? _revealTimer;
  final ScrollController _revealScroll = ScrollController();

  // Surface, when NOT in the PDF: optionally one surface for the whole list.
  bool _singleSurface = false;
  String _singleSurfaceValue = 'None';

  // Admin finishes + this stockist's learned surface aliases — used by the
  // Map-surfaces step to align the PDF's scraped surface text to a real finish
  // (and remember the alias for next time). Falls back to the static list.
  List<String> _finishes = kFinishes;
  Map<String, String> _aliases = {};

  // Outcome counters (Phase 2).
  int _builtMasters = 0;
  int _createdDesigns = 0;
  int _updatedDesigns = 0;
  int _stockRows = 0;
  int _bypassed = 0;

  @override
  void initState() {
    super.initState();
    _brandId = widget.initialBrandId;
    _loadConfig();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _revealTimer?.cancel();
    _revealScroll.dispose();
    _customPiecesCtrl.dispose();
    _boxWeightCtrl.dispose();
    for (final p in _sizePacking.values) {
      p.dispose();
    }
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  // ── Step-2 resolved values ───────────────────────────────────────────────────
  String _libKey(String name, String size) =>
      '${name.trim().toLowerCase()}|${size.trim().toLowerCase()}';

  // True when at least one kept design is NOT already in the library (so its
  // set-once identity attrs — tile type / pieces / weight — must be asked). When
  // every design already exists, Step-2 skips straight to the surface question.
  bool get _hasNewDesigns =>
      _kept.any((r) => !_libKeys.contains(_libKey(r.name, r.size)));

  String _holdingKey(String name, String size, String quality, String surface) {
    final s = surface.trim().isEmpty ? 'none' : surface.trim().toLowerCase();
    return '${name.trim().toLowerCase()}|${size.trim().toLowerCase()}'
        '|${quality.trim().toLowerCase()}|$s';
  }

  // Pure restock = every kept row already exists as a holding (name + size +
  // quality + surface all match). Nothing to set but quantities.
  bool get _allHoldingsMatch {
    final kept = _kept;
    if (kept.isEmpty || _holdingKeys.isEmpty) return false;
    return kept.every((r) =>
        _holdingKeys.contains(_holdingKey(r.name, r.size, r.quality, r.surface)));
  }

  String? get _tileType =>
      _tileTypeSel.length == 1 ? _tileTypeSel.first : null;

  int get _piecesPerBox => _piecesCustom
      ? (int.tryParse(_customPiecesCtrl.text.trim()) ?? 0)
      : (_piecesSel ?? 0);

  double get _boxWeightKg =>
      double.tryParse(_boxWeightCtrl.text.trim()) ?? 0;

  // Distinct admin sizes among the kept rows — >1 means a MIXED-size PDF, which
  // asks tile type / pieces / weight PER SIZE (so it can still add stock).
  Set<String> get _keptSizes => _kept.map((r) => r.size.trim()).toSet();
  bool get _isMultiSize => _keptSizes.length > 1;

  // Mixed-size packing helpers.
  void _ensureSizePacking() {
    for (final s in _keptSizes) {
      _sizePacking.putIfAbsent(s, () => _SizePacking());
    }
  }

  bool get _sizePackingComplete =>
      _keptSizes.every((s) => _sizePacking[s]?.complete ?? false);

  // Resolved packing for a row: per-size when the PDF is mixed-size, else batch.
  ({String tileType, int pieces, double weight}) _packingFor(_ImpRow r) {
    if (_isMultiSize) {
      final p = _sizePacking[r.size.trim()];
      return (
        tileType: p?.tileType ?? '',
        pieces: p?.pieces ?? 0,
        weight: p?.weight ?? 0,
      );
    }
    return (tileType: _tileType ?? '', pieces: _piecesPerBox, weight: _boxWeightKg);
  }

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
      final sizes = await _dataSvc.getActiveSizeNames();
      if (sizes.isNotEmpty) _sizes = sizes;
      // Admin finishes + learned surface aliases for the Map-surfaces step.
      final fins = await _dataSvc.getSurfaceTypes(activeOnly: true);
      final finNames = fins.map((t) => t.name).toList();
      if (finNames.isNotEmpty) _finishes = finNames;
      _aliases = await _dataSvc.getSurfaceAliases(currentStockistUUID);
      // Resolve the chosen brand (default brand when none was passed). Upload fills
      // P_Stock for this brand — no stock list is targeted.
      final brands = await _dataSvc.getMyBrands();
      if (brands.isNotEmpty) {
        final brand = brands.firstWhere((b) => b.id == _brandId,
            orElse: () => brands.firstWhere((b) => b.isDefault,
                orElse: () => brands.first));
        _brandId = brand.id;
        _brandName = brand.name;
        _isDefaultBrand = brand.isDefault;
      }
      _isM = currentStockistBusinessType == 'M';
      if (_sizes.isNotEmpty) _docSize = _sizes.first;
      // Existing library identities (name+size, master + aliases) — drives the
      // Step-2 "ask only when something is new" shortcut.
      final lib = await _dataSvc.getMyLibrary();
      _libKeys
        ..clear()
        ..addAll([
          for (final e in lib) ...[
            _libKey(e.masterName, e.size),
            for (final a in e.aliases.values) _libKey(a, e.size),
          ]
        ]);
      // Names already present under the SELECTED brand (re-uploads are fine). For M
      // on a non-default brand we keep only NEW designs and these own-brand ones;
      // designs that exist only under ANOTHER brand can't be matched safely from a
      // PDF (no reference name) → skipped, link them via Excel mapping instead.
      _libThisBrandKeys.clear();
      if (_brandId != null) {
        for (final e in lib) {
          final a = e.aliases[_brandId];
          if (a != null && a.trim().isNotEmpty) {
            _libThisBrandKeys.add(_libKey(a, e.size));
          }
        }
      }
      // Existing P_Stock holdings (name+size+quality+surface) — drives the pure
      // restock shortcut (skip straight to quantities).
      final holdings = await _dataSvc.getDesignsByStockist(currentStockistUUID);
      _holdingKeys
        ..clear()
        ..addAll([
          for (final d in holdings)
            _holdingKey(d.name, d.size, d.quality, d.surfaceType)
        ]);
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
            // Per-design size from the PDF when the layout carries one (mixed-size
            // files); else the document size. The stockist can still override it.
            size: _normaliseSize(d.sizeRaw ?? '') ?? _docSize,
            imageBytes: d.imageBytes,
            qty: d.quantity,
            surface: d.surface,
            // Seed each row's quality from the PDF (per-row grade if the layout
            // carries one, e.g. PRE/STD, else the document quality). Used when
            // the batch mode is "Both"; uniform modes override it on save.
            quality: canonQuality(d.qualityRaw ?? parsed.quality),
          )));

    // M on a non-default brand: keep only NEW or own-brand designs; designs that
    // exist only under another brand are skipped (review page → link via Excel).
    _applyBrandScopeFilter();

    _endProcessing();
    if (!mounted) return;
    _batchId = const Uuid().v4(); // one idempotency key per parsed PDF
    if (_skippedOtherBrand.isNotEmpty) {
      setState(() => _phase = _Phase.skipped);
    } else {
      _startReveal();
    }
  }

  // M only, non-default brand: classify parsed rows. New or own-brand → keep;
  // exists only under another brand → skip + collect for the review page. A PDF
  // has no reference name, so matching to another brand can't be done safely.
  void _applyBrandScopeFilter() {
    _skippedOtherBrand.clear();
    if (!_isM || _isDefaultBrand) return;
    for (final r in _rows) {
      final key = _libKey(r.name, r.size);
      final underThisBrand = _libThisBrandKeys.contains(key);
      final existsSomewhere = _libKeys.contains(key);
      if (existsSomewhere && !underThisBrand) {
        r.include = false;
        _skippedOtherBrand.add((name: r.name, size: r.size));
      }
    }
  }

  // ── Live design reveal (non-interactive) ─────────────────────────────────────
  // Designs appear one-by-one with a new/already-in-library signal so the stockist
  // sees what's going into the library. No tapping; auto-paced (~2.5s total
  // regardless of count); Continue when done.
  void _startReveal() {
    _revealTimer?.cancel();
    _revealCount = 0;
    final n = _kept.length;
    final interval = n == 0 ? 1 : (2500 ~/ n).clamp(40, 150);
    setState(() => _phase = _Phase.reveal);
    _revealTimer = Timer.periodic(Duration(milliseconds: interval), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_revealCount >= n) {
        t.cancel();
        return;
      }
      setState(() => _revealCount++);
    });
  }

  // Reveal done → the real routing: pure-restock express, else the size question.
  void _afterReveal() {
    _revealTimer?.cancel();
    if (_allHoldingsMatch) {
      // Pure restock: every design already exists as a holding, so there is no
      // library to build — go straight to the stock branch (mode → quantities).
      // Quality is auto "both" (per-row from the PDF); the quality page is skipped.
      _restock = true;
      _qualityMode = _QualityMode.both;
      _surfacePresent = true;
      setState(() => _phase = _Phase.mode);
      return;
    }
    setState(() {
      _restock = false;
      _oneSize = null;
      _mixNoSize = false;
      _phase = _Phase.sizeAsk;
    });
  }

  // ── Step 1 · size question ───────────────────────────────────────────────────
  // A size from the uploaded file's NAME (e.g. "800X1600 PRE.pdf" → 800x1600 mm),
  // mapped to an admin size, used to cross-check the stockist's one-size pick.
  String? _filenameSize() {
    final m = RegExp(r'(\d{2,4})\s*[xX]\s*(\d{2,4})').firstMatch(_filename);
    if (m == null) return null;
    return _normaliseSize('${m.group(1)}x${m.group(2)}');
  }

  // "One size" confirmed: apply it to every row, cross-check the filename, then on
  // to Step-0. A filename size that disagrees with the pick raises a proceed/cancel.
  Future<void> _confirmOneSize() async {
    final picked = _docSize;
    final fileSize = _filenameSize();
    if (fileSize != null && fileSize != picked) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Size mismatch'),
          content: Text(
              'You picked “$picked”, but the PDF file name looks like “$fileSize”. '
              'They are different.\n\nUse your pick “$picked” and continue, or '
              'cancel to choose again?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Continue')),
          ],
        ),
      );
      if (go != true) return;
    }
    for (final r in _rows) {
      r.size = picked;
    }
    _afterSize();
  }

  // "Mixed sizes" + the size is in the PDF: go on; the stockist sets each row's
  // size on the design list (the parser carries only one document size).
  void _proceedMix() {
    _afterSize();
  }

  // Size resolved → Step-0 exact-duplicate scan, then the design list (Step 1).
  void _afterSize() {
    final mistakes = _findMistakes();
    setState(() {
      if (mistakes.isNotEmpty) {
        _mistakeGroups
          ..clear()
          ..addAll(mistakes);
        _phase = _Phase.mistakes;
      } else {
        _phase = _Phase.edit;
      }
    });
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

  // Edit/dedupe resolved → Step 2 wizard. A mixed-size PDF is no longer punted to
  // library-only — Step 2 asks packing per size so it can add stock too.
  void _proceedAfterEdit() {
    // M + all designs already exist → nothing to ask (surface isn't captured on
    // an M PDF); build the library and save now.
    if (_isM && !_hasNewDesigns) {
      _enterStock();
      return;
    }
    setState(() {
      // Identity wizard (LIBRARY build). Quality is no longer asked here — it
      // moved to the stock branch. Start at the first identity question.
      if (!_hasNewDesigns) {
        _askStep = _AskStep.surfaceInPdf;
      } else if (_isMultiSize) {
        _ensureSizePacking();
        _askStep = _AskStep.sizePacking;
      } else {
        _askStep = _AskStep.tileSame;
      }
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
    // Only flag a name+size group when 2+ rows carry a PHOTO — that's the genuine
    // "which image is this design?" question. Rows that merely differ by
    // surface/quality (≤1 photo) are one design with separate stock lines and pass
    // straight through (no folding — they become separate holdings on save).
    return [
      for (final e in byKey.entries)
        if (e.value.length > 1 &&
            e.value.where((r) => r.imageBytes != null).length > 1)
          _DupGroup(e.key, e.value)
    ];
  }

  // "Continue" on the dedupe page. Same-design groups: keep every row (they stay as
  // separate stock lines by surface/quality) but only the chosen row's photo goes to
  // the master. Keep-both groups: every row must have a unique name (they become
  // separate library designs). Nothing is folded — quantities are never merged here.
  void _applyDedupe() {
    // Validate keep-both names first (so we don't half-apply).
    for (final g in _dupGroups) {
      if (!g.keepBoth) continue;
      final seen = <String>{};
      for (final r in g.rows) {
        final n = r.name.trim().toLowerCase();
        if (n.isEmpty) {
          _toast('Give every design a name to keep them separate.', error: true);
          return;
        }
        if (!seen.add(n)) {
          _toast('Two designs still share the name "${r.name.trim()}" — make them different.',
              error: true);
          return;
        }
      }
    }
    for (final g in _dupGroups) {
      if (g.keepBoth) {
        for (final r in g.rows) {
          r.include = true;
          r.contributeImage = true; // each is its own design now
        }
      } else {
        final carrier = g.chosen ?? g.rows.first;
        for (final r in g.rows) {
          r.include = true;
          r.contributeImage = identical(r, carrier);
        }
      }
    }
    _proceedAfterEdit();
  }

  // ── Step 0 · exact-duplicate (PDF mistake) detection ─────────────────────────
  // A genuine duplicate = identical name + size + quality + surface (the SAME stock
  // line listed twice in the PDF). Other same-name rows (differing surface / quality
  // / image) are NOT mistakes — they're handled when building the library (Step 1).
  List<_MistakeGroup> _findMistakes() {
    final byKey = <String, List<_ImpRow>>{};
    for (final r in _rows) {
      if (!r.include || r.name.trim().isEmpty) continue;
      final key = [
        r.name.trim().toLowerCase(),
        r.size.trim().toLowerCase(),
        r.quality.trim().toLowerCase(),
        r.surface.trim().toLowerCase(),
      ].join('|');
      (byKey[key] ??= []).add(r);
    }
    return [
      for (final e in byKey.entries)
        if (e.value.length > 1) _MistakeGroup(e.key, e.value)
    ];
  }

  int _mistakeSum(_MistakeGroup g) => g.rows.fold<int>(0, (n, r) => n + r.qty);

  // "Continue" on Step 0: per group keep the chosen row; Merge sums the others'
  // boxes into it, Keep-one just drops them. Then on to build the library (Step 1).
  void _applyMistakes() {
    for (final g in _mistakeGroups) {
      final carrier = g.chosen ?? g.rows.first;
      var sum = carrier.qty;
      for (final r in g.rows) {
        if (identical(r, carrier)) continue;
        if (g.merge) sum += r.qty;
        r.include = false;
      }
      carrier.include = true;
      if (g.merge) carrier.qtyCtrl.text = sum > 0 ? '$sum' : '';
    }
    setState(() => _phase = _Phase.edit);
  }

  // ── Step 2 wizard navigation ─────────────────────────────────────────────────
  // One full-screen question per sub-step. "Next" advances the option pages;
  // Yes/No pages advance via their own handlers. Back walks the chain in reverse.

  void _askBack() {
    switch (_askStep) {
      case _AskStep.quality:
        // Quality now lives in the stock branch — Back returns to the mode page.
        setState(() => _phase = _Phase.mode);
      case _AskStep.sizePacking:
        setState(() => _phase = _Phase.edit);
      case _AskStep.tileSame:
        setState(() => _phase = _Phase.edit);
      case _AskStep.tilePick:
      case _AskStep.tileBlocked:
        setState(() => _askStep = _AskStep.tileSame);
      case _AskStep.pieces:
        setState(() => _askStep = _AskStep.tilePick);
      case _AskStep.weight:
        setState(() => _askStep = _AskStep.pieces);
      case _AskStep.surfaceInPdf:
        // First identity step when there are no new designs → back to the list.
        if (!_hasNewDesigns) {
          setState(() => _phase = _Phase.edit);
        } else {
          setState(() => _askStep =
              _isMultiSize ? _AskStep.sizePacking : _AskStep.weight);
        }
      case _AskStep.surfaceChoice:
        setState(() => _askStep = _AskStep.surfaceInPdf);
    }
  }

  // "Next" on the option pages (validates that page, then advances).
  void _askNext() {
    switch (_askStep) {
      case _AskStep.quality:
        // No new design → skip identity entirely. New + mixed size → ask packing
        // per size. New + single size → the one-tile-type wizard.
        if (!_hasNewDesigns) {
          setState(() => _askStep = _AskStep.surfaceInPdf);
        } else if (_isMultiSize) {
          _ensureSizePacking();
          setState(() => _askStep = _AskStep.sizePacking);
        } else {
          setState(() => _askStep = _AskStep.tileSame);
        }
      case _AskStep.sizePacking:
        if (!_sizePackingComplete) {
          _toast('Fill tile type, pieces and weight for every size.',
              error: true);
          return;
        }
        _toSurfaceStep();
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
        _toSurfaceStep();
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

  // Advance to the surface question — or, for M, skip it: an M PDF is library-
  // only, so surface is never captured here (it's picked at Add Stock).
  void _toSurfaceStep() {
    if (_isM) {
      _enterStock();
    } else {
      setState(() => _askStep = _AskStep.surfaceInPdf);
    }
  }

  // Wizard done → Step 3 (Quantities). Re-checks the compulsory gates defensively
  // and resolves the document-wide surface for the "not in PDF" branch.
  Future<void> _enterStock() async {
    // Identity gates only apply when the batch has a brand-new design. Mixed-size
    // uses per-size packing; single-size uses the one tile type / pieces / weight.
    if (_hasNewDesigns) {
      if (_isMultiSize) {
        if (!_sizePackingComplete) {
          setState(() => _askStep = _AskStep.sizePacking);
          return;
        }
      } else {
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
      }
    }
    // M: PDF builds the picture library ONLY — surface isn't captured here (it's
    // picked at Add Stock). Skip the surface mapping and save immediately.
    if (_isM) {
      _save(libraryOnly: true);
      return;
    }
    if (!_surfacePresent) {
      final s = _singleSurface ? _singleSurfaceValue : 'None';
      for (final r in _rows) {
        r.surface = s;
      }
    } else {
      // Surface came from the PDF — align each scraped surface to a real finish
      // (and learn the alias). Cancel keeps the stockist on the surface question.
      final ok = await _mapSurfacesStep();
      if (!ok) return;
    }
    setState(() => _phase = _Phase.stockGate);
  }

  // Map each distinct scraped surface to one of the admin finishes (like the Excel
  // importer's "Map Finishes"), then apply it to every row + learn the alias so the
  // next upload of this supplier needs no mapping. Returns false on cancel.
  Future<bool> _mapSurfacesStep() async {
    final groups = <String, _SurfGroup>{}; // normalized raw → group
    for (final r in _kept) {
      final raw = r.surface.trim();
      if (raw.isEmpty || raw.toLowerCase() == 'none') continue;
      final key = normalizeSurfaceRaw(raw);
      final g = groups.putIfAbsent(key, () {
        final aliased = _aliases[key];
        final init = (aliased != null && _finishes.contains(aliased))
            ? aliased
            : (_finishes.contains(raw)
                ? raw
                : (_finishes.isNotEmpty ? _finishes.first : 'None'));
        return _SurfGroup(label: raw, choice: init);
      });
      g.count++;
    }
    if (groups.isEmpty) return true; // nothing scraped to map

    final keys = groups.keys.toList();
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Map surfaces'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    'Match each surface from your PDF to one of your finishes. '
                    'Applies to every design with that surface, and is remembered '
                    'for next time.',
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
                                  value: _surfaceOptions.contains(g.choice)
                                      ? g.choice
                                      : _surfaceOptions.first,
                                  items: _surfaceOptions
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
    if (ok != true) return false;

    for (final r in _kept) {
      final raw = r.surface.trim();
      if (raw.isEmpty || raw.toLowerCase() == 'none') {
        r.surface = 'None';
        continue;
      }
      final g = groups[normalizeSurfaceRaw(raw)];
      if (g != null) r.surface = g.choice;
    }
    // Learn the alias (raw wording → chosen finish) for next time.
    for (final k in keys) {
      final g = groups[k]!;
      if (g.choice != 'None' && currentStockistUUID.isNotEmpty) {
        await _dataSvc.upsertSurfaceAlias(currentStockistUUID, k, g.choice);
      }
    }
    return true;
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

    // Guardrail: the stockist chose to add stock, but every quantity is blank/0.
    // Don't silently save as library-only — make it an explicit choice. (This is
    // the case that earlier looked like "stock didn't save".)
    if (!libraryOnly && kept.every((r) => r.qty <= 0)) {
      final choice = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('No quantities entered'),
          content: const Text(
              'You chose to add stock, but no box quantities are filled in. '
              'Go back to enter quantities, or save these designs to your '
              'Library only?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, 'back'),
                child: const Text('Go back')),
            FilledButton(
                onPressed: () => Navigator.pop(c, 'libonly'),
                child: const Text('Save library only')),
          ],
        ),
      );
      if (choice != 'libonly') return; // 'back' or dismissed → stay on the page
      libraryOnly = true;
    }

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
      if (r.imageBytes != null && r.contributeImage && r.uploadedUrl == null) {
        setState(() => _progressDetail = 'Uploading image for ${r.name}…');
        final up = await CloudinaryService.uploadImageBytes(
          r.imageBytes!,
          filename: '${r.name.trim().replaceAll(' ', '_')}.jpg',
        );
        if (up.ok) r.uploadedUrl = up.url;
      }
    }

    // 2) Build the batch payload. Packing (tile type / pieces / weight) is resolved
    //    PER ROW: per-size for a mixed-size PDF, else the one batch value. The
    //    derived thickness is computed from that row's packing + size.
    final rows = kept.map((r) {
      final pk = _packingFor(r);
      final thick = (!libraryOnly && pk.pieces > 0 && pk.weight > 0)
          ? approxThicknessMm(r.size.trim(), pk.pieces, pk.weight, pk.tileType)
          : null;
      return <String, dynamic>{
        'name': r.name.trim(),
        'size': r.size.trim(),
        'quality': _qualityOf(r),
        'surface': libraryOnly ? 'None' : r.surface,
        'qty': libraryOnly ? 0 : r.qty,
        if (r.uploadedUrl != null && r.contributeImage) 'image_url': r.uploadedUrl,
        'stock_type': 'Uncertain',
        if (!libraryOnly) ...{
          'tile_type': pk.tileType,
          'pieces_per_box': pk.pieces,
          'box_weight_kg': pk.weight,
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
        catalogId: null, // upload fills P_Stock; lists are curated separately
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
      case _Phase.skipped:
        return _skippedBody();
      case _Phase.reveal:
        return _revealBody();
      case _Phase.sizeAsk:
        return _sizeAskBody();
      case _Phase.mistakes:
        return _mistakesBody();
      case _Phase.edit:
        return _editBody();
      case _Phase.dedupe:
        return _dedupeBody();
      case _Phase.ask:
        return _askBody();
      case _Phase.stockGate:
        return _stockGateBody();
      case _Phase.quality:
        return _qualityBody();
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
                'Brand: ${_brandName.isEmpty ? '—' : _brandName}',
                style: const TextStyle(fontSize: 12.5, color: Color(0xFF1B4F72)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Step 1a — choose the upload mode, then a guarded 5-second confirm that names
  // the exact brand. Only on confirm do we move on to pick the PDF.
  Future<void> _pickMode(UploadMode m) async {
    final ok = await showUploadModeConfirm(context, m, _brandName);
    if (!ok || !mounted) return;
    setState(() {
      _mode = m;
      // Normal: mode → quality → quantities. Pure restock: quality is auto-set
      // ("both"), so skip straight to quantities.
      _phase = _restock ? _Phase.stock : _Phase.quality;
    });
  }

  // After the library is built: offer to also record stock now, or save designs
  // only. The library is built either way (on save). "Yes" → stock branch.
  Widget _stockGateBody() {
    final n = _kept.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _contextChip(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          child: _askHeading('Also add stock now?'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: _askHelp(
              'Your library is ready — $n design${n == 1 ? '' : 's'} will be saved '
              'with their photos and details. You can record how many boxes you '
              'have now, or do it later.'),
        ),
        Card(
          margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: ListTile(
            leading: const Icon(Icons.inventory_2_outlined,
                color: Color(0xFF1B4F72)),
            title: const Text('Yes — add stock quantities now',
                style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Record how many boxes you have',
                style: TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : () => setState(() => _phase = _Phase.mode),
          ),
        ),
        Card(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: ListTile(
            leading: const Icon(Icons.collections_bookmark_outlined,
                color: Color(0xFF2E7D32)),
            title: const Text('No — just save the designs',
                style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Library only; add stock anytime later',
                style: TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : () => _save(libraryOnly: true),
          ),
        ),
        const Spacer(),
      ],
    );
  }

  // Stock branch · quality grade (Premium / Standard / Both). Reached after the
  // mode page; continues to the per-design quantities.
  Widget _qualityBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _contextChip(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            children: [
              _askHeading('What grade is the stock in this PDF?'),
              _askHelp(
                  'Choose Premium or Standard if the whole PDF is one grade. '
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
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                OutlinedButton(
                  onPressed:
                      _busy ? null : () => setState(() => _phase = _Phase.mode),
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 22, vertical: 14)),
                  child: const Text('Back'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed:
                        _busy ? null : () => setState(() => _phase = _Phase.stock),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1B4F72),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                    child: const Text('Continue to quantities'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
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
        // "Fully new" (zero everything else) needed a single list to scope to;
        // upload now fills P_Stock for the whole brand, so only the safe top-up /
        // set-matched modes are offered here.
        for (final m in const [UploadMode.add, UploadMode.updateKeep])
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
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => setState(() => _phase = _Phase.stockGate),
              style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 14)),
              child: const Text('Back'),
            ),
          ),
        ),
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
          child: TypewriterText(
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
        // Doc-wide size — shown only when the stockist chose "one size" (Step 1).
        if (_oneSize == true)
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

  // ── M non-default brand · skipped designs review ─────────────────────────────
  // Designs that already exist under another brand are skipped (a PDF can't match
  // them safely). List them so the stockist knows to link via Excel mapping, then
  // continue with the genuinely-new designs (if any).
  Widget _skippedBody() {
    final remaining = _kept.length;
    final n = _skippedOtherBrand.length;
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              '$n design${n == 1 ? '' : 's'} already in your library',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(
              'These already exist under another brand. A PDF has no reference name '
              'to match them safely, so they are skipped here. To also stock them '
              'under "$_brandName", link them using Excel mapping.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _skippedOtherBrand.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final s = _skippedOtherBrand[i];
                return ListTile(
                  dense: true,
                  leading: Icon(Icons.link_off,
                      size: 18, color: Colors.orange.shade700),
                  title: Text(s.name),
                  subtitle: Text(s.size.replaceAll(' mm', '')),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ),
                if (remaining > 0) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _startReveal,
                      child: Text('Continue with $remaining new'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Step 1 · size question (one size vs mixed) ───────────────────────────────
  // ── Live design reveal (non-interactive) ─────────────────────────────────────
  Widget _revealBody() {
    final rows = _kept;
    final n = rows.length;
    final shown = _revealCount > n ? n : _revealCount;
    final done = shown >= n;
    final newCount = rows
        .take(shown)
        .where((r) => !_libKeys.contains(_libKey(r.name, r.size)))
        .length;
    // Keep the newest revealed design in view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_revealScroll.hasClients) {
        _revealScroll.animateTo(_revealScroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
    return Column(
      children: [
        _contextChip(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(children: [
            Expanded(
              child: Text(done ? 'Designs read' : 'Reading your designs…',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
            ),
            Text('$shown of $n',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
                value: n == 0 ? 1 : shown / n,
                minHeight: 6,
                backgroundColor: Colors.grey.shade200),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Row(children: [
            _legendDot(const Color(0xFF2E7D32), 'New to library'),
            const SizedBox(width: 14),
            _legendDot(const Color(0xFF1B4F72), 'Already in library'),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            controller: _revealScroll,
            itemCount: shown,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) => _revealRow(rows[i]),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: done && !_busy ? _afterReveal : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1B4F72),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.grey.shade300,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(done ? 'Continue  ($newCount new)' : 'Reading…'),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _legendDot(Color c, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
        ],
      );

  Widget _revealRow(_ImpRow r) {
    final inLib = _libKeys.contains(_libKey(r.name, r.size));
    final dot = inLib ? const Color(0xFF1B4F72) : const Color(0xFF2E7D32);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        _thumb(r),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(r.name.trim().isEmpty ? '(no name)' : r.name.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              Text(r.size,
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _flag(inLib ? 'In library' : 'New',
            inLib ? const Color(0xFF1B4F72) : const Color(0xFF2E7D32)),
        if (r.imageBytes == null) ...[
          const SizedBox(width: 6),
          _flag('No photo', Colors.orange.shade700),
        ],
      ]),
    );
  }

  Widget _sizeAskBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _contextChip(),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text('Step 1 · Size',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: _sizeAskPage(),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(children: [
              if (_oneSize == null)
                OutlinedButton(
                  onPressed:
                      _busy ? null : () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade700,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 14)),
                  child: const Text('Cancel upload'),
                )
              else
                OutlinedButton.icon(
                  // From the "no size" explanation, Back returns to the question;
                  // otherwise it returns to the one/mixed choice.
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                            if (_mixNoSize) {
                              _mixNoSize = false;
                            } else {
                              _oneSize = null;
                            }
                          }),
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: const Text('Back'),
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 14)),
                ),
              const SizedBox(width: 12),
              if (_oneSize == true)
                Expanded(
                  child: ElevatedButton(
                    onPressed: _busy ? null : _confirmOneSize,
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1B4F72),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                    child: const Text('Continue'),
                  ),
                )
              else if (_mixNoSize)
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        _busy ? null : () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red.shade700,
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                    child: const Text('Cancel upload'),
                  ),
                ),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _sizeAskPage() {
    if (_oneSize == null) {
      return ListView(children: [
        _askHeading('Does this PDF have one size, or a mix of sizes?'),
        _askHelp('Most supplier PDFs are a single size per file. Pick "One size" '
            'to choose it once for every design, or "Mixed sizes" if the file '
            'lists different sizes.'),
        const SizedBox(height: 16),
        _bigChoice('One size — the whole file is a single size', false,
            () => setState(() => _oneSize = true)),
        _bigChoice('Mixed sizes — different sizes in one file', false,
            () => setState(() => _oneSize = false)),
      ]);
    }
    if (_oneSize == true) {
      return ListView(children: [
        _askHeading('Which size?'),
        _askHelp('Pick the one size that matches every design in this PDF. It is '
            'applied to all of them.'),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFF1B4F72)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: DropdownButton<String>(
            value: _sizes.contains(_docSize) ? _docSize : null,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            hint: const Text('Pick a size'),
            items: _sizes
                .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                .toList(),
            onChanged: (v) => setState(() => _docSize = v ?? _docSize),
          ),
        ),
      ]);
    }
    // Mixed sizes, but the PDF has no per-design size → explain why + what to do.
    if (_mixNoSize) {
      return ListView(children: [
        _askHeading('A mixed-size PDF needs a size for each design'),
        _askHelp('Because this file has more than one size, we need the size '
            'written next to each design. Without it we can’t tell which design '
            'is which size, so the stock would be added wrong.\n\n'
            'What to do — either:\n'
            '•  Split the PDF into one file per size, then upload each one and '
            'choose “One size”, or\n'
            '•  Add the size next to each design in the PDF and upload again.'),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF8E1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFFFE082)),
          ),
          child: Row(children: [
            Icon(Icons.lightbulb_outline,
                size: 18, color: Colors.orange.shade800),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  'Tip: one file per size is the quickest — each uploads cleanly '
                  'as a single size.',
                  style:
                      TextStyle(fontSize: 12, color: Colors.orange.shade900)),
            ),
          ]),
        ),
      ]);
    }
    // Mixed sizes → the size must be present per design in the PDF.
    return ListView(children: [
      _askHeading('Is each design’s size written in this PDF?'),
      _askHelp('A mixed-size file must list a size for every design. If yes, '
          'continue and set each design’s size on the next screen.'),
      const SizedBox(height: 24),
      _yesNo(
          selected: null,
          onYes: _proceedMix,
          onNo: () => setState(() => _mixNoSize = true)),
    ]);
  }

  // ── Step 0 · resolve exact-duplicate rows (PDF mistakes) ─────────────────────
  Widget _mistakesBody() {
    return Column(
      children: [
        _contextChip(),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text('Step 0 · Possible mistakes in your PDF',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: TypewriterText(
              'These rows are identical in name, size, quality AND surface — the '
              'same stock line appears more than once in your PDF. Merge them (add '
              'the boxes together) or keep just one.',
              style: TextStyle(fontSize: 12.5, color: Colors.black54)),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            itemCount: _mistakeGroups.length,
            itemBuilder: (_, i) => _mistakeCard(_mistakeGroups[i]),
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
                  onPressed: _busy ? null : _applyMistakes,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1B4F72),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  child: const Text('Continue'),
                ),
              ),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _mistakeCard(_MistakeGroup g) {
    final first = g.rows.first;
    final surface = first.surface.trim().isEmpty ? 'None' : first.surface.trim();
    final quality = first.quality.trim().isEmpty ? '—' : first.quality.trim();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('“${first.name.trim()}”  ·  ${first.size}',
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 2),
            Text('$quality  ·  $surface  ·  appears ${g.rows.length} times',
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [for (final r in g.rows) _mistakePhoto(g, r)],
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: _mistakeChoice(
                    g, true, 'Merge', 'add boxes → ${_mistakeSum(g)} total'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _mistakeChoice(
                    g, false, 'Keep one', 'keep the selected row only'),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  // A selectable row tile in Step 0 (the kept row's photo + box count). Tap to
  // select which row survives; the magnifier opens the full scraped detail.
  Widget _mistakePhoto(_MistakeGroup g, _ImpRow r) {
    final sel = identical(g.chosen, r);
    return InkWell(
      onTap: () => setState(() => g.chosen = r),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 104,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          border: Border.all(
              color: sel ? const Color(0xFF1B4F72) : Colors.grey.shade300,
              width: sel ? 2.5 : 1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              children: [
                SizedBox(width: 92, height: 92, child: _thumbLarge(r)),
                Positioned(
                  right: 2,
                  top: 2,
                  child: GestureDetector(
                    onTap: () => _showFullRow(r),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(5)),
                      child: const Icon(Icons.zoom_in,
                          size: 16, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('Box ${r.qty > 0 ? r.qty : '—'}',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
            const SizedBox(height: 2),
            Icon(sel ? Icons.check_circle : Icons.circle_outlined,
                size: 18,
                color: sel ? const Color(0xFF1B4F72) : Colors.grey.shade400),
          ],
        ),
      ),
    );
  }

  Widget _mistakeChoice(
      _MistakeGroup g, bool mergeVal, String title, String sub) {
    final selected = g.merge == mergeVal;
    return GestureDetector(
      onTap: () => setState(() => g.merge = mergeVal),
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

  // ── Step 1b · resolve same-name duplicates ───────────────────────────────────
  Widget _dedupeBody() {
    return Column(
      children: [
        _contextChip(),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text('Step 1 · Same name, different photos',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: TypewriterText(
              'These designs share a name but came with different photos. For each '
              'one, just tell us: is it the SAME design, or DIFFERENT designs?',
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
                  child: const Text('Continue'),
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
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('“${g.rows.first.name.trim()}”  ·  ${g.rows.first.size}',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 2),
            Text('Came with ${g.rows.length} different photos.',
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
            const SizedBox(height: 10),
            // Lead with the only decision: same design, or different designs.
            Row(children: [
              Expanded(
                  child: _dupModeBtn(g, false, 'Same design', Icons.copy_all)),
              const SizedBox(width: 8),
              Expanded(
                  child: _dupModeBtn(
                      g, true, 'Different designs', Icons.call_split)),
            ]),
            const SizedBox(height: 12),
            if (!g.keepBoth) ...[
              Text('Tap the photo that shows this design:',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [for (final r in g.rows) _dupPhotoChoice(g, r)],
              ),
            ] else ...[
              Text('Give each design its own name:',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
              const SizedBox(height: 4),
              for (final r in g.rows) _dupRenameRow(r),
            ],
          ],
        ),
      ),
    );
  }

  // A segmented "Same design / Different designs" button for the dedupe card.
  Widget _dupModeBtn(
      _DupGroup g, bool keepBothVal, String label, IconData icon) {
    final sel = g.keepBoth == keepBothVal;
    return GestureDetector(
      onTap: () => setState(() => g.keepBoth = keepBothVal),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: sel ? const Color(0xFF1B4F72) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: sel ? const Color(0xFF1B4F72) : Colors.grey.shade300),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 16,
                color: sel ? Colors.white : const Color(0xFF1B4F72)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: sel ? Colors.white : Colors.black87)),
            ),
          ],
        ),
      ),
    );
  }

  // A rename row used when a same-name+size group is split into different designs:
  // its photo + scraped detail + an editable name (must end up unique in the group).
  Widget _dupRenameRow(_ImpRow r) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => _showFullRow(r),
            child: SizedBox(width: 52, height: 52, child: _thumbLarge(r)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  initialValue: r.name,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Design name',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => r.name = v,
                ),
                const SizedBox(height: 2),
                _scrapeDetail(r),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Compact readout of what the parser scraped for THIS row, shown on the
  // duplicate resolver. The whole point: same-name rows usually differ by these
  // fields (e.g. one ANT GREY in Glossy, another in Lustra), so the stockist can
  // tell "same design twice" from "two different designs" at a glance.
  Widget _scrapeDetail(_ImpRow r, {bool center = false}) {
    final surface = r.surface.trim().isEmpty ? 'None' : r.surface.trim();
    final parts = <String>[
      'Box ${r.qty > 0 ? r.qty : '—'}',
      surface,
      if (r.quality.trim().isNotEmpty) r.quality.trim(),
    ];
    return Text(parts.join('  ·  '),
        textAlign: center ? TextAlign.center : TextAlign.start,
        style: TextStyle(
            fontSize: 11, height: 1.2, color: Colors.grey.shade700));
  }

  // Full image + everything the parser scraped for this row, in a popup.
  void _showFullRow(_ImpRow r) {
    Widget img;
    if (r.imageBytes != null) {
      img = Image.memory(r.imageBytes!, fit: BoxFit.contain);
    } else if (r.libImageUrl != null && r.libImageUrl!.isNotEmpty) {
      img = CachedNetworkImage(imageUrl: r.libImageUrl!, fit: BoxFit.contain);
    } else {
      img = Container(
        height: 160,
        color: Colors.grey.shade200,
        child: Icon(Icons.image_not_supported_outlined,
            size: 40, color: Colors.grey.shade400),
      );
    }
    final surface = r.surface.trim().isEmpty ? 'None' : r.surface.trim();
    showDialog<void>(
      context: context,
      builder: (c) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ClipRRect(
                    borderRadius: BorderRadius.circular(8), child: img),
              ),
              const SizedBox(height: 12),
              Text(r.name.trim(),
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 6),
              Text(
                'Size: ${r.size}\n'
                'Box quantity: ${r.qty > 0 ? r.qty : '—'}\n'
                'Surface: $surface\n'
                'Quality: ${r.quality.trim().isEmpty ? '—' : r.quality.trim()}',
                style: TextStyle(fontSize: 13.5, color: Colors.grey.shade800),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                    onPressed: () => Navigator.pop(c),
                    child: const Text('Close')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // A selectable photo tile in the "same design" resolver. Tap the photo to
  // select it as the carrier; tap the magnifier to see the full image + details.
  Widget _dupPhotoChoice(_DupGroup g, _ImpRow r) {
    final sel = identical(g.chosen, r);
    final surface = r.surface.trim().isEmpty ? 'None' : r.surface.trim();
    return InkWell(
      onTap: () => setState(() => g.chosen = r),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 140,
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: sel ? const Color(0xFFE3F2FD) : Colors.white,
          border: Border.all(
              color: sel ? const Color(0xFF1B4F72) : Colors.grey.shade300,
              width: sel ? 2.5 : 1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              children: [
                SizedBox(width: 128, height: 128, child: _thumbLarge(r)),
                Positioned(
                  right: 2,
                  top: 2,
                  child: GestureDetector(
                    onTap: () => _showFullRow(r),
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(5)),
                      child: const Icon(Icons.zoom_in,
                          size: 18, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            // Just the surface — the thing that differs — not box/quality clutter.
            Text('Surface: $surface',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
            const SizedBox(height: 3),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(sel ? Icons.check_circle : Icons.circle_outlined,
                    size: 17,
                    color:
                        sel ? const Color(0xFF1B4F72) : Colors.grey.shade400),
                const SizedBox(width: 4),
                Text(sel ? 'Keep this' : 'Tap to keep',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: sel ? FontWeight.w600 : FontWeight.normal,
                        color: sel
                            ? const Color(0xFF1B4F72)
                            : Colors.grey.shade600)),
              ],
            ),
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
          // Mixed-size PDF → each row picks its own size; one-size → just show it.
          if (_oneSize == false)
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
            )
          else
            Text(r.size,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
        ],
      ),
    );
  }

  // ── Step 2 wizard — one full-screen question per page ────────────────────────
  String _askStepTitle(_AskStep s) {
    switch (s) {
      case _AskStep.quality:
        return 'Quality';
      case _AskStep.sizePacking:
        return 'Packing per size';
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

  // Identity questions only (quality moved to the stock branch): 1 when all
  // designs exist (surface), 2 for a mixed-size new batch (per-size packing +
  // surface), else 4 (tile type + pieces + weight + surface).
  // M skips the surface question (PDF is library-only), so one fewer step.
  int get _askTotal => !_hasNewDesigns
      ? (_isM ? 0 : 1)
      : (_isMultiSize ? (_isM ? 1 : 2) : (_isM ? 3 : 4));

  int _askPhaseNum(_AskStep s) {
    switch (s) {
      case _AskStep.quality:
        return 1; // unused here (quality is its own phase in the stock branch)
      case _AskStep.sizePacking:
        return 1;
      case _AskStep.tileSame:
      case _AskStep.tilePick:
      case _AskStep.tileBlocked:
        return 1;
      case _AskStep.pieces:
        return 2;
      case _AskStep.weight:
        return 3;
      case _AskStep.surfaceInPdf:
      case _AskStep.surfaceChoice:
        return _askTotal; // surface is always the last step
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
                child: Text('Design details · ${_askStepTitle(_askStep)}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ),
              Text('${_askPhaseNum(_askStep)} of $_askTotal',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ],
          ),
        ),
        if (!_hasNewDesigns)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFFE8F5E9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle_outline,
                      size: 16, color: Color(0xFF2E7D32)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        'These designs are already in your library — we only need '
                        'grade, surface and quantities.',
                        style: TextStyle(
                            fontSize: 11.5, color: Colors.green.shade900)),
                  ),
                ],
              ),
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

  // One size's packing inputs (tile type + pieces + weight) for the mixed-size step.
  Widget _sizePackingCard(String size) {
    final p = _sizePacking.putIfAbsent(size, () => _SizePacking());
    final thick = (p.pieces > 0 && p.weight > 0)
        ? approxThicknessMm(
            size, p.pieces, p.weight, p.tileType ?? kTileTypes.first)
        : null;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(size,
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: p.tileType,
              isExpanded: true,
              decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Tile type',
                  border: OutlineInputBorder()),
              items: kTileTypes
                  .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                  .toList(),
              onChanged: (v) => setState(() => p.tileType = v),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: p.piecesCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Pieces / box',
                      border: OutlineInputBorder()),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: p.weightCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Box weight (kg)',
                      border: OutlineInputBorder()),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ]),
            if (thick != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('≈ ${thick.toStringAsFixed(1)} mm thick',
                    style:
                        TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
              ),
          ],
        ),
      ),
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

      case _AskStep.sizePacking:
        final sizes = _keptSizes.toList()..sort();
        return ListView(children: [
          _askHeading('Packing for each size'),
          _askHelp('This PDF has more than one size. Pieces per box and box weight '
              'differ by size — set them per size. Applies to every design of that '
              'size.'),
          const SizedBox(height: 12),
          for (final s in sizes) _sizePackingCard(s),
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

      // Surface is part of the design's identity, so there is no "save them all as None"
      // any more — a tile always has a surface. Since the PDF doesn't carry one, the whole
      // list must take one. That is the normal case for a stockist who makes a single
      // surface (and never writes it in the design name).
      case _AskStep.surfaceChoice:
        return ListView(children: [
          _askHeading('Which surface is this whole list?'),
          _askHelp('The PDF doesn’t show a surface, so every design in it will be saved '
              'with the one you pick here. A tile always has a surface — it is part of '
              'the design. You can change any of them afterwards in your Library.'),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _surfaceOptions.contains(_singleSurfaceValue)
                ? _singleSurfaceValue
                : null,
            decoration: InputDecoration(
              labelText: 'Surface for all',
              border: const OutlineInputBorder(),
              errorText: _surfaceOptions.contains(_singleSurfaceValue)
                  ? null
                  : 'Pick a surface',
            ),
            hint: const Text('Pick a surface'),
            items: _surfaceOptions
                .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                .toList(),
            onChanged: (v) => setState(() {
              _singleSurface = true;
              _singleSurfaceValue = v ?? _singleSurfaceValue;
            }),
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
        _askStep == _AskStep.surfaceChoice ? 'Continue' : 'Next';
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
        // Type-on reveal: paces the stockist through the instruction at each
        // decision page instead of letting it be skimmed. Replays only when the
        // step (text) changes; tap reveals the rest instantly.
        child: TypewriterText(
          t,
          key: ValueKey(t),
          style: TextStyle(
              fontSize: 14, height: 1.4, color: Colors.grey.shade700),
        ),
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
        if (_restock)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
                color: const Color(0xFFE8F5E9),
                borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              const Icon(Icons.bolt, size: 16, color: Color(0xFF2E7D32)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    'Quick restock — every design already exists (same size, '
                    'quality + surface). Just set the box quantities.',
                    style:
                        TextStyle(fontSize: 11.5, color: Colors.green.shade900)),
              ),
            ]),
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
                    if (_isMultiSize)
                      _reviewLine('Packing',
                          'Per size (${_keptSizes.length} sizes)',
                          isText: true)
                    else ...[
                      _reviewLine('Tile type', _tileType ?? '—', isText: true),
                      _reviewLine('Pieces / box',
                          _piecesPerBox > 0 ? '$_piecesPerBox' : '—',
                          isText: true),
                      _reviewLine('Box weight',
                          _boxWeightKg > 0 ? '$_boxWeightKg kg' : '—',
                          isText: true),
                    ],
                    _reviewLine('Brand', _brandName, isText: true),
                    _reviewLine('Added to', 'Your stock (add to a list after)',
                        isText: true),
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
                        initialValue: _surfaceOptions.contains(r.surface)
                            ? r.surface
                            : null, // no 'None' fallback — a surface must be picked
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

  /// **'None' is not offered.** A tile always has a surface, and it is part of the
  /// product's identity — importing a 'None' would create a phantom product beside the
  /// real one. The DB now refuses it outright (stockist_library_surface_not_none).
  /// `_finishes` comes from getSurfaceTypes(activeOnly: true), and 'None' is deactivated.
  List<String> get _surfaceOptions => _finishes;

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
