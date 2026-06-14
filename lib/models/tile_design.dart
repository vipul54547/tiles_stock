class TileDesign {
  final String id;
  final String name;
  final String size;
  final int boxQuantity;
  final String surfaceType;
  /// Original finish text from the PDF when it isn't one of [kFinishes]
  /// (e.g. "Punch Ghr", "Lustra"). Null for standard finishes. Shown as a badge.
  final String? finishLabel;
  final int piecesPerBox;
  final double boxWeightKg;
  final double thicknessMm;
  final String colour;
  final double boxPrice;
  /// Body type (PGVT & GVT, Porcelain, Ceramic, Full Body, DC, Colour Body).
  /// Empty for legacy designs uploaded before this field existed.
  final String tileType;
  final List<String> faceImageUrls;
  final String stockistId;
  /// The seller's display name as the buyer should see it — the real name, or
  /// the masked trade name when the stockist is anonymous (from the
  /// `market_designs` view's `stockist_display_name`). Empty when unknown.
  final String stockistName;
  /// The stock catalog this design belongs to (Father & Child). Null for legacy
  /// rows; the stockist's default public catalog otherwise.
  final String? catalogId;
  final DateTime updatedAt;
  final String quality;
  final String stockType;
  /// When the design was first listed — drives the "new designs first" signal
  /// in the catalog ranking. Falls back to [updatedAt] when absent.
  final DateTime createdAt;
  /// The owning stockist's priority (0.00 default). One ingredient of the
  /// catalog ranking; never shown to buyers.
  final double stockistPriority;

  TileDesign({
    required this.id,
    required this.name,
    required this.size,
    required this.boxQuantity,
    required this.surfaceType,
    this.finishLabel,
    required this.piecesPerBox,
    required this.boxWeightKg,
    required this.thicknessMm,
    required this.colour,
    required this.boxPrice,
    this.tileType = '',
    required this.faceImageUrls,
    required this.stockistId,
    this.stockistName = '',
    this.catalogId,
    required this.updatedAt,
    required this.quality,
    required this.stockType,
    DateTime? createdAt,
    this.stockistPriority = 0,
  }) : createdAt = createdAt ?? updatedAt;

  factory TileDesign.fromJson(Map<String, dynamic> json) => TileDesign(
        id: json['id'],
        name: json['name'],
        size: json['size'],
        boxQuantity: json['box_quantity'],
        surfaceType: json['surface_type'],
        finishLabel: json['finish_label'],
        piecesPerBox: json['pieces_per_box'],
        boxWeightKg: (json['box_weight_kg'] as num).toDouble(),
        thicknessMm: (json['thickness_mm'] as num).toDouble(),
        colour: json['colour'],
        boxPrice: (json['box_price'] as num).toDouble(),
        tileType: json['tile_type'] ?? '',
        faceImageUrls: List<String>.from(json['face_image_urls']),
        stockistId: json['stockist_id'],
        stockistName: json['stockist_display_name'] ?? '',
        catalogId: json['catalog_id'] as String?,
        updatedAt: DateTime.parse(json['updated_at']),
        quality: json['quality'] ?? 'Standard',
        stockType: json['stock_type'] ?? 'Regular',
        createdAt: json['created_at'] != null
            ? DateTime.tryParse(json['created_at'].toString())
            : null,
        stockistPriority:
            (json['stockist_priority'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'size': size,
        'box_quantity': boxQuantity,
        'surface_type': surfaceType,
        'finish_label': finishLabel,
        'pieces_per_box': piecesPerBox,
        'box_weight_kg': boxWeightKg,
        'thickness_mm': thicknessMm,
        'colour': colour,
        'box_price': boxPrice,
        'tile_type': tileType,
        'face_image_urls': faceImageUrls,
        'stockist_id': stockistId,
        'updated_at': updatedAt.toIso8601String(),
        'quality': quality,
        'stock_type': stockType,
      };
}

/// Search-synonym taxonomy for SMART search: typing any term matches designs
/// whose name/finish contains ANY term in the same group — bridging languages
/// (bianco↔white), marble names (carrara→white), materials (cemento→concrete),
/// wood (legno/rovere), finishes (lappato→sugar) and shapes. Marble/material
/// names are folded into their colour group so a colour search also surfaces
/// them. Extend freely. (Source: curated tile-trade vocabulary.)
const Map<String, List<String>> kSearchSynonyms = {
  'white': ['white', 'bianco', 'blanco', 'snow', 'alabaster', 'offwhite',
      'chalk', 'ivory', 'carrara', 'statuario', 'satvario', 'calacatta',
      'arabescato', 'michelangelo', 'thassos', 'volakas'],
  'grey': ['grey', 'gray', 'grigio', 'gris', 'charcoal', 'graphite',
      'anthracite', 'antracite', 'piombo', 'silver', 'argento', 'platino',
      'bardiglio', 'fiorito', 'tundra'],
  'black': ['black', 'nero', 'negro', 'midnight', 'obsidian', 'marquina',
      'portoro', 'laurent'],
  'beige': ['beige', 'cream', 'crema', 'avorio', 'marfil', 'almond', 'sand',
      'sabbia', 'vaniglia', 'biscuit', 'ecru', 'travertino', 'travertine',
      'emperador', 'perlato', 'breccia', 'botticino', 'diano', 'pulpis'],
  'brown': ['brown', 'marrone', 'noce', 'coffee', 'moka', 'chocolate',
      'bronze', 'bronzo', 'taupe', 'wenge', 'terracotta', 'cotto'],
  'gold': ['gold', 'golden', 'oro', 'dorato', 'brass', 'ottone', 'honey',
      'miele'],
  'blue': ['blue', 'blu', 'azzurro', 'azul', 'navy', 'cobalt', 'cobalto',
      'teal', 'turquoise', 'indigo', 'ocean'],
  'green': ['green', 'verde', 'sage', 'emerald', 'smeraldo', 'mint', 'olive',
      'oliva', 'moss', 'jade'],
  'pink': ['pink', 'rosa'],
  'red': ['red', 'rosso'],
  'concrete': ['concrete', 'cement', 'cemento', 'microcement', 'resin',
      'resina', 'plaster', 'beton'],
  'metal': ['metal', 'metallic', 'corten', 'ferro', 'steel', 'titanium',
      'ossido'],
  'terrazzo': ['terrazzo', 'palladiana', 'venetian', 'stracciatella', 'ceppo'],
  'stone': ['stone', 'limestone', 'pietra', 'basalt', 'slate', 'ardesia',
      'quartzite', 'quartz', 'bluestone', 'porphyry', 'porfido', 'luserna'],
  'wood': ['wood', 'legno', 'timber', 'plank', 'rovere', 'oak', 'walnut',
      'cedar', 'parquet', 'hardwood', 'bamboo', 'chestnut', 'castagno'],
  'glossy': ['glossy', 'shiny', 'polished', 'levigato', 'pulido', 'lucido'],
  'matt': ['matt', 'matte', 'honed', 'satinato', 'satina'],
  'sugar': ['sugar', 'lappato', 'semipolished'],
  'rough': ['rough', 'textured', 'structured', 'strutturato', 'antislip',
      'flamed', 'bocciardato', 'bushhammered'],
  'slab': ['slab', 'slabs', 'gvt', 'pgvt', 'jumbo', 'maxi'],
  'subway': ['subway', 'metro', 'brick', 'briquette'],
  'mosaic': ['mosaic', 'hexagonal', 'hexagon', 'esagono', 'herringbone',
      'chevron'],
};

/// Expands a (lowercased) query to its synonym group(s) so search bridges
/// languages/materials. Always includes the original query. Only expands
/// queries of 3+ chars to avoid spurious short-substring hits.
Set<String> expandSearchTerms(String qLower) {
  final terms = <String>{qLower};
  if (qLower.length >= 3) {
    for (final group in kSearchSynonyms.values) {
      if (group.any((t) => t.contains(qLower) || qLower.contains(t))) {
        terms.addAll(group);
      }
    }
  }
  return terms;
}

extension TileDesignSearch on TileDesign {
  /// Whether this design matches a buyer's typed search against the design
  /// name, the standard finish, and the full finish wording (`finishLabel`).
  /// When [smart] is true, colour/material/finish words are expanded via
  /// [kSearchSynonyms] (so "bianco"/"carrara" find white tiles); when false it
  /// is a plain literal substring match. [qLower] must be lowercased.
  bool matchesSearch(String qLower, {bool smart = true}) {
    final terms = smart ? expandSearchTerms(qLower) : {qLower};
    final n = name.toLowerCase();
    final s = surfaceType.toLowerCase();
    final f = finishLabel?.toLowerCase() ?? '';
    return terms.any((t) => n.contains(t) || s.contains(t) || f.contains(t));
  }
}
