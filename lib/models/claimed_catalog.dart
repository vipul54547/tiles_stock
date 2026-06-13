// Father & Child Phase 2: the link between a buyer (end user) and a stockist's
// catalog they have claimed via a share link. A claimed PRIVATE catalog lands in
// the buyer's in-app "Closed Market" (Private tab).

/// A catalog the buyer has claimed — shown in the buyer's Private/Closed Market.
class ClaimedCatalog {
  final String catalogId;
  final String name;
  final String visibility; // 'public' | 'private'
  final String stockistKey; // masked when the stockist is anonymous
  final String stockistName; // masked display name when anonymous
  final String stockistCity;
  /// Non-default brand name + logo (multi-brand). Empty when the catalogue is on
  /// the stockist's default brand (single-brand → show the company as before).
  final String brandName;
  final String brandLogo;
  final int designCount;
  final DateTime? claimedAt;

  const ClaimedCatalog({
    required this.catalogId,
    required this.name,
    required this.visibility,
    required this.stockistKey,
    required this.stockistName,
    required this.stockistCity,
    this.brandName = '',
    this.brandLogo = '',
    required this.designCount,
    required this.claimedAt,
  });

  bool get isPrivate => visibility == 'private';

  factory ClaimedCatalog.fromJson(Map<String, dynamic> j) => ClaimedCatalog(
        catalogId: j['catalog_id'] as String,
        name: (j['catalog_name'] as String?) ?? '',
        visibility: (j['visibility'] as String?) ?? 'private',
        stockistKey: (j['stockist_key'] as String?) ?? '',
        stockistName: (j['stockist_display_name'] as String?) ?? '',
        stockistCity: (j['stockist_city'] as String?) ?? '',
        brandName: (j['brand_name'] as String?) ?? '',
        brandLogo: (j['brand_logo'] as String?) ?? '',
        designCount: (j['design_count'] as num?)?.toInt() ?? 0,
        claimedAt: j['claimed_at'] != null
            ? DateTime.tryParse(j['claimed_at'].toString())
            : null,
      );
}

/// A buyer who has claimed one of the calling stockist's catalogs — shown on the
/// stockist side so they can see who joined their Private Showroom and revoke.
class CatalogClaimer {
  final String catalogId;
  final String catalogName;
  final String visibility;
  final String endUserId;
  final String company;
  final String contact;
  final String phone;
  final String city;
  final DateTime? claimedAt;

  const CatalogClaimer({
    required this.catalogId,
    required this.catalogName,
    required this.visibility,
    required this.endUserId,
    required this.company,
    required this.contact,
    required this.phone,
    required this.city,
    required this.claimedAt,
  });

  factory CatalogClaimer.fromJson(Map<String, dynamic> j) => CatalogClaimer(
        catalogId: j['catalog_id'] as String,
        catalogName: (j['catalog_name'] as String?) ?? '',
        visibility: (j['visibility'] as String?) ?? 'private',
        endUserId: j['end_user_id'] as String,
        company: (j['buyer_company'] as String?) ?? '',
        contact: (j['buyer_contact'] as String?) ?? '',
        phone: (j['buyer_phone'] as String?) ?? '',
        city: (j['buyer_city'] as String?) ?? '',
        claimedAt: j['claimed_at'] != null
            ? DateTime.tryParse(j['claimed_at'].toString())
            : null,
      );
}
