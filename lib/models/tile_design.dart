class TileDesign {
  final String id;
  final String name;
  final String size;
  final int boxQuantity;
  final String surfaceType;
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

  TileDesign({
    required this.id,
    required this.name,
    required this.size,
    required this.boxQuantity,
    required this.surfaceType,
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
  });

  factory TileDesign.fromJson(Map<String, dynamic> json) => TileDesign(
        id: json['id'],
        name: json['name'],
        size: json['size'],
        boxQuantity: json['box_quantity'],
        surfaceType: json['surface_type'],
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
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'size': size,
        'box_quantity': boxQuantity,
        'surface_type': surfaceType,
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
