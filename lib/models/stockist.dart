class Stockist {

  final String id;

  final String name;

  final String email;

  final String phone;

  /// Dialling code (e.g. +91). Defaults to +91 for old data.
  final String countryCode;

  final String city;

  final String state;

  final String address;

  /// Display/boost weight for this stockist (stored as 0.00). Not yet used for
  /// any ordering — kept for future use.
  final double priority;

  /// Optional GST number.
  final String gstNumber;

  /// Optional tier label (e.g. Gold / Platinum / Silver). Free text, for
  /// future use.
  final String stockistType;

  final bool isActive;

  /// Whether the stockist appears in the public in-app market. False = the
  /// stockist is hidden from the market and reachable only via their share link.
  final bool isListed;

  /// Unguessable token that powers the stockist's public web catalog link.
  final String shareToken;

  /// Admin-granted permission to create PRIVATE catalogs (Father & Child).
  /// Default false — public catalogs are always allowed.
  final bool canCreatePrivateCatalog;

  final DateTime createdAt;



  Stockist({

    required this.id,

    required this.name,

    required this.email,

    required this.phone,

    this.countryCode = '+91',

    required this.city,

    required this.state,

    required this.address,

    this.priority = 0,

    this.gstNumber = '',

    this.stockistType = '',

    this.isActive = true,

    this.isListed = true,

    this.shareToken = '',

    this.canCreatePrivateCatalog = false,

    required this.createdAt,

  });



  factory Stockist.fromJson(Map<String, dynamic> json) => Stockist(

    id: json['id'],

    name: json['name'],

    email: json['email'],

    phone: json['phone'],

    countryCode: json['country_code'] ?? '+91',

    city: json['city'],

    state: json['state'],

    address: json['address'],

    priority: (json['priority'] as num?)?.toDouble() ?? 0,

    gstNumber: json['gst_number'] ?? '',

    stockistType: json['stockist_type'] ?? '',

    isActive: json['is_active'] ?? true,

    isListed: json['is_listed'] ?? true,

    shareToken: json['share_token'] ?? '',

    canCreatePrivateCatalog: json['can_create_private_catalog'] ?? false,

    createdAt: DateTime.parse(json['created_at']),

  );

}