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
  final List<String> faceImageUrls;
  final String stockistId;
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
    required this.faceImageUrls,
    required this.stockistId,
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
        faceImageUrls: List<String>.from(json['face_image_urls']),
        stockistId: json['stockist_id'],
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
        'face_image_urls': faceImageUrls,
        'stockist_id': stockistId,
        'updated_at': updatedAt.toIso8601String(),
        'quality': quality,
        'stock_type': stockType,
      };
}
