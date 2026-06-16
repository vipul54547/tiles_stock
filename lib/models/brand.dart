/// A brand under a stockist (multi-brand). A manufacturer-stockist can run several
/// brands; each brand is a parent of one or more stock catalogues, with its own
/// design names + stock. How many brands a stockist may create is admin-controlled
/// (the stockist's brand_limit).
class Brand {
  final String id;
  final String name;
  final String logoUrl;
  final int sortOrder;
  final bool isActive;
  final int catalogCount;

  /// True for the auto-created default brand (named after the stockist). Used to
  /// mask that name in outgoing share messages when the stockist is anonymous.
  final bool isDefault;

  /// Moderation status: 'live' (all see), 'correction' (stockist sees to fix,
  /// buyers don't) or 'off' (hidden — never returned to the stockist).
  final String status;

  const Brand({
    required this.id,
    required this.name,
    this.logoUrl = '',
    this.sortOrder = 0,
    this.isActive = true,
    this.catalogCount = 0,
    this.isDefault = false,
    this.status = 'live',
  });

  /// Admin flagged this brand: buyers can't see it until corrected.
  bool get inCorrection => status == 'correction';

  factory Brand.fromJson(Map<String, dynamic> j) => Brand(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        logoUrl: (j['logo_url'] ?? '').toString(),
        sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
        isActive: j['is_active'] as bool? ?? true,
        catalogCount: (j['catalog_count'] as num?)?.toInt() ?? 0,
        isDefault: j['is_default'] as bool? ?? false,
        status: (j['status'] ?? 'live').toString(),
      );
}
