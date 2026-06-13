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

  /// Public anonymity (admin-controlled). When true, public surfaces show
  /// [publicDisplayName] + [publicCode] instead of the real [name] / [id].
  final bool isAnonymous;

  /// Trade/duplicate name shown publicly when anonymous. Empty when not set.
  final String publicDisplayName;

  /// Masked opaque public code (e.g. 7kp4m) shown publicly instead of the
  /// orderly sequential id. Empty when the stockist was never anonymized.
  final String publicCode;

  /// Max number of devices this login may be active on at once (admin-set,
  /// editable). Default 1. 0 = unlimited.
  final int deviceLimit;

  /// Devices currently registered for this login (admin list view only).
  final int deviceCount;

  /// Max number of brands this stockist may create (admin-set). Default 1.
  final int brandLimit;

  /// Brands currently created (admin list view only).
  final int brandCount;

  /// White-label branding for the public share-link catalog page. All optional.
  /// [logoUrl] is a Cloudinary URL; [brandColor] a hex string (e.g. #1B4F72);
  /// [mapUrl] a Google Maps link. Hidden for anonymous stockists (except
  /// tagline/brandColor) by the public_catalog RPC.
  final String logoUrl;
  final String bannerUrl;
  final String tagline;
  final String brandColor;
  final String mapUrl;

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

    this.isAnonymous = false,

    this.publicDisplayName = '',

    this.publicCode = '',

    this.deviceLimit = 1,

    this.deviceCount = 0,

    this.brandLimit = 1,

    this.brandCount = 0,

    this.logoUrl = '',

    this.bannerUrl = '',

    this.tagline = '',

    this.brandColor = '',

    this.mapUrl = '',

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

    isAnonymous: json['is_anonymous'] ?? false,

    publicDisplayName: json['public_display_name'] ?? '',

    publicCode: json['public_code'] ?? '',

    deviceLimit: json['device_limit'] ?? 1,

    deviceCount: json['device_count'] ?? 0,

    brandLimit: json['brand_limit'] ?? 1,

    brandCount: json['brand_count'] ?? 0,

    logoUrl: json['logo_url'] ?? '',

    bannerUrl: json['banner_url'] ?? '',

    tagline: json['tagline'] ?? '',

    brandColor: json['brand_color'] ?? '',

    mapUrl: json['map_url'] ?? '',

    createdAt: DateTime.parse(json['created_at']),

  );

}