import 'package:flutter/material.dart';
import '../../models/brand.dart';
import '../../models/stock_catalog.dart';
import '../../models/choice_state.dart';
import '../../services/supabase_data_service.dart';

/// 🖼️ Create / edit a PORTFOLIO catalogue (project_media_portfolio_ddpi
/// #13/#15/#21). Stock-blind, scoped to exactly ONE brand — the buyer sees that
/// brand's designs under that brand's cover word, plus the media.
///
/// Optional FACETS narrow which designs appear: surface · size · tile type ·
/// space (the mockup/360 room tag). Empty = the brand's whole range.
class CatalogueListEditor extends StatefulWidget {
  final StockCatalog? existing;
  final List<Brand> brands;
  const CatalogueListEditor({super.key, this.existing, required this.brands});

  @override
  State<CatalogueListEditor> createState() => _CatalogueListEditorState();
}

class _CatalogueListEditorState extends State<CatalogueListEditor> {
  static const _navy = Color(0xFF1B4F72);
  final _data = SupabaseDataService();
  final _name = TextEditingController();
  final _desc = TextEditingController();
  String? _brandId;
  bool _saving = false;

  // facets
  final Set<String> _fSurfaces = {};
  final Set<String> _fSizes = {};
  final Set<String> _fTileTypes = {};
  final Set<String> _fSpaces = {};

  List<String> _surfaces = const [];
  Map<String, String> _surfLabels = const {}; // canonical → stockist word
  List<String> _sizes = const [];
  List<Map<String, dynamic>> _spaces = const []; // {value,label}
  static const _tileTypes = ['Ceramic', 'PGVT & GVT', 'Porcelain'];
  bool _loadingFacets = true;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    _name.text = ex?.name ?? '';
    _desc.text = ex?.description ?? '';
    _brandId = ex?.catalogueBrandId ??
        (widget.brands.where((b) => b.isDefault).isNotEmpty
            ? widget.brands.firstWhere((b) => b.isDefault).id
            : (widget.brands.isNotEmpty ? widget.brands.first.id : null));
    if (ex != null) {
      _fSurfaces.addAll(ex.filterSurfaces);
      _fSizes.addAll(ex.filterSizes);
      _fTileTypes.addAll(ex.filterTileTypes);
      _fSpaces.addAll(ex.filterSpaces);
    }
    _loadFacets();
  }

  Future<void> _loadFacets() async {
    try {
      final designs = await _data.getDesignsByStockist(currentStockistUUID);
      final sizes = designs.map((d) => d.size).toSet().toList()..sort();
      final finishes = await _data.getActiveFinishNames();
      final labels = await _data.getMySurfaceLabels();
      final spaces = await _data.lookupValues('space');
      if (!mounted) return;
      setState(() {
        _sizes = sizes;
        _surfaces = finishes.where((f) => f.toLowerCase() != 'none').toList();
        _surfLabels = labels;
        _spaces = spaces;
        _loadingFacets = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingFacets = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _snack('Give the catalogue a name.');
      return;
    }
    if (_brandId == null) {
      _snack('Pick a brand for the catalogue.');
      return;
    }
    setState(() => _saving = true);
    try {
      await _data.saveCatalogue(
        id: widget.existing?.id,
        name: name,
        brandId: _brandId!,
        description: _desc.text.trim(),
        filterSurfaces: _fSurfaces.toList(),
        filterSizes: _fSizes.toList(),
        filterTileTypes: _fTileTypes.toList(),
        filterSpaces: _fSpaces.toList(),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('$e'.replaceAll('PostgrestException:', '').trim());
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(_isEdit ? 'Edit Catalogue List' : 'New Catalogue List')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _navy.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'A portfolio catalogue shows this brand\'s designs and their media '
              '(rooms · 360 · video) — no stock or price. Facets below are '
              'optional; leave them empty to show the brand\'s whole range.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Catalogue name *',
              hintText: 'e.g. Bianco Tera Collection',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _desc,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          _label('Brand *'),
          const Text(
              'The catalogue is scoped to one brand and shows each design under '
              'that brand\'s name.',
              style: TextStyle(fontSize: 11.5, color: Colors.black54)),
          const SizedBox(height: 8),
          if (widget.brands.isEmpty)
            const Text('No brands yet.', style: TextStyle(color: Colors.grey))
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final b in widget.brands)
                  ChoiceChip(
                    label: Text(b.name),
                    selected: _brandId == b.id,
                    onSelected: (_) => setState(() => _brandId = b.id),
                  ),
              ],
            ),
          const Divider(height: 32),
          const Text('Narrow the range (optional)',
              style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 13, color: _navy)),
          const SizedBox(height: 8),
          if (_loadingFacets)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            _facetGroup('Surface', _surfaces, _fSurfaces, labels: _surfLabels),
            _facetGroup('Size', _sizes, _fSizes),
            _facetGroup('Tile type', _tileTypes, _fTileTypes),
            _facetGroup(
                'Space',
                [for (final s in _spaces) s['value'] as String],
                _fSpaces,
                labels: {
                  for (final s in _spaces)
                    s['value'] as String: s['label'] as String
                }),
          ],
          const SizedBox(height: 28),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                  backgroundColor: _navy, foregroundColor: Colors.white),
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : Text(_isEdit ? 'Save Changes' : 'Create Catalogue',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String s) => Text(s,
      style: const TextStyle(
          fontWeight: FontWeight.bold, fontSize: 13, color: _navy));

  // A multi-select chip group. [labels] maps a stored value → its display word.
  Widget _facetGroup(String title, List<String> options, Set<String> selected,
      {Map<String, String> labels = const {}}) {
    if (options.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade700)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final o in options)
                FilterChip(
                  label: Text(labels[o] ?? o),
                  selected: selected.contains(o),
                  onSelected: (on) => setState(
                      () => on ? selected.add(o) : selected.remove(o)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
