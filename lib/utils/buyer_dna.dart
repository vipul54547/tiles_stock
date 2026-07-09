import '../services/supabase_data_service.dart';

/// Loads + resolves Design DNA for BUYER surfaces (web /s/ + app): the global
/// facet catalog (attribute/value names) + each design's tagged value ids.
/// Provides card tags, faceted match, and search words — one shared source so
/// every buyer screen behaves the same. (project_design_dna_engine)
class BuyerDna {
  final _svc = SupabaseDataService();

  /// Facet catalog: [{id, name, is_multi, values:[{id,name}]}], sorted.
  List<Map<String, dynamic>> facets = [];
  final Map<String, Set<String>> _byDesign = {}; // designId → value ids
  final Map<String, String> _valueName = {};      // value id → name
  final Map<String, List<String>> _attrValues = {}; // attr id → [value ids]

  bool get hasCatalog => facets.isNotEmpty;

  /// Load the global catalog once.
  Future<void> loadCatalog() async {
    facets = await _svc.publicDnaCatalog();
    _valueName.clear();
    _attrValues.clear();
    for (final a in facets) {
      final aid = (a['id'] ?? '').toString();
      final vids = <String>[];
      for (final v in (a['values'] as List? ?? const [])) {
        final id = (v['id'] ?? '').toString();
        _valueName[id] = (v['name'] ?? '').toString();
        vids.add(id);
      }
      _attrValues[aid] = vids;
    }
  }

  /// Load DNA value ids for the given designs (merges; skips ones already known).
  Future<void> loadDesigns(List<String> designIds) async {
    final missing =
        designIds.where((id) => id.isNotEmpty && !_byDesign.containsKey(id)).toList();
    if (missing.isEmpty) return;
    final res = await _svc.designsDnaValues(missing);
    _byDesign.addAll(res);
    for (final id in missing) {
      _byDesign.putIfAbsent(id, () => <String>{}); // remember misses
    }
  }

  /// Card tags: attribute name → [value names] for a design (null when none).
  Map<String, List<String>>? tagsFor(String designId) {
    final vals = _byDesign[designId];
    if (vals == null || vals.isEmpty) return null;
    final out = <String, List<String>>{};
    for (final a in facets) {
      final names = <String>[];
      for (final v in (a['values'] as List? ?? const [])) {
        if (vals.contains((v['id'] ?? '').toString())) {
          names.add((v['name'] ?? '').toString());
        }
      }
      if (names.isNotEmpty) out[(a['name'] ?? '').toString()] = names;
    }
    return out.isEmpty ? null : out;
  }

  /// Faceted match: OR within an attribute, AND across attributes.
  bool matches(String designId, Set<String> selected) {
    if (selected.isEmpty) return true;
    final vals = _byDesign[designId] ?? const <String>{};
    for (final ids in _attrValues.values) {
      final chosen = ids.where(selected.contains);
      if (chosen.isEmpty) continue; // this attribute isn't filtered
      if (!chosen.any(vals.contains)) return false;
    }
    return true;
  }

  /// Value NAMES a design carries for the attribute whose name (lowercased)
  /// equals [attrLower]. Used to fold the "Surface" DNA attribute (in_name
  /// mode) into the single buyer Surface filter. (project_per_brand_surface_mode)
  Set<String> valuesForAttr(String designId, String attrLower) {
    final vals = _byDesign[designId];
    if (vals == null || vals.isEmpty) return const {};
    for (final a in facets) {
      if ((a['name'] ?? '').toString().toLowerCase() != attrLower) continue;
      final out = <String>{};
      for (final v in (a['values'] as List? ?? const [])) {
        if (vals.contains((v['id'] ?? '').toString())) {
          out.add((v['name'] ?? '').toString());
        }
      }
      return out;
    }
    return const {};
  }

  /// All DNA value names for a design, space-joined — for DNA-aware search.
  String words(String designId) {
    final vals = _byDesign[designId];
    if (vals == null || vals.isEmpty) return '';
    return vals
        .map((id) => _valueName[id] ?? '')
        .where((s) => s.isNotEmpty)
        .join(' ');
  }

  /// Value ids actually present across the given designs (to hide empty facets).
  Set<String> valueIdsInUse(Iterable<String> designIds) {
    final used = <String>{};
    for (final id in designIds) {
      used.addAll(_byDesign[id] ?? const <String>{});
    }
    return used;
  }
}
