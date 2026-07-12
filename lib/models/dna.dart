// Design DNA = the dynamic searchable-attribute system (admin canonical values
// + per-stockist aliases, generalising Surface). See project_design_dna_engine.

class DnaValue {
  final String id;
  final String name;

  /// For a value of a DEPENDENT attribute: the parent value it belongs to
  /// (e.g. "Carara".parentValueId = the "Marble" value). Null otherwise.
  final String? parentValueId;

  const DnaValue({required this.id, required this.name, this.parentValueId});

  factory DnaValue.fromJson(Map<String, dynamic> j) => DnaValue(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        parentValueId: (j['parent_value_id'] as String?),
      );
}

class DnaAttribute {
  final String id;
  final String name;

  /// Multi-value (checkbox) attribute — a design can hold several values
  /// (e.g. Colour). Others are single-pick.
  final bool isMulti;

  /// Free text (no canonical value list), e.g. Series.
  final bool isFreeText;

  /// Whether a free-text attribute participates in facet filters (dashboard,
  /// buyer views, public catalog). Non-free-text attributes ignore this and
  /// are always shown.
  final bool showInFacets;

  final int sortOrder;

  /// Whether stockists may attach their own word (alias). Off ⇒ they pick the
  /// admin canonical values only. (project_dna_cascade_mapping)
  final bool allowMapping;

  /// When set, this attribute is a CHILD of another: its values are scoped to a
  /// parent value, and the stockist picks it only after choosing the parent.
  final String? parentAttributeId;

  final List<DnaValue> values;

  const DnaAttribute({
    required this.id,
    required this.name,
    this.isMulti = false,
    this.isFreeText = false,
    this.showInFacets = false,
    this.sortOrder = 0,
    this.allowMapping = true,
    this.parentAttributeId,
    this.values = const [],
  });

  bool get isDependent => parentAttributeId != null;

  factory DnaAttribute.fromJson(Map<String, dynamic> j) => DnaAttribute(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        isMulti: j['is_multi'] == true,
        isFreeText: j['is_free_text'] == true,
        showInFacets: j['show_in_facets'] == true,
        sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
        allowMapping: j['allow_mapping'] != false, // default true
        parentAttributeId: (j['parent_attribute_id'] as String?),
        values: ((j['values'] as List?) ?? const [])
            .map((v) => DnaValue.fromJson(Map<String, dynamic>.from(v as Map)))
            .toList(),
      );
}
