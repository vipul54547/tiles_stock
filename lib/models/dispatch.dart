class Dispatch {
  final String id;
  final String designId;
  final String stockistId;
  final int quantity;
  final String buyerName;
  final String notes;
  final DateTime createdAt;

  Dispatch({
    required this.id,
    required this.designId,
    required this.stockistId,
    required this.quantity,
    required this.buyerName,
    required this.notes,
    required this.createdAt,
  });

  factory Dispatch.fromJson(Map<String, dynamic> json) => Dispatch(
        id: json['id'],
        designId: json['design_id'],
        stockistId: json['stockist_id'],
        quantity: json['quantity_dispatched'],
        buyerName: json['buyer_name'],
        notes: json['notes'] ?? '',
        createdAt: DateTime.parse(json['created_at']),
      );
}
