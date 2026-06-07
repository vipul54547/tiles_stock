class StockIn {
  final String id;
  final String designId;
  final String stockistId;
  final int quantity;
  final String pdfFilename;
  final String size;
  final String quality;
  final DateTime createdAt;

  StockIn({
    required this.id,
    required this.designId,
    required this.stockistId,
    required this.quantity,
    required this.pdfFilename,
    required this.size,
    required this.quality,
    required this.createdAt,
  });

  factory StockIn.fromJson(Map<String, dynamic> json) => StockIn(
        id: json['id'],
        designId: json['design_id'],
        stockistId: json['stockist_id'],
        quantity: json['quantity_added'],
        pdfFilename: json['pdf_filename'] ?? '',
        size: json['size'] ?? '',
        quality: json['quality'] ?? '',
        createdAt: DateTime.parse(json['created_at']),
      );
}
