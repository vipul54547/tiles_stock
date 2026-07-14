/// One MASTER design in a stockist's own Design Library: a physical tile with its
/// own image, identified by master design name + size, carrying the design name it
/// has under each of the stockist's brands (aliases). The image is shared across
/// the stockist's OWN brands only — never borrowed from another stockist.
/// (project_stockist_library)
class LibraryEntry {
  final String id;
  final String size;

  /// THE PRINT this product is made from (`print_master.id`) — the artwork, stored ONCE.
  /// [masterName], [size] and [imageUrl] all belong to IT, not to this row: several
  /// products (a Glossy and a Matt, an 8 mm and a 12 mm) share one print and therefore
  /// share a name, a size and a photo. This is what the Library groups its cards by.
  final String printId;

  /// The clean DESIGN name only (e.g. "AVORIO ROSA") — never brand-prefixed.
  /// Lives on the PRINT.
  final String masterName;
  final String imageUrl;

  /// The brand this design belongs to (the master is bound to ONE brand). The
  /// name is resolved LIVE, so renaming the brand updates the display everywhere.
  final String brandId;
  final String brandName;

  /// brand_id -> the design's name under that brand (kept for M multi-brand link
  /// + the brand+name+size image lookup).
  final Map<String, String> aliases;

  /// 📦 THE TILE'S PACKINGS — pieces + weight, and **NO BRAND**.
  ///
  /// A factory **PACKS ONCE and COVERS DIFFERENTLY**: the packing is the pieces and the weight; the
  /// BOX is the corrugated cover wrapped round it, and the cover is what carries the brand. So
  /// pieces/weight were never the brand's — the old model had them on the box, per brand, and that
  /// was wrong.
  ///
  /// A tile may have **several** packings (5-a-box for one market, 4-a-box for another) — but they
  /// all agree on its thickness: 5 × 10.5 kg and 4 × 8.4 kg are both 2.1 kg a piece. One more than
  /// 1 mm away is not another packing, it is a **different tile**.
  /// (docs/PACKING_BOX_HOLD_PLAN.md)
  final List<({String id, int pieces, double weightKg})> packings;

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
    this.printId = '',
    this.imageUrl = '',
    this.brandId = '',
    this.brandName = '',
    this.aliases = const {},
    this.packings = const [],
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
    // An alias row is the brand's NAME for this tile — the word it prints on its cover. Nothing
    // else: how the tile is PACKED has no brand.
    final aliases = <String, String>{};
    for (final a in (j['aliases'] as List?) ?? const []) {
      final m = Map<String, dynamic>.from(a as Map);
      final bid = (m['brand_id'] ?? '').toString();
      final name = (m['name'] ?? '').toString();
      if (bid.isNotEmpty && name.isNotEmpty) aliases[bid] = name;
    }
    final packings = <({String id, int pieces, double weightKg})>[
      for (final p in (j['packings'] as List?) ?? const [])
        (
          id: ((p as Map)['id'] ?? '').toString(),
          pieces: (p['pieces'] as num?)?.toInt() ?? 0,
          weightKg: (p['weight_kg'] as num?)?.toDouble() ?? 0,
        )
    ];
    return LibraryEntry(
      id: (j['id'] ?? '').toString(),
      size: (j['size'] ?? '').toString(),
      masterName: (j['master_design_name'] ?? '').toString(),
      printId: (j['print_id'] ?? '').toString(),
      imageUrl: (j['image_url'] ?? '').toString(),
      brandId: (j['brand_id'] ?? '').toString(),
      brandName: (j['brand_name'] ?? '').toString(),
      aliases: aliases,
      packings: packings,
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
