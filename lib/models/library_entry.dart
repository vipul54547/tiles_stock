/// One MASTER design in a stockist's own Design Library: a physical tile with its
/// own image, identified by master design name + size, carrying the design name it
/// has under each of the stockist's brands (aliases). The image is shared across
/// the stockist's OWN brands only — never borrowed from another stockist.
/// (project_stockist_library)
class LibraryEntry {
  final String id;
  final String size;

  /// The clean DESIGN name only (e.g. "AVORIO ROSA") — never brand-prefixed.
  final String masterName;
  final String imageUrl;

  /// The brand this design belongs to (the master is bound to ONE brand). The
  /// name is resolved LIVE, so renaming the brand updates the display everywhere.
  final String brandId;
  final String brandName;

  /// brand_id -> the design's name under that brand (kept for M multi-brand link
  /// + the brand+name+size image lookup).
  final Map<String, String> aliases;

  /// THE BOX, per brand: brand_id -> how that brand packs this print.
  ///
  /// An alias IS a box (`stockist_library_brand_names` is keyed `(library_id, brand_id)`),
  /// so the same row carries the name stamped on it AND its packing. Brands can pack
  /// differently — the same print may ship 4/box under one brand and 6/box under another —
  /// which is exactly why pieces/weight are NOT on the product.
  /// (docs/BOX_AND_DERIVED_THICKNESS_PLAN.md)
  final Map<String, ({int pieces, double weightKg})> boxes;

  // ── Identity attributes (describe the DESIGN; set once, here in the Library).
  // The stock row (designs) carries only quality + quantity. (identity split)
  final String surfaceType;
  /// in_name: the design's remembered surface word (auto-fills Add Stock).
  final String surfaceLabel;
  /// Base restocking nature {Continuous, One Time, Uncertain}. The effective
  /// value shown to buyers is clamped by the stock listing's quality.
  final String stockType;
  final String tileType;
  final int piecesPerBox;
  final double boxWeightKg;
  /// DERIVED from the BOX — `weight / (pieces × area × density)`. This is the ONLY way a
  /// thickness is known; it is never typed. Its 0.5 mm BAND is part of product identity
  /// (`thickness_band`). Null when no box carries a spec yet.
  final double? thicknessMm;
  /// When this product was created. Used to tell the ORIGINAL of a print from a product that was
  /// later forked off it by a genuinely different thickness (>1 mm apart) — only the forked one
  /// wears the thickness in brackets.
  final DateTime? createdAt;
  final String colour;
  final String? finishLabel;

  const LibraryEntry({
    required this.id,
    required this.size,
    required this.masterName,
    this.imageUrl = '',
    this.brandId = '',
    this.brandName = '',
    this.aliases = const {},
    this.boxes = const {},
    this.surfaceType = 'None',
    this.surfaceLabel = '',
    this.stockType = 'Uncertain',
    this.tileType = '',
    this.piecesPerBox = 0,
    this.boxWeightKg = 0,
    this.thicknessMm,
    this.createdAt,
    this.colour = '',
    this.finishLabel,
  });

  /// Headline composed LIVE = current brand name + clean design name. Falls back
  /// to the design name alone when the brand is unknown.
  String get displayName =>
      brandName.trim().isEmpty ? masterName : '${brandName.trim()} $masterName';

  factory LibraryEntry.fromJson(Map<String, dynamic> j) {
    // One `aliases` row IS one box: the name stamped on it + how that brand packs it.
    final aliases = <String, String>{};
    final boxes = <String, ({int pieces, double weightKg})>{};
    for (final a in (j['aliases'] as List?) ?? const []) {
      final m = Map<String, dynamic>.from(a as Map);
      final bid = (m['brand_id'] ?? '').toString();
      final name = (m['name'] ?? '').toString();
      if (bid.isEmpty) continue;
      if (name.isNotEmpty) aliases[bid] = name;
      boxes[bid] = (
        pieces: (m['pieces_per_box'] as num?)?.toInt() ?? 0,
        weightKg: (m['box_weight_kg'] as num?)?.toDouble() ?? 0,
      );
    }
    return LibraryEntry(
      id: (j['id'] ?? '').toString(),
      size: (j['size'] ?? '').toString(),
      masterName: (j['master_design_name'] ?? '').toString(),
      imageUrl: (j['image_url'] ?? '').toString(),
      brandId: (j['brand_id'] ?? '').toString(),
      brandName: (j['brand_name'] ?? '').toString(),
      aliases: aliases,
      boxes: boxes,
      surfaceType: (j['surface_type'] ?? 'None').toString(),
      surfaceLabel: (j['surface_label'] ?? '').toString(),
      stockType: (j['stock_type'] ?? 'Uncertain').toString(),
      tileType: (j['tile_type'] ?? '').toString(),
      piecesPerBox: (j['pieces_per_box'] as num?)?.toInt() ?? 0,
      boxWeightKg: (j['box_weight_kg'] as num?)?.toDouble() ?? 0,
      thicknessMm: (j['thickness_mm'] as num?)?.toDouble(),
      createdAt: j['created_at'] == null
          ? null
          : DateTime.tryParse(j['created_at'].toString()),
      colour: (j['colour'] ?? '').toString(),
      finishLabel: (j['finish_label'] as String?)?.trim().isEmpty ?? true
          ? null
          : (j['finish_label'] as String).trim(),
    );
  }
}
