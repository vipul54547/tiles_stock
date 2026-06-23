import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../models/stockist.dart';
import '../../utils/tile_types.dart';

// ADMIN-ONLY bulk image-folder import (concierge onboarding). Reads a brand's
// image folder from disk → builds the stockist's Design Library:
//   folder layout = <brand folder> / <SIZE> / [<SURFACE>] / <design>.jpg
//   size folder   → admin size (inch→mm mapped + confirmed)
//   surface folder→ admin surface (confirmed)
//   filename      → design name; the image is EXIF-baked + downscaled, uploaded,
//                   then admin_library_upsert creates/matches the master.
// Desktop-only (recursive folder reads); never shown to stockists.
class AdminBulkImageImportScreen extends StatefulWidget {
  const AdminBulkImageImportScreen({super.key});
  @override
  State<AdminBulkImageImportScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);
const _imgExts = {'.jpg', '.jpeg', '.png', '.webp'};

// Common inch tile-size folder names → admin mm size. Best-effort pre-fill; the
// admin confirms/overrides each in the Sizes step.
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

  // Commit progress
  int _done = 0, _failed = 0, _total = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final stk = await _data.getAllStockists(activeOnly: true);
      final sizes = await _data.getActiveSizeNames();
      final surfaces = await _data.getSurfaceTypes(activeOnly: true);
      if (!mounted) return;
      setState(() {
        _stockists = stk..sort((a, b) => a.name.compareTo(b.name));
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
        dialogTitle: 'Pick the brand image folder');
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
      for (final f in files) {
        // Path segments relative to the picked root: [SIZE]/[SURFACE?]/file
        var rel = f.path.substring(dir.length);
        if (rel.startsWith(sep)) rel = rel.substring(1);
        final parts = rel.split(sep);
        if (parts.length < 2) continue; // need at least SIZE/file
        final sizeFolder = parts[0];
        final surfaceFolder = parts.length >= 3 ? parts[parts.length - 2] : '';
        final filename = parts.last;
        _designs.add(_ImgDesign(
          path: f.path,
          sizeFolder: sizeFolder,
          surfaceFolder: surfaceFolder,
          name: _designName(filename),
        ));
      }
      // Distinct size folders → packing rows (with inch→mm guess).
      for (final d in _designs) {
        _sizePacks.putIfAbsent(d.sizeFolder, () {
          final guess = _inchToMm[d.sizeFolder.toUpperCase().replaceAll(' ', '')];
          return _SizePack(
            adminSize: (guess != null && _adminSizes.contains(guess)) ? guess : null,
            tileType: kTileTypes.first,
          );
        });
        if (d.surfaceFolder.isNotEmpty) {
          _surfaceMap.putIfAbsent(d.surfaceFolder,
              () => _adminSurfaces.contains('None') ? 'None'
                  : (_adminSurfaces.isNotEmpty ? _adminSurfaces.first : 'None'));
        }
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

  bool get _mapReady =>
      _sizePacks.values.every((p) =>
          p.adminSize != null &&
          p.tileType.isNotEmpty &&
          p.pieces > 0 &&
          (double.tryParse(p.weight.trim()) ?? 0) > 0);

  // ── Commit ───────────────────────────────────────────────────────────────
  Future<void> _commit() async {
    final todo = _designs.where((d) => d.include).toList();
    if (todo.isEmpty) return;
    setState(() {
      _phase = _Phase.committing;
      _done = 0; _failed = 0; _total = todo.length;
    });
    final seq = _stockist!.id;
    for (final d in todo) {
      try {
        final pack = _sizePacks[d.sizeFolder]!;
        final bytes = await _processImage(d);
        final res = await CloudinaryService.uploadImageBytes(bytes,
            filename: '${d.name}.jpg');
        if (!res.ok) throw res.error ?? 'upload failed';
        final surface = d.surfaceFolder.isEmpty
            ? 'None'
            : (_surfaceMap[d.surfaceFolder] ?? 'None');
        final weight = double.tryParse(pack.weight.trim()) ?? 0;
        await _data.adminLibraryUpsert(
          seq: seq,
          size: pack.adminSize!,
          masterName: d.name,
          brandId: _brandId!,
          imageUrl: res.url!,
          surface: surface,
          tileType: pack.tileType,
          pieces: pack.pieces,
          weight: weight,
        );
        d.error = null;
        _done++;
      } catch (e) {
        d.error = '$e';
        _failed++;
      }
      if (mounted) setState(() {});
    }
    if (mounted) setState(() => _phase = _Phase.done);
  }

  // EXIF-bake → rotate (manual) → downscale to ~2000px → JPEG q85.
  Future<Uint8List> _processImage(_ImgDesign d) async {
    final raw = await File(d.path).readAsBytes();
    var im = img.decodeImage(raw);
    if (im == null) throw 'unsupported/corrupt image';
    im = img.bakeOrientation(im);
    if (d.rotation != 0) im = img.copyRotate(im, angle: d.rotation);
    final longest = im.width > im.height ? im.width : im.height;
    if (longest > 2000) {
      im = im.width >= im.height
          ? img.copyResize(im, width: 2000)
          : img.copyResize(im, height: 2000);
    }
    return Uint8List.fromList(img.encodeJpg(im, quality: 85));
  }

  // ── UI ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bulk image import (admin)'),
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
          const Text('1. Choose stockist & brand',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 12),
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
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_error, style: const TextStyle(color: Colors.red, fontSize: 12.5)),
          ],
          const SizedBox(height: 20),
          const Text(
              'Folder layout expected:  <brand folder> / SIZE / [SURFACE] / design.jpg',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
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
            onPressed: (_stockist != null && _brandId != null) ? _pickFolder : null,
            icon: const Icon(Icons.folder_open),
            label: const Text('Pick image folder & scan'),
          ),
        ],
      );

  Widget _buildMap() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('2. Map sizes & packing   (${_designs.length} images)',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          const Text('Each folder size → an admin size, plus its packing.',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
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
            onPressed: _mapReady ? () => setState(() => _phase = _Phase.preview) : null,
            child: Text(_mapReady
                ? 'Continue to preview'
                : 'Fill every size: admin size, tile type, pieces, weight'),
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
              Text('Folder size: "$folder"',
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
                    initialValue: kTileTypes.contains(p.tileType) ? p.tileType : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        isDense: true, labelText: 'Tile type', border: OutlineInputBorder()),
                    items: kTileTypes
                        .map((t) => DropdownMenuItem(
                            value: t, child: Text(t, style: const TextStyle(fontSize: 12))))
                        .toList(),
                    onChanged: (v) => setState(() => p.tileType = v ?? ''),
                  ),
                ),
              ]),
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
              onChanged: (v) => setState(() => _surfaceMap[folder] = v ?? 'None'),
            ),
          ),
        ]),
      );

  Widget _buildPreview() {
    final on = _designs.where((d) => d.include).length;
    return Column(
      children: [
        Container(
          width: double.infinity,
          color: _navy.withValues(alpha: 0.06),
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Text('$on of ${_designs.length} selected',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _navy),
              onPressed: on > 0 ? _commit : null,
              icon: const Icon(Icons.cloud_upload, size: 18),
              label: Text('Import $on'),
            ),
          ]),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: _designs.length,
            itemBuilder: (_, i) => _previewRow(_designs[i]),
          ),
        ),
      ],
    );
  }

  Widget _previewRow(_ImgDesign d) {
    final size = _sizePacks[d.sizeFolder]?.adminSize ?? d.sizeFolder;
    final surface = d.surfaceFolder.isEmpty ? 'None' : (_surfaceMap[d.surfaceFolder] ?? 'None');
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(children: [
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
                  initialValue: d.name,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  decoration: const InputDecoration(
                      isDense: true, border: InputBorder.none, hintText: 'design name'),
                  onChanged: (v) => d.name = v.trim(),
                ),
                Text('$size  ·  $surface',
                    style: const TextStyle(fontSize: 11.5, color: Colors.black54)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Rotate 90°',
            icon: const Icon(Icons.rotate_right, color: _navy),
            onPressed: () => setState(() => d.rotation = (d.rotation + 90) % 360),
          ),
        ]),
      ),
    );
  }

  Widget _buildProgress() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
