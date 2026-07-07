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
  /// Per-inquiry connection code (C-<unique><DDMM>) shared in WhatsApp so the
  /// stockist can match an order to its conversation. (project_dispatch_order_redesign)
  final String connectionCode;
  /// Free-text label the stockist writes for who the order is for (no profile).
  final String customerHint;
  /// Where the order came from: app | web | walkin | stockist.
  final String source;
  final String status;
  final DateTime createdAt;   // "Generated"
  final DateTime updatedAt;   // "Modified"
  final DateTime? confirmedAt;
  final DateTime? lockedAt;

  // H_Quantity (Hold model). Boxes the stockist has HELD for this order — they
  // drop off the buyer-facing F_Stock and stay held until un-held or dispatched.
  // Summed from inquiry_items.held_qty; 0 when nothing is held.
  final int heldBoxes;

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
  final int totalBoxes;    // ordered
  final int dispatchedBoxes;
  final int remainingBoxes; // ordered − dispatched

  /// Designs in this order ({id, name}), for the hub's design filter/preview.
  final List<Map<String, dynamic>> designs;

  /// Non-default brand names present in this order (multi-brand hub filter).
  final List<String> brands;

  InquiryOrder({
    required this.id,
    required this.token,
    this.connectionCode = '',
    this.customerHint = '',
    this.source = 'app',
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.confirmedAt,
    this.lockedAt,
    this.heldBoxes = 0,
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
    this.dispatchedBoxes = 0,
    this.remainingBoxes = 0,
    this.designs = const [],
    this.brands = const [],
  });

  static DateTime _dt(dynamic v) =>
      v == null ? DateTime.fromMillisecondsSinceEpoch(0) : DateTime.parse(v.toString());
  static DateTime? _dtn(dynamic v) =>
      v == null ? null : DateTime.tryParse(v.toString());

  factory InquiryOrder.fromJson(Map<String, dynamic> j) => InquiryOrder(
        id:           (j['id'] ?? '').toString(),
        token:        (j['token'] ?? '').toString(),
        connectionCode: (j['connection_code'] ?? '').toString(),
        customerHint:   (j['customer_hint'] ?? '').toString(),
        source:         (j['source'] ?? 'app').toString(),
        status:       (j['status'] ?? 'draft').toString(),
        createdAt:    _dt(j['created_at']),
        updatedAt:    _dt(j['updated_at']),
        confirmedAt:  _dtn(j['confirmed_at']),
        lockedAt:     _dtn(j['locked_at']),
        heldBoxes:    (j['held_boxes'] as num?)?.toInt() ?? 0,
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
        dispatchedBoxes: (j['dispatched_boxes'] as num?)?.toInt() ?? 0,
        remainingBoxes:  (j['remaining_boxes'] as num?)?.toInt() ?? 0,
        designs:      (j['designs'] as List?)
                ?.map((e) => Map<String, dynamic>.from(e as Map))
                .toList() ??
            const [],
        brands:       (j['brands'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
      );

  /// Comma-joined design names (for search + a compact card preview).
  String get designNames =>
      designs.map((d) => (d['name'] ?? '').toString()).where((s) => s.isNotEmpty).join(', ');

  /// This order currently has boxes held (H_Quantity > 0).
  bool get isHeld => heldBoxes > 0;

  bool get isDraft       => status == 'draft';
  bool get isSent        => status == 'sent';
  bool get isLocked      => status == 'locked';
  bool get isDispatching => status == 'dispatching';
  bool get isCompleted   => status == 'completed';
  bool get isRejected    => status == 'rejected';

  /// The buyer can still edit the basket only while it's an open inquiry
  /// (draft/sent). Once the stockist confirms (locked) it is frozen.
  bool get buyerEditable =>
      status == 'draft' || status == 'sent' || status == 'confirmed';

  /// Short human label for the status chip. The buyer "sends" an inquiry; the
  /// stockist's lock is the real "Confirmed" (the supplier accepted it).
  String get statusLabel {
    switch (status) {
      case 'sent':        return 'Sent';
      case 'confirmed':   return 'Sent';        // legacy buyer-confirm == sent
      case 'locked':      return 'Confirmed';   // supplier accepted the order
      case 'dispatching': return 'Dispatching';
      case 'completed':   return 'Completed';
      case 'rejected':    return 'Rejected';
      default:            return 'Draft';
    }
  }
}
