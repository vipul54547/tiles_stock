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

  // H_Quantity booking (Phase 2). When the stockist confirms (locks) an order it
  // becomes an OFFER: boxes reserved until [guaranteeUntil]. The buyer ACCEPTs to
  // turn the time-limited reservation into a both-side lock ([acceptedAt]); if no
  // one accepts before [guaranteeUntil], the reservation auto-releases.
  final DateTime? guaranteeUntil;
  final DateTime? acceptedAt;
  final int? guaranteeDays;

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
    this.guaranteeUntil,
    this.acceptedAt,
    this.guaranteeDays,
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
        guaranteeUntil: _dtn(j['guarantee_until']),
        acceptedAt:     _dtn(j['accepted_at']),
        guaranteeDays:  (j['guarantee_days'] as num?)?.toInt(),
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
        brands:       (j['brands'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
      );

  /// Comma-joined design names (for search + a compact card preview).
  String get designNames =>
      designs.map((d) => (d['name'] ?? '').toString()).where((s) => s.isNotEmpty).join(', ');

  /// The buyer has accepted the stockist's offer (both-side lock).
  bool get isAccepted => acceptedAt != null;

  /// A still-running guarantee window the buyer can act on.
  bool get reservationActive =>
      isLocked && !isAccepted && guaranteeUntil != null &&
      guaranteeUntil!.isAfter(DateTime.now());

  /// The offer lapsed: locked, never accepted, window passed.
  bool get reservationExpired =>
      isLocked && !isAccepted && guaranteeUntil != null &&
      !guaranteeUntil!.isAfter(DateTime.now());

  /// Whole days left in the guarantee window (0 once it has passed).
  int get daysLeft {
    if (guaranteeUntil == null) return 0;
    final diff = guaranteeUntil!.difference(DateTime.now());
    return diff.isNegative ? 0 : diff.inHours ~/ 24 + (diff.inHours % 24 == 0 ? 0 : 1);
  }

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
