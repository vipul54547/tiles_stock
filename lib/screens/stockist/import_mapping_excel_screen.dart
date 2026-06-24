import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' hide Border, BorderStyle;
import '../../services/supabase_data_service.dart';
import '../../models/brand.dart';
import '../../models/tile_size.dart';
import '../../models/choice_state.dart';
import '../../utils/tile_sizes.dart';

// Mapping-Excel importer for the stockist's Design Library
// ([[project_stockist_library]], Phase 2). The sheet links the SAME physical
// tile to the name it carries under each brand — NO images, NO stock.
//
// Columns: a Size column, a Master design name column, and one column per brand
// (the header = the brand's company name, the cell = that tile's design name in
// that brand). Each row resolves a master by (master name + size) and merges in
// the per-brand aliases (library_map_upsert — existing aliases are kept).
class ImportMappingExcelScreen extends StatefulWidget {
  const ImportMappingExcelScreen({super.key});
  @override
  State<ImportMappingExcelScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);

// Header synonyms for the two fixed columns. Brand columns are matched by name.
const List<String> _sizeHeaders = ['size', 'tile size', 'dimension', 'dimensions'];
const List<String> _masterHeaders = [
  'master', 'master name', 'master design', 'master design name',
  'design', 'design name', 'name', 'tile', 'tile name',
];

class _MapRow {
  final int rowNum;
  final String sizeRaw;
  final String masterRaw;
  final Map<String, String> brandNames; // brandId -> design name in that brand
  String size = ''; // canonical admin size after validation
  String master = ''; // resolved master name (master col, else default brand)
  String? error;
  _MapRow({
    required this.rowNum,
    required this.sizeRaw,
    required this.masterRaw,
    required this.brandNames,
  });
  bool get valid => error == null;
}

class _State extends State<ImportMappingExcelScreen> {
  final _data = SupabaseDataService();

  List<Brand> _brands = [];
  List<String> _sizes = [];
  List<TileSize> _tileSizes = [];
  String? _defaultBrandId;

  List<_MapRow> _rows = [];
  List<String> _unmatchedHeaders = []; // header cells that matched no brand
  bool _parsed = false;
  bool _loading = false;
  bool _importing = false;
  int _done = 0;
  String _blockError = '';

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    if (currentStockistUUID.isEmpty) return;
    final brands = await _data.getMyBrands();
    final tileSizes = await _data.getTileSizes(activeOnly: true);
    if (!mounted) return;
    brands.sort((a, b) {
      if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
      return a.sortOrder.compareTo(b.sortOrder);
    });
    final def = brands.where((b) => b.isDefault).toList();
    setState(() {
      _brands = brands;
      _tileSizes = tileSizes;
      _sizes = tileSizes.map((s) => s.name).toList();
      _defaultBrandId = def.isEmpty ? null : def.first.id;
    });
  }

  void _snack(String m, [Color? c]) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), backgroundColor: c));

  String _norm(String h) =>
      h.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  // ── Pick & parse ───────────────────────────────────────────────────────────

  Future<void> _pickAndParse() async {
    final res = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['xlsx'], withData: true);
    if (res == null || res.files.single.bytes == null) return;
    setState(() { _loading = true; _blockError = ''; });
    await _parseBytes(res.files.single.bytes!);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _parseBytes(List<int> bytes) async {
    if (_brands.isEmpty) {
      setState(() => _blockError = 'No brands found for your account.');
      return;
    }
    final Excel book;
    try {
      book = Excel.decodeBytes(bytes);
    } catch (_) {
      // Same dead-end the stock importer guards against: some exporters write
      // valid-but-unusual .xlsx (e.g. inline-string files) the reader rejects.
      // Re-saving from Excel/Sheets rewrites the file cleanly — give that fix.
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

    final header =
        sheet.rows.first.map((c) => _norm(c?.value?.toString() ?? '')).toList();

    final sizeCol = header.indexWhere((h) => _sizeHeaders.contains(h));
    final masterCol = header.indexWhere((h) => _masterHeaders.contains(h));

    // Map each remaining header to a brand by (normalised) name.
    final brandCols = <int, String>{}; // colIndex -> brandId
    final unmatched = <String>[];
    for (var i = 0; i < header.length; i++) {
      if (i == sizeCol || i == masterCol) continue;
      final h = header[i];
      if (h.isEmpty) continue;
      final b = _brands.where((b) => _norm(b.name) == h).toList();
      if (b.isNotEmpty) {
        brandCols[i] = b.first.id;
      } else {
        unmatched.add(header[i]);
      }
    }

    if (sizeCol < 0) {
      setState(() => _blockError =
          'Missing a "Size" column. Add a header row with Size, Master design '
          'name, and one column per brand (header = brand name).');
      return;
    }
    if (brandCols.isEmpty) {
      setState(() => _blockError =
          'No brand columns recognised. Use each brand\'s exact name as a column '
          'header. Your brands: ${_brands.map((b) => b.name).join(', ')}.');
      return;
    }
    // Without a master column, the default brand column supplies the master name.
    int? defaultCol;
    for (final e in brandCols.entries) {
      if (e.value == _defaultBrandId) { defaultCol = e.key; break; }
    }
    if (masterCol < 0 && defaultCol == null) {
      setState(() => _blockError =
          'Add a "Master design name" column, or include your main brand '
          '(${_brands.isEmpty ? 'default' : _brands.first.name}) as a column.');
      return;
    }

    String cell(List<Data?> row, int i) {
      if (i < 0 || i >= row.length) return '';
      return row[i]?.value?.toString().trim() ?? '';
    }

    final parsed = <_MapRow>[];
    for (var r = 1; r < sheet.rows.length; r++) {
      final row = sheet.rows[r];
      final blank = row.every((c) =>
          c == null || c.value == null || c.value.toString().trim().isEmpty);
      if (blank) continue;
      final brandNames = <String, String>{};
      brandCols.forEach((i, bid) {
        final v = cell(row, i);
        if (v.isNotEmpty) brandNames[bid] = v;
      });
      parsed.add(_MapRow(
        rowNum: r + 1,
        sizeRaw: cell(row, sizeCol),
        masterRaw: masterCol >= 0
            ? cell(row, masterCol)
            : (defaultCol != null ? cell(row, defaultCol) : ''),
        brandNames: brandNames,
      ));
    }
    if (parsed.isEmpty) {
      setState(() => _blockError = 'No data rows found (only a header?).');
      return;
    }

    for (final r in parsed) {
      if (r.sizeRaw.isEmpty) { r.error = 'Missing size'; continue; }
      final sz = resolveCanonicalSize(r.sizeRaw, _tileSizes) ??
          (_sizes.contains(normaliseSize(r.sizeRaw))
              ? normaliseSize(r.sizeRaw)
              : '');
      if (sz.isEmpty) {
        r.error = "Size '${r.sizeRaw}' is not in your size list";
        continue;
      }
      r.size = sz;
      r.master = r.masterRaw.trim();
      if (r.master.isEmpty) { r.error = 'Missing master / main-brand name'; continue; }
      if (r.brandNames.isEmpty) { r.error = 'No brand names on this row'; continue; }
    }

    setState(() {
      _rows = parsed;
      _unmatchedHeaders = unmatched;
      _parsed = true;
      _done = 0;
    });
  }

  // ── Import ───────────────────────────────────────────────────────────────

  Future<void> _startImport() async {
    final toDo = _rows.where((r) => r.valid).toList();
    if (toDo.isEmpty) { _snack('Nothing to import.'); return; }
    setState(() { _importing = true; _done = 0; });
    int ok = 0;
    String? lastError;
    for (final r in toDo) {
      try {
        await _data.libraryMapUpsert(
          size: r.size,
          masterName: r.master,
          aliases: r.brandNames,
        );
        ok++;
      } catch (e) {
        lastError = '$e';
        r.error = '$e';
      }
      setState(() => _done++);
    }
    if (!mounted) return;
    setState(() => _importing = false);
    _snack(
      lastError == null
          ? 'Mapped $ok design${ok == 1 ? '' : 's'} into your library.'
          : 'Mapped $ok; some rows failed: $lastError',
      lastError == null ? Colors.green : Colors.orange.shade800,
    );
    if (ok > 0) Navigator.of(context).pop(true);
  }

  void _reset() => setState(() {
        _rows = []; _parsed = false; _blockError = ''; _done = 0;
        _unmatchedHeaders = [];
      });

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Import name mapping'),
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
                    colors: [_navy, Color(0xFF2E86C1)]),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.account_tree_outlined,
                      color: Colors.white, size: 34),
                  SizedBox(height: 8),
                  Text('Map design names across brands',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.bold)),
                  SizedBox(height: 4),
                  Text('Link the same tile to the name it is sold as under each '
                      'of your brands. No photos or stock — just the names. '
                      'Photos stay on each master in your library.',
                      style: TextStyle(color: Colors.white70, fontSize: 12.5)),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const Text('Columns',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 8),
            _introRow('Size', 'required — must match your sizes'),
            _introRow('Master design name',
                'optional — defaults to your main brand\'s name'),
            for (final b in _brands)
              _introRow(b.name,
                  b.id == _defaultBrandId
                      ? 'this tile\'s name in ${b.name} (your main brand)'
                      : 'this tile\'s name in ${b.name}'),
            const SizedBox(height: 8),
            Text(
                'Tip: name each brand column exactly as the brand appears in the '
                'app.',
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
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
                  foregroundColor: _navy,
                  side: const BorderSide(color: _navy, width: 1.5),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _introRow(String name, String desc) => Container(
        decoration: BoxDecoration(
            border: Border(top: BorderSide(color: Colors.grey.shade100))),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
                flex: 4,
                child: Text(name,
                    style: const TextStyle(
                        fontSize: 12,
                        color: _navy,
                        fontWeight: FontWeight.w600))),
            Expanded(
                flex: 6,
                child: Text(desc, style: const TextStyle(fontSize: 11))),
          ],
        ),
      );

  Widget _buildReview() {
    final valid = _rows.where((r) => r.valid).length;
    final skipped = _rows.length - valid;
    final allDone = !_importing && _done > 0 && _done >= valid;
    return Column(
      children: [
        if (_unmatchedHeaders.isNotEmpty)
          Container(
            width: double.infinity,
            color: const Color(0xFFFFF3E0),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
                'Ignored columns (no matching brand): '
                '${_unmatchedHeaders.join(', ')}',
                style: TextStyle(fontSize: 11.5, color: Colors.orange.shade900)),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: _navy.withValues(alpha: 0.06),
          child: Row(
            children: [
              _chip('$valid', 'To map', _navy),
              if (skipped > 0) ...[
                const SizedBox(width: 12),
                _chip('$skipped', 'Skipped', Colors.red),
              ],
              const Spacer(),
              if (_importing)
                Text('$_done/$valid',
                    style: const TextStyle(fontWeight: FontWeight.bold))
              else if (allDone)
                const Icon(Icons.check_circle_rounded, color: Color(0xFF2E7D32))
              else
                ElevatedButton.icon(
                  onPressed: valid > 0 ? _startImport : null,
                  icon: const Icon(Icons.merge_type_rounded, size: 16),
                  label: Text('Map $valid'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: _navy, foregroundColor: Colors.white),
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

  String _brandName(String id) => _brands
      .firstWhere((b) => b.id == id, orElse: () => const Brand(id: '', name: '?'))
      .name;

  Widget _rowCard(_MapRow r) {
    final bg = r.valid ? Colors.white : const Color(0xFFFFEBEE);
    final border = r.valid ? Colors.grey.shade200 : Colors.red.shade200;
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
              Expanded(
                child: Text(
                    r.master.isEmpty ? (r.masterRaw.isEmpty ? '(no name)' : r.masterRaw) : r.master,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
                    overflow: TextOverflow.ellipsis),
              ),
              Text(r.size.isNotEmpty ? r.size.replaceAll(' mm', '') : r.sizeRaw,
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(width: 8),
              Text('Row ${r.rowNum}',
                  style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ],
          ),
          if (r.valid && r.brandNames.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: r.brandNames.entries
                  .map((a) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: _navy.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('${_brandName(a.key)}: ${a.value}',
                            style: const TextStyle(fontSize: 11, color: _navy)),
                      ))
                  .toList(),
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
}
