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
import '../../utils/finishes.dart';

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

// Nothing is written until the final Save (one atomic batch). pick → edit
// (names/sizes) → ask (quality/surface) → stock (quantities) → review (Save /
// Cancel) → done. Cancel/back before Save writes NOTHING.
enum _Phase { pick, edit, ask, stock, review, done }

enum _QualityMode { premium, standard, both }

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
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
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

  // Edit (names/sizes) → Ask. NOTHING is written here anymore.
  void _goToAsk() {
    if (_kept.isEmpty) {
      _toast('Tick at least one design to import.', error: true);
      return;
    }
    setState(() => _phase = _Phase.ask);
  }

  // Ask → Stock (quantities). Surface=No means every row is None.
  void _goToStock() {
    if (!_surfacePresent) {
      for (final r in _rows) {
        r.surface = 'None';
      }
    }
    setState(() => _phase = _Phase.stock);
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
  Future<void> _save() async {
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

    // 2) Build the batch payload.
    final rows = kept
        .map((r) => <String, dynamic>{
              'name': r.name.trim(),
              'size': r.size.trim(),
              'quality': _qualityOf(r),
              'surface': r.surface,
              'qty': r.qty,
              if (r.uploadedUrl != null) 'image_url': r.uploadedUrl,
              'stock_type': 'Uncertain',
            })
        .toList();

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
          'Nothing was saved, so your stock is unchanged. Please check your '
          'connection and try Save again.\n\n$e');
    }
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
      case _Phase.pick:
        return _pickBody();
      case _Phase.edit:
        return _editBody();
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
              const Spacer(),
              Text('name + size identify each design',
                  style: TextStyle(
                      fontSize: 10.5, color: Colors.grey.shade500)),
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

  Widget _askBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _contextChip(),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Step 2 · About the stock',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text('Quality of this PDF', style: TextStyle(fontSize: 13)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<_QualityMode>(
            segments: const [
              ButtonSegment(value: _QualityMode.premium, label: Text('Premium')),
              ButtonSegment(value: _QualityMode.standard, label: Text('Standard')),
              ButtonSegment(value: _QualityMode.both, label: Text('Both')),
            ],
            selected: {_qualityMode},
            onSelectionChanged: (s) =>
                setState(() => _qualityMode = s.first),
          ),
        ),
        if (_qualityMode == _QualityMode.both)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              'You will set each design’s quality (Premium / Standard) on the '
              'next screen.',
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _surfacePresent,
            activeThumbColor: const Color(0xFF1B4F72),
            title: const Text('Does this PDF list a surface / finish?'),
            subtitle: Text(
                _surfacePresent
                    ? 'You’ll set each design’s surface next (blank = None).'
                    : 'All designs will be saved with surface “None”.',
                style: const TextStyle(fontSize: 11.5)),
            onChanged: (v) => setState(() => _surfacePresent = v),
          ),
        ),
        const Spacer(),
        _bottomBar(label: 'Continue to stock', onTap: _goToStock),
      ],
    );
  }

  Widget _stockBody() {
    final withQty = _kept.where((r) => r.qty > 0).length;
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
            itemCount: _rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) => _stockRow(_rows[i]),
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
          const SizedBox(height: 24),
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
