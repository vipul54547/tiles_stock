class EndUser {
  /// Row UUID (used for updates like activate/deactivate).
  final String uuid;

  /// Auto-generated display ID (e.g. 01A, 02A … 01B). Stored in sequential_id.
  final String id;

  final String companyName;
  final String contactPerson;
  final String email;
  final String phone;

  /// Dialling code (e.g. +91). Defaults to +91 for old data.
  final String countryCode;
  final String city;
  final String gstNumber;

  /// Boost weight (0.00). Stored only; not used for ordering yet.
  final double priority;

  /// Optional tier label (free text). For future use.
  final String endUserType;

  final bool isActive;

  /// Max number of devices this login may be active on at once (admin-set,
  /// editable). Default 1. 0 = unlimited.
  final int deviceLimit;

  /// Admin-set: may this buyer add (claim) catalog links? When false the buyer
  /// sees no Public/Private/Both market tabs and no add-link button — they run
  /// silently in public-only mode and never learn the feature exists.
  final bool canClaimPrivate;

  final int inquiriesToday;
  final DateTime lastInquiryDate;
  final DateTime createdAt;

  EndUser({
    this.uuid = '',
    required this.id,
    required this.companyName,
    required this.contactPerson,
    this.email = '',
    required this.phone,
    this.countryCode = '+91',
    required this.city,
    this.gstNumber = '',
    this.priority = 0,
    this.endUserType = '',
    this.isActive = true,
    this.deviceLimit = 1,
    this.canClaimPrivate = false,
    this.inquiriesToday = 0,
    DateTime? lastInquiryDate,
    DateTime? createdAt,
  })  : lastInquiryDate = lastInquiryDate ?? DateTime.fromMillisecondsSinceEpoch(0),
        createdAt = createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);

  factory EndUser.fromJson(Map<String, dynamic> json) => EndUser(
        uuid:          json['id'] ?? '',
        id:            json['sequential_id'] ?? '',
        companyName:   json['company_name'] ?? '',
        contactPerson: json['contact_person'] ?? '',
        email:         json['email'] ?? '',
        phone:         json['phone'] ?? '',
        countryCode:   json['country_code'] ?? '+91',
        city:          json['city'] ?? '',
        gstNumber:     json['gst_number'] ?? '',
        priority:      (json['priority'] as num?)?.toDouble() ?? 0,
        endUserType:   json['enduser_type'] ?? '',
        isActive:      json['is_active'] ?? true,
        deviceLimit:   json['device_limit'] ?? 1,
        canClaimPrivate: json['can_claim_private'] ?? false,
        inquiriesToday: json['inquiries_today'] ?? 0,
        lastInquiryDate: json['last_inquiry_date'] != null
            ? DateTime.tryParse(json['last_inquiry_date'].toString())
            : null,
        createdAt: json['created_at'] != null
            ? DateTime.tryParse(json['created_at'].toString())
            : null,
      );

  bool get canSendInquiry {
    final today = DateTime.now();
    final sameDay = lastInquiryDate.year == today.year &&
        lastInquiryDate.month == today.month &&
        lastInquiryDate.day == today.day;
    return !sameDay || inquiriesToday < 10;
  }

  int get remainingInquiries {
    final today = DateTime.now();
    final sameDay = lastInquiryDate.year == today.year &&
        lastInquiryDate.month == today.month &&
        lastInquiryDate.day == today.day;
    return sameDay ? (10 - inquiriesToday).clamp(0, 10) : 10;
  }
}
