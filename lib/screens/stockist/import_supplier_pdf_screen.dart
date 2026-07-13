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
import '../../widgets/typewriter_text.dart';

// ─────────────────────────────────────────────────────────────────────────────
// The supplier-PDF importer — a LIBRARY BUILDER. It imports NO STOCK.
//
// A PDF is a portfolio, not a godown. It reliably carries only three things:
// DESIGN NAME · SIZE · PHOTO. Everything else it seems to carry is a trap:
//   * QUANTITY   — a printed box count is a snapshot of the day the supplier made
//                  the file. Importing it silently overwrites what is actually on
//                  the floor. Stock now enters ONLY via the Excel importer or by
//                  hand, where a human states the number he can see.
//   * QUALITY    — grades the HOLDING, not the design, so it belongs with the stock.
//   * SURFACE    — is PRODUCT IDENTITY, and we cannot ask mid-parse. So we must not
//                  GUESS mid-parse either: every row lands on 'Special', a real
//                  surface the stockist corrects in the Library, which cascades onto
//                  his holdings. (Guessing is what filled surface_aliases with
//                  'Bookmatch' and 'Marbleendless' — JOINT TYPES wearing a surface's
//                  clothes — and stamped a made-up surface on real products.)
//
// What it DOES ask, always, is the BOX: tile type + pieces per box + box weight.
// Those are printed on the carton, the stockist has it in front of him, and
// THICKNESS DERIVES FROM THEM — and thickness is in the product key. So:
//     no box → no thickness → no identity → NO PRODUCT.
// It is asked on EVERY import, not just when a design is new: the rows that match
// an existing product are exactly the ones whose box may still be blank, and
// `_library_apply_identity` fills a blank box (first-writer-wins, never overwrites).
//
// Nothing is written until the final Save (ONE atomic, idempotent batch).
// Flow: pick → (skipped) → reveal → sizeAsk → edit → dedupe → ask (the BOX)
//       → review (Save / Cancel) → done.  Cancel/back before Save writes NOTHING.
// ─────────────────────────────────────────────────────────────────────────────
enum _Phase { pick, skipped, reveal, sizeAsk, edit, dedupe, ask, review, done }

// Rows that share a name + size but carry DIFFERENT photos. Same name + same size
// IS the same design — so by default they are ONE library row and the stockist picks
// which photo represents it. If they are genuinely different designs he flips
// "keep both" and renames each, which splits them into two library rows.
//
// Rows sharing a name + size with at most one photo need no question at all: they
// fold into one product on save (library_map_upsert is idempotent on name+size+
// surface), which is also why a PDF that lists the same design twice needs no
// "merge the duplicates" step any more — there are no quantities left to merge.
class _DupGroup {
  final String key;
  final List<_ImpRow> rows;
  _ImpRow? chosen;       // the row whose photo becomes the library image
  bool keepBoth = false; // true = different designs → rename each to split them
  _DupGroup(this.key, this.rows) {
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

// The wizard — one full-screen question per sub-step. It asks the BOX and nothing
// else. tileSame is an instruction page: it asks a Yes/No FIRST and never shows the
// options; they appear on the following page only after the answer.
enum _AskStep {
  sizePacking,   // per-size tile type + pieces + weight (only when the PDF is MIXED size)
  tileSame,      // "Is the whole PDF one tile type?" (Yes/No, no options shown)
  tilePick,      // pick the one tile type (only if tileSame == Yes)
  tileBlocked,   // "split the PDF" dead-end (only if tileSame == No)
  pieces,
  weight,
}

class _ImpRow {
  String name;
  String size;
  final Uint8List? imageBytes; // photo from the PDF (null = none)
  bool include = true; // include this design when building the Library

  // When several rows share a name+size (= one library design) only the chosen row's
  // photo goes to the product; the others skip contributing an image.
  bool contributeImage = true;

  String? uploadedUrl; // Cloudinary URL of the PDF photo, once uploaded
  String? libImageUrl; // this stockist's existing Library image, if any

  _ImpRow({required this.name, required this.size, this.imageBytes});
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

  // Entry is the file picker. A PDF builds the LIBRARY — there is no stock branch.
  _Phase _phase = _Phase.pick;
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

  // Wizard cursor + the one Yes/No answer (null = not answered yet, so the Yes/No
  // buttons start unhighlighted).
  _AskStep _askStep = _AskStep.tileSame;
  bool? _sameTileType; // answer to "Is the whole PDF one tile type?"

  // Same-name duplicate groups in the parsed PDF, resolved on the dedupe page.
  final List<_DupGroup> _dupGroups = [];

  // name|size keys of designs ALREADY in this stockist's library (master + brand
  // aliases) — used only to flag new-vs-existing on the reveal. It does NOT gate the
  // box questions: an existing product is exactly the one whose box may still be
  // blank, and a blank box is what this import is here to fill.
  final Set<String> _libKeys = {};

  // name|size keys this stockist already has under the SELECTED brand (re-uploads
  // of these are fine). Drives the M non-default-brand "create-only" skip rule.
  final Set<String> _libThisBrandKeys = {};
  // Parsed designs skipped because they exist only under ANOTHER brand (M
  // non-default-brand uploads). Shown to the stockist so they know what to link
  // via Excel mapping. (name, size) pairs.
  final List<({String name, String size})> _skippedOtherBrand = [];

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

  // Outcome counter — the only one left: how many products the batch touched.
  int _builtMasters = 0;

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
    super.dispose();
  }

  // ── Step-2 resolved values ───────────────────────────────────────────────────
  String _libKey(String name, String size) =>
      '${name.trim().toLowerCase()}|${size.trim().toLowerCase()}';

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
      // Existing library identities (name+size, master + aliases) — used to flag
      // new-vs-existing on the reveal. It does NOT skip any question.
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
    _rows
      ..clear()
      ..addAll(parsed.designs.map((d) => _ImpRow(
            name: d.name.trim(),
            // Per-design size from the PDF when the layout carries one (mixed-size
            // files); else the document size. The stockist can still override it.
            size: _normaliseSize(d.sizeRaw ?? '') ?? _docSize,
            imageBytes: d.imageBytes,
            // The parser also scrapes a quantity, a quality and a surface. All three
            // are DROPPED on purpose — see the note at the top of this file.
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

  // Reveal done → the size question. (There is no "pure restock" express any more:
  // a PDF never carries stock, so every import has exactly one job — the library.)
  void _afterReveal() {
    _revealTimer?.cancel();
    setState(() {
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

  // Size resolved → the design list.
  //
  // The old "PDF mistakes" step used to sit here: rows identical on name + size +
  // quality + surface were the SAME STOCK LINE listed twice, and it asked whether to
  // SUM their box counts. With no quantities left to sum, a repeated row is simply
  // the same design named twice — library_map_upsert folds it, so there is nothing to
  // ask. Genuinely ambiguous rows (same name + size, DIFFERENT photos) are still
  // resolved, on the dedupe page.
  void _afterSize() {
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

  // Edit/dedupe resolved → the BOX wizard. It runs on EVERY import, including one
  // where every design already exists: an existing product is exactly the one whose
  // box may still be blank, and a blank box means no thickness, which means no
  // identity. `_library_apply_identity` fills a blank box and never overwrites a
  // filled one, so re-stating the packing for a design we already have is harmless.
  void _proceedAfterEdit() {
    setState(() {
      if (_isMultiSize) {
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
    // "which image is this design?" question. A group with at most one photo needs no
    // question: same name + same size IS the same design, so the rows fold into one
    // product on save.
    return [
      for (final e in byKey.entries)
        if (e.value.length > 1 &&
            e.value.where((r) => r.imageBytes != null).length > 1)
          _DupGroup(e.key, e.value)
    ];
  }

  // "Continue" on the dedupe page. Same-design groups: keep every row, but only the
  // chosen row's photo goes to the product (the rest fold into it on save).
  // Keep-both groups: every row must have a unique name (they become separate
  // library designs).
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

  // ── The BOX wizard ───────────────────────────────────────────────────────────
  // One full-screen question per sub-step. "Next" advances the option pages;
  // Yes/No pages advance via their own handlers. Back walks the chain in reverse.

  void _askBack() {
    switch (_askStep) {
      case _AskStep.sizePacking:
      case _AskStep.tileSame:
        setState(() => _phase = _Phase.edit);
      case _AskStep.tilePick:
      case _AskStep.tileBlocked:
        setState(() => _askStep = _AskStep.tileSame);
      case _AskStep.pieces:
        setState(() => _askStep = _AskStep.tilePick);
      case _AskStep.weight:
        setState(() => _askStep = _AskStep.pieces);
    }
  }

  // "Next" on the option pages (validates that page, then advances). The last page
  // of either branch goes straight to Review — there is no stock to enter.
  void _askNext() {
    switch (_askStep) {
      case _AskStep.sizePacking:
        if (!_sizePackingComplete) {
          _toast('Fill tile type, pieces and weight for every size.', error: true);
          return;
        }
        _goToReview();
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
        _goToReview();
      case _AskStep.tileSame:
      case _AskStep.tileBlocked:
        break; // these pages advance via Yes/No, or are a dead end
    }
  }

  void _answerTileSame(bool same) {
    setState(() {
      _sameTileType = same;
      if (!same) _tileTypeSel.clear();
      _askStep = same ? _AskStep.tilePick : _AskStep.tileBlocked;
    });
  }

  // Wizard → Review (read-only confirm with Save / Cancel).
  void _goToReview() => setState(() => _phase = _Phase.review);

  // ── SAVE — the ONLY write. Upload images (best-effort, safe to retry), then ONE
  //    atomic batch call that builds the library all-or-nothing. It creates NO
  //    stock: p_library_only is always true. Cancel/back before this writes nothing.
  Future<void> _save() async {
    final kept = _kept;
    if (kept.isEmpty) return;

    _beginProcessing('Saving…');

    // 1) Upload any PDF photos to Cloudinary first. These are idempotent
    //    (first-writer-wins on the product) so a retry never harms anything.
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

    // 2) Build the batch payload — NAME · SIZE · PHOTO, plus the BOX.
    //
    // The packing is resolved PER ROW (per-size for a mixed-size PDF, else the one
    // batch value) and is sent on EVERY row, including rows whose design already
    // exists: `_library_apply_identity` fills a blank box and never overwrites a
    // filled one, so this is how a product imported before we asked for a box
    // finally gets one — and therefore finally gets a thickness.
    //
    // No thickness is sent. It is DERIVED from the box by a trigger, and the server
    // ignores the field. No quantity and no quality are sent either — a PDF does not
    // know what is on the floor.
    final rows = kept.map((r) {
      final pk = _packingFor(r);
      return <String, dynamic>{
        'name': r.name.trim(),
        'size': r.size.trim(),
        // We never ask a surface mid-parse, so we never guess one. 'Special' is a
        // real surface; the stockist corrects it in the Library and it cascades.
        'surface': kSpecialSurface,
        if (r.uploadedUrl != null && r.contributeImage) 'image_url': r.uploadedUrl,
        'stock_type': 'Uncertain',
        'tile_type': pk.tileType,
        'pieces_per_box': pk.pieces,
        'box_weight_kg': pk.weight,
      };
    }).toList();

    if (mounted) {
      setState(() {
        _progress = null; // server transaction — indeterminate
        _progressDetail = 'Saving to your Library…';
      });
    }

    // 3) ONE atomic, idempotent call. A reused batch id can't double-add.
    //    libraryOnly: TRUE, always — a PDF never writes stock. No mode and no
    //    wipe-brands: those belong to the Excel stock importer, which is now the
    //    only thing that can zero a holding.
    try {
      final res = await _dataSvc.importStockBatch(
        batchId: _batchId,
        catalogId: null, // lists are curated separately
        brandId: _brandId,
        pdfFilename: _filename,
        rows: rows,
        libraryOnly: true,
      );
      _endProcessing();
      if (!mounted) return;
      _builtMasters = (res['masters'] as num?)?.toInt() ?? 0;
      setState(() => _phase = _Phase.done);
    } catch (e) {
      _endProcessing();
      if (!mounted) return;
      // Nothing was saved (the transaction rolled back) — they can retry safely.
      await _alert('Could not save',
          'Nothing was saved, so your Library is unchanged.\n\n${_friendlyError(e)}'
          '\n\nYou can fix the issue and try Save again.');
    }
  }

  // Turn a raw database/network error into something a stockist can act on.
  String _friendlyError(Object e) {
    final raw = e.toString();
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
        title: const Text('Import PDF · build Library'),
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
      case _Phase.pick:
        return _pickBody();
      case _Phase.skipped:
        return _skippedBody();
      case _Phase.reveal:
        return _revealBody();
      case _Phase.sizeAsk:
        return _sizeAskBody();
      case _Phase.edit:
        return _editBody();
      case _Phase.dedupe:
        return _dedupeBody();
      case _Phase.ask:
        return _askBody();
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

  Widget _pickBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _contextChip(),
        const Spacer(),
        const Icon(Icons.upload_file, size: 64, color: Color(0xFF1B4F72)),
        const SizedBox(height: 12),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 28),
          child: TypewriterText(
            'Import a supplier PDF to build your Design Library — names, sizes and '
            'photos. We read it as best we can, then you confirm every design '
            'before anything is saved.\n\n'
            'This adds NO stock. A PDF only tells us what designs exist; what is '
            'actually in your godown you enter yourself.',
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

  // Compact readout for THIS row on the duplicate resolver. The only thing that can
  // still tell two same-name rows apart is the SIZE and the PHOTO — the quantity,
  // quality and surface the parser also scraped are not imported, so showing them
  // here would only invite the stockist to decide on data we are about to throw away.
  Widget _scrapeDetail(_ImpRow r, {bool center = false}) {
    return Text(r.size,
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
                'Size: ${r.size}',
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
            // The PHOTO is the question here — which one is this design? Nothing else
            // about these rows differs any more, so nothing else is worth showing.
            Text(r.size,
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

  // ── The BOX wizard — one full-screen question per page ───────────────────────
  String _askStepTitle(_AskStep s) {
    switch (s) {
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
    }
  }

  // A mixed-size PDF asks its packing on ONE page (per size); a single-size PDF
  // walks tile type → pieces → weight.
  int get _askTotal => _isMultiSize ? 1 : 3;

  int _askPhaseNum(_AskStep s) {
    switch (s) {
      case _AskStep.sizePacking:
      case _AskStep.tileSame:
      case _AskStep.tilePick:
      case _AskStep.tileBlocked:
        return 1;
      case _AskStep.pieces:
        return 2;
      case _AskStep.weight:
        return 3;
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
                child: Text('The box · ${_askStepTitle(_askStep)}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ),
              Text('${_askPhaseNum(_askStep)} of $_askTotal',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ],
          ),
        ),
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
                const Icon(Icons.inventory_2_outlined,
                    size: 16, color: Color(0xFF2E7D32)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      'Read these off the carton. The tile’s thickness is worked out '
                      'from them — so a design cannot exist without them.',
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
            size, p.pieces, p.weight, p.tileType ?? tileTypeNames.first)
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
              items: tileTypeNames
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
          for (final t in tileTypeNames)
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

    }
  }

  // Bottom navigation for the wizard. The Yes/No page (tileSame) and the dead-end
  // tileBlocked page have no Next — they advance via their own buttons. The last
  // page of either branch says Review, because that is where it goes.
  Widget _askNav() {
    final hasNext =
        _askStep != _AskStep.tileSame && _askStep != _AskStep.tileBlocked;
    final nextLabel = (_askStep == _AskStep.weight ||
            _askStep == _AskStep.sizePacking)
        ? 'Review'
        : 'Next';
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

  // Read-only confirm. NOTHING is written until Save; Cancel/back writes nothing.
  Widget _reviewBody() {
    final kept = _kept;
    return Column(
      children: [
        _contextChip(),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Review & Save',
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
                    _reviewLine('Designs added to your Library', kept.length),
                    _reviewLine('Surface', '$kSpecialSurface (change it later)',
                        isText: true),
                    const Divider(height: 18),
                    if (_isMultiSize)
                      _reviewLine(
                          'Packing', 'Per size (${_keptSizes.length} sizes)',
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
                    _reviewLine('Stock', 'None — a PDF adds no stock',
                        isText: true),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                  'This adds the designs to your Library. It does NOT change any '
                  'stock — enter that from the Excel import or by hand.\n\n'
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
                        _busy ? null : () => setState(() => _phase = _Phase.ask),
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

  Widget _doneBody() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.task_alt, size: 64, color: Color(0xFF2E7D32)),
          const SizedBox(height: 16),
          const Text('Library updated',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 16),
          _summaryLine('Designs in this import', _builtMasters),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFE3F2FD),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.inventory_2_outlined,
                        size: 18, color: Color(0xFF1B4F72)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                          'No stock was added — a PDF only builds your Library. '
                          'Enter stock from the Excel import, or by hand.',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade800)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.auto_awesome,
                        size: 18, color: Color(0xFF1B4F72)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                          'These designs were saved with the “$kSpecialSurface” '
                          'surface. Set each one’s real surface in your Library.',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade800)),
                    ),
                  ],
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
