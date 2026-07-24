import 'package:flutter/material.dart';
import '../../services/cloudinary_service.dart';
import '../../services/supabase_data_service.dart';
import 'add_material_screen.dart';

/// 🖼️ The stockist's Catalogue management page (project_media_portfolio_ddpi
/// #20/#22). Windows-first. Two views over the same media:
///  • Materials — every uploaded material (mockup/aligning/close-look/360/video),
///    with its tagged designs; add / edit / delete here.
///  • Overview  — the artwork × media-type COUNT matrix, to spot gaps.
///
/// Stock-blind by construction — it shows design identity + media only.
class CatalogueScreen extends StatefulWidget {
  const CatalogueScreen({super.key});

  @override
  State<CatalogueScreen> createState() => _CatalogueScreenState();
}

const _typeLabels = <String, String>{
  'mockup': 'Mockup',
  'aligning': 'Aligning',
  'closelook': 'Close-look',
  '360': '360',
  'video': 'Video',
};

class _CatalogueScreenState extends State<CatalogueScreen> {
  static const _navy = Color(0xFF1B4F72);
  final _data = SupabaseDataService();

  Map<String, dynamic> _config = {};
  List<Map<String, dynamic>> _media = [];
  List<Map<String, dynamic>> _matrix = [];
  bool _loading = true;
  bool _overview = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _data.myMediaConfig(),
        _data.myMedia(),
        _data.myPortfolioMatrix(),
      ]);
      setState(() {
        _config = results[0] as Map<String, dynamic>;
        _media = results[1] as List<Map<String, dynamic>>;
        _matrix = results[2] as List<Map<String, dynamic>>;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  bool get _anyEnabled =>
      _typeLabels.keys.any((t) => _config[t] == true);

  Future<void> _add() async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => AddMaterialScreen(config: _config)));
    if (ok == true) _load();
  }

  Future<void> _edit(Map<String, dynamic> row) async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => AddMaterialScreen(config: _config, existing: row)));
    if (ok == true) _load();
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this material?'),
        content: const Text(
            'It will be removed from your catalogue and the buyer link. This '
            'cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await _data.mediaDelete(row['id'] as String);
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$e'), backgroundColor: Colors.red.shade700));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Catalogue'),
        actions: [
          if (!_loading && _anyEnabled)
            TextButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add, color: Colors.white, size: 20),
              label: const Text('Add Material',
                  style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorView()
              : Column(
                  children: [
                    _toggle(),
                    Expanded(
                        child: _overview ? _overviewView() : _materialsView()),
                  ],
                ),
    );
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 40),
              const SizedBox(height: 12),
              Text('Could not load:\n$_error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              ElevatedButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );

  Widget _toggle() => Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        alignment: Alignment.centerLeft,
        child: SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Materials')),
            ButtonSegment(value: true, label: Text('Overview')),
          ],
          selected: {_overview},
          onSelectionChanged: (s) => setState(() => _overview = s.first),
        ),
      );

  // ── Materials ───────────────────────────────────────────────────────────────
  Widget _materialsView() {
    if (!_anyEnabled) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
              'No media types are enabled for you yet. Ask the admin to turn on '
              'Mockup / Aligning / Close-look / 360 / Video.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey)),
        ),
      );
    }
    if (_media.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('No materials yet.', style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 12),
            ElevatedButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add),
                label: const Text('Add Material')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
        itemCount: _media.length,
        itemBuilder: (_, i) => _materialCard(_media[i]),
      ),
    );
  }

  Widget _materialCard(Map<String, dynamic> m) {
    final type = m['type'] as String? ?? '';
    final isImage = type == 'mockup' || type == 'aligning' || type == 'closelook';
    final url = m['url'] as String? ?? '';
    final artworks = (m['artworks'] as List? ?? const []);
    final tiles = (m['tiles'] as List? ?? const []);
    // Representative name + "+N variants" (# distinct designs the material rides).
    final names = <String>[
      for (final a in artworks) (a as Map)['name']?.toString() ?? '',
    ].where((s) => s.isNotEmpty).toList();
    final repName = names.isNotEmpty
        ? names.first
        : (tiles.isNotEmpty ? (tiles.first as Map)['name']?.toString() ?? '' : '');
    final variantCount = type == 'closelook' ? tiles.length : artworks.length;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: SizedBox(
          width: 56,
          height: 56,
          child: isImage && url.isNotEmpty
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.network(
                      CloudinaryService.thumbUrl(url, width: 150),
                      fit: BoxFit.cover),
                )
              : Container(
                  decoration: BoxDecoration(
                    color: _navy.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                      type == 'video'
                          ? Icons.play_circle_outline
                          : Icons.threesixty,
                      color: _navy),
                ),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: _navy.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(_typeLabels[type] ?? type,
                  style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: _navy)),
            ),
            if ((m['space_label'] as String?)?.isNotEmpty == true) ...[
              const SizedBox(width: 6),
              Text(m['space_label'] as String,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            ],
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            repName.isEmpty
                ? 'No design tagged'
                : variantCount > 1
                    ? '$repName  +${variantCount - 1} variants'
                    : repName,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                onPressed: () => _edit(m)),
            IconButton(
                icon: const Icon(Icons.delete_outline,
                    size: 20, color: Colors.red),
                onPressed: () => _delete(m)),
          ],
        ),
      ),
    );
  }

  // ── Overview matrix ──────────────────────────────────────────────────────────
  Widget _overviewView() {
    if (_matrix.isEmpty) {
      return const Center(
          child: Text('No designs yet.', style: TextStyle(color: Colors.grey)));
    }
    const cols = ['mockup', 'aligning', 'closelook', '360', 'video'];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(
        child: DataTable(
          headingRowHeight: 40,
          columns: [
            const DataColumn(label: Text('Design')),
            for (final c in cols)
              DataColumn(label: Text(_typeLabels[c] ?? c), numeric: true),
          ],
          rows: [
            for (final r in _matrix)
              DataRow(cells: [
                DataCell(ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(r['name']?.toString() ?? '',
                      overflow: TextOverflow.ellipsis),
                )),
                for (final c in cols)
                  DataCell(_countCell((r[c] as num?)?.toInt() ?? 0)),
              ]),
          ],
        ),
      ),
    );
  }

  Widget _countCell(int n) => Text(
        n == 0 ? '·' : '$n',
        style: TextStyle(
            color: n == 0 ? Colors.grey.shade400 : _navy,
            fontWeight: n == 0 ? FontWeight.normal : FontWeight.bold),
      );
}
