import '../utils/business_types.dart';

class Stockist {

  /// Display key shown to the user: the real sequential_id, OR the masked public
  /// code when the stockist is anonymous in the public market. NOT stable across
  /// anonymity/market changes — use [uuid] for identity matching (e.g. groups).
  final String id;

  /// Stable internal stockists.id (uuid). Present from the buyer_stockists view;
  /// empty elsewhere. Use this to match a stockist regardless of how [id] is
  /// currently masked.
  final String uuid;

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

  /// Business / actor type: 'M' (Manufacturer/Author), 'T' (Trader) or 'W'
  /// (Wholesaler). A DIFFERENT dimension from [stockistType] (the tier).
  /// Decides the upload behaviour — authors vs importers. Defaults to 'M'.
  /// See lib/utils/business_types.dart.
  final String businessType;

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

  /// Max number of stock lists per brand this stockist may create (admin-set).
  /// Default 3 (Premium / Standard / OneTime).
  final int stockListLimit;

  /// White-label branding for the public share-link catalog page. All optional.
  /// [logoUrl] is a Cloudinary URL; [brandColor] a hex string (e.g. #1B4F72);
  /// [mapUrl] a Google Maps link. Hidden for anonymous stockists (except
  /// tagline/brandColor) by the public_catalog RPC.
  final String logoUrl;
  final String bannerUrl;
  final String tagline;
  final String brandColor;
  final String mapUrl;

  /// Admin-controlled: whether the TilesDesign mark shows on this stockist's
  /// banners (the stockist only chooses its position). Default off.
  final bool tdShow;

  final DateTime createdAt;



  Stockist({

    required this.id,

    this.uuid = '',

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

    this.businessType = 'M',

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

    this.stockListLimit = 3,

    this.logoUrl = '',

    this.bannerUrl = '',

    this.tagline = '',

    this.brandColor = '',

    this.mapUrl = '',

    this.tdShow = false,

    required this.createdAt,

  });



  factory Stockist.fromJson(Map<String, dynamic> json) => Stockist(

    id: json['id'],

    uuid: json['uuid'] ?? '',

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

    businessType: ((json['business_type'] as String?)?.trim().isNotEmpty ?? false)
        ? json['business_type']
        : 'M',

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

    stockListLimit: json['stock_list_limit'] ?? 3,

    logoUrl: json['logo_url'] ?? '',

    bannerUrl: json['banner_url'] ?? '',

    tagline: json['tagline'] ?? '',

    brandColor: json['brand_color'] ?? '',

    mapUrl: json['map_url'] ?? '',

    tdShow: json['td_show'] ?? false,

    createdAt: DateTime.parse(json['created_at']),

  );

  /// Trader or Wholesaler — gets the stripped-down external-file import path.
  bool get isImporter => isImporterType(businessType);

  /// Manufacturer — the design author with the full toolkit.
  bool get isManufacturer => isAuthorType(businessType);

}