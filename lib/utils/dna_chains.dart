// Build DNA "breadcrumb" chains from a design's tags, following parent_value_id.
// A tag whose parent is another tagged value is a CHILD; the chain runs from the
// root value down. Example: Emboss (Punch) → Wave (Punch Type) → Water Punch
// (detail) renders as "Emboss › Wave › Water Punch", grouped under the ROOT
// attribute (Punch). A flat attribute (Colour: White, Black) yields one-item
// chains. (project_dna_cascade_mapping)

const String kDnaChainSep = ' › ';

class DnaTag {
  final String valueId;
  final String label; // the shown word (stockist's word / admin canonical / detail)
  final String attribute; // the value's own attribute name
  final String? parentValueId;
  final int attrSort;
  final int valSort;

  /// `'print'` = this tag describes the ARTWORK and is stored on the print, so every piece of that
  /// print carries it. `'product'` = it describes this piece alone. (`dna_attributes.scope`)
  final String scope;

  const DnaTag({
    required this.valueId,
    required this.label,
    required this.attribute,
    this.parentValueId,
    this.attrSort = 0,
    this.valSort = 0,
    this.scope = 'product',
  });

  /// Belongs to the PRINT — render it once, under the print, not under each piece.
  bool get isPrintDna => scope == 'print';

  factory DnaTag.fromJson(Map<String, dynamic> j) => DnaTag(
        valueId: (j['value_id'] ?? j['id'] ?? '').toString(),
        label: (j['label'] ?? j['name'] ?? '').toString(),
        attribute: (j['attribute'] ?? '').toString(),
        parentValueId: (j['parent_value_id'] as String?),
        attrSort: (j['attr_sort'] as num?)?.toInt() ?? 0,
        valSort: (j['val_sort'] as num?)?.toInt() ?? 0,
        scope: (j['scope'] ?? 'product').toString(),
      );
}

/// Build the chain map for a design straight from a facet catalog
/// (`[{name, sort_order, values:[{id, name, parent_value_id}]}]`) + the design's
/// tagged value ids. Used by every buyer surface so they all render the same.
Map<String, List<String>> dnaChainsFromCatalog(
    List<Map<String, dynamic>> facets, Set<String> valueIds) {
  if (valueIds.isEmpty) return const {};
  final tags = <DnaTag>[];
  for (final a in facets) {
    final attr = (a['name'] ?? '').toString();
    final attrSort = (a['sort_order'] as num?)?.toInt() ?? 0;
    var vs = 0;
    for (final v in (a['values'] as List? ?? const [])) {
      final m = Map<String, dynamic>.from(v as Map);
      final id = (m['id'] ?? '').toString();
      final vs0 = vs++;
      if ((m['name'] ?? '').toString().toLowerCase() == 'none') continue;
      if (!valueIds.contains(id)) continue;
      tags.add(DnaTag(
        valueId: id,
        label: (m['name'] ?? '').toString(),
        attribute: attr,
        parentValueId: m['parent_value_id'] as String?,
        attrSort: attrSort,
        valSort: vs0,
      ));
    }
  }
  return buildDnaChainMap(tags);
}

/// Group a design's tags into `{ rootAttribute: [breadcrumb strings] }`, ordered
/// by attribute then value. Hierarchical tags collapse into a single chain; flat
/// ones stay as individual entries. A LinkedHashMap keeps insertion order.
Map<String, List<String>> buildDnaChainMap(List<DnaTag> tags) {
  final byId = {for (final t in tags) t.valueId: t};
  final children = <String, List<DnaTag>>{};
  for (final t in tags) {
    final p = t.parentValueId;
    if (p != null && byId.containsKey(p)) {
      (children[p] ??= []).add(t);
    }
  }

  // Every path from [t] down to a leaf, as label lists.
  List<List<String>> paths(DnaTag t) {
    final kids = children[t.valueId];
    if (kids == null || kids.isEmpty) {
      return [
        [t.label]
      ];
    }
    kids.sort((a, b) => a.valSort.compareTo(b.valSort));
    final out = <List<String>>[];
    for (final c in kids) {
      for (final p in paths(c)) {
        out.add([t.label, ...p]);
      }
    }
    return out;
  }

  // Roots: a tag with no tagged parent.
  final roots = tags
      .where((t) => t.parentValueId == null || !byId.containsKey(t.parentValueId))
      .toList()
    ..sort((a, b) {
      final c = a.attrSort.compareTo(b.attrSort);
      return c != 0 ? c : a.valSort.compareTo(b.valSort);
    });

  final out = <String, List<String>>{};
  for (final r in roots) {
    for (final path in paths(r)) {
      (out[r.attribute] ??= []).add(path.join(kDnaChainSep));
    }
  }
  return out;
}
