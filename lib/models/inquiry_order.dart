// A tokenised buyer→stockist ORDER (what the app calls an "inquiry"). One active
// token per buyer↔stockist; it persists through the lifecycle below, with the
// token + Generated/Modified times always shown to both sides.
//
//   draft → confirmed → locked → dispatching → completed   (+ rejected)
//
// `InquiryOrder` carries both the buyer-side fields (stockist identity) and the
// stockist-side fields (buyer identity); the irrelevant side is just empty.

class InquiryOrder {
  final String id;
  final String token;
  final String status;
  final DateTime createdAt;   // "Generated"
  final DateTime updatedAt;   // "Modified"
  final DateTime? confirmedAt;
  final DateTime? lockedAt;

  // Buyer-side (from my_orders): who the order is with.
  final String stockistId;
  final String stockistKey;   // sequential id or masked public code
  final String stockistName;

  // Stockist-side (from my_inquiries): who placed it.
  final String endUserId;
  final String company;
  final String contact;
  final String phone;
  final String countryCode;
  final String city;

  final int lineCount;
  final int totalBoxes;

  /// Designs in this order ({id, name}), for the hub's design filter/preview.
  final List<Map<String, dynamic>> designs;

  InquiryOrder({
    required this.id,
    required this.token,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.confirmedAt,
    this.lockedAt,
    this.stockistId = '',
    this.stockistKey = '',
    this.stockistName = '',
    this.endUserId = '',
    this.company = '',
    this.contact = '',
    this.phone = '',
    this.countryCode = '+91',
    this.city = '',
    this.lineCount = 0,
    this.totalBoxes = 0,
    this.designs = const [],
  });

  static DateTime _dt(dynamic v) =>
      v == null ? DateTime.fromMillisecondsSinceEpoch(0) : DateTime.parse(v.toString());
  static DateTime? _dtn(dynamic v) =>
      v == null ? null : DateTime.tryParse(v.toString());

  factory InquiryOrder.fromJson(Map<String, dynamic> j) => InquiryOrder(
        id:           (j['id'] ?? '').toString(),
        token:        (j['token'] ?? '').toString(),
        status:       (j['status'] ?? 'draft').toString(),
        createdAt:    _dt(j['created_at']),
        updatedAt:    _dt(j['updated_at']),
        confirmedAt:  _dtn(j['confirmed_at']),
        lockedAt:     _dtn(j['locked_at']),
        stockistId:   (j['stockist_id'] ?? '').toString(),
        stockistKey:  (j['stockist_key'] ?? '').toString(),
        stockistName: (j['stockist_name'] ?? '').toString(),
        endUserId:    (j['end_user_id'] ?? '').toString(),
        company:      (j['company'] ?? '').toString(),
        contact:      (j['contact'] ?? '').toString(),
        phone:        (j['phone'] ?? '').toString(),
        countryCode:  (j['country_code'] ?? '+91').toString(),
        city:         (j['city'] ?? '').toString(),
        lineCount:    (j['line_count'] as num?)?.toInt() ?? 0,
        totalBoxes:   (j['total_boxes'] as num?)?.toInt() ?? 0,
        designs:      (j['designs'] as List?)
                ?.map((e) => Map<String, dynamic>.from(e as Map))
                .toList() ??
            const [],
      );

  /// Comma-joined design names (for search + a compact card preview).
  String get designNames =>
      designs.map((d) => (d['name'] ?? '').toString()).where((s) => s.isNotEmpty).join(', ');

  bool get isDraft       => status == 'draft';
  bool get isConfirmed   => status == 'confirmed';
  bool get isLocked      => status == 'locked';
  bool get isDispatching => status == 'dispatching';
  bool get isCompleted   => status == 'completed';
  bool get isRejected    => status == 'rejected';

  /// The buyer can still edit the basket only while draft/confirmed.
  bool get buyerEditable => status == 'draft' || status == 'confirmed';

  /// Short human label for the status chip.
  String get statusLabel {
    switch (status) {
      case 'confirmed':   return 'Confirmed';
      case 'locked':      return 'Locked';
      case 'dispatching': return 'Dispatching';
      case 'completed':   return 'Completed';
      case 'rejected':    return 'Rejected';
      default:            return 'Draft';
    }
  }
}
