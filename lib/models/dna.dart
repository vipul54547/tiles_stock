// Design DNA = the dynamic searchable-attribute system (admin canonical values
// + per-stockist aliases, generalising Surface). See project_design_dna_engine.

class DnaValue {
  final String id;
  final String name;

  /// For a value of a DEPENDENT attribute: the parent value it belongs to
  /// (e.g. "Carara".parentValueId = the "Marble" value). Null otherwise.
  final String? parentValueId;

  /// True for the STOCKIST'S OWN free-text value (editable / deletable); false for an admin
  /// canonical. Only the pickers that offer edit/delete care about this.
  final bool isOwn;

  const DnaValue(
      {required this.id,
      required this.name,
      this.parentValueId,
      this.isOwn = false});

  factory DnaValue.fromJson(Map<String, dynamic> j) => DnaValue(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        parentValueId: (j['parent_value_id'] as String?),
        isOwn: j['is_own'] == true,
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

  /// A value-list attribute where, after picking a value, the stockist can add a
  /// free-text word tied to THAT value (e.g. Punch Type = Wave → "water punch").
  /// Forces mapping off. (project_dna_cascade_mapping)
  final bool freeTextDetail;

  /// 🖼️ WHERE this attribute is STORED — `'print'` or `'product'`.
  ///
  /// **IMAGE DNA lives on the PRINT** (`print_dna`): Look Type ▸ Natural Name · Design Joint ·
  /// Print Type · Colour. They describe the ARTWORK, so they belong to the artwork and not to a
  /// piece cut from it. Tag the print `1001` once and **all three of its pieces (Matt, Carving,
  /// GHR) carry it** — the Matt cannot be "white marble, bookmatch" while the Carving is something
  /// else. A fork (a second thickness of one print) inherits it for free.
  ///
  /// Everything else describes the PIECE and stays on it (`library_dna`).
  /// (20260714d_image_dna_lives_on_the_print · `dna_attributes.scope`)
  final String scope;

  /// When non-null, this attribute applies ONLY to these tile_types (bodies) — e.g. Body Colour is
  /// for {Full Body, Colour Body} only. Null ⇒ every body. (`dna_attributes.tile_type_gate`)
  final List<String>? tileTypeGate;

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
    this.freeTextDetail = false,
    this.scope = 'product',
    this.tileTypeGate,
    this.values = const [],
  });

  bool get isDependent => parentAttributeId != null;

  /// This attribute describes the ARTWORK, not the piece. See [scope].
  bool get isPrintDna => scope == 'print';

  /// Does this attribute apply to a tile whose body is [tileType]? A null gate applies to all.
  bool appliesToBody(String tileType) =>
      tileTypeGate == null || tileTypeGate!.contains(tileType);

  factory DnaAttribute.fromJson(Map<String, dynamic> j) => DnaAttribute(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        isMulti: j['is_multi'] == true,
        isFreeText: j['is_free_text'] == true,
        showInFacets: j['show_in_facets'] == true,
        sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
        allowMapping: j['allow_mapping'] != false, // default true
        parentAttributeId: (j['parent_attribute_id'] as String?),
        freeTextDetail: j['free_text_detail'] == true,
        scope: (j['scope'] ?? 'product').toString(),
        tileTypeGate: (j['tile_type_gate'] as List?)
            ?.map((e) => e.toString())
            .toList(),
        values: ((j['values'] as List?) ?? const [])
            .map((v) => DnaValue.fromJson(Map<String, dynamic>.from(v as Map)))
            .toList(),
      );
}
