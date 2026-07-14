import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../models/stockist.dart';
import '../../utils/finishes.dart';
import '../../utils/tile_types.dart';

// Image-folder import → builds a Design Library from a folder on disk.
//
// 🔑 ONE SIZE AT A TIME. The folder he picks IS the size:
//
//     300x450 / MATTE / 1001.jpg      surface folder  → admin surface (confirmed)
//     300x450 / 1001.jpg              no surface folder → 'Special'
//                                     FILENAME → THE PRINT NAME
//
//    There is no "parent of all sizes" mode — he asked for it gone. It was also a trap: picking
//    `300x450` (the obvious thing) put every image one level above where the parser looked, and
//    the scan silently reported "0 images".
//
// 🔑 THE FOLDER IS THE ONLY HONEST SOURCE OF A PRINT NAME.
//    A supplier PDF prints the name stamped on the BOX — `brand_design_name`. That is the
//    FACTORY'S word, it is per-brand and it is free text ("1001", "CARRARA GOLD"). It is NOT the
//    stockist's own word for the artwork, and `print_name` is exactly that. Feeding a PDF label
//    into print_name forges a WRONG PRINT for every row — and the print sits at the top of the
//    identity chain, so the damage runs all the way down.
//    In a folder, THE STOCKIST NAMED THE FILES HIMSELF. The filename IS his word.
//    → this replaced the PDF importer, which is now hidden from the platform.
//
// 🚫 AND IT IS BRAND-FREE (stockist path). It builds:
//
//     ARTWORK   the print — name (the FILENAME), size, one photo
//     TILE      artwork + surface + BODY  (he confirms the body; the disk cannot know it)
//     PACKING   pieces + weight  → and the THICKNESS falls out of it
//
//    📦 It asks for pieces and weight precisely BECAUSE A PACKING HAS NO BRAND. A factory packs
//    once and covers differently, so the packing belongs to the tile. (This was the objection:
//    "why are we importing under brand?" — pieces/weight used to live on the box, per brand, so
//    asking for them meant asking for a brand. They do not any more.)
//
//    🚫 It writes NO BOX. A folder cannot know what a brand prints on its cover (`1001` on FAMOUS,
//    `601001` on ANUJ). The cover goes on later, by him.
//    (docs/PACKING_BOX_HOLD_PLAN.md · 20260714j_folder_import_makes_the_packing)
//
// Runs in BOTH roles off one screen:
//   admin       — picks a stockist, then his brand   → admin_library_upsert (unchanged)
//   forStockist — his own library, NO brand          → library_image_upsert
//
// DESKTOP-ONLY: it reads a folder tree with dart:io, so it is offered on Windows only. The
// stockist's images live on his PC anyway, and Android's scoped storage makes a picked directory
// unreadable often enough that it cannot be trusted.
class AdminBulkImageImportScreen extends StatefulWidget {
  /// true = the signed-in STOCKIST is importing into his own library (no stockist picker,
  /// his own brands, and the write goes through the stockist-facing RPC).
  final bool forStockist;
  const AdminBulkImageImportScreen({super.key, this.forStockist = false});
  @override
  State<AdminBulkImageImportScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);
const _imgExts = {'.jpg', '.jpeg', '.png', '.webp'};

// How many designs are processed+uploaded concurrently during commit. The old
// commit loop ran one image fully (decode→upload→DB) before starting the next,
// so CPU sat idle during the network round-trips and vice-versa. A small pool
// overlaps decode (across cores) with uploads, cutting commit time ~4x. Kept
// modest so a weak uplink / low-core machine isn't overwhelmed.
const _kCommitConcurrency = 4;

// Common inch tile-size folder names → admin mm size. Best-effort pre-fill; the
// admin confirms/overrides each in the Sizes step.
/// Does this folder name read as a SIZE (`600x1200`, `24x48`, `800 X 800`)? Used only to catch the
/// mistake of picking the parent folder — a "surface" folder called `600x1200` is not a surface.
bool _looksLikeSize(String name) {
  final n = name.trim().toUpperCase().replaceAll(' ', '');
  if (_inchToMm.containsKey(n)) return true;
  return RegExp(r'^\d{2,4}X\d{2,4}(MM)?$').hasMatch(n);
}

const _inchToMm = {
  '12X12': '300x300', '16X16': '400x400', '24X24': '600x600',
  '12X18': '300x450', '18X12': '300x450', '12X24': '300x600', '24X12': '300x600',
  '24X48': '600x1200', '48X24': '600x1200', '32X64': '800x1600', '64X32': '800x1600',
  '48X48': '1200x1200', '32X32': '800x800', '24X32': '600x800',
};

class _ImgDesign {
  final String path;
  final String sizeFolder;
  final String surfaceFolder; // '' when none
  String name;
  bool include = true;
  int rotation = 0; // 0 / 90 / 180 / 270
  String? error; // set during commit on failure
  // Per-design packing — seeded from the size/surface defaults on entering
  // Preview, then individually overridable (two designs of one size can differ).
  String? surface;
  String? tileType;
  int? pieces;
  String weight = '';
  _ImgDesign({
    required this.path,
    required this.sizeFolder,
    required this.surfaceFolder,
    required this.name,
  });
}

class _SizePack {
  String? adminSize; // mapped admin size
  String tileType;
  int pieces = 1;
  String weight = ''; // free text → parsed to double
  _SizePack({this.adminSize, this.tileType = ''});
}

enum _Phase { pick, map, preview, committing, done }

// Cloudinary's per-image upload cap (free tier) is 1 MB. We keep a safety margin
// below it so the file is never rejected mid-import.
const _maxUploadBytes = 980 * 1024; // ~0.96 MB

// EXIF-bake → manual rotate → downscale to ~1600px → JPEG q80, then GUARANTEE the
// result fits under Cloudinary's 1 MB limit (step quality down, then dimensions,
// for the rare ultra-detailed tile that's still too big). Top-level + sync so it
// can run inside Isolate.run (off the UI thread). Reads the file itself so only
// the path (sendable) crosses the isolate boundary. Bulk-import only — the PDF
// importer keeps its own (q85/native) encoding.
Uint8List _processImageSync(String path, int rotation) {
  final raw = File(path).readAsBytesSync();
  final decoded = img.decodeImage(raw);
  if (decoded == null) throw 'unsupported/corrupt image';
  var im = img.bakeOrientation(decoded);
  if (rotation != 0) im = img.copyRotate(im, angle: rotation);
  final longest = im.width > im.height ? im.width : im.height;
  if (longest > 1600) {
    im = im.width >= im.height
        ? img.copyResize(im, width: 1600)
        : img.copyResize(im, height: 1600);
  }
  // Start at q80; if a detailed tile encodes over the cap, drop quality, then
  // (last resort) shrink dimensions, until it fits. Re-encoding is cheap next to
  // the one-time decode above, so this stays fast for the common (already-fits)
  // case where the loop bodies never run.
  var quality = 80;
  var out = img.encodeJpg(im, quality: quality);
  while (out.length > _maxUploadBytes && quality > 45) {
    quality -= 8;
    out = img.encodeJpg(im, quality: quality);
  }
  while (out.length > _maxUploadBytes) {
    final w = (im.width * 0.85).round();
    final h = (im.height * 0.85).round();
    if (w < 600) break; // never loop forever / never go uselessly tiny
    im = img.copyResize(im, width: w, height: h);
    out = img.encodeJpg(im, quality: quality);
  }
  return Uint8List.fromList(out);
}

class _State extends State<AdminBulkImageImportScreen> {
  final _data = SupabaseDataService();

  _Phase _phase = _Phase.pick;
  bool _loading = true;
  String _error = '';

  // Selection
  List<Stockist> _stockists = [];
  Stockist? _stockist;
  List<Map<String, dynamic>> _brands = [];
  String? _brandId;

  // Config (admin vocab)
  List<String> _adminSizes = [];
  List<String> _adminSurfaces = [];

  // Parsed
  final List<_ImgDesign> _designs = [];
  final Map<String, _SizePack> _sizePacks = {}; // sizeFolder → packing
  final Map<String, String> _surfaceMap = {}; // surfaceFolder → admin surface
  bool _stripSuffix = false; // strip trailing _A/_B from filenames
  Set<String> _existingKeys = {}; // "name|size|brandId" already in the library

  // Per-design text controllers, OWNED by the State (keyed by file path) so the
  // typed name/weight survive a row being disposed+rebuilt while scrolling — the
  // model (`d`) stays the source of truth, the controller just keeps the widget
  // text alive. Without this, edits to scrolled-past rows were lost.
  final Map<String, TextEditingController> _nameCtrls = {};
  final Map<String, TextEditingController> _weightCtrls = {};

  // Commit progress
  int _done = 0, _failed = 0, _total = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _disposePreviewCtrls();
    super.dispose();
  }

  void _disposePreviewCtrls() {
    for (final c in _nameCtrls.values) {
      c.dispose();
    }
    for (final c in _weightCtrls.values) {
      c.dispose();
    }
    _nameCtrls.clear();
    _weightCtrls.clear();
  }

  TextEditingController _nameCtrl(_ImgDesign d) =>
      _nameCtrls.putIfAbsent(d.path, () => TextEditingController(text: d.name));
  TextEditingController _weightCtrl(_ImgDesign d) =>
      _weightCtrls.putIfAbsent(d.path, () => TextEditingController(text: d.weight));

  bool get _forStockist => widget.forStockist;

  /// True once we know WHOSE library we're filling — a stockist always does.
  bool get _haveOwner => _forStockist || _stockist != null;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final sizes = await _data.getActiveSizeNames();
      final surfaces = await _data.getSurfaceTypes(activeOnly: true);
      // A stockist is importing into his OWN library: no picker, and his own brands.
      final stk = _forStockist
          ? <Stockist>[]
          : (await _data.getAllStockists(activeOnly: true));
      final myBrands = _forStockist
          ? [for (final b in await _data.getMyBrands()) {'id': b.id, 'name': b.name}]
          : <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _stockists = stk..sort((a, b) => a.name.compareTo(b.name));
        _brands = myBrands;
        _brandId = _forStockist && myBrands.isNotEmpty
            ? myBrands.first['id'] as String
            : null;
        _adminSizes = sizes;
        _adminSurfaces = surfaces.map((s) => s.name).toList();
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = '$e'; _loading = false; });
    }
  }

  Future<void> _pickBrands(Stockist s) async {
    setState(() { _stockist = s; _brands = []; _brandId = null; });
    final b = await _data.adminStockistBrands(s.id);
    if (!mounted) return;
    setState(() => _brands = b);
  }

  // ── Folder pick + parse ─────────────────────────────────────────────────────
  Future<void> _pickFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Pick ONE size folder (e.g. 300x450)');
    if (dir == null) return;
    setState(() { _error = ''; });
    try {
      final root = Directory(dir);
      final files = root
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((f) {
            final base = f.path.split(Platform.pathSeparator).last;
            // Skip hidden / OS-junk that a Mac-made zip leaves behind: AppleDouble
            // "._*" resource forks, ".DS_Store", "Thumbs.db" — they're not real
            // images (decode fails) and would create garbage "._design" entries.
            if (base.startsWith('.')) return false;
            if (base.toLowerCase() == 'thumbs.db') return false;
            return _imgExts.contains(_ext(f.path));
          })
          .toList();
      if (files.isEmpty) {
        setState(() => _error = 'No image files (.jpg/.png/.webp) under that folder.');
        return;
      }
      _designs.clear();
      _sizePacks.clear();
      _surfaceMap.clear();
      final sep = Platform.pathSeparator;

      // 🔑 ONE SIZE AT A TIME. The folder he picks IS the size — its own name is the size folder.
      //
      //     300x450 / MATTE / 1001.jpg     ← surface folders inside
      //     300x450 / 1001.jpg             ← no surface folder → Special
      //
      // There is no "parent of all sizes" mode. It was the source of the bug he hit: he picked
      // 300x450 (the obvious thing to do), every image sat one level up from where the parser
      // looked, and the scan silently reported 0 images.
      final rootName =
          dir.split(sep).where((x) => x.trim().isNotEmpty).last;

      for (final f in files) {
        var rel = f.path.substring(dir.length);
        if (rel.startsWith(sep)) rel = rel.substring(1);
        final parts = rel.split(sep);
        _designs.add(_ImgDesign(
          path: f.path,
          sizeFolder: rootName,
          // Whatever folder the image sits in, if any. Nothing → Special.
          surfaceFolder: parts.length >= 2 ? parts[parts.length - 2] : '',
          name: _designName(parts.last),
        ));
      }

      // A "surface" folder whose name is really a SIZE means he picked the parent by mistake.
      // Say so, rather than importing every design under a surface called "600x1200".
      final sizeShaped = _designs
          .map((d) => d.surfaceFolder)
          .where((s) => s.isNotEmpty && _looksLikeSize(s))
          .toSet();
      if (sizeShaped.isNotEmpty) {
        _designs.clear();
        setState(() => _error =
            'That folder holds SIZE folders (${sizeShaped.take(3).join(', ')}), not images.\n'
            'Pick ONE size folder at a time — e.g. "${sizeShaped.first}".');
        return;
      }
      // Distinct size folders → packing rows (with inch→mm guess).
      for (final d in _designs) {
        _sizePacks.putIfAbsent(d.sizeFolder, () {
          final guess = _inchToMm[d.sizeFolder.toUpperCase().replaceAll(' ', '')];
          return _SizePack(
            adminSize: (guess != null && _adminSizes.contains(guess)) ? guess : null,
            tileType: tileTypeNames.first,
          );
        });
        if (d.surfaceFolder.isNotEmpty) {
          _surfaceMap.putIfAbsent(d.surfaceFolder, () {
            // Auto-match the folder word to an admin surface, case-insensitively
            // ("MATT" → "Matt"). An unrecognised word is NOT a guess we get to make —
            // it becomes 'Special', which the admin can correct in the dropdown below.
            final m = _adminSurfaces.where(
                (s) => s.toLowerCase() == d.surfaceFolder.trim().toLowerCase());
            return m.isNotEmpty ? m.first : kSpecialSurface;
          });
        }
      }
      // Preload the existing library keys → flag NEW vs already-in. (A stockist reads his own;
      // only an admin may read someone else's.)
      if (_forStockist) {
        // Keyed WITHOUT a brand — a PRINT is brand-free, so "have I got this artwork at this size?"
        // is a brand-free question.
        final lib = await _data.getMyLibrary();
        _existingKeys = {
          for (final e in lib) '${e.masterName.toLowerCase()}|${e.size}'
        };
      } else {
        final lib = await _data.adminStockistLibrary(_stockist!.id);
        _existingKeys = {
          for (final m in lib)
            '${(m['master_design_name'] ?? '').toString().toLowerCase()}'
            '|${m['size']}|${m['brand_id']}'
        };
      }
      setState(() => _phase = _Phase.map);
    } catch (e) {
      setState(() => _error = 'Could not read the folder — $e');
    }
  }

  String _ext(String p) {
    final i = p.lastIndexOf('.');
    return i < 0 ? '' : p.substring(i).toLowerCase();
  }

  // filename → design name: drop extension; optionally strip a trailing _A/_B.
  String _designName(String filename) {
    var n = filename;
    final dot = n.lastIndexOf('.');
    if (dot > 0) n = n.substring(0, dot);
    if (_stripSuffix) {
      n = n.replaceAll(RegExp(r'[_\- ]?[A-Za-z]$'), '').trim();
    }
    return n.trim();
  }

  // Re-derive names when the strip-suffix toggle changes (names not hand-edited).
  void _reapplyNames() {
    for (final d in _designs) {
      d.name = _designName(d.path.split(Platform.pathSeparator).last);
    }
  }

  /// The size, the BODY and the PACKING. The body and the packing are what make the thickness —
  /// `weight / (pieces × area × DENSITY)`, and the density comes from the body — so all of them are
  /// needed, and none may be guessed. Still no brand: a packing has none.
  bool get _mapReady => _sizePacks.values.every((p) =>
      p.adminSize != null &&
      p.tileType.isNotEmpty &&
      p.pieces > 0 &&
      (double.tryParse(p.weight.trim()) ?? 0) > 0);

  // Already in the library? A stockist's PRINT is brand-free (name + size). The admin path still
  // keys on the brand, because admin_library_upsert does.
  bool _isExisting(_ImgDesign d) {
    final size = _sizePacks[d.sizeFolder]?.adminSize;
    if (size == null) return false;
    final key = '${d.name.toLowerCase()}|$size';
    return _existingKeys.contains(_forStockist ? key : '$key|$_brandId');
  }

  // Name of the currently-selected brand (for the header), looked up from the
  // loaded brand list by its id. '' until a brand is chosen. Admin path only —
  // the stockist folder import has no brand.
  String get _selectedBrandName {
    if (_forStockist) return '';
    final m = _brands.where((b) => b['id'] == _brandId);
    return m.isNotEmpty ? (m.first['name'] ?? '').toString() : '';
  }

  // Surface picklist for the per-design dropdown. 'None' is NOT offered — a tile always has a
  // surface, and the surface is part of the product's identity, so a 'None' would spawn a
  // phantom product beside the real one. 'Special' IS a real surface and is already in the
  // admin list; a folder with no surface subfolder lands there.
  List<String> get _surfaceOptions => [
        ..._adminSurfaces,
        if (!_adminSurfaces.contains(kSpecialSurface)) kSpecialSurface,
      ];

  // Seed each design's packing from the size/surface defaults, then show
  // Preview where they become individually editable. One-way (Preview only
  // exits via Import or Restart), so defaults always flow in cleanly.
  void _enterPreview() {
    // Drop any controllers from a previous preview so they re-seed from the
    // values we set below (handles Restart / re-scanning the same folder).
    _disposePreviewCtrls();
    for (final d in _designs) {
      final pack = _sizePacks[d.sizeFolder];
      d.surface = d.surfaceFolder.isEmpty
          ? kSpecialSurface
          : (_surfaceMap[d.surfaceFolder] ?? kSpecialSurface);
      d.tileType = pack?.tileType;
      d.pieces = pack?.pieces;
      d.weight = pack?.weight ?? '';
    }
    setState(() => _phase = _Phase.preview);
  }

  // Importable once the tile is fully described: a surface, a body, and a packing.
  bool _designReady(_ImgDesign d) =>
      (d.surface ?? '').isNotEmpty &&
      (d.tileType ?? '').isNotEmpty &&
      (d.pieces ?? 0) > 0 &&
      (double.tryParse(d.weight.trim()) ?? 0) > 0;

  // ── Commit ───────────────────────────────────────────────────────────────
  Future<void> _commit() async {
    final todo = _designs.where((d) => d.include).toList();
    if (todo.isEmpty) return;
    setState(() {
      _phase = _Phase.committing;
      _done = 0; _failed = 0; _total = todo.length;
    });
    final seq = _forStockist ? '' : _stockist!.id;

    // Worker pool: _kCommitConcurrency workers pull the next design off a shared
    // cursor and run its full decode→upload→DB pipeline. Dart runs one isolate
    // single-threaded, so `cursor++` between workers is race-free (no await sits
    // between the read and the increment). This overlaps CPU-bound image work
    // with network-bound uploads instead of doing them strictly one-at-a-time.
    var cursor = 0;
    Future<void> runWorker() async {
      while (true) {
        if (cursor >= todo.length) break;
        final d = todo[cursor++];
        await _commitOne(d, seq);
        if (mounted) setState(() {});
      }
    }

    await Future.wait(
      List.generate(_kCommitConcurrency, (_) => runWorker()),
    );
    if (mounted) setState(() => _phase = _Phase.done);
  }

  // Process + upload + upsert a single design. Updates _done/_failed and stamps
  // d.error on failure (surfaced on the Done screen). Never throws.
  Future<void> _commitOne(_ImgDesign d, String seq) async {
    try {
      final pack = _sizePacks[d.sizeFolder]!;
      final bytes = await _processImage(d);
      final res = await CloudinaryService.uploadImageBytes(bytes,
          filename: '${d.name}.jpg');
      if (!res.ok) throw res.error ?? 'upload failed';
      // Per-design values win; the size-pack default is the fallback.
      final surface = surfaceForImport((d.surface ?? '').isNotEmpty
          ? d.surface
          : _surfaceMap[d.surfaceFolder]);
      final weightStr = d.weight.trim().isNotEmpty ? d.weight : pack.weight;
      final weight = double.tryParse(weightStr.trim()) ?? 0;
      final tileType =
          (d.tileType ?? '').isNotEmpty ? d.tileType : pack.tileType;
      final pieces = d.pieces ?? pack.pieces;

      if (_forStockist) {
        // BRAND-FREE. The FILENAME is the ARTWORK's name — his own word for it, which is exactly
        // why a folder is an honest source and a supplier PDF is not.
        //
        // It builds the artwork, the tile, and the tile's PACKING (pieces + weight) — and the
        // THICKNESS falls out of the packing. It can ask for pieces/weight precisely BECAUSE a
        // packing has no brand: a factory packs once and covers differently.
        //
        // 🚫 NO BOX. A folder cannot know what a brand prints on its cover; the cover goes on
        // later, by him. (docs/PACKING_BOX_HOLD_PLAN.md)
        await _data.libraryImageUpsert(
          size: pack.adminSize!,
          name: d.name,
          imageUrl: res.url!,
          surface: surface,
          tileType: tileType,
          pieces: pieces,
          weightKg: weight,
        );
      } else {
        await _data.adminLibraryUpsert(
          seq: seq,
          size: pack.adminSize!,
          masterName: d.name,
          brandId: _brandId!,
          imageUrl: res.url!,
          surface: surface,
          tileType: tileType,
          pieces: pieces,
          weight: weight,
        );
      }
      d.error = null;
      _done++;
    } catch (e) {
      d.error = '$e';
      _failed++;
    }
  }

  // Run the heavy decode/resize/encode in a BACKGROUND ISOLATE so the UI never
  // freezes and the progress counter updates live (30 MB+ JPEGs are CPU-heavy).
  // Capture only primitives (path, rotation) across the isolate boundary.
  Future<Uint8List> _processImage(_ImgDesign d) {
    final path = d.path;
    final rot = d.rotation;
    return Isolate.run(() => _processImageSync(path, rot));
  }

  // ── UI ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // Once a stockist+brand are picked, keep them in the header for the rest
        // of the flow (map→preview→upload→done) so the admin never loses track of
        // which library they're filling.
        title: (_haveOwner && _phase != _Phase.pick)
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_forStockist ? 'Import images' : 'Bulk image import (admin)',
                      style: const TextStyle(fontSize: 16)),
                  Text(
                    '${_forStockist ? 'My Library' : _stockist!.name}'
                    '${_selectedBrandName.isNotEmpty ? '  ·  $_selectedBrandName' : ''}',
                    style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: Colors.white70),
                  ),
                ],
              )
            : Text(_forStockist ? 'Import images' : 'Bulk image import (admin)'),
        actions: [
          if (_phase != _Phase.pick && _phase != _Phase.committing)
            TextButton.icon(
              onPressed: () => setState(() {
                _phase = _Phase.pick;
                _designs.clear();
              }),
              icon: const Icon(Icons.refresh, color: Colors.white),
              label: const Text('Restart', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      // Centred + width-capped so it stays usable on a wide desktop monitor
      // instead of stretching full-width (this runs on the Windows admin build).
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error.isNotEmpty && _phase == _Phase.pick
                  ? _errorBox()
                  : switch (_phase) {
                      _Phase.pick => _buildPick(),
                      _Phase.map => _buildMap(),
                      _Phase.preview => _buildPreview(),
                      _Phase.committing => _buildProgress(),
                      _Phase.done => _buildDone(),
                    },
        ),
      ),
    );
  }

  Widget _errorBox() => Padding(
        padding: const EdgeInsets.all(20),
        child: Text(_error, style: const TextStyle(color: Colors.red)),
      );

  Widget _buildPick() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_forStockist ? '1. Pick the folder' : '1. Choose stockist & brand',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 12),
          if (!_forStockist) ...[
            DropdownButtonFormField<Stockist>(
              initialValue: _stockist,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Stockist', border: OutlineInputBorder()),
              items: _stockists
                  .map((s) => DropdownMenuItem(
                      value: s, child: Text('${s.name}  (${s.id} · ${s.businessType})')))
                  .toList(),
              onChanged: (s) { if (s != null) _pickBrands(s); },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _brandId,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Brand', border: OutlineInputBorder()),
              items: _brands
                  .map((b) => DropdownMenuItem(
                      value: b['id'] as String,
                      child: Text((b['name'] ?? '').toString())))
                  .toList(),
              onChanged: (v) => setState(() => _brandId = v),
            ),
          ],
          // 🚫 NO BRAND. A folder of images knows the ARTWORK and the PIECE, and neither has a
          // brand: identity is brand-free, and the brand belongs to the BOX. Asking for one here
          // is asking a question this step cannot answer — and the old code answered it anyway, by
          // stamping the FILENAME into the box's name. Set the box afterwards, per brand.
          if (_forStockist)
            Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: const Color(0xFF1B4F72).withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'This builds your DESIGNS — the artwork, its surfaces, and how it is PACKED '
                '(pieces + weight). The thickness is worked out from the packing; you never type it.\n'
                'NO BRAND: a packing has none. A factory packs once and covers differently — the '
                'brand is the COVER, and you put that on afterwards.',
                style: TextStyle(fontSize: 12, color: Color(0xFF1B4F72), height: 1.45),
              ),
            ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_error, style: const TextStyle(color: Colors.red, fontSize: 12.5)),
          ],
          const SizedBox(height: 20),
          const Text(
              'Pick ONE SIZE folder at a time. Inside it:   [SURFACE] / design.jpg\n'
              'No surface folder → the surface is Special.   The FILENAME is the design name.',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
          if (_forStockist) ...[
            const SizedBox(height: 8),
            const Text(
                'The FILE NAME becomes the design name — your own name for the tile. '
                'A folder with no SURFACE level is saved as “Special”; you set the real '
                'surface afterwards in your Library.',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
          ],
          const SizedBox(height: 10),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Strip trailing _A / _B from filenames',
                style: TextStyle(fontSize: 13)),
            subtitle: const Text('e.g. "3212_A" → "3212" (shade variants)',
                style: TextStyle(fontSize: 11)),
            value: _stripSuffix,
            onChanged: (v) => setState(() {
              _stripSuffix = v;
              _reapplyNames();
            }),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _navy),
            onPressed: (_haveOwner && (_forStockist || _brandId != null))
                ? _pickFolder
                : null,
            icon: const Icon(Icons.folder_open),
            label: const Text('Pick a size folder & scan'),
          ),
        ],
      );

  Widget _buildMap() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('2. Size, body & packing   (${_designs.length} images)',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          Text(
              _forStockist
                  // The BODY is not on the disk anywhere, and it cannot be guessed: it is part of
                  // what makes a piece a piece (print + surface + BODY + thickness), and the
                  // thickness is later derived as weight / (pieces × area × DENSITY) — where the
                  // density comes from the body. No body, no thickness, whatever the box weight is.
                  ? 'Confirm the size, say what the tile is MADE OF, and how it is PACKED. The '
                      'thickness is worked out from the packing and the body — you never type it.'
                  : 'Each folder size → an admin size, plus its packing.',
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 10),
          ..._sizePacks.entries.map((e) => _sizeRow(e.key, e.value)),
          if (_surfaceMap.isNotEmpty) ...[
            const SizedBox(height: 18),
            const Text('3. Map surfaces',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            ..._surfaceMap.keys.map(_surfaceRow),
          ],
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _navy),
            onPressed: _mapReady ? _enterPreview : null,
            child: Text(_mapReady
                ? 'Continue to preview'
                : 'Fill in: admin size, tile type, pieces, weight'),
          ),
        ],
      );

  Widget _sizeRow(String folder, _SizePack p) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Size folder: "$folder"',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  flex: 5,
                  child: DropdownButtonFormField<String>(
                    initialValue: p.adminSize,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        isDense: true, labelText: 'Admin size', border: OutlineInputBorder()),
                    items: _adminSizes
                        .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                        .toList(),
                    onChanged: (v) => setState(() => p.adminSize = v),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 5,
                  child: DropdownButtonFormField<String>(
                    initialValue: tileTypeNames.contains(p.tileType) ? p.tileType : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        isDense: true, labelText: 'Tile type', border: OutlineInputBorder()),
                    items: tileTypeNames
                        .map((t) => DropdownMenuItem(
                            value: t, child: Text(t, style: const TextStyle(fontSize: 12))))
                        .toList(),
                    onChanged: (v) => setState(() => p.tileType = v ?? ''),
                  ),
                ),
              ]),
              // 📦 THE PACKING — pieces + weight, and it has NO BRAND. A factory packs once and
              // covers differently, so this belongs here, with the tile. The THICKNESS falls out of
              // it, and the tile keeps only that.
              ...[
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: p.pieces,
                      decoration: const InputDecoration(
                          isDense: true, labelText: 'Pieces/box', border: OutlineInputBorder()),
                      items: const [1, 2, 3, 4, 5, 6, 8, 10, 12]
                          .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
                          .toList(),
                      onChanged: (v) => setState(() => p.pieces = v ?? 1),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextFormField(
                      initialValue: p.weight,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                          isDense: true, labelText: 'Box weight (kg)', border: OutlineInputBorder()),
                      onChanged: (v) => setState(() => p.weight = v),
                    ),
                  ),
                ]),
              ],
            ],
          ),
        ),
      );

  Widget _surfaceRow(String folder) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          Expanded(flex: 4, child: Text('"$folder"', style: const TextStyle(fontSize: 13))),
          const SizedBox(width: 8),
          Expanded(
            flex: 6,
            child: DropdownButtonFormField<String>(
              initialValue: _surfaceMap[folder],
              isExpanded: true,
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
              items: _adminSurfaces
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (v) =>
                  setState(() => _surfaceMap[folder] = v ?? kSpecialSurface),
            ),
          ),
        ]),
      );

  Widget _buildPreview() {
    final included = _designs.where((d) => d.include).toList();
    final on = included.length;
    final existing = included.where(_isExisting).length;
    final fresh = on - existing;
    final notReady = included.where((d) => !_designReady(d)).length;
    return Column(
      children: [
        Container(
          width: double.infinity,
          color: _navy.withValues(alpha: 0.06),
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('$on selected · $fresh new · $existing already in library',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  if (notReady > 0)
                    Text('$notReady need surface / tile type / pieces / weight',
                        style: const TextStyle(fontSize: 11.5, color: Colors.red)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _navy),
              onPressed: (on > 0 && notReady == 0) ? _commit : null,
              icon: const Icon(Icons.cloud_upload, size: 18),
              label: Text('Import $on'),
            ),
          ]),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(8),
            // Keep a large cache so rows aren't disposed while scrolling —
            // belt-and-braces with the State-owned controllers above.
            cacheExtent: 100000,
            itemCount: _designs.length,
            itemBuilder: (_, i) => _previewRow(_designs[i]),
          ),
        ),
      ],
    );
  }

  Widget _previewRow(_ImgDesign d) {
    final size = _sizePacks[d.sizeFolder]?.adminSize ?? d.sizeFolder;
    return Card(
      key: ValueKey(d.path),
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Row(children: [
              Checkbox(
                value: d.include,
                onChanged: (v) => setState(() => d.include = v ?? true),
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: RotatedBox(
                  quarterTurns: d.rotation ~/ 90,
                  child: Image.file(File(d.path),
                      width: 56, height: 56, fit: BoxFit.cover, cacheWidth: 120,
                      errorBuilder: (_, __, ___) => Container(
                          width: 56, height: 56, color: Colors.grey.shade200,
                          child: const Icon(Icons.broken_image, size: 18))),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      key: ValueKey('name_${d.path}'),
                      controller: _nameCtrl(d),
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                      decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: 'design name'),
                      onChanged: (v) => d.name = v.trim(),
                    ),
                    Text(size,
                        style: const TextStyle(
                            fontSize: 11.5, color: Colors.black54)),
                  ],
                ),
              ),
              Builder(builder: (_) {
                final ex = _isExisting(d);
                final c = ex ? _navy : const Color(0xFF2E7D32);
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                      color: c.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4)),
                  child: Text(ex ? 'EXISTS' : 'NEW',
                      style: TextStyle(
                          fontSize: 9, fontWeight: FontWeight.bold, color: c)),
                );
              }),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Rotate 90°',
                icon: const Icon(Icons.rotate_right, color: _navy),
                onPressed: () =>
                    setState(() => d.rotation = (d.rotation + 90) % 360),
              ),
            ]),
            // Per-design packing — pre-filled from the size/surface defaults,
            // overridable so two designs of one size can differ.
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                flex: 6,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('surf_${d.path}'),
                  initialValue:
                      _surfaceOptions.contains(d.surface) ? d.surface : null,
                  isExpanded: true,
                  decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Surface',
                      border: OutlineInputBorder()),
                  items: _surfaceOptions
                      .map((s) => DropdownMenuItem(
                          value: s,
                          child: Text(s, style: const TextStyle(fontSize: 12))))
                      .toList(),
                  onChanged: (v) => setState(() => d.surface = v),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                flex: 6,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('tt_${d.path}'),
                  initialValue:
                      tileTypeNames.contains(d.tileType) ? d.tileType : null,
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
                  onChanged: (v) => setState(() => d.tileType = v),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                flex: 4,
                child: DropdownButtonFormField<int>(
                  key: ValueKey('pcs_${d.path}'),
                  initialValue: const [1, 2, 3, 4, 5, 6, 8, 10, 12]
                          .contains(d.pieces)
                      ? d.pieces
                      : null,
                  isExpanded: true,
                  decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Pcs',
                      border: OutlineInputBorder()),
                  items: const [1, 2, 3, 4, 5, 6, 8, 10, 12]
                      .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
                      .toList(),
                  onChanged: (v) => setState(() => d.pieces = v),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                flex: 5,
                child: TextFormField(
                  key: ValueKey('wt_${d.path}'),
                  controller: _weightCtrl(d),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(fontSize: 12),
                  decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Wt (kg)',
                      border: OutlineInputBorder()),
                  onChanged: (v) => setState(() => d.weight = v),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _buildProgress() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_haveOwner) ...[
              Text(_forStockist ? 'My Library' : _stockist!.name,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
              if (_selectedBrandName.isNotEmpty)
                Text(_selectedBrandName,
                    style: const TextStyle(fontSize: 13, color: _navy)),
              const SizedBox(height: 20),
            ],
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('Importing… ${_done + _failed} / $_total'),
            if (_failed > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('$_failed failed',
                    style: const TextStyle(color: Colors.red, fontSize: 12)),
              ),
          ],
        ),
      );

  Widget _buildDone() {
    final fails = _designs.where((d) => d.include && d.error != null).toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(children: [
          const Icon(Icons.check_circle, color: Color(0xFF2E7D32)),
          const SizedBox(width: 8),
          Text('Done — $_done imported, $_failed failed',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        ]),
        if (fails.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('Failures:', style: TextStyle(fontWeight: FontWeight.bold)),
          ...fails.map((d) => Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${d.name}: ${d.error}',
                    style: const TextStyle(fontSize: 12, color: Colors.red)),
              )),
        ],
        const SizedBox(height: 20),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _navy),
          onPressed: () => setState(() {
            _phase = _Phase.pick;
            _designs.clear();
          }),
          child: const Text('Import another folder'),
        ),
      ],
    );
  }
}
