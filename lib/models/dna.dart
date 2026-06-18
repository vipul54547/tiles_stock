// Design DNA = the dynamic searchable-attribute system (admin canonical values
// + per-stockist aliases, generalising Surface). See project_design_dna_engine.

class DnaValue {
  final String id;
  final String name;
  const DnaValue({required this.id, required this.name});

  factory DnaValue.fromJson(Map<String, dynamic> j) =>
      DnaValue(id: j['id'] as String, name: (j['name'] ?? '') as String);
}

class DnaAttribute {
  final String id;
  final String name;

  /// Multi-value (checkbox) attribute — a design can hold several values
  /// (e.g. Colour). Others are single-pick.
  final bool isMulti;

  /// Free text (no canonical value list), e.g. Range.
  final bool isFreeText;

  final int sortOrder;
  final List<DnaValue> values;

  const DnaAttribute({
    required this.id,
    required this.name,
    this.isMulti = false,
    this.isFreeText = false,
    this.sortOrder = 0,
    this.values = const [],
  });

  factory DnaAttribute.fromJson(Map<String, dynamic> j) => DnaAttribute(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        isMulti: j['is_multi'] == true,
        isFreeText: j['is_free_text'] == true,
        sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
        values: ((j['values'] as List?) ?? const [])
            .map((v) => DnaValue.fromJson(Map<String, dynamic>.from(v as Map)))
            .toList(),
      );
}
